-- qd_belt: owned consumables shown as icon cards on a belt at the waist; grab one with either grip, bring it to the mouth
-- to select + use it (test 21). Pure layout math at the top (unit tested by tools/test_qd_belt.lua), UEVR code below (init/tick).
-- Copyright (C) 2026 Queen's Domain VR contributors. AGPL-3.0 (see LICENSE).
local M = {}

M.MAX_SLOTS = 5
M.STEP_DEG = 33.0      -- angle between neighbouring cards around the body (step 30: 26 let the frames overlap)
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
-- step 39: previous / next entries around cur in a slot list (n entries, may hold nils). Returns prev, next
-- (nil when there is no other weapon). Game order (Test 49): NextWeapon = index + 1, PreviousWeapon = index - 1, both wrap.
function M.neighbours(list, n, cur, selIdx0)
	local ci = nil
	for i = 1, n do if list[i] ~= nil and list[i] == cur then ci = i break end end
	if ci == nil and selIdx0 ~= nil and selIdx0 >= 0 and selIdx0 < n then ci = selIdx0 + 1 end
	if ci == nil then return nil, nil end
	local prev, nxt = nil, nil
	for k = 1, n - 1 do local e = list[(ci - 1 + k) % n + 1] if e ~= nil and e ~= list[ci] then nxt = e break end end
	for k = 1, n - 1 do local e = list[(ci - 1 - k) % n + 1] if e ~= nil and e ~= list[ci] then prev = e break end end
	return prev, nxt
end

-- step 46: lower card row in the body frame. k: 1 weapon prev, 2 weapon next (right side), 3 throwable prev,
-- 4 throwable next (left side); prev left of next on each side. Returns forward, lateral cm (lateral + = right).
M.WCARD_INNER_CM = 9.0  -- inner cards' centre this far from the middle (6 cm gap between the two groups)
M.WCARD_OUTER_CM = 23.0 -- outer cards (2 cm gap to the inner card of the 12 cm wide cards)
M.WCARD_FWD_IN = 9.0    -- inner cards a bit further forward, outer ones closer: follows the body curve
M.WCARD_FWD_OUT = 3.0
function M.wcardPos(k)
	local outer = (k == 2 or k == 3)
	local lat = outer and M.WCARD_OUTER_CM or M.WCARD_INNER_CM
	if k >= 3 then lat = -lat end
	return outer and M.WCARD_FWD_OUT or M.WCARD_FWD_IN, lat
end

-- step 46: insert item with sort key id into list[1..n] (ascending), returns the new n (keys kept in parallel ks)
function M.sortedInsert(list, ks, n, item, id)
	local i = n
	while i >= 1 and ks[i] > id do list[i + 1], ks[i + 1] = list[i], ks[i] i = i - 1 end
	list[i + 1], ks[i + 1] = item, id
	return n + 1
end

-- step 49: tiers of one item look the same (same model, ascending SortOrder: live check 2026-11-16). Rank of entry i
-- among entries with the same key, by sort value: returns rank (1 = lowest), group size. keys/sorts are parallel arrays.
function M.tierRank(keys, sorts, n, i)
	local k, so = keys[i], sorts[i]
	if k == nil then return 1, 1 end
	local rank, size = 1, 0
	for j = 1, n do
		if keys[j] == k then
			size = size + 1
			if sorts[j] < so or (sorts[j] == so and j < i) then rank = rank + 1 end
		end
	end
	return rank, size
end
M.PIPS = 5 -- most tier pips a card shows

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

-- step 58: healing items carry DataImportKey "item_heal_<family>[_<tier>]" (live 2026-11-16); their heal amount is
-- the balance asset field "Healing<Family><tier>HealAmount" (tier 1 when the key has no suffix). nil = not healing.
function M.healField(key)
	if type(key) ~= "string" then return nil end
	local fam, tier = key:match("^item_heal_(%a+)_?(%d*)$")
	if fam == nil then return nil end
	if tier == "" then tier = "1" end
	return "Healing" .. fam:sub(1, 1):upper() .. fam:sub(2) .. tier .. "HealAmount"
end

-- step 58: index of the weakest owned healing item: amounts[i] = heal amount (nil = not healing), owned[i] = usable.
-- Ties keep the earlier entry. Returns nil when none is owned.
function M.healPick(amounts, owned, n)
	local best, bestA = nil, nil
	for i = 1, n do
		local a = amounts[i]
		if type(a) == "number" and owned[i] and (bestA == nil or a < bestA) then best, bestA = i, a end
	end
	return best
