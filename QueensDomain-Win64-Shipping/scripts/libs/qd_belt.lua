-- qd_belt: owned consumables shown as icon cards on a belt at the waist; grab one with either grip, bring it to the mouth
-- to select + use it (test 21). Pure layout math at the top (unit tested by tools/test_qd_belt.lua), UEVR code below (init/tick).
-- Copyright (C) 2026 Queen's Domain VR contributors. AGPL-3.0 (see LICENSE).
local M = {}

M.MAX_SLOTS = 5
M.STEP_DEG = 26.0      -- angle between neighbouring cards around the body
M.RADIUS = 24.0        -- cm from the body axis
M.FORWARD = 4.0        -- cm: body axis sits slightly in front of the head position
M.CARD_CM = 12.0       -- card width in the world
M.GRAB_CM = 14.0       -- hand within this distance of a card grabs it
M.MOUTH_CM = 17.0      -- held card within this distance of the mouth is used
M.SHOW_PITCH = -22.0   -- head pitch below this (looking down) shows the belt
M.NEAR_CM = 32.0       -- a hand this close to the belt centre also shows it
M.PX = 64

-- slot angle offsets (degrees, + = to the right of the body's forward), centred, n <= MAX_SLOTS
function M.slotAngles(n, step)
	step = step or M.STEP_DEG
	local out = {}
	for i = 1, n do out[i] = (i - (n + 1) / 2) * step end
	return out
end

-- world position of a slot: belt centre (cx, cy) + radius along yaw + angle (UE: yaw + = clockwise from above = right)
function M.slotPos(cx, cy, yawDeg, angDeg, radius)
	local a = math.rad(yawDeg + angDeg)
	return cx + math.cos(a) * radius, cy + math.sin(a) * radius
end

-- exponential yaw smoothing with wrap-around; tau seconds
function M.smoothYaw(cur, target, dt, tau)
	if cur == nil then return target end
	local d = (target - cur + 540.0) % 360.0 - 180.0
	local k = 1.0 - math.exp(-(dt or 0.0) / (tau or 0.4))
	return (cur + d * k + 540.0) % 360.0 - 180.0
end

function M.dist(ax, ay, az, bx, by, bz)
	local dx, dy, dz = ax - bx, ay - by, az - bz
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- index of the nearest slot within r of point p, or nil. slots: array of {x, y, z, on}
function M.nearestSlot(slots, n, px, py, pz, r)
	local best, bd = nil, r
	for i = 1, n do
		local s = slots[i]
		if s ~= nil and s.on then
			local d = M.dist(px, py, pz, s.x, s.y, s.z)
			if d <= bd then best, bd = i, d end
		end
	end
	return best, bd
end

-- Step 8: the game's quick slots (SaveSlot.QuickSlotItems, a TSet Lua can't read) are listed by walking the game's own
-- consumable cycle, which visits owned quick-slot items only, in rotation order. nextFn() advances and returns the
-- current item (nil = nothing). Returns the set {item = true} of items visited before the first repeat (limit steps max)
-- and their number; the caller orders them by ConsumableRotationOrder.
function M.walkCycle(nextFn, limit)
	local seen, n = {}, 0
	for _ = 1, (limit or 32) do
		local it = nextFn()
		if it == nil or seen[it] then break end
		seen[it] = true
		n = n + 1
	end
	return seen, n
end

