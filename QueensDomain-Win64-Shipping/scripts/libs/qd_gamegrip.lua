-- qd_gamegrip (step 126, user 2026-11-21: "research hand poses for grabbing each weapon in flat and add the same to VR").
-- Flat game: no grip enum; each weapon script feeds its own idle arm sequence (WeaponScriptBase_C.RootAnim) into the
-- first-person arms anim BP (pawn.Arms, Player_FPArms_Arms_ABP_C), so the finger shape per weapon lives in that
-- animation. The VR hands are a poseable copy of pawn.Arms with fixed finger poses (hands_parameters.json, Shared
-- positions right_grip_weapon). Here: after a weapon change, read the finger bones of the game's own pawn.Arms (parent
-- bone space = the same local rotators the hands lib applies), cache them per weapon and write them into the shared
-- right_grip_weapon "on" table in place (qd_handpose re-asserts). Option weapon_grip_from_game; off / unsampled ->
-- the original pose. Polled (no hooks), sampling at most twice per weapon change.
local M = {}

M.SETTLE_S = 1.2   -- wait after a weapon change (pull-out montage) before sampling
M.RESAMPLE_S = 1.0 -- second sample this long after the first; both must agree (idle pose, not a montage frame)
M.AGREE_DEG = 6.0
M.HAND_BONE = "Hand_R" -- step 127 seat discovery (same bone name as qd_armhud M.LOWER.hand)  -- max per-bone difference between the two samples
M.POS = "right_grip_weapon"

-- pure: largest absolute angle difference (deg, wrapped) between two poses over the bones of a
function M.maxDiff(a, b)
	local m = 0.0
	for bone, r in pairs(a) do
		local o = b[bone]
		if o ~= nil then
			for k = 1, 3 do
				local d = math.abs(((r[k] - o[k]) + 180.0) % 360.0 - 180.0)
				if d > m then m = d end
			end
		end
	end
	return m
end
-- pure: copy the angles of src into dst for the bones dst already has (in place, no new bone keys)
function M.copyInto(dst, src)
	local n = 0
	for bone, r in pairs(dst) do
		local s = src[bone]
		if s ~= nil then r[1], r[2], r[3] = s[1], s[2], s[3] n = n + 1 end
	end
	return n
end
-- pure: deep copy of a pose table {bone = {p, y, r}}
function M.copyPose(p)
	local o = {}
	for bone, r in pairs(p) do o[bone] = { r[1], r[2], r[3] } end
	return o
end

---------------------------------------------------------------- runtime (UEVR)
local D = nil
local S = { key = nil, addr = nil, t = 0.0, first = nil, cache = {}, orig = nil, origTbl = nil, applied = nil, seat = {}, onPrev = nil }
M.S = S
local function log(msg) if D ~= nil and D.log ~= nil then D.log("[GRIP] " .. msg) end end

function M.init(deps) D = deps end

-- the shared "on" table of right_grip_weapon (nil until the hands are created)
local function onTable()
	local a = D.anims ~= nil and D.anims() or nil
	if a == nil or a.positions == nil or a.positions[M.POS] == nil then return nil end
	return a.positions[M.POS].on
end

-- finger local rotators of pawn.Arms for the bones of tbl (parent bone space, same convention as the hands lib)
local function sample(arms, tbl)
	local out = {}
	local kml = kismet_math_library -- global (uevr_utils)
	for bone, _ in pairs(tbl) do
		local t = arms:GetSocketTransform(D.uevrUtils.fname_from_string(bone), 3) -- RTS_ParentBoneSpace
		local r = kml:TransformRotation(t, D.uevrUtils.rotator(0, 0, 0))
		out[bone] = { r.Pitch, r.Yaw, r.Roll }
	end
	return out
end

-- weapon class name, re-read only when the held weapon object changes (no per-tick closures)
local function weaponKey(pawn)
	local w = pawn.CurrentInHandWeapon
	local a = w ~= nil and w:get_address() or 0
	if a == S.addr then return S.key end
	S.addr = a
	if w == nil then return nil end
	local okN, n = pcall(function() return w:get_class():get_fname():to_string() end)
	return okN and n or nil
end

local function restore()
	if S.applied ~= nil and S.origTbl ~= nil and S.orig ~= nil then
		M.copyInto(S.origTbl, S.orig)
		if D.dirty ~= nil then pcall(D.dirty) end
	end
	S.applied = nil
end