end

-- step 21: an item's 3D model = the StaticMesh of its pickup class's "PickupGraphics" component template.
-- fullClassName = get_full_name() of item.Pickup_BP ("BlueprintGeneratedClass /Game/X.X_C") -> template object name
function M.meshTemplateName(fullClassName)
	if type(fullClassName) ~= "string" then return nil end
	local path = fullClassName:match("^%S+ (/%S+)$")
	if path == nil then return nil end
	return "StaticMeshComponent " .. path .. ".PickupGraphics_GEN_VARIABLE"
end

-- uniform scale so the mesh's largest half extent (cm) becomes halfCm; nil for a degenerate mesh
function M.meshScale(maxHalfExtent, halfCm)
	if type(maxHalfExtent) ~= "number" or maxHalfExtent < 0.01 then return nil end
	local sc = halfCm / maxHalfExtent
	if sc > 50.0 then sc = 50.0 end
	return sc
end

-- the slot a grip would take now: the grabbed one, else the nearest card within r of either hand. Returns slot, hand
function M.targetSlot(slots, n, hands, r, grab)
	if grab ~= nil then return grab.slot, grab.hand end
	local best, bh, bd = nil, nil, r
	for h = 1, 2 do
		local p = hands[h]
		if p ~= nil then
			local i, d = M.nearestSlot(slots, n, p.X, p.Y, p.Z, bd)
			if i ~= nil then best, bh, bd = i, h, d end
		end
	end
	return best, bh
end

---------------------------------------------------------------- runtime (UEVR)
local D = nil -- deps from init
local S = {slots = {}, wslots = {}, wItems = {}, wlist = {}, tlist = {}, tkeys = {}, wCounts = {}, tCandBuf = {}, tCandT = 0.0, tOut = {}, tOut2 = {}, n = 0, items = {}, counts = {}, yaw = nil, refreshT = 0.0, shown = false, grab = nil,
	gripPrev = {false, false}, gripEdge = {false, false}, gripNow = {false, false}, errLogged = false, rot = {Pitch = 0, Yaw = 0, Roll = 0},
	loc = {X = 0, Y = 0, Z = 0}, scale = {X = 1, Y = 1, Z = 1}, created = 0, failT = 0.0, lastUseT = 0.0, angs = {}, handPos = {},
	pressed = {false, false}, ownedCounts = {}, list = {}, healOwn = {}, selAddr = nil, selCheckT = 0.0, mask = nil, quick = nil, forceWalk = true,
	meshes = {}, mloc = {X = 0, Y = 0, Z = 0}, mrot = {Pitch = 0, Yaw = 0, Roll = 0}, mscale = {X = 1, Y = 1, Z = 1}, spin = 0.0, hl = nil}
M.MODEL_HALF_CM = 4.5  -- model's largest half extent on the belt
M.HL_SCALE = 1.4       -- highlighted (grip would take it) model scale
M.SPIN_DPS = 40.0      -- idle model spin
M.MODEL_FWD_CM = 5.0   -- model centre this far in front of its card
M.HOLD_FWD_CM = 7.0    -- step 31: held model centre this far forward of the controller
M.HOLD_UP_CM = -1.0
local BG_N = {R = 0.32, G = 0.27, B = 0.18, A = 0.6}  -- parchment tint
local BG_H = {R = 0.95, G = 0.78, B = 0.30, A = 0.85} -- highlighted card
local EDGE_N = {R = 0.55, G = 0.47, B = 0.30, A = 0.55} -- model cards: frame only (any fill draws over the model)
local EDGE_H = {R = 1.0, G = 0.80, B = 0.30, A = 1.0}
local EDGE_S = {R = 0.35, G = 0.85, B = 1.0, A = 1.0} -- step 33: the game's selected consumable (B uses it)
local BG_S = {R = 0.25, G = 0.55, B = 0.70, A = 0.75}
local EDGE_ALIGN = {{0, 1}, {0, 3}, {1, 0}, {3, 0}} -- {H, V}: top, bottom, left, right bars (0 Fill, 1 Left/Top, 3 Right/Bottom)
local EDGE_PX = 4
M.S = S

local function log(msg) if D ~= nil and D.log ~= nil then D.log("[BELT] " .. msg) end end

function M.init(deps)
	D = deps
	log("init")
end

local function enabled() return D ~= nil and D.configui.getValue("belt") ~= false end

