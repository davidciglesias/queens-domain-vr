-- qd_knives (step 37): throwing-knife charges shown as knife models held between the left-hand fingers; one vanishes per
-- throw and comes back as the game recharges it. Replaces the flat knife-count widget on the left hand (option knife_fingers).
-- Pure helpers at the top (unit tested by tools/test_qd_knives.lua), UEVR code below (init/tick).
-- Copyright (C) 2026 Queen's Domain VR contributors. AGPL-3.0 (see LICENSE).
local M = {}

M.MAX = 5
-- step 47: some throwables hold 5 charges -> 5th knife on the thumb side of the index finger (SIDE -1 mirrors the x offset)
M.FINGERS = { "Index", "Middle", "Ring", "Pinky", "Index" }
M.SIDE = { 1, 1, 1, 1, -1 }
M.REFRESH_S = 0.15   -- count / visibility poll
-- step 48: one charge component per throwable (pawn.DaggerItemToComponent); a cached comp showed the previous
-- throwable's (often full) count for up to the cache time after a switch -> fetch it on every poll
M.COMP_S = 0.0

-- knives shown for a charge count (nil/negative -> 0, capped at maxN)
function M.visibleCount(count, maxN)
	count = math.floor(tonumber(count) or 0)
	maxN = maxN or M.MAX
	if count < 0 then return 0 end
	if count > maxN then return maxN end
	return count
end

-- bone for knife i (1 = index finger side): Finger_<Name>_<seg>_L, seg clamped to 0..2
function M.boneName(i, seg)
	seg = math.floor(tonumber(seg) or 0)
	if seg < 0 then seg = 0 elseif seg > 2 then seg = 2 end
	local f = M.FINGERS[i]
	if f == nil then return nil end
	return "Finger_" .. f .. "_" .. seg .. "_L"
end

