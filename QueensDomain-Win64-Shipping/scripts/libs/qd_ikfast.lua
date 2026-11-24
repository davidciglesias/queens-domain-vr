-- qd_ikfast (s115, option ik_fast_math): faster copies of per-frame steps of uevrlib libs/ik.lua's two-bone solve
-- (rotateShoulder / rotateElbow incl. alignBoneAxisToDirCS, getMeshOutward) and of our own forearm-twist math.
-- Same formulas, thresholds and cached choices as the lib, on plain Lua numbers (libs/qd_fastmath) instead of one Kismet
-- ProcessEvent per vector / rotator operation. The lib is NOT modified: qd_ik sets these as fields on the rig instance
-- (an instance field wins over the class method) and clears them when the option is off, so the lib's own code runs.
-- Only the paths our rig uses are copied (smoothing 0, no wrist influence on the elbow pole); anything else, and any
-- error (logged once, then fast math stays off), falls through to the lib's method.
-- Pure math at the top (unit tested by tools/test_qd_ikfast.lua), engine glue below.
-- Copyright (C) 2026 Queen's Domain VR contributors. AGPL-3.0 (see LICENSE).
local M = {}

local okF, FM = pcall(require, "libs/qd_fastmath")
if not okF then FM = require("qd_fastmath") end

local sqrt, acos, asin, atan, abs, sin, cos = math.sqrt, math.acos, math.asin, math.atan, math.abs, math.sin, math.cos
local R2D = 180.0 / math.pi
local quatFromRot, rotateVec, unrotateVec, rotAxis, composeRot = FM.quatFromRot, FM.rotateVec, FM.unrotateVec, FM.rotAxis, FM.composeRot
local projectOnPlane = FM.projectOnPlane

M.on = false        -- set by qd_ik from the option
M.failed = nil      -- first error message (fast math then stays off)
M.MIN_SWING = 0.02  -- libs/ik.lua IK_MIN_SWING_DEG
M.MIN_TWIST = 0.02  -- libs/ik.lua IK_MIN_TWIST_DEG
M.deadband = 0.0    -- libs/ik.lua ALIGN_SWING_DEADBAND_DEG (0.6 while a scope is active, same callback)
M.calls, M.fallbacks = 0, 0

-- lib safeNormalize (math_lib.vectorSafeNormalize): zero vector below length 1e-4
local function norm(x, y, z)
	local l = sqrt(x * x + y * y + z * z)
	if l < 0.0001 then return 0.0, 0.0, 0.0 end
	local k = 1.0 / l
	return x * k, y * k, z * k
end
M.norm = norm
-- lib vectorLengthLessThan(v, 0.0001)
local function tiny(x, y, z) return x * x + y * y + z * z < 1e-8 end