-- step 58: heal amount per rotation-order entry (false = not healing), rebuilt when the rotation order length changes.
-- Balance asset path found live 2026-11-16; if it can't be read, SortOrder stands in (still lowest tier first).
local BALANCE = "PlayerBalance_C /Game/Player/PlayerBalance.PlayerBalance"
local function healAmounts(ro)
	if S.healN == #ro then return S.healAmt end
	S.healN, S.healAmt = #ro, {}
	local bal = nil
	pcall(function() bal = uevr.api:find_uobject(BALANCE) end)
	local nh, fb = 0, 0
	for i, it in ipairs(ro) do
		local a = false
		pcall(function()
			local f = M.healField(it.DataImportKey:to_string())
			if f ~= nil then
				local v = nil
				if bal ~= nil then pcall(function() v = bal[f] end) end
				if type(v) ~= "number" then v = it.SortOrder or i fb = fb + 1 end
				a = v
			end
		end)
		S.healAmt[i] = a
		if a then nh = nh + 1 end
	end
	log(string.format("heal card: %d healing types of %d (%d without balance amount)", nh, #ro, fb))
	return S.healAmt
end

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
		-- step 58 (belt_heal_card): one fixed leftmost card = the weakest owned healing item; other healing types are
		-- left out of the scrolling window
		local ha = nil
		if D.configui.getValue("belt_heal_card") ~= false then
			local okA, r = pcall(healAmounts, ro)
			if okA then ha = r end
		end
		local hOwn = S.healOwn
		for i, it in ipairs(ro) do
			hOwn[i] = false
			if oc[i] > 0 then
				local a = it:get_address()
				if q == nil or q[a] then
					if ha ~= nil and ha[i] then hOwn[i] = true
					else
						total = total + 1
						L[total] = i
						if a == selAddr then selPos = total end
					end
				end
			end
		end
		for k = total + 1, #L do L[k] = nil end
		local hj = ha ~= nil and M.healPick(ha, hOwn, #ro) or nil
		if hj ~= nil then
			n = 1
			S.items[1], S.counts[1] = ro[hj], oc[hj]
			max = max - 1
		end
		local start, cnt = M.window(total, selPos, max)
		for k = 0, cnt - 1 do
			local j = L[(start - 1 + k) % total + 1]
			n = n + 1
			S.items[n], S.counts[n] = ro[j], oc[j]
		end
	end
	for i = n + 1, M.MAX_SLOTS do S.items[i], S.counts[i] = nil, nil end
	S.n = n
	-- step 39: item data of the previous / next slot weapon (left / right shoulder) for the display-only cards
	local pd, nd = nil, nil
	pcall(function()
		local ws = pawn.WeaponSelection
		local t = S.wlist
		for i = #t, 1, -1 do t[i] = nil end
		ws:GetWeaponsInSlots(false, t)
		local pw, nw = M.neighbours(t, #t, pawn.CurrentInHandWeapon, ws.SelectedWeaponSlot)
		if pw ~= nil then pd = pw.ItemData end
		if nw ~= nil then nd = nw.ItemData end
	end)
	S.wItems[1], S.wItems[2] = pd, nd
	-- step 46: previous / next equipped throwable (left shoulder / reach across) for the left-side cards
	local tp, tn = nil, nil
	local okT, errT = pcall(function()
		local o = S.tOut
		o.result = nil
		pawn:GetCurrentlySelectedDaggerType(o)
		local cur = o.result
		if cur == nil then return end
		if S.tUtil == nil then
			local c = uevr.api:find_uobject("Class /Script/QueensDomain.FS_SaveGameUtils")
			if c ~= nil then S.tUtil = c:get_class_default_object() end
		end
		local now = os.clock()
		if S.tCand == nil or now > S.tCandT then -- candidates = item data of the selected throwable's equip slot type
			S.tCandT = now + 10.0
			local st, all = cur.EquipSlot, UEVR_UObjectHook.get_objects_by_class(cur:get_class(), false)
			local c, n = S.tCandBuf, 0
			for i = 1, #all do
				local it = all[i]
				if it.EquipSlot == st and not it:get_full_name():find("Default__", 1, true) then n = n + 1 c[n] = it end
			end
			for i = #c, n + 1, -1 do c[i] = nil end
			S.tCand = c
		end
		local L, K, n = S.tlist, S.tkeys, 0
		local slot = gi.ActiveSaveSlot
		for i = 1, #S.tCand do
			local it = S.tCand[i]
			if slot:IsItemEquipped(it) then
				local id = S.tUtil ~= nil and S.tUtil:GetItemEquipSlotID(gi, it, S.tOut2) or i
				n = M.sortedInsert(L, K, n, it, tonumber(id) or i)
			end
		end
		for i = #L, n + 1, -1 do L[i], K[i] = nil, nil end
		if n ~= S.tN then S.tN = n log("throwables equipped: " .. n) end
		local p, x = M.neighbours(L, n, cur, nil)
		tp, tn = p, x
	end)
	if not okT and not S.tErrLogged then S.tErrLogged = true log("throwable cards failed: " .. tostring(errT)) end
	S.wItems[3], S.wItems[4] = tp, tn
	-- step 49b: current charges of those throwables (one charge component per throwable)
	for k = 3, 4 do
		local c = nil
		local it = S.wItems[k]
		if it ~= nil then pcall(function() c = pawn:GetDaggerChargeCompFromItem(it).CurrentCharges end) end
		S.wCounts[k] = c
	end
end

-- step 49: owned count on the card. FText can't be built from Lua (Conv_StringToText returns nil, SetText throws), so
-- the number is a style-less SpinBox (float value, 0 fraction digits). count < 1 or nil hides it.
local function setText(slot, count)
	if slot.text == nil or slot.shownCount == count then return end
	slot.shownCount = count
	pcall(function()
		if count ~= nil and count >= 1 then
			slot.text:SetValue(count)
			slot.text:SetVisibility(4)
		else
			slot.text:SetVisibility(2)
		end
	end)
end

-- step 49: tier pips (rank among owned-or-not consumables sharing the same model); hidden for single-tier items
local function setPips(slot, rank, size)
	if slot.pips == nil then return end
	local n = (size ~= nil and size > 1) and math.min(rank or 0, M.PIPS) or 0
	if slot.pipN == n then return end
	slot.pipN = n
	for k = 1, M.PIPS do pcall(function() slot.pips[k]:SetVisibility(k <= n and 4 or 2) end) end
end

-- font for the numbers: a copy of the first game text widget's font (the engine default is thin); nil = default
local function gameFont()
	if S.fontTried then return S.fontSrc end
	S.fontTried = true
	pcall(function()
		local all = UEVR_UObjectHook.get_objects_by_class(uevr.api:find_uobject("Class /Script/UMG.TextBlock"), false)
		for i = 1, #all do
			local t = all[i]
			local ok, fo = pcall(function() return t.Font.FontObject end)
			if ok and fo ~= nil and not t:get_full_name():find("Default__", 1, true) then S.fontSrc = t break end
		end
	end)
	log("count font from game widget: " .. tostring(S.fontSrc ~= nil))
	return S.fontSrc
end

local NUM_FG = {SpecifiedColor = {R = 1.0, G = 0.95, B = 0.8, A = 1.0}, ColorUseRule = 0}
local PIP_C = {R = 1.0, G = 0.80, B = 0.30, A = 1.0}
local function makeNumber(wt)
	local sb = D.uevrUtils.spawn_object("Class /Script/UMG.SpinBox", wt)
	if sb == nil then return nil end
	-- style before the widget is added (Slate is built from it then); struct reads are live views of sb's memory
	pcall(function()
		local st = sb.WidgetStyle
		for _, k in ipairs({"BackgroundBrush", "HoveredBackgroundBrush", "ActiveFillBrush", "InactiveFillBrush", "ArrowsImage"}) do
			pcall(function() st[k].DrawAs = 0 end) -- NoDrawType
		end
		pcall(function() st.TextPadding = {Left = 0, Top = 0, Right = 1, Bottom = 0} end)
		pcall(function() st.ArrowsImage.ImageSize = {X = 0, Y = 0} end)
	end)
	pcall(function() sb.Justification = 2 end) -- right (Slate keeps a ~36 px minimum width)
	pcall(function()
		local src = gameFont()
		if src ~= nil then sb.Font = src.Font end -- copied into sb; only sb's copy is changed below
		local f = sb.Font
		f.Size = M.NUM_PT
		pcall(function() f.OutlineSettings.OutlineSize = 2 f.OutlineSettings.OutlineColor = {R = 0, G = 0, B = 0, A = 1} end)
	end)
	pcall(function() sb.ForegroundColor = NUM_FG end)
	pcall(function() sb:SetMinFractionalDigits(0) sb:SetMaxFractionalDigits(0) end)
	pcall(function() sb:SetVisibility(2) end)
	return sb
end
M.NUM_PT = 12 -- count font size (card canvas is M.PX px; 18 covered most of the model)

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
	local root, text, bgImg, edges, pips = img, nil, nil, nil, nil
	pcall(function()
		local ov = D.uevrUtils.spawn_object("Class /Script/UMG.Overlay", widget.WidgetTree)
		local bg = D.uevrUtils.spawn_object("Class /Script/UMG.Image", widget.WidgetTree)
		local tb = makeNumber(widget.WidgetTree)
		if ov == nil or bg == nil then return end
		bgImg = bg
		bg:SetColorAndOpacity(BG_N) -- parchment tint: visible on dark ground
		local s0 = ov:AddChildToOverlay(bg)
		local s1 = ov:AddChildToOverlay(img)
		s0:SetHorizontalAlignment(0) s0:SetVerticalAlignment(0)
		s1:SetHorizontalAlignment(0) s1:SetVerticalAlignment(0)
		s1:SetPadding({Left = 4, Top = 4, Right = 4, Bottom = 4})
		pcall(function() -- step 21: frame bars shown instead of the fill on model cards
			local e = {}
			for k = 1, 4 do
				local bar = D.uevrUtils.spawn_object("Class /Script/UMG.Image", widget.WidgetTree)
				if bar == nil then return end
				bar:SetBrushSize({X = EDGE_PX, Y = EDGE_PX})
				bar:SetColorAndOpacity(EDGE_N)
				bar:SetVisibility(2)
				local sl = ov:AddChildToOverlay(bar)
				sl:SetHorizontalAlignment(EDGE_ALIGN[k][1]) sl:SetVerticalAlignment(EDGE_ALIGN[k][2])
				e[k] = bar
			end
			edges = e
		end)
		if tb ~= nil then
			local s2 = ov:AddChildToOverlay(tb)
			s2:SetHorizontalAlignment(2) s2:SetVerticalAlignment(2) -- right, bottom
			pcall(function() s2:SetPadding({Left = 0, Top = 0, Right = -2, Bottom = -3}) end)
			text = tb
		end
		pcall(function() -- step 49: tier pips, top left
			local hb = D.uevrUtils.spawn_object("Class /Script/UMG.HorizontalBox", widget.WidgetTree)
			if hb == nil then return end
			local p = {}
			for k = 1, M.PIPS do
				local pip = D.uevrUtils.spawn_object("Class /Script/UMG.Image", widget.WidgetTree)
				if pip == nil then return end
				pip:SetBrushSize({X = 6, Y = 6})
				pip:SetColorAndOpacity(PIP_C)
				pip:SetVisibility(2)
				local hs = hb:AddChildToHorizontalBox(pip)
				pcall(function() hs:SetPadding({Left = 0, Top = 0, Right = 2, Bottom = 0}) end)
				p[k] = pip
			end
			local s3 = ov:AddChildToOverlay(hb)
			s3:SetHorizontalAlignment(1) s3:SetVerticalAlignment(1) -- left, top
			s3:SetPadding({Left = 5, Top = 5, Right = 0, Bottom = 0})
			pips = p
		end)
		root = ov
	end)
	widget.WidgetTree.RootWidget = root
	local comp = D.uevrUtils.createWidgetComponent(widget, {removeFromViewport = false, twoSided = true, drawSize = vector_2(M.PX, M.PX)})
	if comp == nil then S.failT = os.clock() + 5.0 log("WidgetComponent failed") return nil end
	pcall(function() comp.BlendMode = 2 comp:SetMaterial(0, comp.TranslucentMaterial) end)
	pcall(function() comp:SetCastShadow(false) end)
	pcall(function() comp:SetCollisionEnabled(0) end)
	S.created = S.created + 1
	local slot = {comp = comp, img = img, text = text, pips = pips, bg = bgImg, edges = edges, item = nil, x = 0, y = 0, z = 0, on = false, visible = true,
		mesh = nil, model = nil, hl = false}
	log(string.format("card %d created number=%s pips=%s", i, tostring(text ~= nil), tostring(pips ~= nil)))
	return slot
end

local function show(slot, v)
	if slot.visible ~= v then
		slot.visible = v
		pcall(function() slot.comp:SetVisibility(v, true) end)
		if slot.mesh ~= nil then pcall(function() slot.mesh:SetVisibility(v and slot.model ~= nil, false) end) end
	end
end

-- step 21: {mesh, half, ox, oy, oz} for an item (cached per item; false = no model -> icon)
local function itemModel(item)
	local key = item:get_address()
	local m = S.meshes[key]
	if m ~= nil then return m or nil end
	m = false
	local why = "no pickup class"
	pcall(function()
		-- reflected names have spaces (SDK dump shows Pickup_BP / _Fallback_Visual_BP); live: consumables fill only the 2nd
		local cls = nil
		pcall(function() cls = item["Pickup BP"] end)
		if cls == nil then pcall(function() cls = item["Drop BP / Fallback Visual BP"] end) end
		for _ = 1, 4 do -- own template first, then parents' (a child that kept the base mesh has none of its own)
			if cls == nil then break end
			why = "no template"
			local tn = M.meshTemplateName(cls:get_full_name())
			local t = tn ~= nil and uevr.api:find_uobject(tn) or nil
			local mesh = t ~= nil and t.StaticMesh or nil
			if mesh ~= nil then
				why = "bad bounds"
				local b = mesh:GetBounds()
				local e = b.BoxExtent
				local half = math.max(e.X, e.Y, e.Z)
				if M.meshScale(half, M.MODEL_HALF_CM) ~= nil then
					m = {mesh = mesh, half = half, ox = b.Origin.X, oy = b.Origin.Y, oz = b.Origin.Z}
				end
				break
			end
			cls = cls:get_super()
		end
	end)
	S.meshes[key] = m
	log(string.format("model for item %s: %s", tostring(key), m and string.format("half=%.1f", m.half) or ("none (icon): " .. why)))
	return m or nil
end

-- the card's 3D model follows its item; no model -> the icon shows instead
local function setModel(slot)
	local m = nil
	if slot.item ~= nil then local ok, r = pcall(itemModel, slot.item) m = ok and r or nil end
	if m ~= nil then
		if slot.mesh == nil or D.uevrUtils.getValid(slot.mesh) == nil then
			slot.mesh = nil
			pcall(function()
				local c = D.uevrUtils.createStaticMeshComponent(m.mesh, {parent = slot.comp:GetOwner(), manualAttachment = true})
				if c ~= nil then
					pcall(function() c:SetCastShadow(false) end)
					pcall(function() c:SetCollisionEnabled(0) end)
					slot.mesh = c
				end
			end)
			if slot.mesh == nil then log("model component failed") end
		else
			pcall(function() slot.mesh:SetStaticMesh(m.mesh) end)
		end
		slot.mscale = nil
		if slot.mesh == nil then m = nil end
	end
	slot.model = m
	slot.styled = nil -- cardStyle re-applies fill vs frame
	pcall(function() slot.img:SetVisibility(m ~= nil and 2 or 4) end) -- 2 Hidden, 4 SelfHitTestInvisible
	if slot.mesh ~= nil then pcall(function() slot.mesh:SetVisibility(slot.visible and m ~= nil, false) end) end
end

-- step 49: {rank, size} of an item among all consumable types with the same model (icon if none), by SortOrder.
-- Built once per rotation-order length (all consumable types, owned or not, so a rank never shifts with ownership).
local function tierFor(item)
	local pawn = uevr.api:get_local_pawn(0)
	local ro = pawn ~= nil and pawn.ConsumableRotationOrder or nil
	if ro == nil then return 1, 1 end
	if S.tierN ~= #ro then
		S.tierN = #ro
		S.tier = {}
		local keys, sorts, addrs = {}, {}, {}
		for j, it in ipairs(ro) do
			local key, so = nil, 0
			pcall(function()
				local m = itemModel(it)
				key = m ~= nil and m.mesh:get_address() or it.ItemIcon:get_address()
				so = it.SortOrder or 0
			end)
			keys[j], sorts[j], addrs[j] = key or ("u" .. j), so, it:get_address()
		end
		local multi = 0
		for j = 1, #ro do
			local rk, sz = M.tierRank(keys, sorts, #ro, j)
			S.tier[addrs[j]] = {rk, sz}
			if sz > 1 and rk == 1 then multi = multi + 1 end
		end
		log(string.format("tiers: %d consumable types, %d multi-tier groups", #ro, multi))
	end
	local t = S.tier[item:get_address()]
	if t == nil then return 1, 1 end
	return t[1], t[2]
end

-- icon card: tinted fill (gold when highlighted); model card: no fill (it would draw over the model), frame bars instead
local function cardStyle(slot)
	slot.styled = true
	local frame = slot.model ~= nil and slot.edges ~= nil
	if slot.bg ~= nil then
		slot.bg:SetVisibility(frame and 2 or 4)
		if not frame then slot.bg:SetColorAndOpacity(slot.hl and BG_H or (slot.sel and BG_S or BG_N)) end
	end
	if slot.edges ~= nil then
		for k = 1, 4 do
			local bar = slot.edges[k]
			bar:SetVisibility(frame and 4 or 2)
			if frame then bar:SetColorAndOpacity(slot.hl and EDGE_H or (slot.sel and EDGE_S or EDGE_N)) end
		end
	end
end

local function placeModel(slot, hx, hy, hz, hlOn)
	local m = slot.model
	if m == nil or slot.mesh == nil then return end
	local sc = M.meshScale(m.half, M.MODEL_HALF_CM) * (hlOn and M.HL_SCALE or 1.0)
	if slot.mscale ~= sc then
		slot.mscale = sc
		S.mscale.X, S.mscale.Y, S.mscale.Z = sc, sc, sc
		slot.mesh:SetWorldScale3D(S.mscale)
	end
	-- in front of the card along the line to the head (the card is tilted to face it), mesh bounds centre on that
	-- point, spinning about Z
	local dx, dy, dz = hx - slot.x, hy - slot.y, hz - slot.z
	local l = math.sqrt(dx * dx + dy * dy + dz * dz)
	if l > 0.01 then l = M.MODEL_FWD_CM / l dx, dy, dz = dx * l, dy * l, dz * l else dx, dy, dz = 0.0, 0.0, 0.0 end
	local yaw = math.rad(S.spin)
	local c, s = math.cos(yaw), math.sin(yaw)
	local ox, oy = (m.ox * c - m.oy * s) * sc, (m.ox * s + m.oy * c) * sc
	S.mloc.X, S.mloc.Y, S.mloc.Z = slot.x + dx - ox, slot.y + dy - oy, slot.z + dz - m.oz * sc
	S.mrot.Pitch, S.mrot.Yaw, S.mrot.Roll = 0.0, S.spin, 0.0
	slot.mesh:K2_SetWorldLocationAndRotation(S.mloc, S.mrot, false, D.hr, true)
end

local function clearInput() -- no hand counts as "at a card" and no latched press survives a pause/menu/level change
	S.nearHand, S.armed = nil, nil
	S.gripEdge[1], S.gripEdge[2] = false, false
end

-- step 31: a grabbed model rides the controller (no spin, no card); released -> back to belt placement
local function holdModel(slot, ctrl)
	if ctrl ~= nil then
		local m = slot.model
		local sc = M.meshScale(m.half, M.MODEL_HALF_CM) * M.HL_SCALE
		slot.mesh:K2_AttachToComponent(ctrl, D.uevrUtils.fname_from_string(""), 2, 2, 1, false)
		S.mscale.X, S.mscale.Y, S.mscale.Z = sc, sc, sc
		slot.mesh:SetWorldScale3D(S.mscale)
		S.mloc.X, S.mloc.Y, S.mloc.Z = M.HOLD_FWD_CM - m.ox * sc, -m.oy * sc, M.HOLD_UP_CM - m.oz * sc
		S.mrot.Pitch, S.mrot.Yaw, S.mrot.Roll = 0.0, 0.0, 0.0
		slot.mesh:K2_SetRelativeLocationAndRotation(S.mloc, S.mrot, false, D.hr, true)
		slot.held = true
	else
		slot.held = false
		slot.mscale = nil
		slot.mesh:K2_DetachFromComponent(1, 1, 1, false)
	end
	slot.visible = nil -- show() re-applies card/mesh visibility
end

local function releaseHeld()
	for i = 1, M.MAX_SLOTS do
		local s = S.slots[i]
		if s ~= nil and s.held then pcall(holdModel, s, nil) end
	end
end

function M.hideAll()
	releaseHeld()
	for k = 1, 4 do if S.wslots[k] ~= nil then show(S.wslots[k], false) end end
	for i = 1, M.MAX_SLOTS do local s = S.slots[i] if s ~= nil then show(s, false) s.on = false end end
	S.shown = false
	S.grab = nil
	clearInput()
end

-- level change: the cards' owner actor dies with the level; drop them so tick recreates them
function M.reset()
	M.hideAll()
	for i = 1, M.MAX_SLOTS do local s = S.slots[i] if s ~= nil then s.held = false end end
	for i = 1, M.MAX_SLOTS do S.slots[i] = nil end
	for k = 1, 4 do S.wslots[k] = nil end
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

-- step 32/39/46: display-only cards under the belt row (M.wcardPos): weapons prev / next on the right, throwables on the left
M.WEAPON_DROP_CM = 18.0 -- below the belt row
local function weaponCard(want, cx, cy, cz, hp, k)
	local w = S.wslots[k]
	local item = S.wItems[k]
	if not want or item == nil then
		if w ~= nil then show(w, false) end
		return
	end
	if w == nil or D.uevrUtils.getValid(w.comp) == nil then
		w = createSlot(0)
		S.wslots[k] = w
		if w == nil then return end
		pcall(function() w.bg:SetColorAndOpacity(BG_N) end)
		for k = 1, 4 do pcall(function() w.edges[k]:SetVisibility(4) w.edges[k]:SetColorAndOpacity(EDGE_H) end) end
	end
	if w.item ~= item then
		w.item = item
		pcall(function() w.img:SetBrushFromTexture(w.item.ItemIcon, false) end)
	end
	setText(w, k >= 3 and S.wCounts[k] or nil)
	local f, l = M.wcardPos(k)
	local fx, fy = math.cos(math.rad(S.yaw)), math.sin(math.rad(S.yaw))
	local x, y = cx + fx * f - fy * l, cy + fy * f + fx * l
	pcall(place, w, x, y, cz - M.WEAPON_DROP_CM, hp.X, hp.Y, hp.Z)
	if w.scaled == nil then
		w.scaled = true
		local k = M.CARD_CM / M.PX
		S.scale.X, S.scale.Y, S.scale.Z = k, k, k
		pcall(function() w.comp:SetWorldScale3D(S.scale) end)
	end
	show(w, true)
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
				s.itemAddr = nil
				pcall(function() s.itemAddr = s.item:get_address() end)
				s.shownCount = nil
				pcall(function() s.img:SetBrushFromTexture(s.item.ItemIcon, false) end)
				setModel(s)
				local okT, rk, sz = pcall(tierFor, s.item)
				setPips(s, okT and rk or 1, okT and sz or 1)
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
	-- step 21: highlight the card a grip would take (bigger model, bright card) + haptic tick when it changes
	local hl, hlHand = M.targetSlot(S.slots, S.n, hands, M.GRAB_CM, S.grab)
	if hl ~= S.hl then
		if hl ~= nil and hlHand ~= nil and S.grab == nil then
			D.uevrUtils.triggerHapticVibration(hlHand == 1 and Handed.Left or Handed.Right, 0, 0.02, 150, 0.25)
		end
		S.hl = hl
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
	S.spin = (S.spin + M.SPIN_DPS * dt) % 360.0
	local held = S.grab ~= nil and S.grab.slot or nil
	for i = 1, M.MAX_SLOTS do -- step 31: hold/release transitions
		local s = S.slots[i]
		if s ~= nil then
			local wantHeld = i == held and s.model ~= nil and s.mesh ~= nil
			if wantHeld ~= (s.held == true) then
				local ok, err = pcall(holdModel, s, wantHeld and D.controllers.getController(S.grab.hand == 1 and 0 or 1) or nil)
				if not ok then s.held = false log("hold failed: " .. tostring(err)) end
			end
		end
	end
	for i = 1, S.n do
		local s = S.slots[i]
		if s ~= nil then
			local hlOn = want and (i == S.hl) and not s.held
			local selOn = s.itemAddr ~= nil and s.itemAddr == S.selAddr
			if s.held then
				if s.visible ~= "held" then
					s.visible = "held"
					pcall(function() s.comp:SetVisibility(false, false) end)
					pcall(function() s.mesh:SetVisibility(true, false) end)
				end
			elseif want then
				pcall(place, s, s.x, s.y, s.z, hp.X, hp.Y, hp.Z)
				if s.scaled ~= hlOn then -- nil (new card) / false / true: card scale, 1.15x when highlighted
					s.scaled = hlOn
					local k = sc * (hlOn and 1.15 or 1.0)
					S.scale.X, S.scale.Y, S.scale.Z = k, k, k
					pcall(function() s.comp:SetWorldScale3D(S.scale) end)
				end
				pcall(placeModel, s, hp.X, hp.Y, hp.Z, hlOn)
			end
			if s.hl ~= hlOn or s.sel ~= selOn or s.styled == nil then
				s.hl, s.sel = hlOn, selOn
				pcall(cardStyle, s)
			end
			if not s.held then show(s, want) end
		end
	end
	pcall(weaponCard, want, cx, cy, cz, hp, 1)
	pcall(weaponCard, want, cx, cy, cz, hp, 2)
	pcall(weaponCard, want, cx, cy, cz, hp, 3)
	pcall(weaponCard, want, cx, cy, cz, hp, 4)
end

return M
