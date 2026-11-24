-- qd_fingerfit (step 129, plan 127g; user 2026-11-21: keep the tuned VR weapon seats, fit the fingers per weapon instead).
-- After a weapon change each right-hand finger curls in small steps from its open pose ("off") toward and a bit past
-- the weapon fist ("on" of right_grip_weapon / right_trigger_weapon). Every step traces the swept joint points against
-- the held weapon mesh; the first segment that touches freezes its bone (and the ones before it) and the outer bones
-- keep curling, so the finger wraps the handle. Result cached per weapon class and written in place into the "on"
-- tables (qd_handpose re-asserts). Contact needs collision: the weapon meshes are NoCollision, so each finger's sweep
-- sets them QueryOnly and restores them in the same call (probe 2026-11-21: complex traces then hit static meshes;
-- NoCollision and simple-collision traces never do). One finger per tick. Option weapon_grip_fit.
local M = {}

M.SETTLE_S = 0.8    -- wait after a weapon change (pull-out, visuals attach) before fitting
M.RETRY_S = 0.5     -- hand / mesh not ready -> try again this much later
M.MAX_TRIES = 10
M.STEP = 0.05       -- curl step (0 = open pose, 1 = default weapon fist)
M.MAX_ALPHA = 1.35  -- thin handles: curl past the default fist
M.FREE_ALPHA = 1.0  -- bones that never touch end at the default fist
M.PAD_CM = 0.8      -- finger half thickness: each swept trace runs this far past the new point
M.TIP_FRAC = 0.85   -- fingertip = last bone + this fraction of its own bone offset, along the last bone
M.NEAR_CM = 30      -- the weapon mesh must be this close to the hand bone (held, not holstered / dropped)
M.HAND_BONE = "Hand_R"
M.DEBUG = false     -- log each touch (segment, curl, hit point in Hand_R space)
M.FINGERS = {
	{ pos = "right_trigger_weapon", bones = { "Finger_Index_0_R", "Finger_Index_1_R", "Finger_Index_2_R" } },
	{ pos = "right_grip_weapon", bones = { "Finger_Middle_0_R", "Finger_Middle_1_R", "Finger_Middle_2_R" } },
	{ pos = "right_grip_weapon", bones = { "Finger_Ring_0_R", "Finger_Ring_1_R", "Finger_Ring_2_R" } },
	{ pos = "right_grip_weapon", bones = { "Finger_Pinky_0_R", "Finger_Pinky_1_R", "Finger_Pinky_2_R" } },
	{ pos = "right_grip_weapon", bones = { "Thumb_0_R", "Thumb_1_R", "Thumb_2_R" } },
}

-- pure: angle lerp a -> b (deg, shortest way), t may exceed 1 (extrapolates)
function M.lerpAng(a, b, t)
	return a + ((((b - a) + 180.0) % 360.0) - 180.0) * t
end
-- pure: {p, y, r} lerp into out (new table when out is nil)
function M.lerpRot(a, b, t, out)
	out = out or {}
	out[1], out[2], out[3] = M.lerpAng(a[1], b[1], t), M.lerpAng(a[2], b[2], t), M.lerpAng(a[3], b[3], t)
	return out
end

-- pure: wrap one finger of n bones. hitFn(cur, nxt, frozen) -> lowest touching segment index (> frozen) when the
-- bones move from alphas cur to nxt, else nil. Segment k = bone k -> bone k+1 (n = bone n -> tip) moves with bones
-- 1..k, so a touch on k freezes bones 1..k. Returns alphas, number of frozen bones, touches.
function M.fitFinger(n, step, maxA, freeA, hitFn)
	local cur, nxt = {}, {}
	for k = 1, n do cur[k] = 0.0 end
	local frozen, a, touches, guard = 0, 0.0, 0, 0
	while frozen < n and a < maxA - 1e-9 and guard < 1000 do
		guard = guard + 1
		local na = math.min(a + step, maxA)
		for k = 1, n do nxt[k] = (k > frozen) and na or cur[k] end
		local seg = hitFn(cur, nxt, frozen)
		if seg ~= nil and seg > frozen then
			frozen, touches = math.min(seg, n), touches + 1
		else
			for k = 1, n do cur[k] = nxt[k] end
			a = na
		end
	end
	for k = frozen + 1, n do cur[k] = math.min(cur[k], freeA) end
	return cur, frozen, touches