-- math_lib.rotatorFromAxisAndAngle (the lib's own quat -> Euler formula, kept as is)
function M.rotFromAxisAngle(ax, ay, az, angleDeg)
	local len = sqrt(ax * ax + ay * ay + az * az)
	if len < 1e-12 then return 0.0, 0.0, 0.0 end
	ax, ay, az = ax / len, ay / len, az / len
	local half = angleDeg * (math.pi / 360.0)
	local s = sin(half)
	local qw, qx, qy, qz = cos(half), ax * s, ay * s, az * s
	local sinp = 2.0 * ((qw * qy) - (qz * qx))
	if sinp > 1.0 then sinp = 1.0 elseif sinp < -1.0 then sinp = -1.0 end
	return -asin(sinp) * R2D, atan(2.0 * ((qw * qz) + (qx * qy)), 1.0 - (2.0 * ((qy * qy) + (qz * qz)))) * R2D,
		-atan(2.0 * ((qw * qx) + (qy * qz)), 1.0 - (2.0 * ((qx * qx) + (qy * qy)))) * R2D
end
local rotFromAxisAngle = M.rotFromAxisAngle

-- dot(normalize(rotate(localDir, rot)), desired): the lib's swing-order score
local function scoreDir(p, y, r, lx, ly, lz, dx, dy, dz)
	local qx, qy, qz, qw = quatFromRot(p, y, r)
	local ax, ay, az = norm(rotateVec(qx, qy, qz, qw, lx, ly, lz))
	return ax * dx + ay * dy + az * dz
end
-- dot(normalize(project(axis(rot) * sign, desired)), desiredPole): the lib's twist-order score
local function scorePole(p, y, r, axis, sign, dx, dy, dz, ex, ey, ez)
	local ax, ay, az = rotAxis(p, y, r, axis)
	ax, ay, az = norm(projectOnPlane(ax * sign, ay * sign, az * sign, dx, dy, dz))
	return ax * ex + ay * ey + az * ez
end

-- libs/ik.lua alignBoneAxisToDirCS (non-aggressive pole branch, as the lib runs it) on numbers.
-- cur rot (cp, cy, cr), cur bone dir (cdx..; unit or zero), desired dir, pole (CS), axis choice, cached compose orders
-- -> changed (false = keep the current rotator), p, y, r, orderSwing, orderTwist
function M.align(cp, cy, cr, cdx, cdy, cdz, ddx, ddy, ddz, pcx, pcy, pcz, axisChoice, oSw, oTw, deadband)
	if tiny(cdx, cdy, cdz) then return false, 0.0, 0.0, 0.0, oSw, oTw end
	ddx, ddy, ddz = norm(ddx, ddy, ddz)
	if tiny(ddx, ddy, ddz) then return false, 0.0, 0.0, 0.0, oSw, oTw end
	local dot = cdx * ddx + cdy * ddy + cdz * ddz
	if dot > 1.0 then dot = 1.0 elseif dot < -1.0 then dot = -1.0 end
	local swingDeg = acos(dot) * R2D
	local sx, sy, sz = cdy * ddz - cdz * ddy, cdz * ddx - cdx * ddz, cdx * ddy - cdy * ddx
	if tiny(sx, sy, sz) then
		local px, py, pz = norm(pcx, pcy, pcz)
		if tiny(px, py, pz) then px, py, pz = 0.0, 1.0, 0.0 end -- lib VEC_UNIT_Y (= +Y during a solve)
		sx, sy, sz = cdy * pz - cdz * py, cdz * px - cdx * pz, cdx * py - cdy * px
	end
	sx, sy, sz = norm(sx, sy, sz)
	if tiny(sx, sy, sz) then return false, 0.0, 0.0, 0.0, oSw, oTw end
	local eff = swingDeg - (deadband or 0.0)
	if eff < 0.0 then eff = 0.0 end
	if eff < M.MIN_SWING then return false, 0.0, 0.0, 0.0, oSw, oTw end
	local dp, dyw, dr = rotFromAxisAngle(sx, sy, sz, eff)
	local wp, wy, wr
	if oSw == 1 then
		wp, wy, wr = composeRot(dp, dyw, dr, cp, cy, cr)
	elseif oSw == 2 then
		wp, wy, wr = composeRot(cp, cy, cr, dp, dyw, dr)
	else
		local p1, y1, r1 = composeRot(dp, dyw, dr, cp, cy, cr)
		local p2, y2, r2 = composeRot(cp, cy, cr, dp, dyw, dr)
		local qx, qy, qz, qw = quatFromRot(cp, cy, cr)
		local lx, ly, lz = norm(unrotateVec(qx, qy, qz, qw, cdx, cdy, cdz))
		if scoreDir(p2, y2, r2, lx, ly, lz, ddx, ddy, ddz) > scoreDir(p1, y1, r1, lx, ly, lz, ddx, ddy, ddz) then
			oSw, wp, wy, wr = 2, p2, y2, r2
		else
			oSw, wp, wy, wr = 1, p1, y1, r1
		end
	end
	local pole = axisChoice and axisChoice.pole or nil
	if pole == nil then return true, wp, wy, wr, oSw, oTw end
	local pAx, pSg = pole.axis, pole.sign or 1
	local ex, ey, ez = projectOnPlane(pcx, pcy, pcz, ddx, ddy, ddz)
	local el = sqrt(ex * ex + ey * ey + ez * ez)
	if el < 0.15 then return true, wp, wy, wr, oSw, oTw end
	ex, ey, ez = ex / el, ey / el, ez / el
	local ax, ay, az = rotAxis(wp, wy, wr, pAx)
	local cx, cy, cz = projectOnPlane(ax * pSg, ay * pSg, az * pSg, ddx, ddy, ddz)
	local cl = sqrt(cx * cx + cy * cy + cz * cz)
	if cl < 0.15 then return true, wp, wy, wr, oSw, oTw end
	cx, cy, cz = cx / cl, cy / cl, cz / cl
	-- math_lib.signedAngleDegAroundAxis(currentPole, desiredPole, desiredDir)
	local kx, ky, kz = cy * ez - cz * ey, cz * ex - cx * ez, cx * ey - cy * ex
	local tw = atan(ddx * kx + ddy * ky + ddz * kz, cx * ex + cy * ey + cz * ez) * R2D
	if abs(tw) < M.MIN_TWIST then return true, wp, wy, wr, oSw, oTw end
	local tp, ty, tr = rotFromAxisAngle(ddx, ddy, ddz, tw)
	if oTw == 1 then
		local p, y, r = composeRot(tp, ty, tr, wp, wy, wr)
		return true, p, y, r, oSw, oTw
	elseif oTw == 2 then
		local p, y, r = composeRot(wp, wy, wr, tp, ty, tr)
		return true, p, y, r, oSw, oTw
	end
	local p1, y1, r1 = composeRot(tp, ty, tr, wp, wy, wr)
	local p2, y2, r2 = composeRot(wp, wy, wr, tp, ty, tr)
	if scorePole(p2, y2, r2, pAx, pSg, ddx, ddy, ddz, ex, ey, ez) > scorePole(p1, y1, r1, pAx, pSg, ddx, ddy, ddz, ex, ey, ez) then
		return true, p2, y2, r2, oSw, 2
	end
	return true, p1, y1, r1, oSw, 1
end

-- libs/ik.lua getMeshOutward without the wrist-influence branch. Mesh right / forward / up as numbers (the component's
-- rotation axes), anchor = state.anchorPoleInBodySpace {right, fwd, up}, last pole (or nil), reach dir, previous smoothed
-- pole (or nil), left hand? -> pole x, y, z
function M.outward(rx, ry, rz, fx, fy, fz, ux, uy, uz, anchor, lastX, lastY, lastZ, wx, wy, wz, prevX, prevY, prevZ, left)
	local ox, oy, oz
	if lastX ~= nil then ox, oy, oz = lastX, lastY, lastZ
	elseif left then ox, oy, oz = -rx, -ry, -rz
	else ox, oy, oz = rx, ry, rz end
	local a, b, c = anchor.right, anchor.fwd, anchor.up
	local apx, apy, apz = rx * a + fx * b + ux * c, ry * a + fy * b + uy * c, rz * a + fz * b + uz * c
	-- perp = reach x (anchor x reach)
	local c1x, c1y, c1z = apy * wz - apz * wy, apz * wx - apx * wz, apx * wy - apy * wx
	local px, py, pz = wy * c1z - wz * c1y, wz * c1x - wx * c1z, wx * c1y - wy * c1x
	local perpLen = sqrt(px * px + py * py + pz * pz)
	if perpLen >= 0.0001 then
		ox, oy, oz = px / perpLen, py / perpLen, pz / perpLen
		if ox * apx + oy * apy + oz * apz < 0.0 then ox, oy, oz = -ox, -oy, -oz end
	end
	if prevX ~= nil then
		local alpha = (perpLen < 0.30) and 0.90 or 0.72
		local mx, my, mz = prevX * alpha + ox * (1.0 - alpha), prevY * alpha + oy * (1.0 - alpha), prevZ * alpha + oz * (1.0 - alpha)
		local ml = sqrt(mx * mx + my * my + mz * mz)
		if ml > 0.0001 then
			ox, oy, oz = mx / ml, my / ml, mz / ml
			if ox * apx + oy * apy + oz * apz < 0.0 then ox, oy, oz = -ox, -oy, -oz end
			local c2x, c2y, c2z = oy * wz - oz * wy, oz * wx - ox * wz, ox * wy - oy * wx
			local sx, sy, sz = wy * c2z - wz * c2y, wz * c2x - wx * c2z, wx * c2y - wy * c2x
			local sl = sqrt(sx * sx + sy * sy + sz * sz)
			if sl > 0.0001 then
				ox, oy, oz = sx / sl, sy / sl, sz / sl
				if ox * apx + oy * apy + oz * apz < 0.0 then ox, oy, oz = -ox, -oy, -oz end
			end
		end
	end
	return ox, oy, oz
end

-- math_lib.computeTwistDegAroundAxis_Rotators: twist (deg) of rotator B relative to A about a unit axis; nil = bad axis
function M.twistDeg(ap, ay, ar, bp, by, br, kx, ky, kz)
	if kx * kx + ky * ky + kz * kz < 1e-8 then return nil end
	local ax, ayq, az, aw = quatFromRot(ap, ay, ar)
	local bx, byq, bz, bw = quatFromRot(bp, by, br)
	local rw = (bw * aw) + (bx * ax) + (byq * ayq) + (bz * az)
	local rx = (-bw * ax) + (bx * aw) - (byq * az) + (bz * ayq)
	local ry = (-bw * ayq) + (bx * az) + (byq * aw) - (bz * ax)
	local rz = (-bw * az) - (bx * ayq) + (byq * ax) + (bz * aw)
	if rw * rw + rx * rx + ry * ry + rz * rz < 1e-12 then return 0.0 end
	return 2.0 * atan(rx * kx + ry * ky + rz * kz, rw) * R2D
end

-- twist bone rotation (qd_ik twistForearmQD): stored lower-arm-local X / Z axes -> component space, turned about the
-- forearm axis (unit) by deg -> MakeRotFromXZ
function M.twistBoneRot(lqx, lqy, lqz, lqw, xx, xy, xz, zx, zy, zz, ax, ay, az, deg)
	xx, xy, xz = rotateVec(lqx, lqy, lqz, lqw, xx, xy, xz)
	zx, zy, zz = rotateVec(lqx, lqy, lqz, lqw, zx, zy, zz)
	local half = math.rad(deg) * 0.5
	local s = sin(half)
	local tx, ty, tz, tw = ax * s, ay * s, az * s, cos(half)
	xx, xy, xz = rotateVec(tx, ty, tz, tw, xx, xy, xz)
	zx, zy, zz = rotateVec(tx, ty, tz, tw, zx, zy, zz)
	return FM.makeRotFromXZ(xx, xy, xz, zx, zy, zz)
end

---------------------------------------------------------------------------------------------------------------------------
-- engine glue
---------------------------------------------------------------------------------------------------------------------------
local CS = 1 -- EBoneSpaces.ComponentSpace
local log = function() end
M.cls = nil -- the lib's Rig class table (fallback methods), set by qd_ik at create

local function newRot()
	-- Vector3f is what Kismet returns for vectors and rotators (x = Pitch, y = Yaw, z = Roll)
	return Vector3f.new(0.0, 0.0, 0.0)
end

local function fail(where, err)
	if M.failed == nil then
		M.failed = tostring(where) .. ": " .. tostring(err)
		log("[IK] fast math error, back to the lib's math: " .. M.failed)
	end
	M.on = false
end

local function alignMesh(mesh, boneF, childF, dirCS, axisChoice, poleCS, state, kSw, kTw, kRot)
	local cur = mesh:GetBoneRotationByName(boneF, CS)
	if cur == nil then return nil end
	local cp, cy, cr = cur.Pitch, cur.Yaw, cur.Roll
	local cdx, cdy, cdz
	local a = childF ~= nil and mesh:GetBoneLocationByName(boneF, CS) or nil
	local b = childF ~= nil and mesh:GetBoneLocationByName(childF, CS) or nil
	if a ~= nil and b ~= nil then
		cdx, cdy, cdz = norm(b.X - a.X, b.Y - a.Y, b.Z - a.Z)
	elseif axisChoice ~= nil then
		local x, y, z = rotAxis(cp, cy, cr, axisChoice.axis or "X")
		local s = axisChoice.sign or 1
		cdx, cdy, cdz = norm(x * s, y * s, z * s)
	else
		return cur
	end
	local changed, p, y, r, oSw, oTw = M.align(cp, cy, cr, cdx, cdy, cdz, dirCS.X, dirCS.Y, dirCS.Z, poleCS.X, poleCS.Y, poleCS.Z,
		axisChoice, state[kSw], state[kTw], M.deadband)
	state[kSw], state[kTw] = oSw, oTw
	if not changed then return cur end
	local o = state[kRot]
	if o == nil then o = newRot() state[kRot] = o end
	o.x, o.y, o.z = p, y, r
	return o
end

local function setAll(meshList, boneF, rot)
	for _, mesh in ipairs(meshList) do
		if mesh ~= nil then mesh:SetBoneRotationByName(boneF, rot, CS) end
	end
end

-- Rig:rotateShoulder (smoothing 0 path)
function M.rotateShoulder(self, meshList, rootF, jointF, upperDirCS, axisShoulder, poleCS, state, smoothing)
	if M.on and (smoothing or 0) <= 0 and state ~= nil and meshList ~= nil and meshList[1] ~= nil and upperDirCS ~= nil and poleCS ~= nil then
		local ok, rot = pcall(alignMesh, meshList[1], rootF, jointF, upperDirCS, axisShoulder, poleCS, state,
			"composeOrderSwingShoulder", "composeOrderTwistShoulder", "qdRotShoulder")
		if ok then
			M.calls = M.calls + 1
			if rot ~= nil then setAll(meshList, rootF, rot) end
			return
		end
		fail("shoulder", rot)
	end
	M.fallbacks = M.fallbacks + 1
	return M.cls.rotateShoulder(self, meshList, rootF, jointF, upperDirCS, axisShoulder, poleCS, state, smoothing)
end

-- Rig:rotateElbow (smoothing 0 path)
function M.rotateElbow(self, meshList, jointF, endF, lowerDirCS, axisJoint, poleCS, state, smoothing)
	if M.on and (smoothing or 0) <= 0 and state ~= nil and meshList ~= nil and meshList[1] ~= nil and lowerDirCS ~= nil and poleCS ~= nil then
		local ok, rot = pcall(alignMesh, meshList[1], jointF, endF, lowerDirCS, axisJoint, poleCS, state,
			"composeOrderSwingElbow", "composeOrderTwistElbow", "qdRotElbow")
		if ok then
			M.calls = M.calls + 1
			if rot ~= nil then
				setAll(meshList, jointF, rot)
				state.lastLowerDirCS = lowerDirCS
				state.lastElbowCompRot = rot
			end
			return rot
		end
		fail("elbow", rot)
	end
	M.fallbacks = M.fallbacks + 1
	return M.cls.rotateElbow(self, meshList, jointF, endF, lowerDirCS, axisJoint, poleCS, state, smoothing)
end

local function outwardEngine(mesh, shoulderWS, jointWS, reach, compToWorld, solverParams, state)
	local q = compToWorld.Rotation
	local qx, qy, qz, qw = q.X, q.Y, q.Z, q.W
	local rx, ry, rz = rotateVec(qx, qy, qz, qw, 0.0, 1.0, 0.0) -- GetRightVector
	local fx, fy, fz = rotateVec(qx, qy, qz, qw, 1.0, 0.0, 0.0) -- GetForwardVector
	local ux, uy, uz = rotateVec(qx, qy, qz, qw, 0.0, 0.0, 1.0) -- GetUpVector
	if state.anchorPoleInBodySpace == nil then
		local dx, dy, dz = norm(jointWS.X - shoulderWS.X, jointWS.Y - shoulderWS.Y, jointWS.Z - shoulderWS.Z)
		state.anchorPoleInBodySpace = {right = dx * rx + dy * ry + dz * rz, fwd = dx * fx + dy * fy + dz * fz, up = dx * ux + dy * uy + dz * uz}
	end
	local last, prev = state.lastValidPoleWS, state.smOutwardWS
	local lx, ly, lz, px, py, pz
	if last ~= nil then lx, ly, lz = last.X, last.Y, last.Z end
	if prev ~= nil then px, py, pz = prev.X, prev.Y, prev.Z end
	local left = solverParams.hand == ((Handed ~= nil and Handed.Left) or 0)
	local ox, oy, oz = M.outward(rx, ry, rz, fx, fy, fz, ux, uy, uz, state.anchorPoleInBodySpace, lx, ly, lz, reach.X, reach.Y, reach.Z, px, py, pz, left)
	local o = state.qdOutward
	if o == nil then o = Vector3f.new(0.0, 0.0, 0.0) state.qdOutward = o end
	o.X, o.Y, o.Z = ox, oy, oz
	state.smOutwardWS, state.lastValidPoleWS = o, o
	return o
end

-- Rig:getMeshOutward (no wrist influence). orig = the lib's method (qd_ik's outwardQD passes it)
function M.getMeshOutward(orig, self, mesh, shoulderWS, jointWS, reach, compToWorld, ctrlRotCS, allow, infl, wMax, solverParams, state)
	if M.on and state ~= nil and compToWorld ~= nil and reach ~= nil and solverParams ~= nil and shoulderWS ~= nil and jointWS ~= nil
		and not (ctrlRotCS ~= nil and allow and (infl or 0) > 0) then
		local ok, out = pcall(outwardEngine, mesh, shoulderWS, jointWS, reach, compToWorld, solverParams, state)
		if ok then return out end
		fail("outward", out)
	end
	M.fallbacks = M.fallbacks + 1
	return orig(self, mesh, shoulderWS, jointWS, reach, compToWorld, ctrlRotCS, allow, infl, wMax, solverParams, state)