-- belt window over the quick list (circular, like the game's cycle): returns start index, count. With more items than
-- max the selected item sits in the middle (left of middle for even max); otherwise the list is shown as is (stable).
function M.window(total, sel, max)
	local cnt = math.min(total, max)
	if total <= max or cnt <= 0 or sel == nil then return 1, cnt end
	return (sel - 1 - (cnt - 1) // 2) % total + 1, cnt
end

-- clamp the belt_slots option to 1..MAX_SLOTS (default MAX_SLOTS)
function M.slotCount(v)
	v = math.floor(tonumber(v) or M.MAX_SLOTS)
	if v < 1 then return 1 end
	if v > M.MAX_SLOTS then return M.MAX_SLOTS end
	return v
end

---------------------------------------------------------------- runtime (UEVR)
local D = nil -- deps from init
local S = {slots = {}, n = 0, items = {}, counts = {}, yaw = nil, refreshT = 0.0, shown = false, grab = nil,
	gripPrev = {false, false}, gripEdge = {false, false}, gripNow = {false, false}, errLogged = false, rot = {Pitch = 0, Yaw = 0, Roll = 0},
	loc = {X = 0, Y = 0, Z = 0}, scale = {X = 1, Y = 1, Z = 1}, created = 0, failT = 0.0, lastUseT = 0.0, angs = {}, handPos = {},
	pressed = {false, false}, ownedCounts = {}, list = {}, selAddr = nil, selCheckT = 0.0, mask = nil, quick = nil, forceWalk = true}
M.S = S

local function log(msg) if D ~= nil and D.log ~= nil then D.log("[BELT] " .. msg) end end

function M.init(deps)
	D = deps
	S.ktl = nil
	pcall(function() S.ktl = D.uevrUtils.find_default_instance("Class /Script/Engine.KismetTextLibrary") end)
	log("init")
end

local function enabled() return D ~= nil and D.configui.getValue("belt") ~= false end

-- Step 8: walk the game's cycle (owned quick-slot items only), then put the selection back. Returns {address = true}.
local function walkQuick(pawn, slot, n)
	local s0 = slot.SelectedConsumable
	local seen = M.walkCycle(function()
		pawn:SelectNextConsumable()
		local s = slot.SelectedConsumable
		return s ~= nil and s:get_address() or nil
	end, n + 2)
	pcall(function() slot.SelectedConsumable = s0 end)
	local hud = pawn.HUD ~= nil and pawn.HUD.ConsumableHUD or nil
	if hud ~= nil and s0 ~= nil then pcall(function() hud:SetSelectedItem(s0) end) end
	return seen
end

-- owned quick-slot consumables (count > 0), in the game's rotation order, at most belt_slots (<= MAX_SLOTS).
-- The quick set is re-walked when ownership or the set's header (SDK: SaveSlot.QuickSlotItems TSet at 0x468:
-- Elements.Data, .Num at 0x470, NumFreeIndices at 0x49C) changes, or when forced (belt shown: catches same-size swaps
-- made in the inventory menu). If the walk fails, all owned items are shown (pre-step-8 behaviour).
function M.refresh(forceWalk)
	local pawn = uevr.api:get_local_pawn(0)
	local gi = uevr.api:get_engine().GameInstance
	local n = 0
	local ro = pawn ~= nil and pawn.ConsumableRotationOrder or nil
	if gi ~= nil and ro ~= nil then
		local max = M.slotCount(D.configui.getValue("belt_slots"))
		local oc, mask = S.ownedCounts, 0
		for i, it in ipairs(ro) do
			local ok, c = pcall(function() return gi:ReadInventoryItemCount(it) end)
			c = (ok and type(c) == "number") and c or 0
			oc[i] = c
			if c > 0 then mask = mask + (i <= 62 and (1 << (i - 1)) or i) end
		end
		local slot = gi.ActiveSaveSlot
		local okH, qd, qn, qf = pcall(function() return slot:read_qword(0x468), slot:read_dword(0x470), slot:read_dword(0x49C) end)
		if forceWalk or not okH or mask ~= S.mask or qd ~= S.qsData or qn ~= S.qsNum or qf ~= S.qsFree then
			S.mask, S.qsData, S.qsNum, S.qsFree = mask, qd, qn, qf
			local okW, seen = pcall(walkQuick, pawn, slot, #ro)
			if okW then S.quick = seen else
				S.quick = nil
				if not S.walkErrLogged then S.walkErrLogged = true log("quick slot walk failed, showing all owned: " .. tostring(seen)) end
			end
		end
		-- all owned quick items, then a window of max around the game's selected item (its next/previous scrolls the belt)
		local q, L, total = S.quick, S.list, 0
		local selAddr = nil
		pcall(function() local s = slot.SelectedConsumable if s ~= nil then selAddr = s:get_address() end end)
		S.selAddr = selAddr
		local selPos = nil
		for i, it in ipairs(ro) do
			if oc[i] > 0 then
				local a = it:get_address()
				if q == nil or q[a] then
					total = total + 1
					L[total] = i
					if a == selAddr then selPos = total end
				end
			end
		end
		for k = total + 1, #L do L[k] = nil end
		local start, cnt = M.window(total, selPos, max)
		for k = 0, cnt - 1 do
			local j = L[(start - 1 + k) % total + 1]
			n = n + 1
			S.items[n], S.counts[n] = ro[j], oc[j]
		end
	end
	for i = n + 1, M.MAX_SLOTS do S.items[i], S.counts[i] = nil, nil end
	S.n = n
end

local function setText(slot, count)
	if slot.text == nil or S.ktl == nil or slot.shownCount == count then return end
	slot.shownCount = count
	pcall(function() slot.text:SetText(S.ktl:Conv_StringToText(count > 1 and tostring(count) or "")) end)
end

local function createSlot(i)
	if os.clock() < S.failT then return nil end
	local widget = nil
	for _, cls in ipairs(D.hosts) do
		local ok, w = pcall(D.uevrUtils.createWidget, cls)
		if ok and w ~= nil and w.WidgetTree ~= nil then widget = w break end
	end
	if widget == nil then S.failT = os.clock() + 5.0 log("no host widget") return nil end
	local img = D.uevrUtils.spawn_object("Class /Script/UMG.Image", widget.WidgetTree)
	if img == nil then S.failT = os.clock() + 5.0 log("Image spawn failed") return nil end
	local root, text = img, nil
	pcall(function()
		local ov = D.uevrUtils.spawn_object("Class /Script/UMG.Overlay", widget.WidgetTree)
		local bg = D.uevrUtils.spawn_object("Class /Script/UMG.Image", widget.WidgetTree)
		local tb = D.uevrUtils.spawn_object("Class /Script/UMG.TextBlock", widget.WidgetTree)
		if ov == nil or bg == nil then return end
		bg:SetColorAndOpacity({R = 0.32, G = 0.27, B = 0.18, A = 0.6}) -- parchment tint: visible on dark ground
		local s0 = ov:AddChildToOverlay(bg)
		local s1 = ov:AddChildToOverlay(img)
		s0:SetHorizontalAlignment(0) s0:SetVerticalAlignment(0)
		s1:SetHorizontalAlignment(0) s1:SetVerticalAlignment(0)
		s1:SetPadding({Left = 4, Top = 4, Right = 4, Bottom = 4})
		if tb ~= nil then
			local s2 = ov:AddChildToOverlay(tb)
			s2:SetHorizontalAlignment(2) s2:SetVerticalAlignment(2) -- right, bottom
			pcall(function() tb:SetShadowOffset({X = 1.0, Y = 1.0}) end)
			text = tb
		end
		root = ov
	end)
	widget.WidgetTree.RootWidget = root
	local comp = D.uevrUtils.createWidgetComponent(widget, {removeFromViewport = false, twoSided = true, drawSize = vector_2(M.PX, M.PX)})
	if comp == nil then S.failT = os.clock() + 5.0 log("WidgetComponent failed") return nil end
	pcall(function() comp.BlendMode = 2 comp:SetMaterial(0, comp.TranslucentMaterial) end)
	pcall(function() comp:SetCastShadow(false) end)
	pcall(function() comp:SetCollisionEnabled(0) end)
	S.created = S.created + 1
	local slot = {comp = comp, img = img, text = text, item = nil, x = 0, y = 0, z = 0, on = false, visible = true}
	log(string.format("card %d created text=%s", i, tostring(text ~= nil)))
	return slot
end

local function show(slot, v)
	if slot.visible ~= v then
		slot.visible = v
		pcall(function() slot.comp:SetVisibility(v, true) end)
	end
end

local function clearInput() -- no hand counts as "at a card" and no latched press survives a pause/menu/level change
	S.nearHand, S.armed = nil, nil
	S.gripEdge[1], S.gripEdge[2] = false, false
end

function M.hideAll()
	for i = 1, M.MAX_SLOTS do local s = S.slots[i] if s ~= nil then show(s, false) s.on = false end end
	S.shown = false
	S.grab = nil
	clearInput()
end

-- level change: the cards' owner actor dies with the level; drop them so tick recreates them
function M.reset()
	M.hideAll()
	for i = 1, M.MAX_SLOTS do S.slots[i] = nil end
	S.yaw = nil
end

local function place(slot, x, y, z, hx, hy, hz)
	S.loc.X, S.loc.Y, S.loc.Z = x, y, z
	slot.comp:K2_SetWorldLocation(S.loc, false, D.hr, true)
	local dx, dy, dz = hx - x, hy - y, hz - z
	S.rot.Yaw = math.deg(math.atan(dy, dx))
	S.rot.Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
	S.rot.Roll = 0.0
	slot.comp:K2_SetWorldRotation(S.rot, false, D.hr, true)
end

-- xinput: grip edges for both hands; a grab in progress swallows its grip so neither the game nor the pickup code sees it
function M.onXInput(state)
	if not enabled() then return end
	local b = state.Gamepad.wButtons
	S.gripNow[1] = (b & XINPUT_GAMEPAD_LEFT_SHOULDER) ~= 0
	S.gripNow[2] = (b & XINPUT_GAMEPAD_RIGHT_SHOULDER) ~= 0
	local pressed = S.pressed
	for h = 1, 2 do
		pressed[h] = S.gripNow[h] and not S.gripPrev[h]
		if pressed[h] then S.gripEdge[h] = true end
		S.gripPrev[h] = S.gripNow[h]
	end
	-- a FRESH press with the hand at a card arms that hand; a grab or an armed hand owns its button until released
	if S.nearHand ~= nil and pressed[S.nearHand] and S.grab == nil then S.armed = S.nearHand end
	if S.armed ~= nil and not S.gripNow[S.armed] then S.armed = nil end
	if S.grab ~= nil or S.armed ~= nil then
		local h = (S.grab ~= nil) and S.grab.hand or S.armed
		local bit = (h == 1) and XINPUT_GAMEPAD_LEFT_SHOULDER or XINPUT_GAMEPAD_RIGHT_SHOULDER
		if (b & bit) ~= 0 then state.Gamepad.wButtons = b & ~bit end
	end
end

local function itemCount(item)
	local ok, c = pcall(function() return uevr.api:get_engine().GameInstance:ReadInventoryItemCount(item) end)
	return ok and c or -1
end

-- make item the game's selected consumable (the flat HUD's current item); the game cycles owned items only
-- Step 7 VERIFIED: the use event consumes GameInstance.ActiveSaveSlot.SelectedConsumable, NOT the HUD's CurrentItem
-- (HUD-only selection used whatever the slot held, e.g. the game's auto-picked heal item when hurt). Set both.
local function selectItem(pawn, item)
	local okSlot = pcall(function()
		local slot = uevr.api:get_engine().GameInstance.ActiveSaveSlot
		slot.SelectedConsumable = item
		if slot.SelectedConsumable ~= item then error("not set") end
	end)
	local hud = pawn.HUD ~= nil and pawn.HUD.ConsumableHUD or nil
	if okSlot then
		if hud ~= nil then pcall(function() hud:SetSelectedItem(item) end) end -- display only
		return true
	end
	if hud == nil then return false end
	if pcall(function() hud:SetSelectedItem(item) end) and hud.CurrentItem == item then return true end -- test 22: works when cycling does not
	if hud.CurrentItem == nil then pcall(function() pawn:RefreshSelectedConsumable() end) end
	local start = hud.CurrentItem
	for _ = 1, 32 do
		if hud.CurrentItem == item then return true end
		pawn:SelectNextConsumable()
		if hud.CurrentItem == start then return false end -- full cycle: the item is no longer owned
	end
	return hud.CurrentItem == item
end

-- Test 21 findings: ScriptUseItem returns fine but never lowered the count (possible free use: not used); the item is
-- selected the game's way, then the game's own UseItem input event runs (same code as its button, with its costs).
-- Test 22 VERIFIED: event consumes (count 4->3, heals) when the item applies (heal at full health does nothing, count unchanged).
local function useItem(item)
	local pawn = uevr.api:get_local_pawn(0)
	if pawn == nil then return false, "no pawn" end
	local okD, dis = pcall(function() return pawn:IsUseItemDisabled() end)
	if okD and dis == true then return false, "use disabled" end
	local okS, sel = pcall(selectItem, pawn, item)
	if not okS or not sel then return false, "select failed " .. tostring(sel) end
	S.verify = {item = item, before = itemCount(item), t = os.clock() + 1.5}
	if S.useKey == nil then S.useKey = {KeyName = D.uevrUtils.fname_from_string("Gamepad_FaceButton_Top")} end
	local ok, err = pcall(function() pawn:InpActEvt_UseItem_K2Node_InputActionEvent_21(S.useKey) end)
	return ok, err
end

function M.tick(dt)
	if not enabled() then if S.shown or S.grab ~= nil then M.hideAll() end return end
	local now = os.clock()
	if now > S.refreshT then
		S.refreshT = now + 0.5
		pcall(M.refresh, S.forceWalk)
		S.forceWalk = false
		for i = 1, M.MAX_SLOTS do -- a card whose component died (level change) is recreated
			local s = S.slots[i]
			if s ~= nil and D.uevrUtils.getValid(s.comp) == nil then S.slots[i] = nil if S.grab ~= nil and S.grab.slot == i then S.grab = nil end end
		end
	end
	if S.verify ~= nil and now > S.verify.t then
		log(string.format("use result: count %d -> %d", S.verify.before, itemCount(S.verify.item)))
		S.verify = nil
	end
	if S.shown and now > S.selCheckT then -- game's next/previous item changed the selection: re-centre the belt soon
		S.selCheckT = now + 0.1
		pcall(function()
			local s = uevr.api:get_engine().GameInstance.ActiveSaveSlot.SelectedConsumable
			local a = s ~= nil and s:get_address() or nil
			if a ~= S.selAddr then S.selAddr = a S.refreshT = 0.0 end
		end)
	end
	local head = D.controllers.getController(2)
	local lh, rh = D.controllers.getController(0), D.controllers.getController(1)
	if head == nil then clearInput() return end
	local hp, hr = head:K2_GetComponentLocation(), head:K2_GetComponentRotation()
	S.yaw = M.smoothYaw(S.yaw, hr.Yaw, dt, 0.45)
	local drop = (D.configui.getValue("belt_drop") or 60.0)
	local fx, fy = math.cos(math.rad(S.yaw)), math.sin(math.rad(S.yaw))
	local cx, cy, cz = hp.X + fx * M.FORWARD, hp.Y + fy * M.FORWARD, hp.Z - drop
	local hands = S.handPos
	hands[1], hands[2] = lh ~= nil and lh:K2_GetComponentLocation() or nil, rh ~= nil and rh:K2_GetComponentLocation() or nil
	-- layout
	local angs = S.angs[S.n]
	if angs == nil then angs = M.slotAngles(S.n) S.angs[S.n] = angs end
	for i = 1, S.n do
		local s = S.slots[i]
		if s == nil then s = createSlot(i) S.slots[i] = s end
		if s ~= nil then
			s.x, s.y = M.slotPos(cx, cy, S.yaw, angs[i], M.RADIUS)
			s.z = cz
			s.on = true
			if s.item ~= S.items[i] then
				s.item = S.items[i]
				s.shownCount = nil
				pcall(function() s.img:SetBrushFromTexture(s.item.ItemIcon, false) end)
			end
			setText(s, S.counts[i] or 0)
		end
	end
	for i = S.n + 1, M.MAX_SLOTS do local s = S.slots[i] if s ~= nil then s.on = false show(s, false) end end
	-- which hand is at a card (for the xinput swallow) + grab start on a fresh grip
	S.nearHand = nil
	local nearBelt = false
	for h = 1, 2 do
		local p = hands[h]
		if p ~= nil then
			if M.dist(p.X, p.Y, p.Z, cx, cy, cz) < M.RADIUS + M.NEAR_CM then nearBelt = true end
			local i = M.nearestSlot(S.slots, S.n, p.X, p.Y, p.Z, M.GRAB_CM)
			if i ~= nil and S.grab == nil then
				S.nearHand = h
				if S.gripEdge[h] then
					S.grab = {hand = h, slot = i, item = S.slots[i].item}
					D.uevrUtils.triggerHapticVibration(h == 1 and Handed.Left or Handed.Right, 0, 0.05, 200, 0.5)
					log(string.format("grab card %d hand=%s", i, h == 1 and "L" or "R"))
				end
			end
		end
		S.gripEdge[h] = false
	end
	-- held card follows the hand; at the mouth it is used
	local g = S.grab
	if g ~= nil then
		local p = hands[g.hand]
		local s = S.slots[g.slot]
		if p == nil or s == nil or not S.gripNow[g.hand] then
			S.grab = nil
		else
			s.x, s.y, s.z = p.X, p.Y, p.Z + 3.0
			local mx, my, mz = hp.X + fx * 4.0, hp.Y + fy * 4.0, hp.Z - 9.0
			if M.dist(p.X, p.Y, p.Z, mx, my, mz) < M.MOUTH_CM and now - S.lastUseT > 1.0 then
				S.lastUseT = now
				local ok, err = useItem(g.item)
				D.uevrUtils.triggerHapticVibration(g.hand == 1 and Handed.Left or Handed.Right, 0, ok and 0.15 or 0.04, 150, ok and 0.9 or 0.3)
				log("use ok=" .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
				S.grab = nil
				S.refreshT = 0.0
			end
		end
	end
	-- visibility: looking down, a hand near the belt, or holding a card
	local want = (hr.Pitch < M.SHOW_PITCH) or nearBelt or S.grab ~= nil
	if want and not S.shown then S.forceWalk = true S.refreshT = 0.0 end -- re-read quick slots (menu edits) on next tick
	S.shown = want
	local sc = M.CARD_CM / M.PX
	S.scale.X, S.scale.Y, S.scale.Z = sc, sc, sc
	for i = 1, S.n do
		local s = S.slots[i]
		if s ~= nil then
			if want then
				pcall(place, s, s.x, s.y, s.z, hp.X, hp.Y, hp.Z)
				if not s.scaled then s.scaled = true pcall(function() s.comp:SetWorldScale3D(S.scale) end) end
			end
			show(s, want)
		end
	end
end

return M