local function apply(key)
	local tbl = onTable()
	local pose = S.cache[key]
	if tbl == nil or pose == nil then return end
	if S.origTbl ~= tbl then S.origTbl, S.orig = tbl, M.copyPose(tbl) end -- new hands config: remember its own pose
	M.copyInto(tbl, pose)
	S.applied = key
	if D.dirty ~= nil then pcall(D.dirty) end
end

-- step 127 discovery (headset 2026-11-21c: copied fingers don't hold the weapon; user: maybe our weapon rotation):
-- once per weapon class, the weapon's seat in the hand, flat vs VR: flat = the visuals' socket component relative to
-- pawn.Arms Hand_R (its attach parent + socket name too); VR = the held weapon mesh relative to our hand's Hand_R
local function relStr(a, b)
	local kml = kismet_math_library
	local t = kml:MakeRelativeTransform(a, b)
	local l = kml:TransformLocation(t, D.uevrUtils.vector(0, 0, 0))
	local r = kml:TransformRotation(t, D.uevrUtils.rotator(0, 0, 0))
	return string.format("loc %.1f %.1f %.1f rot p %.1f y %.1f r %.1f", l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll)
end
local function seatLog(pawn, key)
	local hb = D.uevrUtils.fname_from_string(M.HAND_BONE)
	local flat, vr = "n/a", "n/a"
	pcall(function() -- Test 95: SocketComp is already re-parented to the controller -> use the script's VisualsAttachPoint
		local ap = pawn.CurrentInHandWeapon.VisualsAttachPoint
		local par, sock = ap:GetAttachParent(), ap.AttachSocketName
		local hw = pawn.Arms:GetSocketTransform(hb, 0)
		flat = string.format("%s (attach point %s, parent %s, socket %s)", relStr(ap:K2_GetComponentToWorld(), hw), ap:get_fname():to_string(),
			par ~= nil and par:get_fname():to_string() or "none", sock ~= nil and sock:to_string() or "?")
	end)
	pcall(function()
		local m, h = D.weaponMesh ~= nil and D.weaponMesh() or nil, D.hand ~= nil and D.hand() or nil
		if m == nil or h == nil then return end
		vr = relStr(m:K2_GetComponentToWorld(), h:GetSocketTransform(hb, 0))
	end)
	log(string.format("weapon seat %s: flat %s | VR %s", key, flat, vr))
end

-- every tick (cheap: one property read; sampling only around weapon changes). on = option weapon_grip_from_game
function M.tick(dt, on)
	if D == nil then return end
	if on ~= S.onPrev then S.onPrev, S.key = on, nil end -- re-evaluate the held weapon after a toggle
	if not on and S.applied ~= nil then restore() end
	local pawn = D.uevrUtils.get_local_pawn ~= nil and D.uevrUtils.get_local_pawn() or uevr.api:get_local_pawn(0)
	if pawn == nil then return end
	local key = weaponKey(pawn)
	if key ~= S.key then
		S.key, S.t, S.first = key, 0.0, nil
		if key == nil then restore() return end
		if on and S.cache[key] ~= nil then apply(key) else restore() end
		return
	end
	if key == nil then return end
	if S.seat[key] and (not on or S.cache[key] ~= nil) then return end -- cache false also ends here
	S.t = S.t + (dt or 0.0)
	if S.t < M.SETTLE_S then return end
	if not S.seat[key] then S.seat[key] = true pcall(seatLog, pawn, key) end
	if not on or S.cache[key] ~= nil then return end
	local tbl = onTable()
	local arms = pawn.Arms
	if tbl == nil or arms == nil then return end
	if S.origTbl ~= tbl then S.origTbl, S.orig = tbl, M.copyPose(tbl) end
	local okS, p = pcall(sample, arms, S.orig)
	if not okS then S.cache[key] = false log("sample error: " .. tostring(p)) return end
	if S.first == nil then S.first, S.t = p, M.SETTLE_S - M.RESAMPLE_S return end
	local agree = M.maxDiff(S.first, p)
	if agree > M.AGREE_DEG then S.first, S.t = p, M.SETTLE_S - M.RESAMPLE_S return end -- still moving: try again
	local nb = 0
	for _ in pairs(p) do nb = nb + 1 end
	S.cache[key] = p
	log(string.format("weapon grip sampled: %s, %d bones, differs from the default grip by up to %.0f deg", key, nb, M.maxDiff(p, S.orig)))
	apply(key)
end

function M.reset() S.origTbl, S.orig, S.applied, S.key, S.addr = nil, nil, nil, nil, nil end
return M