end

---------------------------------------------------------------- runtime (UEVR)
local D = nil
local S = { key = nil, addr = nil, t = 0.0, tries = 0, cache = {}, job = nil, orig = {}, origTbl = {}, applied = nil, onPrev = nil }
M.S = S
local function log(msg) if D ~= nil and D.log ~= nil then D.log("[FIT] " .. msg) end end

function M.init(deps) D = deps end

local function posTable(name)
	local a = D.anims ~= nil and D.anims() or nil
	if a == nil or a.positions == nil or a.positions[name] == nil then return nil end
	return a.positions[name]
end
local function copyPose(p)
	local o = {}
	for bone, r in pairs(p) do o[bone] = { r[1], r[2], r[3] } end
	return o
end
-- remember each position's own (unfitted) on/off tables; a new hands config resets them
local function captureOrig()
	for _, f in ipairs(M.FINGERS) do
		local pt = posTable(f.pos)
		if pt == nil or pt.on == nil or pt.off == nil then return false end
		if S.origTbl[f.pos] ~= pt.on then S.origTbl[f.pos], S.orig[f.pos] = pt.on, { on = copyPose(pt.on), off = copyPose(pt.off) } end
	end
	return true
end

local function copyInto(dst, src)
	for bone, r in pairs(dst) do
		local s = src[bone]
		if s ~= nil then r[1], r[2], r[3] = s[1], s[2], s[3] end
	end
end

local function restore()
	if S.applied ~= nil then
		for pos, tbl in pairs(S.origTbl) do if S.orig[pos] ~= nil then copyInto(tbl, S.orig[pos].on) end end
		if D.dirty ~= nil then pcall(D.dirty) end
		if D.onRestore ~= nil then pcall(D.onRestore) end
	end
	S.applied = nil
end

local function apply(key)
	local pose = S.cache[key]
	if type(pose) ~= "table" or not captureOrig() then return end
	for pos, bones in pairs(pose) do
		local tbl = S.origTbl[pos]
		if tbl ~= nil then copyInto(tbl, bones) end
	end
	S.applied = key
	if D.dirty ~= nil then pcall(D.dirty) end
end

local function weaponKey(pawn)
	local w = pawn.CurrentInHandWeapon
	local a = w ~= nil and w:get_address() or 0
	if a == S.addr then return S.key end
	S.addr = a
	if w == nil then return nil end
	local okN, n = pcall(function() return w:get_class():get_fname():to_string() end)
	return okN and n or nil
end

local function isMeshComp(c)
	local okC, n = pcall(function() return c:get_class():get_fname():to_string() end)
	return okC and n ~= nil and (n:find("StaticMeshComponent", 1, true) ~= nil or n:find("SkeletalMeshComponent", 1, true) ~= nil)
end

