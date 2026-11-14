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

function M.normDeg(a) return (a + 540.0) % 360.0 - 180.0 end

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
	errLogged = false, calT = 0.0, lx = 0.0, ly = 0.0, lz = 0.0, rx = 0.0, ry = 0.0, rz = 0.0, armL = 60.0, armR = 60.0}
M.st = st

local function log(m) if D ~= nil and D.log ~= nil then D.log("[IK] " .. m) end end
local function fname(s) return D.uevrUtils.fname_from_string(s) end

function M.init(deps)
	D = deps
	pcall(function() D.ik.setAutoCreateArms(false) end) -- we create and destroy the rig ourselves
	log("module loaded")
end

function M.exists() return st.rig ~= nil end

function M.destroy(why)
	if st.rig ~= nil then
		pcall(function() D.ik.destroyAll() end)
		log("destroyed (" .. tostring(why) .. ")")
	end
	st.rig, st.mesh, st.hidden, st.bodyYaw = nil, nil, false, nil
end

-- wrist target = the hand mesh's own hand bone, expressed in controller space (the solver adds it to the controller pose)
local function calibrateHand(hand, solverId, boneName)
	local active = st.rig.activeSolvers and st.rig.activeSolvers[solverId]
	if active == nil then return false end
	local comp = D.uevrUtils.getValid(D.hands.getHandComponent(hand))
	local ctrl = D.uevrUtils.getValid(D.controllers.getController(hand))
	if comp == nil or ctrl == nil then return false end
	local boneWS = comp:GetBoneLocationByName(fname(boneName), 0) -- 0 = EBoneSpaces::WorldSpace
	local t = ctrl:K2_GetComponentToWorld()
	if boneWS == nil or t == nil then return false end
	local off = kismet_math_library:InverseTransformLocation(t, boneWS)
	if off == nil then return false end
	if active.handOffset ~= nil then
		active.handOffset.X, active.handOffset.Y, active.handOffset.Z = off.X, off.Y, off.Z
	else
		active.handOffset = D.uevrUtils.vector(off.X, off.Y, off.Z)
	end
	return true, off
end

function M.calibrate(verbose)
	if st.rig == nil then return end
	local okL, offL = calibrateHand(0, M.SOLVERS.left, M.BONES.handL)
	local okR, offR = calibrateHand(1, M.SOLVERS.right, M.BONES.handR)
	if verbose then
		log(string.format("wrist offsets L ok=%s (%.1f,%.1f,%.1f) R ok=%s (%.1f,%.1f,%.1f)", tostring(okL), offL and offL.X or 0, offL and offL.Y or 0,
			offL and offL.Z or 0, tostring(okR), offR and offR.X or 0, offR and offR.Y or 0, offR and offR.Z or 0))
	end
	return okL and okR
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
	mesh:HideBoneByName(fname(M.BONES.handL), 0) -- hands (and fingers below them) come from the hands lib meshes
	mesh:HideBoneByName(fname(M.BONES.handR), 0)
	pcall(function() mesh.bCastDynamicShadow = false end)
	local l = mesh:GetBoneLocationByName(fname(M.BONES.upperL), 1) -- 1 = EBoneSpaces::ComponentSpace
	local r = mesh:GetBoneLocationByName(fname(M.BONES.upperR), 1)
	st.mx, st.my, st.mz = (l.X + r.X) * 0.5, (l.Y + r.Y) * 0.5, (l.Z + r.Z) * 0.5
	st.lx, st.ly, st.lz, st.rx, st.ry, st.rz = l.X, l.Y, l.Z, r.X, r.Y, r.Z
	local function dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
	local el, hl = mesh:GetBoneLocationByName(fname(M.BONES.lowerL), 1), mesh:GetBoneLocationByName(fname(M.BONES.handL), 1)
	local er, hrr = mesh:GetBoneLocationByName(fname(M.BONES.lowerR), 1), mesh:GetBoneLocationByName(fname(M.BONES.handR), 1)
	st.armL, st.armR = dist(l, el) + dist(el, hl), dist(r, er) + dist(er, hrr) -- unscaled cm, shoulder to wrist
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
function M.tick(on, play, dt)
	dt = dt or 0.0
	if st.rig ~= nil and D.uevrUtils.getValid(st.mesh) == nil then M.destroy("mesh gone") end
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
		st.hidden = true
		st.mesh:SetVisibility(false, true)
	else
		if act == "show" then
			st.hidden = false
			st.mesh:SetVisibility(true, true)
		end
		place(dt)
		-- the hand meshes are rebuilt on level changes and can lag the rig by a few ticks: re-measure once a second
		st.calT = st.calT + dt
		if st.calT > 1.0 then st.calT = 0.0 M.calibrate(false) end
	end
end

function M.reset() M.destroy("level change") end

return M
