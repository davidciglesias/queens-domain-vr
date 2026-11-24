-- qd_ik: IK arms (option ik_arms). Wraps uevrlib's libs/ik.lua: a poseable copy of pawn.Arms whose shoulders hang under the
-- headset and whose wrists are solved to the hand meshes that the hands lib already draws on the controllers. The copy's own
-- hand bones are hidden, so weapons, pickups and finger poses stay on the existing hand meshes, untouched.
-- Pure math at the top (unit tested by tools/test_qd_ik.lua), UEVR code below (init/tick/reset).
-- Copyright (C) 2026 Queen's Domain VR contributors. AGPL-3.0 (see LICENSE).
local M = {}

M.DROP = 21.0       -- cm: shoulder line below the eyes
M.BACK = 9.0        -- cm: shoulder line behind the eyes
M.SCALE = 1.2       -- same as the hand meshes (hands_parameters.json)
M.MESH_YAW = -90.0  -- arms mesh faces +Y in component space (pawn.Arms RelativeRotation yaw, logged)
M.DEAD = 30.0       -- deg: the head turns this far before the shoulders follow
M.RATE = 540.0      -- deg/s: how fast the shoulders catch up
M.DRIFT = 20.0      -- deg/s: slow re-centring under the head inside the dead zone
M.RETRY = 2.0       -- s between create attempts
M.REACH = 0.97      -- hands further than this share of the arm length pull the shoulders along
M.MAX_PULL = 12.0   -- cm: limit of that pull
M.BONES = {upperL = "UpperArm_L", upperR = "UpperArm_R", lowerL = "LowerArm_L", lowerR = "LowerArm_R", handL = "Hand_L", handR = "Hand_R"}
M.SOLVERS = {left = "left_arm", right = "right_arm"}
-- s103: place + solve late (post stereo view calc, after UEVR moved the controller / hand meshes for this frame) instead of
-- in the pre-engine tick (controller pose of the previous frame, before the pawn moved: arm ends lag the gloves)
M.LATE = true
M.LATE_VIEW = 1      -- view_index to solve on (native stereo: 2nd eye, both controllers surely updated); -1 = any
M.LATE_MISS = 30     -- frames without a matching view before accepting any view index
M.CAL_PERIOD = 0.0   -- s between wrist re-calibrations (0 = every solve)
M.TWIST = true       -- auto forearm twist bones (discovered by name at create)
M.TWIST_FRACTION = 0.5
M.SAMPLE = false     -- probe: record the rendered glove-to-arm gap at each pre tick (bridge turns it on)
-- s105b wrist gap: hiding the Hand bone collapses every vertex skinned to it, so the wrist ring (shared by forearm and
-- hand) shrinks into the forearm, and the glove (same mesh, forearm collapsed onto its hand bone) has no wrist either ->
-- a see-through gap. false = keep the arm's own hand (it sits exactly on the glove's) and hide only the finger roots.
M.HIDE_HAND = false  -- true = old behaviour (whole hand hidden); live: QD.ik.HIDE_HAND = x then QD.ik.applyHide()
M.FINGER_ROOTS = {"Finger_Index_0", "Finger_Middle_0", "Finger_Ring_0", "Finger_Pinky_0", "Thumb_0"}
-- s111 wrist roll: the lib measured the forearm twist as the raw hand-vs-lower-arm twist (their bone frames differ by ~155
-- deg at rest), wrapped it at +-180 and clamped it at +-100: the twist sat on the clamp at the neutral pose (forearm stops
-- turning) and flipped 100 deg when the raw value crossed 180 (wrist end jumps). Now (qd override, M.QD_TWIST): twist =
-- raw - rest (rest measured at create), unwrapped against the last frame, held (not wrapped) at +-TWIST_MAX.
M.QD_TWIST = true
M.TWIST_MAX = 150.0  -- deg of hand roll vs the forearm before the twist bones stop following (held, no snap)
M.TWIST_WRAP = 270.0 -- deg: the unwrapped twist only re-wraps past this (a full controller spin)
-- s111 elbow follows the hand: the elbow (pole) is pulled towards hand + FOREARM_DIR (glove hand-bone space, hand ->
-- elbow, measured on the game's own arms) so the forearm enters the hand along its natural axis (no 90 deg wrist bend).
M.ELBOW_FOLLOW = 0.0 -- EXPERIMENTAL, off: 1 broke the left arm on the fake (lib pole axes flip, 45-80 cm wrist gap) and raised the right elbow
M.ELBOW_MIN = 0.15   -- share of the forearm length the hand pole must stand off the reach line to count (degenerate)
M.FOREARM_DIR = {0.0, 1.0, 0.0}
M.ELBOW_MAX_DEG = 60.0 -- the hand pole may turn the elbow at most this far from the body pole
-- s115 (option ik_fast_math): libs/qd_ikfast's copies of the lib's per-frame solve steps in plain Lua math (same look,
-- less CPU) set on the rig instance; false = the lib's own methods. Main sets this every tick; applied live.
M.FAST = true

function M.normDeg(a) return (a + 540.0) % 360.0 - 180.0 end

-- a + k*360 nearest to ref
function M.unwrapNear(a, ref)
	if ref == nil then return a end
	return ref + M.normDeg(a - ref)
end

-- forearm twist from the raw lib value: relative to the rest twist, continuous with the previous (unclamped) value, held
-- at +-maxDeg. Returns applied, acc (store acc for the next call).
function M.twistStep(raw, rest, prevAcc, maxDeg, wrapAt)
	local acc = M.unwrapNear(M.normDeg(raw - (rest or 0.0)), prevAcc)
	if math.abs(acc) > (wrapAt or 270.0) then acc = M.normDeg(acc) end
	local m = maxDeg or 150.0
	local applied = acc
	if applied > m then applied = m elseif applied < -m then applied = -m end
	return applied, acc
end

-- elbow pole from the hand: s shoulder, r unit reach dir, h hand, d unit hand->elbow dir, low forearm length, o the
-- body pole (unit, perpendicular to r), w blend weight, minShare = degenerate threshold (share of low). Returns a unit pole
-- perpendicular to r, or o unchanged.
function M.handPole(sx, sy, sz, rx, ry, rz, hx, hy, hz, dx, dy, dz, low, ox, oy, oz, w, minShare, maxDeg)
	if w == nil or w <= 0 then return ox, oy, oz end
	local px, py, pz = hx + dx * low - sx, hy + dy * low - sy, hz + dz * low - sz
	local pr = px * rx + py * ry + pz * rz
	px, py, pz = px - rx * pr, py - ry * pr, pz - rz * pr
	local pl = math.sqrt(px * px + py * py + pz * pz)
	if pl < (minShare or 0.15) * low or pl < 1e-6 then return ox, oy, oz end
	if w > 1 then w = 1 end
	local mx, my, mz = ox * (1 - w) + px / pl * w, oy * (1 - w) + py / pl * w, oz * (1 - w) + pz / pl * w
	local mr = mx * rx + my * ry + mz * rz
	mx, my, mz = mx - rx * mr, my - ry * mr, mz - rz * mr
	local ml = math.sqrt(mx * mx + my * my + mz * mz)
	if ml < 1e-6 then mx, my, mz = px / pl, py / pl, pz / pl else mx, my, mz = mx / ml, my / ml, mz / ml end
	-- stay within maxDeg of the body pole (both are perpendicular to r): a hand pole on the far side (elbow into the chest)
	-- flips the lib's shoulder/elbow pole axes (NaN arm seen live)
	if maxDeg ~= nil then
		local c = mx * ox + my * oy + mz * oz
		local cm = math.cos(math.rad(maxDeg))
		if c < cm then
			local tx, ty, tz = mx - ox * c, my - oy * c, mz - oz * c
			local tl = math.sqrt(tx * tx + ty * ty + tz * tz)
			if tl < 1e-6 then return ox, oy, oz end
			local sm = math.sin(math.rad(maxDeg))
			return ox * cm + tx / tl * sm, oy * cm + ty / tl * sm, oz * cm + tz / tl * sm
		end
	end
	return mx, my, mz
end

-- bones to hide on the IK arm mesh for one side ("L"/"R"): the hand (old) or only the finger roots (s105b)
function M.hideList(side, hideHand, roots)
	if hideHand then return {"Hand_" .. side} end
	local out = {}
	for i, r in ipairs(roots or {}) do out[i] = r .. "_" .. side end
	return out
end

-- late solve: does this post-calc call solve? pending = a pre tick asked for it this frame
function M.lateAccept(pending, viewIndex, want)
	if not pending then return false end
	return want == nil or want < 0 or viewIndex == want
end

-- forearm twist bones from the mesh bone names: contain "twist" and a forearm word, end with the side suffix (_l/_r)
function M.pickTwist(names, side)
	local out = {}
	local suf = "_" .. string.lower(side)
	for _, n in ipairs(names or {}) do
		local l = string.lower(n)
		if string.find(l, "twist", 1, true) and (string.find(l, "lower", 1, true) or string.find(l, "fore", 1, true))
			and string.sub(l, -#suf) == suf then
			out[#out + 1] = n
		end
	end
	return out
end

function M.angleDeg(ax, ay, az, bx, by, bz)
	local la, lb = math.sqrt(ax * ax + ay * ay + az * az), math.sqrt(bx * bx + by * by + bz * bz)
	if la < 1e-9 or lb < 1e-9 then return 0.0 end
	local d = (ax * bx + ay * by + az * bz) / (la * lb)
	if d > 1 then d = 1 elseif d < -1 then d = -1 end
	return math.deg(math.acos(d))
end

-- elbow relative to the shoulder->hand line: drop = cm below the line (+ = down), out = cm away from the body midline
-- side (+ = outward). sx.. shoulder, ex.. elbow, hx.. hand, mx,my = body midline point (world, cm)
function M.elbowPlace(sx, sy, sz, ex, ey, ez, hx, hy, hz, mx, my)
	local dx, dy, dz = hx - sx, hy - sy, hz - sz
	local len2 = dx * dx + dy * dy + dz * dz
	local t = len2 > 1e-9 and ((ex - sx) * dx + (ey - sy) * dy + (ez - sz) * dz) / len2 or 0.0
	local px, py, pz = sx + dx * t, sy + dy * t, sz + dz * t
	local ox, oy = sx - mx, sy - my -- outward direction (horizontal) = midline -> shoulder
	local ol = math.sqrt(ox * ox + oy * oy)
	local out = ol > 1e-9 and ((ex - px) * ox + (ey - py) * oy) / ol or 0.0
	return pz - ez, out
end

-- shoulder yaw trails the head yaw: inside +-dead it only drifts back under the head (drift deg/s), beyond that it turns
-- at rate deg/s until the head is back at the edge
function M.followYaw(body, head, dead, rate, dt, drift)
	if body == nil then return M.normDeg(head) end
	local d = M.normDeg(head - body)
	local ad = math.abs(d)
	local over = ad - (dead or M.DEAD)
	local step = math.min(ad, (drift or 0.0) * (dt or 0.0))
	if over > 0 then step = math.max(step, math.min(over, (rate or M.RATE) * (dt or 0.0))) end
	return M.normDeg(body + (d > 0 and step or -step))
end

-- what to do this tick. on = option (and motion controls) on, play = regular unpaused play
function M.decide(on, play, exists, hidden)
	if not on then return exists and "destroy" or nil end
	if not exists then return play and "create" or nil end
	if play then return hidden and "show" or "place" end
	return (not hidden) and "hide" or nil
end

-- world position of the mesh origin so that the shoulder midpoint (mx, my, mz: component space, unscaled) sits
-- back cm behind and drop cm below the eyes (ex, ey, ez), with the body facing bodyYaw. Returns x, y, z, meshYaw.
function M.meshOrigin(ex, ey, ez, bodyYaw, mx, my, mz, scale, back, drop, meshYawOff)
	local by = math.rad(bodyYaw)
	local tx, ty, tz = ex - math.cos(by) * back, ey - math.sin(by) * back, ez - drop
	local yaw = bodyYaw + meshYawOff
	local a = math.rad(yaw)
	local c, s = math.cos(a), math.sin(a)
	local sx, sy, sz = mx * scale, my * scale, mz * scale
	return tx - (c * sx - s * sy), ty - (s * sx + c * sy), tz - sz, M.normDeg(yaw)
end

-- component-space point (px, py, pz, unscaled) of a mesh at origin (ox, oy, oz) with yaw meshYaw -> world
function M.toWorld(ox, oy, oz, meshYaw, px, py, pz, scale)
	local a = math.rad(meshYaw)
	local c, s = math.cos(a), math.sin(a)
	return ox + (c * px - s * py) * scale, oy + (s * px + c * py) * scale, oz + pz * scale
end

-- the arm cannot stretch: how far the shoulder (sx, sy, sz) must move so that the hand (hx, hy, hz) is maxLen away
function M.reachShift(sx, sy, sz, hx, hy, hz, maxLen)
	local dx, dy, dz = hx - sx, hy - sy, hz - sz
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	if len <= maxLen or len < 1e-6 then return 0.0, 0.0, 0.0 end
	local k = 1.0 - maxLen / len
	return dx * k, dy * k, dz * k
end

function M.clampLen(x, y, z, max)
	local len = math.sqrt(x * x + y * y + z * z)
	if len <= max or len < 1e-6 then return x, y, z end
	local k = max / len
	return x * k, y * k, z * k
end

------------------------------------------------------------------------------------------------------------------------
-- UEVR side
local D = nil -- deps: ik, uevrUtils, controllers, hands, hr (hit result), log
local st = {rig = nil, mesh = nil, hidden = false, wait = 0.0, bodyYaw = nil, mx = 0.0, my = 0.0, mz = 0.0, loc = nil, rot = nil,
	errLogged = false, calT = 0.0, lx = 0.0, ly = 0.0, lz = 0.0, rx = 0.0, ry = 0.0, rz = 0.0, armL = 60.0, armR = 60.0,
	late = false, pending = false, dt = 0.0, miss = 0, solves = 0, lateErr = false, twistL = 0, twistR = 0,
	gapMaxL = 0.0, gapMaxR = 0.0, samples = 0, lowL = 25.0, lowR = 25.0,
	handL = {ok = false, x = 0.0, y = 0.0, z = 0.0, dx = 0.0, dy = 1.0, dz = 0.0, out = nil},
	handR = {ok = false, x = 0.0, y = 0.0, z = 0.0, dx = 0.0, dy = 1.0, dz = 0.0, out = nil},
	origTwist = nil, origOutward = nil, natDir = nil}
M.st = st

local function log(m) if D ~= nil and D.log ~= nil then D.log("[IK] " .. m) end end
local function fname(s) return D.uevrUtils.fname_from_string(s) end
local IKF = nil -- libs/qd_ikfast (s115), loaded in init
local FM = nil  -- libs/qd_fastmath

function M.init(deps)
	D = deps
	D.mathLib = D.mathLib or package.loaded["libs/core/math_lib"] -- loaded by libs/ik (s111 twist override)
	local okF, errF = pcall(function()
		IKF = require("libs/qd_ikfast")
		FM = require("libs/qd_fastmath")
		IKF.init(D.uevrUtils, function(m) if D.log ~= nil then D.log(m) end end)
	end)
	if not okF then IKF, FM = nil, nil log("fast math load error: " .. tostring(errF)) end
	pcall(function() D.ik.setAutoCreateArms(false) end) -- we create and destroy the rig ourselves
	local okL = pcall(function() D.uevrUtils.registerPostCalculateStereoViewCallback(function(device, viewIndex) M.late(viewIndex) end) end)
	log("module loaded (late callback " .. tostring(okL) .. ")")
end

function M.exists() return st.rig ~= nil end
function M.rigDev() return st.rig, st.mesh end -- s115: dev bridge (profiling / A-B checks)
-- step 120: the body yaw the IK mesh faces (dead zone + rate follow of the head), nil without a shown rig
function M.bodyYaw() if st.rig == nil or st.hidden then return nil end return st.bodyYaw end
-- step 114: world location of an IK mesh bone (forearm anchors read the elbow); nil without a rig
local boneNames = {}
function M.boneLoc(name)
	if st.rig == nil or st.mesh == nil or st.hidden then return nil end
	local n = boneNames[name]
	if n == nil then n = fname(name) boneNames[name] = n end
	return st.mesh:GetBoneLocationByName(n, 0)
end
-- step 121: world rotation of an IK mesh bone (lower-arm HUD anchors ride the LowerArm bone); nil without a rig
function M.boneRot(name)
	if st.rig == nil or st.mesh == nil or st.hidden then return nil end
	local n = boneNames[name]
	if n == nil then n = fname(name) boneNames[name] = n end
	return st.mesh:GetBoneRotationByName(n, 0)
end

function M.destroy(why)
	if st.rig ~= nil then
		pcall(function() D.ik.destroyAll() end)
		log("destroyed (" .. tostring(why) .. ")")
	end
	st.rig, st.mesh, st.hidden, st.bodyYaw, st.fastOn = nil, nil, false, nil, nil
	st.late, st.pending = false, false
end

-- s115: calibrateHand's math on numbers (Kismet InverseTransformLocation / InverseTransformRotation / vector >> rotator
-- formulas: FTransform::InverseTransformPosition incl. the safe scale reciprocal, (T.Rot^-1 * Q).Rotator(), RotateVector)
local function recip(v) if math.abs(v) <= 1e-8 then return 0.0 end return 1.0 / v end
local function calibrateFast(active, hand, comp, boneWS, t, bn)
	local q, tr, sc = t.Rotation, t.Translation, t.Scale3D
	local qx, qy, qz, qw = q.X, q.Y, q.Z, q.W
	local ox, oy, oz = FM.unrotateVec(qx, qy, qz, qw, boneWS.X - tr.X, boneWS.Y - tr.Y, boneWS.Z - tr.Z)
	ox, oy, oz = ox * recip(sc.X), oy * recip(sc.Y), oz * recip(sc.Z)
	if active.handOffset ~= nil then
		active.handOffset.X, active.handOffset.Y, active.handOffset.Z = ox, oy, oz
	else
		active.handOffset = D.uevrUtils.vector(ox, oy, oz)
	end
	local hr = comp:GetBoneRotationByName(bn, 0)
	if hr ~= nil and active.endBoneRotation ~= nil then
		local p, y, r = FM.invXformRot(qx, qy, qz, qw, hr.Pitch, hr.Yaw, hr.Roll)
		active.endBoneRotation.Pitch, active.endBoneRotation.Yaw, active.endBoneRotation.Roll = p, y, r
	end
	local h = hand == 0 and st.handL or st.handR
	h.ok = false
	if hr ~= nil and st.natDir ~= nil then
		local hx, hy, hz, hw = FM.quatFromRot(hr.Pitch, hr.Yaw, hr.Roll)
		local dx, dy, dz = FM.rotateVec(hx, hy, hz, hw, st.natDir.X, st.natDir.Y, st.natDir.Z)
		local l = math.sqrt(dx * dx + dy * dy + dz * dz)
		if l > 1e-6 then
			h.x, h.y, h.z, h.dx, h.dy, h.dz, h.ok = boneWS.X, boneWS.Y, boneWS.Z, dx / l, dy / l, dz / l, true
		end
	end
end

-- wrist target = the hand mesh's own hand bone, expressed in controller space (the solver adds it to the controller pose)
local function calibrateHand(hand, solverId, boneName, verbose)
	local active = st.rig.activeSolvers and st.rig.activeSolvers[solverId]
	if active == nil then return false end
	local comp = D.uevrUtils.getValid(D.hands.getHandComponent(hand))
	local ctrl = D.uevrUtils.getValid(D.controllers.getController(hand))
	if comp == nil or ctrl == nil then return false end
	local bn = boneNames[boneName] -- s115: cached FName
	if bn == nil then bn = fname(boneName) boneNames[boneName] = bn end
	local boneWS = comp:GetBoneLocationByName(bn, 0) -- 0 = EBoneSpaces::WorldSpace
	local t = ctrl:K2_GetComponentToWorld()
	if boneWS == nil or t == nil then return false end
	if st.fastOn and FM ~= nil and not verbose and not st.calFastBad then
		local okC, errC = pcall(calibrateFast, active, hand, comp, boneWS, t, bn)
		if okC then return true end
		st.calFastBad = true
		log("fast calibrate error (back to Kismet): " .. tostring(errC))
	end
	local off = kismet_math_library:InverseTransformLocation(t, boneWS)
	if off == nil then return false end
	if active.handOffset ~= nil then
		active.handOffset.X, active.handOffset.Y, active.handOffset.Z = off.X, off.Y, off.Z
	else
		active.handOffset = D.uevrUtils.vector(off.X, off.Y, off.Z)
	end
	-- s103: wrist rotation too. With end_bone_rotation 0 the solver gave the IK hand bone the controller's rotation, not the
	-- glove's: the (hidden) hand bone still bends the wrist-ring vertices and is the reference for the forearm twist.
	-- InverseTransformRotation(ctrl, glove) = glove rotation in controller space; the solver composes it with the controller.
	local hr = comp:GetBoneRotationByName(bn, 0)
	local rr = hr ~= nil and kismet_math_library:InverseTransformRotation(t, hr) or nil
	if rr ~= nil and active.endBoneRotation ~= nil then
		active.endBoneRotation.Pitch, active.endBoneRotation.Yaw, active.endBoneRotation.Roll = rr.Pitch, rr.Yaw, rr.Roll
	end
	-- s111: glove wrist position + natural forearm direction (world) for the elbow-follows-hand pole (outwardQD)
	local h = hand == 0 and st.handL or st.handR
	h.ok = false
	if hr ~= nil and st.natDir ~= nil then
		local d = kismet_math_library:GreaterGreater_VectorRotator(st.natDir, hr)
		if d ~= nil then
			local l = math.sqrt(d.X * d.X + d.Y * d.Y + d.Z * d.Z)
			if l > 1e-6 then
				h.x, h.y, h.z, h.dx, h.dy, h.dz, h.ok = boneWS.X, boneWS.Y, boneWS.Z, d.X / l, d.Y / l, d.Z / l, true
			end
		end
	end
	return true, off, rr
end

function M.calibrate(verbose)
	if st.rig == nil then return end
	st.handL.ok, st.handR.ok = false, false
	local okL, offL, rotL = calibrateHand(0, M.SOLVERS.left, M.BONES.handL, verbose)
	local okR, offR, rotR = calibrateHand(1, M.SOLVERS.right, M.BONES.handR, verbose)
	if verbose then
		log(string.format("wrist offsets L ok=%s (%.1f,%.1f,%.1f) rot (%.0f,%.0f,%.0f) R ok=%s (%.1f,%.1f,%.1f) rot (%.0f,%.0f,%.0f)", tostring(okL),
			offL and offL.X or 0, offL and offL.Y or 0, offL and offL.Z or 0, rotL and rotL.Pitch or 0, rotL and rotL.Yaw or 0, rotL and rotL.Roll or 0,
			tostring(okR), offR and offR.X or 0, offR and offR.Y or 0, offR and offR.Z or 0, rotR and rotR.Pitch or 0, rotR and rotR.Yaw or 0, rotR and rotR.Roll or 0))
	end
	return okL and okR
end

-- s105b: hide the hand (old) or only the fingers on the IK mesh; also callable from the bridge after changing M.HIDE_HAND
function M.applyHide()
	local mesh = st.mesh
	if mesh == nil then return "no rig" end
	local ok, err = pcall(function()
		for _, side in ipairs({"L", "R"}) do
			if not M.HIDE_HAND then mesh:UnHideBoneByName(fname("Hand_" .. side)) end
			for _, b in ipairs(M.hideList(side, M.HIDE_HAND, M.FINGER_ROOTS)) do mesh:HideBoneByName(fname(b), 0) end
		end
	end)
	local msg = "hide " .. (M.HIDE_HAND and "hands (old)" or "fingers only") .. " ok=" .. tostring(ok) .. (ok and "" or (" " .. tostring(err)))
	log(msg)
	return msg
end

-- s111: instance overrides of two uevrlib Rig methods (lib untouched; the rig is setmetatable({}, Rig) with Rig.__index = Rig,
-- so a field on the instance wins). Same arguments as the lib's methods.
local tubeQ = {X = 0.0, Y = 0.0, Z = 0.0, W = 1.0}
local function twistForearmQD(self, meshList, lowerDirCS, lowerArmRotCS, handRotCS, twistBones, fMax, wMax, state, incr)
	local ML = D.mathLib
	if not M.QD_TWIST or ML == nil or state == nil or state.qdTwistRest == nil or lowerArmRotCS == nil or handRotCS == nil
		or lowerDirCS == nil or twistBones == nil or #twistBones == 0 then
		if st.origTwist ~= nil then return st.origTwist(self, meshList, lowerDirCS, lowerArmRotCS, handRotCS, twistBones, fMax, wMax, state, incr) end
		return
	end
	local fast = st.fastOn and IKF ~= nil and IKF.on -- s115: same math on numbers (libs/qd_ikfast)
	local raw
	if fast then
		raw = IKF.twistDeg(lowerArmRotCS.Pitch, lowerArmRotCS.Yaw, lowerArmRotCS.Roll, handRotCS.Pitch, handRotCS.Yaw, handRotCS.Roll,
			lowerDirCS.X or 0.0, lowerDirCS.Y or 0.0, lowerDirCS.Z or 0.0)
	else
		raw = ML.computeTwistDegAroundAxis_Rotators(lowerArmRotCS, handRotCS, lowerDirCS)
	end
	if raw == nil or raw ~= raw then st.twistNaN = (st.twistNaN or 0) + 1 return end -- NaN would stick in the unwrap
	if state.qdTwistAcc ~= nil and state.qdTwistAcc ~= state.qdTwistAcc then state.qdTwistAcc = nil end
	local applied, acc = M.twistStep(raw, state.qdTwistRest, state.qdTwistAcc, M.TWIST_MAX, M.TWIST_WRAP)
	state.qdTwistAcc, state.qdTwistApplied = acc, applied
	if fast and IKF.twistBones(meshList, lowerDirCS, lowerArmRotCS, applied, twistBones, state, fname) then return end
	local ax, ay, az = lowerDirCS.X or 0.0, lowerDirCS.Y or 0.0, lowerDirCS.Z or 0.0
	for _, entry in ipairs(twistBones) do
		local vecs = state.twistBoneVecs and state.twistBoneVecs[entry.bone]
		if vecs == nil then break end
		if entry._fname == nil then entry._fname = fname(entry.bone) end
		-- as the lib: stored lower-arm-local axes -> component space, turned about the forearm by fraction * twist
		local xCS, zCS = ML.vectorRotate(vecs.x, lowerArmRotCS), ML.vectorRotate(vecs.z, lowerArmRotCS)
		local half = math.rad(applied * (entry.fraction or 0.0)) * 0.5
		local s = math.sin(half)
		tubeQ.X, tubeQ.Y, tubeQ.Z, tubeQ.W = ax * s, ay * s, az * s, math.cos(half)
		xCS, zCS = ML.vectorRotate_Quat(xCS, tubeQ, false), ML.vectorRotate_Quat(zCS, tubeQ, false)
		local finalCS = ML.makeRotFromXZ(xCS, zCS, true)
		for _, mesh in ipairs(meshList) do
			if mesh ~= nil then mesh:SetBoneRotationByName(entry._fname, finalCS, 1) end -- 1 = ComponentSpace
		end
	end
end

local function outwardQD(self, mesh, shoulderWS, jointWS, reach, compToWorld, ctrlRotCS, allow, infl, wMax, solverParams, state)
	local out
	if st.fastOn and IKF ~= nil then -- s115: lib's getMeshOutward on numbers (falls back to the lib's own when needed)
		out = IKF.getMeshOutward(st.origOutward, self, mesh, shoulderWS, jointWS, reach, compToWorld, ctrlRotCS, allow, infl, wMax, solverParams, state)
	else
		out = st.origOutward(self, mesh, shoulderWS, jointWS, reach, compToWorld, ctrlRotCS, allow, infl, wMax, solverParams, state)
	end
	if (M.ELBOW_FOLLOW or 0) <= 0 or out == nil or reach == nil or shoulderWS == nil or solverParams == nil then return out end
	local left = solverParams.endBone == M.BONES.handL
	local h = left and st.handL or st.handR
	if not h.ok or h.out == nil then return out end
	local low = (left and st.lowL or st.lowR) * M.SCALE
	local px, py, pz = M.handPole(shoulderWS.X, shoulderWS.Y, shoulderWS.Z, reach.X, reach.Y, reach.Z, h.x, h.y, h.z, h.dx, h.dy, h.dz,
		low, out.X, out.Y, out.Z, M.ELBOW_FOLLOW, M.ELBOW_MIN, M.ELBOW_MAX_DEG)
	if px ~= px or py ~= py or pz ~= pz then st.poleNaN = (st.poleNaN or 0) + 1 return out end
	h.out.x, h.out.y, h.out.z = px, py, pz -- own reused vector: the lib keeps `out` for its pole smoothing
	return h.out
end

-- s111: rest twist (hand vs lower arm about the forearm) of the pose the twist-bone axes were captured in
local function captureTwistRest(rig, mesh)
	local ML = D.mathLib
	if ML == nil then return "no math lib" end
	local msg = ""
	for side, id in pairs({L = M.SOLVERS.left, R = M.SOLVERS.right}) do
		local a = rig.activeSolvers and rig.activeSolvers[id]
		if a ~= nil and a.state ~= nil then
			local lN, hN = fname(side == "L" and M.BONES.lowerL or M.BONES.lowerR), fname(side == "L" and M.BONES.handL or M.BONES.handR)
			local lr, hr, ll, hl = mesh:GetBoneRotationByName(lN, 1), mesh:GetBoneRotationByName(hN, 1), mesh:GetBoneLocationByName(lN, 1), mesh:GetBoneLocationByName(hN, 1)
			local dx, dy, dz = hl.X - ll.X, hl.Y - ll.Y, hl.Z - ll.Z
			local l = math.sqrt(dx * dx + dy * dy + dz * dz)
			if l > 1e-6 then
				a.state.qdTwistRest = ML.computeTwistDegAroundAxis_Rotators(lr, hr, D.uevrUtils.vector(dx / l, dy / l, dz / l))
				a.state.qdTwistAcc = nil
				msg = msg .. string.format(" %s=%.1f", side, a.state.qdTwistRest or 0)
			end
		end
	end
	return msg
end

local function create()
	local rig = D.ik.new({})
	if rig == nil or rig.meshList == nil or rig.meshList[1] == nil then
		if not st.errLogged then st.errLogged = true log("create failed (ik.new returned nil): see ik_parameters.json / pawn.Arms") end
		return false
	end
	local mesh = rig.meshList[1]
	st.rig, st.mesh, st.hidden, st.bodyYaw = rig, mesh, false, nil
	mesh:SetAbsolute(true, true, true) -- placed in world space every tick (place)
	mesh:SetRelativeScale3D(D.uevrUtils.vector(M.SCALE, M.SCALE, M.SCALE))
	M.applyHide() -- fingers (or whole hands, M.HIDE_HAND) come from the hands lib meshes
	pcall(function() mesh.bCastDynamicShadow = false end)
	local l = mesh:GetBoneLocationByName(fname(M.BONES.upperL), 1) -- 1 = EBoneSpaces::ComponentSpace
	local r = mesh:GetBoneLocationByName(fname(M.BONES.upperR), 1)
	st.mx, st.my, st.mz = (l.X + r.X) * 0.5, (l.Y + r.Y) * 0.5, (l.Z + r.Z) * 0.5
	st.lx, st.ly, st.lz, st.rx, st.ry, st.rz = l.X, l.Y, l.Z, r.X, r.Y, r.Z
	local function dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
	local el, hl = mesh:GetBoneLocationByName(fname(M.BONES.lowerL), 1), mesh:GetBoneLocationByName(fname(M.BONES.handL), 1)
	local er, hrr = mesh:GetBoneLocationByName(fname(M.BONES.lowerR), 1), mesh:GetBoneLocationByName(fname(M.BONES.handR), 1)
	st.armL, st.armR = dist(l, el) + dist(el, hl), dist(r, er) + dist(er, hrr) -- unscaled cm, shoulder to wrist
	st.lowL, st.lowR = dist(el, hl), dist(er, hrr)
	st.natDir = st.natDir or D.uevrUtils.vector(0, 0, 0)
	st.natDir.X, st.natDir.Y, st.natDir.Z = M.FOREARM_DIR[1], M.FOREARM_DIR[2], M.FOREARM_DIR[3]
	-- the lib does arithmetic on the pole: needs UEVR's Vector3d (operators), not a struct object
	if Vector3d ~= nil then
		st.handL.out = st.handL.out or Vector3d.new(0, 0, 0)
		st.handR.out = st.handR.out or Vector3d.new(0, 0, 0)
	end
	st.loc = st.loc or D.uevrUtils.vector(0, 0, 0)
	st.rot = st.rot or D.uevrUtils.rotator(0, 0, 0)
	st.calT = 0.0
	local n, bones = 0, ""
	for id, a in pairs(rig.activeSolvers or {}) do
		n = n + 1
		bones = bones .. " " .. tostring(id) .. "=" .. tostring(a.startBone) .. "/" .. tostring(a.jointBone) .. "/" .. tostring(a.endBone)
	end
	log(string.format("created %s solvers=%d%s shoulders L(%.1f,%.1f,%.1f) R(%.1f,%.1f,%.1f) arm %.1f/%.1f cm", mesh:get_fname():to_string(), n, bones,
		l.X, l.Y, l.Z, r.X, r.Y, r.Z, st.armL, st.armR))
	M.calibrate(true)
	-- s103 late solve: take the rig's own solve off the pre-engine tick; M.late runs place + calibrate + rig.tickFn once a frame
	st.late, st.pending, st.miss = false, false, 0
	if M.LATE and rig.tickFn ~= nil then
		local okU = pcall(function() D.uevrUtils.unregisterUEVRCallback("preEngineTick", rig.tickFn) end)
		st.late = okU
	end
	log("solve phase: " .. (st.late and ("late (view " .. tostring(M.LATE_VIEW) .. ")") or "pre-engine tick"))
	-- s103 forearm twist: bones found by name (logged once so a wrong guess is visible)
	pcall(function()
		local names = D.uevrUtils.getBoneNames(mesh)
		local seen = ""
		for _, n in ipairs(names) do
			local s = string.lower(n)
			if string.find(s, "arm", 1, true) or string.find(s, "twist", 1, true) or string.find(s, "hand", 1, true) then seen = seen .. " " .. n end
		end
		log("bones " .. tostring(#names) .. ":" .. seen)
		st.twistL, st.twistR = 0, 0
		if not M.TWIST then return end
		for side, id in pairs({l = M.SOLVERS.left, r = M.SOLVERS.right}) do
			local tw = M.pickTwist(names, side)
			if #tw > 0 then
				local list = {}
				for i, n in ipairs(tw) do list[i] = {bone = n, fraction = M.TWIST_FRACTION} end
				rig:setSolverParameter(id, "twist_bones", list)
				if side == "l" then st.twistL = #tw else st.twistR = #tw end
				log("twist bones " .. id .. ": " .. table.concat(tw, ","))
			end
		end
	end)
	-- s111: twist + elbow overrides (see twistForearmQD / outwardQD)
	local okO, errO = pcall(function()
		local cls = getmetatable(rig)
		cls = cls and cls.__index
		st.origTwist = type(cls) == "table" and cls.twistForearm or nil
		st.origOutward = type(cls) == "table" and cls.getMeshOutward or nil
		local rest = captureTwistRest(rig, mesh)
		if st.origTwist ~= nil then rig.twistForearm = twistForearmQD end
		if st.origOutward ~= nil then rig.getMeshOutward = outwardQD end
		if IKF ~= nil then IKF.cls = type(cls) == "table" and cls or nil end
		st.fastOn = nil -- s115: applyFast installs the fast methods on the new rig
		log("s111 overrides twist=" .. tostring(st.origTwist ~= nil) .. " outward=" .. tostring(st.origOutward ~= nil) .. " rest" .. tostring(rest))
	end)
	if not okO then log("s111 override error: " .. tostring(errO)) end
	return true
end

local function place(dt)
	local hmd = D.controllers.getController(2)
	if hmd == nil then return end
	local loc, rot = hmd:K2_GetComponentLocation(), hmd:K2_GetComponentRotation()
	if loc == nil or rot == nil then return end
	st.bodyYaw = M.followYaw(st.bodyYaw, rot.Yaw, M.DEAD, M.RATE, dt, M.DRIFT)
	local x, y, z, yaw = M.meshOrigin(loc.X, loc.Y, loc.Z, st.bodyYaw, st.mx, st.my, st.mz, M.SCALE, M.BACK, M.DROP, M.MESH_YAW)
	-- arms cannot stretch: a hand out of reach pulls the shoulders towards it (leaning / reaching forward)
	local px, py, pz = 0.0, 0.0, 0.0
	local cl, cr = D.controllers.getController(0), D.controllers.getController(1)
	if cl ~= nil then
		local h = cl:K2_GetComponentLocation()
		local sx, sy, sz = M.toWorld(x, y, z, yaw, st.lx, st.ly, st.lz, M.SCALE)
		px, py, pz = M.reachShift(sx, sy, sz, h.X, h.Y, h.Z, st.armL * M.SCALE * M.REACH)
	end
	if cr ~= nil then
		local h = cr:K2_GetComponentLocation()
		local sx, sy, sz = M.toWorld(x, y, z, yaw, st.rx, st.ry, st.rz, M.SCALE)
		local qx, qy, qz = M.reachShift(sx, sy, sz, h.X, h.Y, h.Z, st.armR * M.SCALE * M.REACH)
		px, py, pz = px + qx, py + qy, pz + qz
	end
	px, py, pz = M.clampLen(px, py, pz, M.MAX_PULL)
	x, y, z = x + px, y + py, z + pz
	st.loc.X, st.loc.Y, st.loc.Z = x, y, z
	st.rot.Pitch, st.rot.Yaw, st.rot.Roll = 0.0, yaw, 0.0
	st.mesh:K2_SetWorldLocationAndRotation(st.loc, st.rot, false, D.hr, false)
end

-- every pre-engine tick. on = option + motion controls, play = regular unpaused play
-- s115: install / remove the fast solve steps on the rig instance (a nil field = the lib's class method again)
local function applyFast()
	local rig = st.rig
	if rig == nil then return end
	local want = M.FAST == true and IKF ~= nil and IKF.failed == nil and IKF.cls ~= nil
		and IKF.cls.rotateShoulder ~= nil and IKF.cls.rotateElbow ~= nil
	if st.fastOn == want then return end
	st.fastOn = want
	if IKF ~= nil then IKF.on = want end
	if want then
		rig.rotateShoulder, rig.rotateElbow = IKF.rotateShoulder, IKF.rotateElbow
	else
		rig.rotateShoulder, rig.rotateElbow = nil, nil
	end
	log("fast math " .. (want and "on" or "off") .. ((IKF ~= nil and IKF.failed ~= nil) and " (error)" or ""))
end

function M.tick(on, play, dt)
	dt = dt or 0.0
	if st.rig ~= nil and D.uevrUtils.getValid(st.mesh) == nil then M.destroy("mesh gone") end
	applyFast()
	-- probe: state here = what the last frame rendered (before this frame moves anything)
	if M.SAMPLE and st.rig ~= nil and not st.hidden then pcall(M.sample) end
	local act = M.decide(on, play, st.rig ~= nil, st.hidden)
	if act == nil then return end
	if act == "destroy" then
		M.destroy("option off")
	elseif act == "create" then
		st.wait = st.wait - dt
		if st.wait <= 0 then
			st.wait = M.RETRY
			local ok, err = pcall(create)
			if not ok then
				if not st.errLogged then st.errLogged = true log("create error: " .. tostring(err)) end
				M.destroy("create error")
			end
		end
	elseif act == "hide" then
		st.hidden, st.pending = true, false
		st.mesh:SetVisibility(false, true)
	else
		if act == "show" then
			st.hidden = false
			st.mesh:SetVisibility(true, true)
		end
		if st.late then
			-- last frame had no post-calc call with the wanted view index (cumulative: AFR alternates the index per frame)
			if st.pending then
				st.miss = st.miss + 1
				if st.miss == M.LATE_MISS and M.LATE_VIEW >= 0 then
					M.LATE_VIEW = -1
					log("no post-calc call with the wanted view index: solving on any view")
				end
			end
			st.pending, st.dt = true, dt
			return
		end
		place(dt)
		-- the hand meshes are rebuilt on level changes and can lag the rig by a few ticks: re-measure once a second
		st.calT = st.calT + dt
		if st.calT > 1.0 then st.calT = 0.0 M.calibrate(false) end
	end
end

-- s103: post stereo view calc (registered in init). Controllers, HMD and hand meshes hold this frame's pose here, and the
-- poseable mesh is sent to the renderer after the views are calculated, so arm and glove meet on the rendered frame.
local function lateSolve()
	if st.rig == nil or st.hidden or D.uevrUtils.getValid(st.mesh) == nil then return end
	local P = M.prof -- s115: optional section timer (nil = off; set from the dev bridge)
	if P ~= nil then P() end
	place(st.dt)
	if P ~= nil then P("ik.place") end
	st.calT = st.calT + st.dt
	if st.calT >= M.CAL_PERIOD then st.calT = 0.0 M.calibrate(false) end
	if P ~= nil then P("ik.calibrate") end
	if st.rig.tickFn ~= nil then st.rig.tickFn(nil, st.dt) end
	if P ~= nil then P("ik.rigtick") end
	st.solves = st.solves + 1
end

function M.late(viewIndex)
	if not st.late or not M.lateAccept(st.pending, viewIndex, M.LATE_VIEW) then return end
	st.pending = false
	local ok, err = pcall(lateSolve)
	if not ok and not st.lateErr then st.lateErr = true log("late solve error: " .. tostring(err)) end
end

-- glove-to-arm gap now: IK hand bone vs hands-lib hand bone (cm) and their rotation difference (deg, forward/up axes)
local function handGap(hand, boneName)
	local comp = D.uevrUtils.getValid(D.hands.getHandComponent(hand))
	if comp == nil or st.mesh == nil then return nil end
	local fn = fname(boneName)
	local a, b = st.mesh:GetBoneLocationByName(fn, 0), comp:GetBoneLocationByName(fn, 0)
	local ra, rb = st.mesh:GetBoneRotationByName(fn, 0), comp:GetBoneRotationByName(fn, 0)
	if a == nil or b == nil or ra == nil or rb == nil then return nil end
	local fa, fb = kismet_math_library:GetForwardVector(ra), kismet_math_library:GetForwardVector(rb)
	local ua, ub = kismet_math_library:GetUpVector(ra), kismet_math_library:GetUpVector(rb)
	return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2), M.angleDeg(fa.X, fa.Y, fa.Z, fb.X, fb.Y, fb.Z),
		M.angleDeg(ua.X, ua.Y, ua.Z, ub.X, ub.Y, ub.Z)
end

function M.sample()
	local g = handGap(0, M.BONES.handL)
	if g ~= nil and g > st.gapMaxL then st.gapMaxL = g end
	g = handGap(1, M.BONES.handR)
	if g ~= nil and g > st.gapMaxR then st.gapMaxR = g end
	st.samples = st.samples + 1
end

-- bridge: return QD.ik.probe() -> one line; resets the sampled maxima
function M.probe()
	if st.rig == nil then return "no rig (late=" .. tostring(st.late) .. ")" end
	local out = string.format("late=%s view=%s miss=%d solves=%d twist=%d/%d samples=%d maxgap L=%.2f R=%.2f", tostring(st.late),
		tostring(M.LATE_VIEW), st.miss, st.solves, st.twistL, st.twistR, st.samples, st.gapMaxL, st.gapMaxR)
	st.gapMaxL, st.gapMaxR, st.samples = 0.0, 0.0, 0
	local mesh = st.mesh
	local midX, midY = 0.0, 0.0
	local sl = mesh:GetBoneLocationByName(fname(M.BONES.upperL), 0)
	local sr = mesh:GetBoneLocationByName(fname(M.BONES.upperR), 0)
	if sl ~= nil and sr ~= nil then midX, midY = (sl.X + sr.X) * 0.5, (sl.Y + sr.Y) * 0.5 end
	for _, s in ipairs({{0, "L", M.BONES.upperL, M.BONES.lowerL, M.BONES.handL}, {1, "R", M.BONES.upperR, M.BONES.lowerR, M.BONES.handR}}) do
		local d, af, au = handGap(s[1], s[5])
		local sh, el, ha = mesh:GetBoneLocationByName(fname(s[3]), 0), mesh:GetBoneLocationByName(fname(s[4]), 0), mesh:GetBoneLocationByName(fname(s[5]), 0)
		local drop, outw = 0.0, 0.0
		if sh ~= nil and el ~= nil and ha ~= nil then drop, outw = M.elbowPlace(sh.X, sh.Y, sh.Z, el.X, el.Y, el.Z, ha.X, ha.Y, ha.Z, midX, midY) end
		out = out .. string.format(" | %s gap=%.2f fwd=%.1f up=%.1f elbowDrop=%.1f elbowOut=%.1f", s[2], d or -1, af or -1, au or -1, drop, outw)
	end
	local sl2, sr2 = st.rig.activeSolvers[M.SOLVERS.left], st.rig.activeSolvers[M.SOLVERS.right]
	sl2, sr2 = sl2 and sl2.state or {}, sr2 and sr2.state or {}
	return out .. string.format(" | bodyYaw=%.1f | twist L=%.1f R=%.1f (rest %.1f/%.1f)", st.bodyYaw or 0, sl2.qdTwistApplied or 0,
		sr2.qdTwistApplied or 0, sl2.qdTwistRest or 0, sr2.qdTwistRest or 0)
end

function M.reset() M.destroy("level change") end

return M
