-- Queen's Domain VR: item view distance (step 137). The game's three item displays (pickup, given item, merged item)
-- hang a fresh SceneComponent (LocalRotBase) on the first-person camera at 0.1 * (offset + 100 cm) with the model at
-- 0.1 scale: the same picture on a flat screen, but about 10 cm from the eyes in VR. We re-hang LocalRotBase on a child
-- of the camera scaled by k = wanted cm / 10: the game keeps writing the same relative transforms, and distance and size
-- both grow k times about the eye (same apparent size, comfortable distance). Nothing is hidden.
local M = {}

M.BASE_CM = 10.0     -- the game's own display distance
M.DEFAULT_CM = 50.0
M.MIN_CM, M.MAX_CM = 10.0, 120.0
M.POLL_S = 0.05
M.TAG = "qd_itemview"
M.CLASSES = {
	"BlueprintGeneratedClass /Game/Blueprints/ItemPickupAnimationComp.ItemPickupAnimationComp_C",
	"BlueprintGeneratedClass /Game/NPCs/Shared/ItemGiveAnimationComp.ItemGiveAnimationComp_C",
	"BlueprintGeneratedClass /Game/Player/ItemmergeAnim/ItemMergeActorAnim.ItemMergeActorAnim_C",
}

-- pure: scale factor for a wanted distance (cm)
function M.factor(cm)
	cm = tonumber(cm) or M.DEFAULT_CM
	if cm ~= cm then cm = M.DEFAULT_CM end
	if cm < M.MIN_CM then cm = M.MIN_CM elseif cm > M.MAX_CM then cm = M.MAX_CM end
	return cm / M.BASE_CM
end
-- pure: name of a component added at run time without a name (AddComponentByClass): "SceneComponent_2147452697"
function M.isTempName(n) return type(n) == "string" and n:find("^SceneComponent_%d+$") ~= nil end

local D = nil
local S = { t = 0.0, anchor = nil, cam = nil, k = nil, skip = {}, skipN = nil, moved = 0, err = nil, failT = 0.0 }
M.S = S
local scl = { X = 1.0, Y = 1.0, Z = 1.0 }

-- d: { uevrUtils, api, getValue, log }
function M.init(d) D = d end
local function log(m) if D ~= nil and D.log ~= nil then D.log("[ITEMVIEW] " .. m) end end

local function ensureAnchor(cam, k)
	if S.anchor ~= nil and (D.uevrUtils.getValid(S.anchor) == nil or S.cam ~= cam:get_address()) then
		S.anchor, S.k = nil, nil
	end
	if S.anchor == nil then
		local now = os.clock()
		if now < S.failT then return nil end
		local c = D.uevrUtils.create_component_of_class("Class /Script/Engine.SceneComponent", true, nil, false, nil, M.TAG)
		if c == nil then S.failT = now + 5.0 log("anchor creation failed") return nil end
		c:K2_AttachToComponent(cam, D.uevrUtils.fname_from_string(""), 2, 2, 2, false) -- 2 = SnapToTarget
		S.anchor, S.cam, S.k = c, cam:get_address(), nil
		log("anchor on the camera")
	end
	if S.k ~= k then
		scl.X, scl.Y, scl.Z = k, k, k
		S.anchor:SetRelativeScale3D(scl)
		S.k = k
	end
	return S.anchor
end

-- is c the LocalRotBase of one of the game's item display components on its owner?
local function isDisplayBase(c, owner)
	local addr = c:get_address()
	for i = 1, #M.CLASSES do
		local cls = D.api:find_uobject(M.CLASSES[i])
		if cls ~= nil then
			local comp = owner:GetComponentByClass(cls)
			if comp ~= nil then
				local b = comp.LocalRotBase
				if b ~= nil and b:get_address() == addr then return true end
			end
		end
	end
	return false
end

local function poll()
	local pawn = D.api:get_local_pawn(0)
	if pawn == nil then return end
	local cam = pawn.FirstPersonCamera
	if cam == nil then return end
	local kids = cam.AttachChildren
	if kids == nil then return end
	local n = #kids
	if n ~= S.skipN then -- the child list changed: forget earlier rejections (addresses get reused)
		S.skipN = n
		for a in pairs(S.skip) do S.skip[a] = nil end
	end
	local k = M.factor(D.getValue ~= nil and D.getValue("item_view_cm") or nil)
	if S.anchor ~= nil and S.k ~= k and D.uevrUtils.getValid(S.anchor) ~= nil then ensureAnchor(cam, k) end
	for i = 1, n do
		local c = kids[i]
		if c ~= nil then
			local a = c:get_address()
			if not S.skip[a] then
				local take = false
				if M.isTempName(c:get_fname():to_string()) then
					local o = c:GetOwner()
					if o ~= nil and o:get_address() ~= pawn:get_address() then take = isDisplayBase(c, o) end
				end
				if take then
					local an = ensureAnchor(cam, k)
					if an ~= nil then
						c:K2_AttachToComponent(an, D.uevrUtils.fname_from_string(""), 0, 0, 0, false) -- 0 = KeepRelative
						S.moved = S.moved + 1
						S.skipN = nil -- the list just changed
						local l, cl = c:K2_GetComponentLocation(), cam:K2_GetComponentLocation()
						log(string.format("display %d moved to x%.1f, %.1f cm from the camera", S.moved, k,
							math.sqrt((l.X - cl.X) ^ 2 + (l.Y - cl.Y) ^ 2 + (l.Z - cl.Z) ^ 2)))
					end
					return -- the list changed under us: the rest next poll
				end
				S.skip[a] = true
			end
		end
	end
end

-- every tick; works at M.POLL_S
function M.tick(dt)
	if D == nil then return end
	S.t = S.t + (dt or 0)
	if S.t < M.POLL_S then return end
	S.t = 0.0
	local ok, err = pcall(poll)
	if not ok and S.err == nil then S.err = tostring(err) log("error: " .. S.err) end
end

return M