-- held weapon mesh + its mesh children (multi-part visuals), only when it sits in the right hand
local function findMeshes(hand)
	local m = D.weaponMesh ~= nil and D.weaponMesh() or nil
	if m == nil or not isMeshComp(m) then return nil, "no weapon mesh" end
	local kml = kismet_math_library
	local hb = hand:GetBoneTransformByName(D.uevrUtils.fname_from_string(M.HAND_BONE), 0)
	local hl = kml:TransformLocation(hb, D.uevrUtils.vector(0, 0, 0))
	local ml = m:K2_GetComponentLocation()
	local d = math.sqrt((hl.X - ml.X) ^ 2 + (hl.Y - ml.Y) ^ 2 + (hl.Z - ml.Z) ^ 2)
	if d > M.NEAR_CM then return nil, string.format("mesh %.0f cm from the hand", d) end
	local list = { m }
	pcall(function()
		for _, c in ipairs(m.AttachChildren) do if c ~= nil and isMeshComp(c) then list[#list + 1] = c end end
	end)
	return list, nil
end

-- one finger's sweep (all in one call: collision on/off, bone writes, traces, bone restore)
local function fitOne(job, fi)
	local f = M.FINGERS[fi]
	local hand, kml, U = job.hand, kismet_math_library, D.uevrUtils
	local o = S.orig[f.pos]
	local n = #f.bones
	local fn, offR, onR, tipOff, prevLocal = {}, {}, {}, nil, {}
	local zeroV, zeroR = U.vector(0, 0, 0), U.rotator(0, 0, 0)
	for k = 1, n do
		fn[k] = U.fname_from_string(f.bones[k])
		offR[k], onR[k] = o.off[f.bones[k]], o.on[f.bones[k]]
		if offR[k] == nil or onR[k] == nil then return nil, "bone missing in the pose: " .. f.bones[k] end
		local t = hand:GetSocketTransform(fn[k], 3)
		local r = kml:TransformRotation(t, zeroR)
		prevLocal[k] = { r.Pitch, r.Yaw, r.Roll }
		if k == n then
			local l = kml:TransformLocation(t, zeroV) -- own offset from the parent bone = phalanx length + direction
			tipOff = U.vector(l.X * M.TIP_FRAC, l.Y * M.TIP_FRAC, l.Z * M.TIP_FRAC)
		end
	end
	local rot, tmp = U.rotator(0, 0, 0), {}
	local function setPose(alphas)
		for k = 1, n do
			M.lerpRot(offR[k], onR[k], alphas[k], tmp)
			rot.Pitch, rot.Yaw, rot.Roll = tmp[1], tmp[2], tmp[3]
			D.animation.setBoneSpaceLocalRotator(hand, fn[k], rot, 0)
		end
	end
	-- sample points: segment k -> mid + end (joint k+1 / tip), as plain numbers
	local function points()
		local j = {}
		for k = 1, n do
			local t = hand:GetBoneTransformByName(fn[k], 0)
			local l = kml:TransformLocation(t, zeroV)
			j[k] = { l.X, l.Y, l.Z }
			if k == n then local tl = kml:TransformLocation(t, tipOff) j[n + 1] = { tl.X, tl.Y, tl.Z } end
		end
		local p = {}
		for k = 1, n do
			local a, b = j[k], j[k + 1]
			p[k] = { { (a[1] + b[1]) * 0.5, (a[2] + b[2]) * 0.5, (a[3] + b[3]) * 0.5 }, b }
		end
		return p
	end
	local va, vb, hl = U.vector(0, 0, 0), U.vector(0, 0, 0), {}
	local function sweepHits(p, q)
		local dx, dy, dz = q[1] - p[1], q[2] - p[2], q[3] - p[3]
		local len = math.sqrt(dx * dx + dy * dy + dz * dz)
		if len < 1e-4 then return false end
		local s = (len + M.PAD_CM) / len
		va.X, va.Y, va.Z = p[1], p[2], p[3]
		vb.X, vb.Y, vb.Z = p[1] + dx * s, p[2] + dy * s, p[3] + dz * s
		job.traces = job.traces + 1
		for i = 1, #job.meshes do
			if job.meshes[i]:K2_LineTraceComponent(va, vb, true, false, false, hl, {}, {}, {}) == true then
				if M.DEBUG and hl.result ~= nil then job.lastHit = kml:InverseTransformLocation(job.handT, hl.result) end
				return true
			end
		end
		return false
	end
	local cur = nil
	if M.DEBUG then
		job.handT = hand:GetBoneTransformByName(U.fname_from_string(M.HAND_BONE), 0)
		local b0 = kml:InverseTransformLocation(job.handT, kml:TransformLocation(hand:GetBoneTransformByName(fn[1], 0), zeroV))
		job.dbg[#job.dbg + 1] = string.format("f%d base(%.1f %.1f %.1f)", fi, b0.X, b0.Y, b0.Z)
	end
	setPose({ 0.0, 0.0, 0.0 })
	cur = points()
	local function hitFn(_, nxt, frozen)
		setPose(nxt)
		local q = points()
		local seg = nil
		for k = frozen + 1, n do
			if sweepHits(cur[k][1], q[k][1]) or sweepHits(cur[k][2], q[k][2]) then seg = k break end
		end
		if seg == nil then cur = q
		elseif M.DEBUG then
			local h = job.lastHit
			job.dbg[#job.dbg + 1] = string.format("f%d s%d@%.2f hit(%.1f %.1f %.1f)", fi, seg, nxt[seg], h and h.X or 0, h and h.Y or 0, h and h.Z or 0)
		end
		return seg
	end
	local prevColl = {}
	for i, m in ipairs(job.meshes) do prevColl[i] = m:GetCollisionEnabled() m:SetCollisionEnabled(1) end -- QueryOnly
	local okF, alphas, frozen, touches = pcall(M.fitFinger, n, M.STEP, M.MAX_ALPHA, M.FREE_ALPHA, hitFn)
	for i, m in ipairs(job.meshes) do pcall(function() m:SetCollisionEnabled(prevColl[i]) end) end
	for k = 1, n do -- put the bones back; qd_handpose re-asserts the fitted pose after the job
		rot.Pitch, rot.Yaw, rot.Roll = prevLocal[k][1], prevLocal[k][2], prevLocal[k][3]
		pcall(D.animation.setBoneSpaceLocalRotator, hand, fn[k], rot, 0)
	end
	if not okF then return nil, tostring(alphas) end
	local out = {}
	for k = 1, n do out[f.bones[k]] = M.lerpRot(offR[k], onR[k], alphas[k]) end
	return { pose = out, alphas = alphas, frozen = frozen, touches = touches }, nil
end

local function startJob(pawn)
	local hand = D.hand ~= nil and D.hand() or nil
	if hand == nil or hand.GetBoneTransformByName == nil then return nil, "no hand" end
	if not captureOrig() then return nil, "no hand poses" end
	local meshes, why = findMeshes(hand)
	if meshes == nil then return nil, why end
	return { hand = hand, meshes = meshes, i = 1, res = {}, traces = 0, dbg = {}, clock = 0.0, kind = meshes[1]:get_class():get_fname():to_string() }, nil
end

local function finishJob(key, job)
	local pose, touches, parts = {}, 0, {}
	for fi, f in ipairs(M.FINGERS) do
		local r = job.res[fi]
		if r ~= nil then
			touches = touches + r.touches
			pose[f.pos] = pose[f.pos] or {}
			for bone, v in pairs(r.pose) do pose[f.pos][bone] = v end
			parts[#parts + 1] = string.format("%.2f/%.2f/%.2f", r.alphas[1], r.alphas[2], r.alphas[3])
		else
			parts[#parts + 1] = "-"
		end
	end
	local head = string.format("weapon %s (%s, %d mesh): ", key, job.kind, #job.meshes)
	local tail = string.format(" | touches %d, traces %d, %.1f ms", touches, job.traces, job.clock * 1000.0)
	if touches == 0 then
		S.cache[key] = false
		log(head .. "no finger touched the weapon -> default grip" .. tail)
		restore()
		return
	end
	if M.DEBUG then log("debug " .. key .. ": " .. table.concat(job.dbg, "; ")) end
	S.cache[key] = pose
	log(head .. "curl index/middle/ring/pinky/thumb " .. table.concat(parts, " ") .. tail)
	apply(key)
end

-- every tick. on = option weapon_grip_fit (and the hand pose driver)
function M.tick(dt, on)
	if D == nil then return end
	if on ~= S.onPrev then S.onPrev, S.key, S.addr, S.job = on, nil, nil, nil if not on then restore() end end
	if not on then return end
	local pawn = uevr.api:get_local_pawn(0)
	if pawn == nil then return end
	local key = weaponKey(pawn)
	if key ~= S.key then
		S.key, S.t, S.tries, S.job = key, 0.0, 0, nil
		if key ~= nil and type(S.cache[key]) == "table" then apply(key) else restore() end
		return
	end
	if key == nil or S.cache[key] ~= nil then return end
	S.t = S.t + (dt or 0.0)
	if S.t < M.SETTLE_S then return end
	if S.job == nil then
		local job, why = startJob(pawn)
		if job == nil then
			S.tries = S.tries + 1
			if S.tries >= M.MAX_TRIES then S.cache[key] = false log("weapon " .. key .. ": not fitted (" .. tostring(why) .. ")") end
			S.t = M.SETTLE_S - M.RETRY_S
			return
		end
		S.job = job
	end
	local job = S.job
	local c0 = os.clock()
	local res, err = fitOne(job, job.i)
	job.clock = job.clock + (os.clock() - c0)
	if res == nil then log("finger " .. job.i .. " error: " .. tostring(err)) end
	job.res[job.i] = res
	job.i = job.i + 1
	if job.i > #M.FINGERS then S.job = nil finishJob(key, job) end
end

-- forget the cached fits (weapon seat tuned) and refit the held weapon
function M.refit() S.cache, S.key, S.addr, S.job = {}, nil, nil, nil end
function M.reset() restore() S.orig, S.origTbl, S.key, S.addr, S.job = {}, {}, nil, nil, nil end
return M