end

-- twist bones (qd_ik twistForearmQD after the twist angle): returns true when done
local function twistEngine(meshList, lowerDirCS, lowerArmRotCS, applied, twistBones, state, fname)
	local lqx, lqy, lqz, lqw = quatFromRot(lowerArmRotCS.Pitch, lowerArmRotCS.Yaw, lowerArmRotCS.Roll)
	local ax, ay, az = lowerDirCS.X or 0.0, lowerDirCS.Y or 0.0, lowerDirCS.Z or 0.0
	for _, entry in ipairs(twistBones) do
		local vecs = state.twistBoneVecs and state.twistBoneVecs[entry.bone]
		if vecs == nil then break end
		if entry._fname == nil then entry._fname = fname(entry.bone) end
		local x, z = vecs.x, vecs.z
		local p, y, r = M.twistBoneRot(lqx, lqy, lqz, lqw, x.X, x.Y, x.Z, z.X, z.Y, z.Z, ax, ay, az, applied * (entry.fraction or 0.0))
		local o = entry._qdRot
		if o == nil then o = newRot() entry._qdRot = o end
		o.x, o.y, o.z = p, y, r
		setAll(meshList, entry._fname, o)
	end
	return true
end
function M.twistBones(meshList, lowerDirCS, lowerArmRotCS, applied, twistBones, state, fname)
	local ok, err = pcall(twistEngine, meshList, lowerDirCS, lowerArmRotCS, applied, twistBones, state, fname)
	if ok then return true end
	fail("twist", err)
	return false
end

function M.init(uevrUtils, logFn)
	if logFn ~= nil then log = logFn end
	if M.inited then return end
	M.inited = true
	-- the lib's scope stability deadband follows this callback (libs/ik.lua enableScopeStability = true)
	pcall(function() uevrUtils.registerUEVRCallback("scope_active_change", function(isActive) M.deadband = isActive and 0.6 or 0.0 end) end)
end

return M