-- tuning values from options with defaults (cm / degrees / scale factor on the game knife's own scale)
-- Test 50: finger bones point along -Y, the next finger is at -X (~2.6 cm); knife mesh = blade along -Y, flat in X/Y
-- -> pitch 90 turns the flat side to the neighbour finger, x -1.3 = half a finger gap, 0.7 = ~18 cm knife
M.DEFAULTS = { x = -1.3, y = 0.0, z = 0.0, pitch = 90.0, yaw = 0.0, roll = 0.0, scale = 0.7, seg = 0 }
function M.readTuning(get, out)
	out = out or {}
	local function v(id, d) local r = get(id) if type(r) ~= "number" then return d end return r end
	local D = M.DEFAULTS
	out.x, out.y, out.z = v("knife_fx", D.x), v("knife_fy", D.y), v("knife_fz", D.z)
	out.pitch, out.yaw, out.roll = v("knife_fpitch", D.pitch), v("knife_fyaw", D.yaw), v("knife_froll", D.roll)
	out.scale, out.seg = v("knife_fscale", D.scale), v("knife_fbone", D.seg)
	return out
end

function M.sameTuning(a, b)
	if a == nil or b == nil then return false end
	for k in pairs(M.DEFAULTS) do if a[k] ~= b[k] then return false end end
	return true
end

-- haptic tick only when a charge comes back (not on first read or a drop)
function M.gained(prev, cur)
	return prev ~= nil and cur ~= nil and cur > prev
end

-- ===================== UEVR runtime =====================
local D = nil
local S = { comps = {}, vis = {}, t = 0.0, tc = 0.0, chargeComp = nil, count = nil, hand = nil, mesh = nil,
	tune = nil, tuneNow = {}, parts = {}, baseScale = 1.0, hudHidden = false, logged = {}, maxOut = {}, ccSeen = nil, maxCharges = nil }
local vloc, vrot, vscale = nil, nil, nil

local function log(m) if D ~= nil and D.log ~= nil then pcall(D.log, "[KNIFE] " .. m) end end
local function logOnce(k, m) if not S.logged[k] then S.logged[k] = true log(m) end end

function M.init(deps)
	D = deps
	vloc = { X = 0.0, Y = 0.0, Z = 0.0 }
	vrot = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
	vscale = { X = 1.0, Y = 1.0, Z = 1.0 }
end

local function setVis(i, on)
	local c = S.comps[i]
	if c == nil then return end
	if S.vis[i] ~= on then
		S.vis[i] = on
		-- hidden-in-game, not visibility: the main tick's hands.hideHands(false) re-shows hand children every frame
		pcall(function() c:SetHiddenInGame(not on, true) end) -- true: step 55 extra parts are children
	end
end

-- step 55: multi-part throwables (one has its blade as a separate StaticMeshComponent attached to the visuals Mesh,
-- live 2026-11-16): clone each StaticMesh child of src onto copy i with the same relative transform and materials.
local function destroyParts(i)
	local p = S.parts[i]
	if p == nil then return end
	for k = #p, 1, -1 do
		local c = p[k]
		pcall(function() c:K2_DestroyComponent(c) end)
		p[k] = nil
	end
end

local function buildParts(i, src, owner)
	destroyParts(i)
	S.parts[i] = S.parts[i] or {}
	local parent = S.comps[i]
	local kids = nil
	pcall(function() kids = src.AttachChildren end)
	if kids == nil or parent == nil then return 0 end
	local n = 0
	for k = 1, #kids do
		pcall(function()
			local kc = kids[k]
			local sm = kc.StaticMesh
			if sm == nil then return end
			local c = D.uevrUtils.createStaticMeshComponent(sm, { parent = owner, manualAttachment = true })
			if c == nil then return end
			pcall(function() c:SetCastShadow(false) end)
			pcall(function() c:SetCollisionEnabled(0) end)
			pcall(function() for m = 0, kc:GetNumMaterials() - 1 do c:SetMaterial(m, kc:GetMaterial(m)) end end)
			c:K2_AttachToComponent(parent, D.uevrUtils.fname_from_string(""), 0, 0, 0, false)
			local l, r, s = kc.RelativeLocation, kc.RelativeRotation, kc.RelativeScale3D
			vloc.X, vloc.Y, vloc.Z = l.X, l.Y, l.Z
			vrot.Pitch, vrot.Yaw, vrot.Roll = r.Pitch, r.Yaw, r.Roll
			c:K2_SetRelativeLocationAndRotation(vloc, vrot, false, D.hr, true)
			vscale.X, vscale.Y, vscale.Z = s.X, s.Y, s.Z
			c:SetRelativeScale3D(vscale)
			pcall(function() c:SetHiddenInGame(parent.bHiddenInGame == true, false) end)
			n = n + 1
			S.parts[i][n] = c
		end)
	end
	return n
end

local function hideAllComps()
	for i = 1, M.MAX do setVis(i, false) end
end

local function destroyComps()
	for i = 1, M.MAX do
		destroyParts(i)
		local c = S.comps[i]
		if c ~= nil then
			pcall(function() c:SetHiddenInGame(true, false) end)
			pcall(function() c:K2_DestroyComponent(c) end)
		end
		S.comps[i], S.vis[i] = nil, nil
	end
	S.hand, S.handObj, S.mesh, S.tune = nil, nil, nil, nil
end

-- the game's flat knife-count widget (part of the status cluster on the left hand): hidden while finger knives are on
local function setHudHidden(pawn, hide)
	if S.hudHidden == hide and not hide then return end
	local ok = pcall(function()
		local w = pawn.HUD.StatusCluster.DaggerChargeHUD
		if w == nil then return end
		if hide then
			-- step 52: the game shows it again (seen Visible with hudHidden set, 2026-11-16) -> re-collapse every poll
			if S.hudHidden and w:GetVisibility() == 1 then return end
			if S.hudHidden then logOnce("hudReshow", "flat knife HUD re-shown by the game: collapsing again (logged once)") end
			local v = w:GetVisibility()
			if v ~= 1 then S.hudVis = v end
			w:SetVisibility(1) -- Collapsed
		else
			w:SetVisibility(S.hudVis or 4) -- back to what the game had (4 SelfHitTestInvisible if never read)
		end
	end)
	if ok then S.hudHidden = hide end
end

local function chargeComp(pawn)
	if S.chargeComp ~= nil and S.tc > 0.0 and D.uevrUtils.getValid(S.chargeComp) ~= nil then return S.chargeComp end
	S.tc = M.COMP_S
	local ok, c = pcall(function() return pawn:GetDaggerChargeComp() end)
	S.chargeComp = ok and c or nil
	return S.chargeComp
end

local function knifeMesh(pawn)
	local ok, m = pcall(function()
		local dv = pawn.Daggervisuals
		if dv == nil or dv.Mesh == nil then return nil end
		return dv.Mesh
	end)
	return ok and m or nil
end

local function placeAll(t)
	for i = 1, M.MAX do
		local c = S.comps[i]
		if c ~= nil then
			pcall(function()
				local bone = M.boneName(i, t.seg)
				c:K2_AttachToComponent(S.handObj, D.uevrUtils.fname_from_string(bone), 2, 2, 1, false)
				vloc.X, vloc.Y, vloc.Z = t.x * (M.SIDE[i] or 1), t.y, t.z
				vrot.Pitch, vrot.Yaw, vrot.Roll = t.pitch, t.yaw, t.roll
				c:K2_SetRelativeLocationAndRotation(vloc, vrot, false, D.hr, true)
				local s = S.baseScale * t.scale
				vscale.X, vscale.Y, vscale.Z = s, s, s
				c:SetWorldScale3D(vscale)
			end)
		end
	end
	S.tune = S.tune or {}
	for k in pairs(M.DEFAULTS) do S.tune[k] = t[k] end
end

local function addr(o)
	local ok, a = pcall(function() return o:get_address() end)
	return ok and a or nil
end

local function ensureComps(hand, src)
	local staticMesh = nil
	pcall(function() staticMesh = src.StaticMesh end)
	if staticMesh == nil then return false end
	local ha, ma = addr(hand), addr(staticMesh)
	if S.hand ~= ha then destroyComps() end
	if S.mesh ~= ma then
		for i = 1, M.MAX do
			local c = S.comps[i]
			if c == nil or D.uevrUtils.getValid(c) == nil then
				S.comps[i], S.vis[i] = nil, nil
				pcall(function()
					c = D.uevrUtils.createStaticMeshComponent(staticMesh, { parent = hand:GetOwner(), manualAttachment = true })
					if c ~= nil then
						pcall(function() c:SetCastShadow(false) end)
						pcall(function() c:SetCollisionEnabled(0) end)
						S.comps[i] = c
					end
				end)
			else
				pcall(function() c:SetStaticMesh(staticMesh) end)
			end
			-- same look as the game's knife (variants use override materials)
			pcall(function()
				local n = src:GetNumMaterials()
				for m = 0, n - 1 do S.comps[i]:SetMaterial(m, src:GetMaterial(m)) end
			end)
		end
		if S.comps[1] == nil then logOnce("fail", "knife component creation failed") return false end
		S.src = nil -- step 55: rebuild the extra parts below
	end
	local sa = addr(src)
	if S.src ~= sa then
		S.src = sa
		local np, owner = 0, nil
		pcall(function() owner = hand:GetOwner() end)
		for i = 1, M.MAX do
			if S.comps[i] ~= nil then
				local ok, r = pcall(buildParts, i, src, owner)
				if ok and i == 1 then np = r end
			end
		end
		log("knife extra parts per copy: " .. tostring(np))
	end
	if S.mesh ~= ma then
		S.baseScale = 1.0
		pcall(function() local sc = src:K2_GetComponentToWorld().Scale3D if sc ~= nil and sc.X > 0 then S.baseScale = sc.X end end)
		S.mesh, S.hand, S.handObj, S.tune = ma, ha, hand, nil
		local bones = 0
		for i = 1, M.MAX do
			pcall(function() if hand:GetBoneIndex(D.uevrUtils.fname_from_string(M.boneName(i, 0))) >= 0 then bones = bones + 1 end end)
		end
		local hx = -1
		pcall(function() local b = src:GetLocalBounds() hx = (b.Max.X - b.Min.X) end)
		log(string.format("knives created: %d comps, finger bones found %d/" .. M.MAX .. ", base scale %.3f, local bounds X %.1f", #S.comps, bones, S.baseScale, hx))
	end
	return true
end

function M.hideAll()
	hideAllComps()
	if S.hudHidden then
		local pawn = D ~= nil and D.api:get_local_pawn(0) or nil
		if pawn ~= nil then setHudHidden(pawn, false) end
	end
end

-- active = regular unpaused play with motion controls; called every pre-engine tick
function M.tick(dt, active)
	if D == nil then return end
	S.t = S.t - (dt or 0.0)
	S.tc = S.tc - (dt or 0.0)
	if S.t > 0.0 then return end
	S.t = M.REFRESH_S
	local on = active and D.configui.getValue("knife_fingers") == true
	local pawn = D.api:get_local_pawn(0)
	if pawn == nil then hideAllComps() return end
	if not on then
		hideAllComps()
		if S.hudHidden then setHudHidden(pawn, false) end
		return
	end
	local src = knifeMesh(pawn)
	local hand = D.hands.getHandComponent(Handed.Left)
	if src == nil or hand == nil then hideAllComps() return end
	if not ensureComps(hand, src) then hideAllComps() return end
	M.readTuning(D.configui.getValue, S.tuneNow)
	if not M.sameTuning(S.tune, S.tuneNow) then placeAll(S.tuneNow) end
	local cc = chargeComp(pawn)
	local count = nil
	if cc ~= nil then pcall(function() count = cc.CurrentCharges end) end -- (cached_Max_Charge_Count reads nil)
	if cc ~= S.ccSeen then -- discovery (steps 47/49b): max charges of each throwable
		S.ccSeen = cc
		local mx = nil
		pcall(function() local o = S.maxOut o.MaxChargeCount, o.result = nil, nil local r = cc:GetmaxChargeCount(o) mx = o.MaxChargeCount or o.result or r end)
		S.maxCharges = tonumber(mx)
		log("charge comp changed, max " .. tostring(mx))
	end
	if count ~= S.count then
		if M.gained(S.count, count) then
			pcall(D.uevrUtils.triggerHapticVibration, Handed.Left, 0, 0.03, 150, 0.3)
		end
		log("charges " .. tostring(count))
		S.count = count
	end
	local handHidden = false
	pcall(function() handHidden = hand.bHiddenInGame == true or hand.bVisible == false end)
	local n = handHidden and 0 or M.visibleCount(count, M.MAX)
	for i = 1, M.MAX do setVis(i, i <= n) end
	setHudHidden(pawn, true)
end

function M.reset()
	destroyComps()
	S.chargeComp, S.count, S.hudHidden, S.ccSeen = nil, nil, false, nil
end

M.S = S
return M
