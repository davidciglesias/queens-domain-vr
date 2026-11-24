-- qd_belt: owned consumables shown as icon cards on a belt at the waist; grab one with either grip, bring it to the mouth
-- to select + use it (test 21). Pure layout math at the top (unit tested by tools/test_qd_belt.lua), UEVR code below (init/tick).
-- Copyright (C) 2026 Queen's Domain VR contributors. AGPL-3.0 (see LICENSE).
local M = {}

M.MAX_SLOTS = 5
M.MAX_CARDS = 7 -- step 67/91: weak heal + 3 items + 2 peek cards + strong heal
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
-- step 109: belt centre (x,y) from the head. yaw in degrees (UE: forward=(cos,sin), right=(-sin,cos));
-- fwd cm along head-yaw forward (negative = behind the head), side cm to the user's right (+ = right).
function M.anchor(hx, hy, yawDeg, fwd, side)
	local r = math.rad(yawDeg)
	local fx, fy = math.cos(r), math.sin(r)
	return hx + fx * fwd - fy * side, hy + fy * fwd + fx * side
end
M.fwdLive, M.sideLive = M.FORWARD, 0.0 -- live config values, read by qd_belt3d for label placement
function M.fwdNow() return M.fwdLive end
function M.sideNow() return M.sideLive end

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
-- step 93: generous, blind-friendly reach. Each slot may carry its own reach s.r (else r). Above a card the reach stays
-- GRAB_UP_CM (so a bigger sphere doesn't reach up into the shoulder zones or the hands' rest pose); below / sideways /
-- front-back it is the full s.r. Returns the slot with the lowest distance/reach (<= lim, default 1) and that ratio.
M.GRAB_UP_CM = 14.0
M.REACH_ITEM_CM = 19.0 -- belt items
M.HEAL_BEHIND_CM = 4.0 -- step 132: shoulder-hung heal not grabbable by a hand this far behind the card (weapon-swap reach)
M.REACH_HEAL_CM = 25.0 -- heal cards (hip sides): meant to be grabbed without looking
-- step 117/122: heal items leave the belt (weakest "heal" left, strongest "heal2" right). Step 122 (headset
-- 2026-11-20c: shoulder heals still moved with the body): they sit on the IK gloves, in the IK lower-arm frame (qd_armhud
-- gloveFrame: X across, Y toward the elbow, Z off the arm face; turns with the forearm, not with a wrist roll), and only
-- the OTHER hand grabs them (the own hand is always next to its glove). Spots = options heal_gl_* / heal_gr_*.
M.GL_L = { x = -8.438, y = 33.656, z = 19.687 } -- left glove heal (step 124: user values, headset 2026-11-21)
M.GL_R = { x = 10.501, y = 26.875, z = 22.625 } -- right glove heal (step 124: user values)
M.SH_REACH_CM = 12.0
-- step 124 (headset 2026-11-21: glove heals twitched with the hands, the IK shoulders don't): option heal_on_shoulders
-- hangs the heals on a chain from the IK shoulder joint (UpperArm bone) in the IK body-yaw frame. Chain point = bone +
-- SH_FWD forward, SH_OUT outward, SH_UP up (cm) + the heal_shl_* / heal_shr_* nudges; the model hangs below it.
M.SH_FWD, M.SH_OUT, M.SH_UP = 3.0, 0.0, 13.0
M.shoulderLoc = nil -- step 124: function(side 0 left / 1 right) -> x, y, z of the IK shoulder joint, or nil (main script)
-- step 124 (pure): chain point from the shoulder joint s*, body yaw (deg), side sg (-1 left / 1 right), offsets (cm)
function M.shoulderPoint(sx, sy, sz, yawDeg, sg, fwd, out, up)
	local r = math.rad(yawDeg)
	local fx, fy = math.cos(r), math.sin(r)
	local rx, ry = -fy, fx -- right of the body
	return sx + fx * fwd + rx * sg * out, sy + fy * fwd + ry * sg * out, sz + up
end
-- step 125 (headset 2026-11-21b: shoulder heals stayed put when the real shoulders moved, chain not on the arm): option
-- heal_spot 1 hangs the heals from the IK UPPER arm EL_ALONG cm above the elbow (just past the arm HUD toward the
-- shoulder), EL_OUT cm out to the side (arm surface), so the chain starts on the arm and follows the elbow.
M.EL_ALONG, M.EL_OUT, M.EL_FWD, M.EL_UP = 6.0, 4.0, 0.0, 0.0
M.elbowLoc = nil -- step 125: function(side) -> elbow x, y, z, shoulder x, y, z of the IK arm, or nil (main script)
-- step 125 (pure): chain point from elbow e and shoulder s joints: along cm from e toward s, then shoulderPoint offsets
function M.elbowPoint(ex, ey, ez, sx, sy, sz, yawDeg, sg, along, fwd, out, up)
	local ux, uy, uz = sx - ex, sy - ey, sz - ez
	local l = math.sqrt(ux * ux + uy * uy + uz * uz)
	if l > 1e-3 then
		local k = math.min(along, l) / l
		ex, ey, ez = ex + ux * k, ey + uy * k, ez + uz * k
	end
	return M.shoulderPoint(ex, ey, ez, yawDeg, sg, fwd, out, up)
end
-- step 125 (headset 2026-11-21b: the belt turned with the head; "look right -> belt stays, turn the body -> it turns"):
-- option belt_body_yaw. No torso tracking, so the body facing comes from the hands: while both hands are raised in front
-- (above the belt, the midpoint HAND_MIN_CM+ out from the head and not behind it) the belt turns toward the hands
-- direction (dead zone HAND_DEAD, HAND_RATE deg/s); the head alone only pushes it past NECK deg; otherwise a slow DRIFT
-- toward the head re-centres it.
M.BODY = { HAND_DEAD = 15.0, HAND_RATE = 120.0, NECK = 65.0, DRIFT = 3.0, HAND_MIN_CM = 15.0, ABOVE_CM = 5.0 }
-- pure: yaw (deg) of the hands' midpoint seen from the head (horizontal), or nil when the hands say nothing about the
-- body (lowered to the belt, too close to the head, or behind it). hy = head yaw, beltZ = belt height
function M.handsYaw(hx, hy, headYaw, lx, ly, lz, rx, ry, rz, beltZ)
	local B = M.BODY
	if lz == nil or rz == nil or lz < beltZ + B.ABOVE_CM or rz < beltZ + B.ABOVE_CM then return nil end
	local mx, my = (lx + rx) * 0.5 - hx, (ly + ry) * 0.5 - hy
	local d = math.sqrt(mx * mx + my * my)
	if d < B.HAND_MIN_CM then return nil end
	local r = math.rad(headYaw)
	if (mx * math.cos(r) + my * math.sin(r)) / d < 0.0 then return nil end -- behind the head
	return math.deg(math.atan(my, mx))
end
-- pure: next body yaw from the current one, head yaw, hands yaw (nil = no hand cue), dt
function M.bodyYawStep(cur, headYaw, handYaw, dt)
	if cur == nil then return M.yawDelta(handYaw or headYaw, 0.0) end
	local B = M.BODY
	dt = dt or 0.0
	local y = cur
	if handYaw ~= nil then
		local d = M.yawDelta(handYaw, y)
		local over = math.abs(d) - B.HAND_DEAD
		if over > 0.0 then
			local st = math.min(over, B.HAND_RATE * dt)
			y = y + (d > 0 and st or -st)
		end
	else
		local d = M.yawDelta(headYaw, y)
		local st = math.min(math.abs(d), B.DRIFT * dt)
		y = y + (d > 0 and st or -st)
	end
	local dh = M.yawDelta(headYaw, y)
	if dh > B.NECK then y = y + (dh - B.NECK) elseif dh < -B.NECK then y = y + (dh + B.NECK) end
	return M.yawDelta(y, 0.0)
end
M.onHold = nil -- step 120: function(hand 1 left / 2 right, on) set by the main script (hides the right weapon while held)
M.gloveFrame = nil -- step 122: function(side 0 left / 1 right) -> qd_armhud.gloveFrame numbers, or nil (main script)
M.bodyYaw = nil -- step 120: function() -> body yaw (deg) the glove heal models face, or nil (set by the main script)
-- step 113/120 (user 2026-11-18, style chosen 2026-11-20): "can't use now" hint (grey shell + red X; grab and use
-- unchanged). Pure: false = not usable now. hp/maxHp only matter for healers; canFlag nil = no own check (usable).
function M.usableNow(isHealer, hp, maxHp, globalOff, canFlag)
	if globalOff == true then return false end
	if canFlag == false then return false end
	if isHealer and type(hp) == "number" and type(maxHp) == "number" and maxHp > 0 and hp >= maxHp - 0.5 then return false end
	return true
end
-- item key substring -> own check (Test 87, all items used on slot 2): "fn" = pawn bool function; "need" = usable only
-- while that pawn status component is .Applied (cures); "busy" = not usable while it is .Applied (buffs refuse re-use)
M.CAN_USE = {
	{ "item_cure_potion", "fn", "CanUsePanacea" }, -- true while any of the six ailments is applied
	{ "returngem", "fn", "CanUseTeleportItem" }, { "tp_crystal", "fn", "CanUseTeleportItem" }, -- incl. the infinite ones
	{ "item_cure_poison", "need", "PoisonStatusEffect" }, { "item_cure_weaken", "need", "WeakenStatusEffect" },
	{ "item_cure_disease", "need", "DiseaseStatusEffect" }, { "item_cure_sticky", "need", "StickyStatusEffect" },
	{ "item_cure_binding", "need", "BindingStatusEffect" }, { "item_cure_heavy", "need", "HeavyStatusEffect" },
	{ "item_resist_mp_potion", "busy", "MagicRotResistStatusEffect" }, { "item_iron_fruit", "busy", "IronskinFruitStatusEffect" },
	{ "item_iron_potion", "busy", "IronskinPotionStatusEffect" }, { "item_berserk_fruit", "busy", "BerserkFruitStatusEffect" },
	{ "item_berserk_potion", "busy", "BerserkPotionStatusEffect" }, { "item_glowfruit", "busy", "RadiantFruitStatusEffect" },
}
-- pure: kind ("fn" / "need" / "busy") and name of the own check for an item key, or nil
function M.canUseFn(key, tbl)
	if type(key) ~= "string" then return nil end
	for _, e in ipairs(tbl or M.CAN_USE) do if key:find(e[1], 1, true) ~= nil then return e[2], e[3] end end
	return nil
end
-- pure: own-check result -> canFlag for usableNow (v = function result or the status .Applied flag)
function M.checkFlag(kind, v)
	if kind == "fn" or kind == "need" then return v == true end
	if kind == "busy" then return v ~= true end
	return nil
end
-- pure: a - b wrapped to (-180, 180]
function M.yawDelta(a, b)
	local d = (a - b) % 360.0
	if d > 180.0 then d = d - 360.0 end
	return d
end
-- pure: shoulder side (-1 left, 1 right) for a role, or nil (option off / not a heal card)
function M.shoulderSide(on, role)
	if not on then return nil end
	if role == "heal" then return -1 elseif role == "heal2" then return 1 end
	return nil
end
-- step 122 (pure): belt height (cm below the eyes) for the stance: seated_play -> belt_drop_seated, else belt_drop
function M.beltDrop(get)
	if get("seated_play") == true then return tonumber(get("belt_drop_seated")) or 35.0 end
	return tonumber(get("belt_drop")) or 60.0
end
-- step 122 (pure): world point at offsets ox/oy/oz along the X/Y/Z axes from the origin w
function M.glovePoint(wx, wy, wz, xx, xy, xz, yx, yy, yz, zx, zy, zz, ox, oy, oz)
	return wx + xx * ox + yx * oy + zx * oz, wy + xy * ox + yy * oy + zy * oz, wz + xz * ox + yz * oy + zz * oz
end
-- step 122 (pure): is slot s a glove heal on the side of hand h (1 left / 2 right)? Only the other hand may take it
function M.ownGlove(s, h)
	return s.glove == true and s.sh ~= nil and h ~= nil and s.sh == (h == 1 and -1 or 1) -- step 124: shoulder heals: either hand
end
-- pure: may a held item be used at the mouth? dm = hand-mouth distance now; away = it was outside the mouth zone since
-- the grab (an item grabbed right next to the mouth must leave first). Returns use, away
function M.mouthUse(dm, away, mouthCm)
	if dm > mouthCm then away = true end
	return away and dm < mouthCm, away
end
function M.reachFor(role)
	if role == "heal" or role == "heal2" then return M.REACH_HEAL_CM end
	if role == "item" then return M.REACH_ITEM_CM end
	return M.GRAB_CM
end
function M.nearestSlot(slots, n, px, py, pz, r, lim, hand)
	local best, bs = nil, lim or 1.0
	for i = 1, n do
		local s = slots[i]
		if s ~= nil and s.on and not M.ownGlove(s, hand) then -- step 122: hand (optional) skips its own glove heal
			local rad = s.r or r
			local dz = pz - s.z
			if dz > 0 and rad > M.GRAB_UP_CM then dz = dz * rad / M.GRAB_UP_CM end
			local dx, dy = px - s.x, py - s.y
			local sc = math.sqrt(dx * dx + dy * dy + dz * dz) / rad
			if sc <= bs then best, bs = i, sc end
		end
	end
	return best, bs
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
M.AMMO_FWD_CM = 37.0    -- step 62: ammo card (k 5) just beyond the middle of the item row (radius 24), same height
M.AMMO_DROP_CM = 0.0    -- below the item row (the 4 lower cards use WEAPON_DROP_CM)
M.AMMO_SCALE = 0.75
-- step 90 (user 2026-11-17): previous cards on the left, next on the right (= the shoulder that switches to them);
-- weapons outer, throwables inner. Left to right: weapon prev, throwable prev, throwable next, weapon next.
function M.wcardPos(k)
	if k == 5 then return M.AMMO_FWD_CM, 0.0 end
	local outer = (k == 1 or k == 2)
	local lat = outer and M.WCARD_OUTER_CM or M.WCARD_INNER_CM
	if k == 1 or k == 3 then lat = -lat end
	return outer and M.WCARD_FWD_OUT or M.WCARD_FWD_IN, lat
end

-- step 86 (weapon_cards_up): cards near the shoulders. Returns forward, lateral (+ right) cm from the eyes and the cm below
-- the eyes. latCm/dropCm/fwdCm = options; prev outside, next inside, UP_GAP_CM apart. k 1-2 right side, 3-4 left.
-- weapon_cards_show: 1 near shoulder or belt (default), 2 always, 3 never. Pure.
function M.wcardVisible(mode, beltShown, handNear)
	if mode == 2 then return true elseif mode == 3 then return false end
	return beltShown == true or handNear == true
end
M.UP_GAP_CM = 13.0
function M.wcardUpPos(k, latCm, dropCm, fwdCm)
	local right = k == 1 or k == 2
	local outer = k == 1 or k == 3
	local lat = latCm + (outer and M.UP_GAP_CM * 0.5 or -M.UP_GAP_CM * 0.5)
	return fwdCm, right and lat or -lat, dropCm
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
-- step 79b: trigger as the grab button. Pure hysteresis: down from the previous state and the 0..255 trigger byte.
M.TRIG_HI, M.TRIG_LO = 128, 77
function M.trigDown(prev, v)
	if prev then return v > M.TRIG_LO end
	return v >= M.TRIG_HI
end

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
-- Ties keep the earlier entry. Returns nil when none is owned. Step 91: strongest = true picks the strongest instead.
function M.healPick(amounts, owned, n, strongest)
	local best, bestA = nil, nil
	for i = 1, n do
		local a = amounts[i]
		if type(a) == "number" and owned[i] and (bestA == nil or (strongest and a > bestA) or (not strongest and a < bestA)) then best, bestA = i, a end
	end
	return best
end

-- step 61: direction of a move from position "from" to "to" in a cycle of n entries: +1 next, -1 previous, 0 none
-- (shorter way round; a tie counts as next).
function M.cycleDir(n, from, to)
	if type(n) ~= "number" or n < 2 or from == nil or to == nil or from == to then return 0 end
	local d = (to - from) % n
	if d == 0 then return 0 end
	return (d <= n - d) and 1 or -1
end

-- step 61: the belt's own scroll anchor (position in the list of total non-healing items). cur = position of the
-- remembered anchor item (nil when it left the list), last = its last known position, scroll = pending steps.
function M.anchorPos(total, cur, last, scroll)
	if total <= 0 then return nil end
	local p = cur
	if p == nil then
		p = last or 1
		if p > total then p = total end
		if p < 1 then p = 1 end
	end
	return (p - 1 + (scroll or 0)) % total + 1
end

-- step 67 (belt_arrows): 3 item cards in the middle, a smaller "peek" card on each side (the item the belt scrolls to;
-- grip it = one scroll step) and the heal card on the right, a bit apart. Cards are ordered [heal], items, [prev, next].
M.ARROW_ITEMS = 3
M.ARROW_DEG = 60.0  -- peek cards
M.HEAL_DEG = 98.0   -- heal card (right side, one gap further out than a normal step)
M.PEEK_SCALE = 0.72
M.HEAL_RAISE_CM = 12.0 -- step 71: heal card (arrows mode) sits this much higher than the item row
-- fills angs[1..n] / roles[1..n] ("heal", "item", "prev", "next", "heal2"); returns n. arrows false = old layout (heal
-- leftmost, heal2 rightmost, all centred). Pure. Step 91 (user 2026-11-17): weakest healer ("heal") on the LEFT, strongest
-- ("heal2", only when it differs) on the RIGHT, both set apart; card order [heal], items, [prev, next], [heal2].
function M.layout(hasHeal, nItems, hasPeek, arrows, angs, roles, hasHeal2)
	local n = 0
	local total = nItems + (hasHeal and 1 or 0) + (hasHeal2 and 1 or 0)
	if not arrows then
		for i = 1, total do
			n = n + 1
			angs[n] = (i - (total + 1) / 2) * M.STEP_DEG
			roles[n] = (hasHeal and i == 1) and "heal" or ((hasHeal2 and i == total) and "heal2" or "item")
		end
		return n
	end
	local hd = math.max(M.HEAL_DEG, ((nItems - 1) / 2 + 1) * M.STEP_DEG)
	if hasHeal then n = n + 1 angs[n] = -hd roles[n] = "heal" end
	for i = 1, nItems do n = n + 1 angs[n] = (i - (nItems + 1) / 2) * M.STEP_DEG roles[n] = "item" end
	if hasPeek then
		n = n + 1 angs[n] = -M.ARROW_DEG roles[n] = "prev"
		n = n + 1 angs[n] = M.ARROW_DEG roles[n] = "next"
	end
	if hasHeal2 then n = n + 1 angs[n] = hd roles[n] = "heal2" end
	return n
end

-- step 67: window start/count plus the positions of the previous / next peek items (nil when everything fits). Pure.
function M.peekWindow(total, anchor, max)
	local start, cnt = M.window(total, anchor, max)
	if total <= max or cnt <= 0 then return start, cnt, nil, nil end
	return start, cnt, (start - 2) % total + 1, (start - 1 + cnt) % total + 1
end

-- step 62: whole shots left for an energy weapon: energy in cells / cells per shot (nil = weapon uses no energy)
function M.shots(energy, perShot)
	if type(energy) ~= "number" or type(perShot) ~= "number" or perShot <= 0 then return nil end
	return math.floor(energy / perShot + 0.001)
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
	local best, bh, bs = nil, nil, 1.0
	for h = 1, 2 do
		local p = hands[h]
		if p ~= nil then
			local i, sc = M.nearestSlot(slots, n, p.X, p.Y, p.Z, r, bs, h)
			if i ~= nil then best, bh, bs = i, h, sc end
		end
	end
	return best, bh
end

---------------------------------------------------------------- runtime (UEVR)
local D = nil -- deps from init
local S = {cyc = {}, cycN = 0, scroll = 0, wPer = {}, slots = {}, wslots = {}, wItems = {}, wlist = {}, tlist = {}, tkeys = {}, wCounts = {}, tCandBuf = {}, tCandT = 0.0, tOut = {}, tOut2 = {}, n = 0, items = {}, counts = {}, yaw = nil, refreshT = 0.0, shown = false, grab = nil,
	gripPrev = {false, false}, gripEdge = {false, false}, gripNow = {false, false}, errLogged = false, rot = {Pitch = 0, Yaw = 0, Roll = 0},
	loc = {X = 0, Y = 0, Z = 0}, scale = {X = 1, Y = 1, Z = 1}, created = 0, failT = 0.0, lastUseT = 0.0, angs = {}, cardAng = {}, role = {}, handPos = {},
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
local TINT_OFF = {R = 0.45, G = 0.45, B = 0.45, A = 1.0} -- step 120: item can't be used now (whole card / label)
local TINT_ON = {R = 1.0, G = 1.0, B = 1.0, A = 1.0}
local EDGE_X = {R = 0.9, G = 0.12, B = 0.1, A = 1.0} -- step 120: 2D card frame when it can't be used
local EDGE_P = {R = 0.75, G = 0.75, B = 0.75, A = 0.45} -- step 67: peek cards (grip = scroll)
local BG_P = {R = 0.25, G = 0.25, B = 0.25, A = 0.45}
local EDGE_ALIGN = {{0, 1}, {0, 3}, {1, 0}, {3, 0}} -- {H, V}: top, bottom, left, right bars (0 Fill, 1 Left/Top, 3 Right/Bottom)
local EDGE_PX = 4
M.S = S
-- step 91: per hand (1 L, 2 R) "at a belt card or holding one", set in tick; the shoulder switch yields to the belt
S.atCard, S.atCardT = {false, false}, -1.0
-- step 94: hover feel per target, told apart by rhythm and length (controllers differ on frequency):
-- item / arrow = one short soft tick; heal = two firm taps; weapon or throwable switch (qd_shoulder) = one long low rumble.
-- {duration s, frequency, amplitude, gap s before a second pulse (0 = single)}
M.HAPTIC = {item = {0.02, 150, 0.25, 0}, heal = {0.035, 170, 0.65, 0.09}, switch = {0.14, 80, 0.5, 0}}
local function buzzOnce(h, kind)
	local p = M.HAPTIC[kind] or M.HAPTIC.item
	D.uevrUtils.triggerHapticVibration(h == 1 and Handed.Left or Handed.Right, 0, p[1], p[2], p[3])
end
-- the second tap is timed by M.tick (not the runtime's start delay, which some runtimes ignore)
function M.buzz(h, kind)
	local p = M.HAPTIC[kind] or M.HAPTIC.item
	pcall(buzzOnce, h, kind)
	if p[4] > 0 then S.bzH, S.bzK, S.bzT = h, kind, os.clock() + p[4] end
end
function M.handAtCard(h) return S.atCard[h] == true and os.clock() - S.atCardT < 0.25 end
-- step 92: a trigger pulled from rest with its hand at a card never reaches the game until released (any pull, not just
-- past the grab threshold; left trigger = melee special attack). A pull started away from the cards passes. Pure.
M.TRIG_REST = 30
function M.trigLock(locked, at, v)
	if v < M.TRIG_REST then return at == true end
	return locked == true
end
S.tlock = {false, false}

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

-- step 62: shooting weapons have no magazine of their own: every shot takes energy cells (weapon script
-- GetCellConsumptionPerShot(Secondary, out), live 2026-11-16: 0.5 and 0.0625 seen; melee scripts lack the function).
-- Item flag "Consumes Battery" = same test as the right-hand aim (step 54).
local function perShot(w)
	if w == nil then return nil end
	local v = nil
	pcall(function()
		local it = w.ItemData
		if it == nil or it["Consumes Battery"] ~= true then return end
		local o = S.tOut
		o.result = nil
		w:GetCellConsumptionPerShot(false, o)
		if type(o.result) == "number" and o.result > 0 then v = o.result end
	end)
	return v
end

-- owned quick-slot consumables (count > 0), in the game's rotation order, at most belt_slots (<= MAX_SLOTS).
-- The quick set is re-walked when ownership or the set's header (SDK: SaveSlot.QuickSlotItems TSet at 0x468:
-- Elements.Data, .Num at 0x470, NumFreeIndices at 0x49C) changes, or when forced (belt shown: catches same-size swaps
-- made in the inventory menu). If the walk fails, all owned items are shown (pre-step-8 behaviour).
-- step 120: S.noUse[i] = true when shown item i can't be used now (hint only). Per item address: healer flag + own-check
-- name cached once; globals / HP read once per refresh. Any failed call = usable (logged once).
function M.useCheck(pawn, n)
	S.noUse = S.noUse or {}
	S.useInfo = S.useInfo or {}
	S.useOut = S.useOut or {{}, {}}
	local nu = S.noUse
	if pawn == nil then for i = 1, M.MAX_CARDS do nu[i] = false end return end
	local off = false
	local okG = pcall(function() off = pawn:IsUseItemDisabled() == true or pawn.TempDisableUseItems == true end)
	if not okG and not S.useGlobalBad then S.useGlobalBad = true log("use check: global flags not readable") end
	local hp, maxHp = nil, nil
	pcall(function() hp = pawn.Health end)
	pcall(function()
		local a, b = S.useOut[1], S.useOut[2]
		a.result, b.result = nil, nil
		pawn:GetMaxHP(false, a, b)
		maxHp = a.result
	end)
	for i = 1, M.MAX_CARDS do
		local it = i <= n and S.items[i] or nil
		local bad = false
		if it ~= nil and S.role[i] ~= "prev" and S.role[i] ~= "next" then
			local addr = nil
			pcall(function() addr = it:get_address() end)
			local inf = addr ~= nil and S.useInfo[addr] or nil
			if inf == nil and addr ~= nil then
				local key = nil
				pcall(function() key = it.DataImportKey:to_string() end)
				local kind, fn = M.canUseFn(key)
				inf = { heal = M.healField(key) ~= nil, kind = kind, fn = fn }
				S.useInfo[addr] = inf
			end
			local can = nil
			if inf ~= nil and inf.fn ~= nil then
				local okC, r = pcall(function()
					if inf.kind == "fn" then return pawn[inf.fn](pawn) end
					local c = pawn[inf.fn]
					return c ~= nil and c.Applied == true
				end)
				if okC then can = M.checkFlag(inf.kind, r) elseif not inf.bad then inf.bad = true log("use check: " .. inf.fn .. " failed") end
			end
			bad = not M.usableNow(inf ~= nil and inf.heal, hp, maxHp, off, can)
		end
		if nu[i] ~= bad and i <= n then log("item " .. i .. " usable=" .. tostring(not bad)) end
		nu[i] = bad
	end
end

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
		local selPos, ancPos = nil, nil
		local cyc, cn = S.cyc, 0
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
					cn = cn + 1
					cyc[cn] = a
					if ha ~= nil and ha[i] then hOwn[i] = true
					else
						total = total + 1
						L[total] = i
						if a == selAddr then selPos = total end
						if a == S.anchorAddr then ancPos = total end
					end
				end
			end
		end
		for k = total + 1, #L do L[k] = nil end
		for k = cn + 1, #cyc do cyc[k] = nil end
		S.cycN = cn
		local hj = ha ~= nil and M.healPick(ha, hOwn, #ro) or nil
		local hj2 = ha ~= nil and M.healPick(ha, hOwn, #ro, true) or nil -- step 91: strongest healer, right side
		if hj2 == hj then hj2 = nil end
		local arrows = D.configui.getValue("belt_arrows") ~= false
		if hj2 ~= nil and not arrows then max = max - 1 end
		-- step 71: arrows mode = belt_slots items centred + the heal card set apart (right, raised); no peek cards
		if hj ~= nil then
			n = 1
			S.items[1], S.counts[1] = ro[hj], oc[hj]
			if not arrows then max = max - 1 end
		end
		-- step 61: the belt scrolls on its own anchor, not on the game's selection (using an item no longer moves it).
		-- Panic heal: the selection is pinned to the heal card's item; a next / previous press (seen in tick as a
		-- selection change) becomes one scroll step. Without a pin the anchor follows the game's selection as before.
		local pin = (hj ~= nil and D.configui.getValue("belt_panic_heal") ~= false) and ro[hj] or nil
		local pinAddr = nil
		if pin ~= nil then pcall(function() pinAddr = pin:get_address() end) end
		if pinAddr == nil then pin = nil end
		if pinAddr ~= S.pinAddr then
			S.pinFresh = true -- the first re-select after a pin change is not a next / previous press
			log("panic heal pin " .. (pin ~= nil and "set" or "off"))
		end
		S.pin, S.pinAddr = pin, pinAddr
		if pin == nil and S.verify == nil and selPos ~= nil then ancPos = selPos end
		ancPos = M.anchorPos(total, ancPos, S.anchorPos, pin ~= nil and S.scroll or 0)
		S.scroll = 0
		S.anchorPos = ancPos
		S.anchorAddr = nil
		if ancPos ~= nil then pcall(function() S.anchorAddr = ro[L[ancPos]]:get_address() end) end
		local start, cnt, pp, pn = M.peekWindow(total, ancPos, max)
		for k = 0, cnt - 1 do
			local j = L[(start - 1 + k) % total + 1]
			n = n + 1
			S.items[n], S.counts[n] = ro[j], oc[j]
		end
		local peek = arrows and pp ~= nil -- step 79b: peeks back, only when more items are owned than shown
		if peek then
			n = n + 1 S.items[n], S.counts[n] = ro[L[pp]], oc[L[pp]]
			n = n + 1 S.items[n], S.counts[n] = ro[L[pn]], oc[L[pn]]
		end
		if hj2 ~= nil then n = n + 1 S.items[n], S.counts[n] = ro[hj2], oc[hj2] end
		local ln = M.layout(hj ~= nil, cnt, peek, arrows, S.cardAng, S.role, hj2 ~= nil)
		S.healApart = arrows
		if ln ~= n then log("layout mismatch " .. ln .. " vs " .. n) n = math.min(n, ln) end
	end
	for i = n + 1, M.MAX_CARDS do S.items[i], S.counts[i] = nil, nil end
	S.n = n
	pcall(M.useCheck, pawn, n) -- step 120: can't-use hint per shown item (every refresh, 0.5 s)
	-- step 39: item data of the previous / next slot weapon (left / right shoulder) for the display-only cards
	local pd, nd = nil, nil
	pcall(function()
		local ws = pawn.WeaponSelection
		local t = S.wlist
		for i = #t, 1, -1 do t[i] = nil end
		ws:GetWeaponsInSlots(false, t)
		local cw = pawn.CurrentInHandWeapon
		local pw, nw = M.neighbours(t, #t, cw, ws.SelectedWeaponSlot)
		if pw ~= nil then pd = pw.ItemData end
		if nw ~= nil then nd = nw.ItemData end
		-- step 62: energy cells per shot of the previous / next / held weapon (nil = no energy use); held one = card 5
		local ammoOn = D.configui.getValue("belt_ammo_card") ~= false
		S.wPer[1] = ammoOn and perShot(pw) or nil
		S.wPer[2] = ammoOn and perShot(nw) or nil
		S.wPer[5] = ammoOn and perShot(cw) or nil
		S.wItems[5] = (S.wPer[5] ~= nil and cw ~= nil) and cw.ItemData or nil
		S.energy = pawn.EnergyChargeLogic
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
local function setText(slot, count, zeroOk)
	if slot.text == nil or slot.shownCount == count then return end
	slot.shownCount = count
	pcall(function()
		if count ~= nil and (count >= 1 or (zeroOk and count >= 0)) then
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
	log(string.format("card %s created number=%s pips=%s", tostring(i), tostring(text ~= nil), tostring(pips ~= nil)))
	return slot
end

-- step 76: one stand-alone card (icon + number) for other HUD bits (coin counter); same look as a belt card
function M.counterCard()
	return createSlot("counter")
end
function M.counterSet(slot, icon, count)
	if slot == nil then return end
	if slot.icon ~= icon then
		slot.icon = icon
		pcall(function() slot.img:SetBrushFromTexture(icon, false) end)
	end
	setText(slot, count, true)
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
					m = {mesh = mesh, half = half, ox = b.Origin.X, oy = b.Origin.Y, oz = b.Origin.Z, ex = e.X, ey = e.Y, ez = e.Z}
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

M.itemModel = itemModel -- step 82: the 3D skin (libs/qd_belt3d.lua, M.skin) reads the same models
M.skin = nil

-- the card's 3D model follows its item; no model -> the icon shows instead
local function setModel(slot)
	local m = nil
	if slot.item ~= nil and not slot.peek then local ok, r = pcall(itemModel, slot.item) m = ok and r or nil end
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
	pcall(function() slot.img:SetVisibility((m ~= nil or slot.peek) and 2 or 4) end) -- 2 Hidden, 4 SelfHitTestInvisible; step 88: peek = empty
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
		if not frame then slot.bg:SetColorAndOpacity(slot.hl and BG_H or (slot.peek and BG_P or (slot.sel and BG_S or BG_N))) end
	end
	if slot.edges ~= nil then
		for k = 1, 4 do
			local bar = slot.edges[k]
			bar:SetVisibility(frame and 4 or 2)
			if frame then bar:SetColorAndOpacity(slot.hl and EDGE_H or (slot.peek and EDGE_P or (slot.noUse and EDGE_X or (slot.sel and EDGE_S or EDGE_N)))) end
		end
	end
end

local function placeModel(slot, hx, hy, hz, hlOn)
	local m = slot.model
	if m == nil or slot.mesh == nil then return end
	local sc = M.meshScale(m.half, M.MODEL_HALF_CM) * (hlOn and M.HL_SCALE or 1.0) * (slot.peek and M.PEEK_SCALE or 1.0)
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
		S.holdHand = S.grab ~= nil and S.grab.hand or nil
		if M.onHold ~= nil and S.holdHand ~= nil then pcall(M.onHold, S.holdHand, true) end -- step 120
	else
		slot.held = false
		slot.mscale = nil
		if M.onHold ~= nil and S.holdHand ~= nil then pcall(M.onHold, S.holdHand, false) end -- step 120
		S.holdHand = nil
		slot.mesh:K2_DetachFromComponent(1, 1, 1, false)
	end
	slot.visible = nil -- show() re-applies card/mesh visibility
end

local function releaseHeld()
	for i = 1, M.MAX_CARDS do
		local s = S.slots[i]
		if s ~= nil and s.held then pcall(holdModel, s, nil) end
	end
end

function M.hideAll()
	releaseHeld()
	for k = 1, 5 do if S.wslots[k] ~= nil then show(S.wslots[k], false) end end
	for i = 1, M.MAX_CARDS do local s = S.slots[i] if s ~= nil then show(s, false) s.on = false end end
	S.shown = false
	S.grab = nil
	clearInput()
	if M.skin ~= nil then pcall(M.skin.hide) end -- step 82
end

-- level change: the cards' owner actor dies with the level; drop them so tick recreates them
function M.reset()
	M.hideAll()
	for i = 1, M.MAX_CARDS do local s = S.slots[i] if s ~= nil then s.held = false end end
	for i = 1, M.MAX_CARDS do S.slots[i] = nil end
	for k = 1, 5 do S.wslots[k] = nil end
	S.yaw = nil
	S.pin, S.pinAddr, S.restore, S.energy = nil, nil, nil, nil
	if M.skin ~= nil then pcall(M.skin.reset) end -- step 82
end

-- step 101 pure: rotator facing the eyes along (dx,dy,dz) whose up is the shared hint world-up + belt forward (fx,fy)
-- made perpendicular to the face normal. Roll-0 look-at fanned the up vectors radially for cards below the eyes
-- (headset 2026-11-17: under-belt icons/numbers "not all looking up"); with the shared hint they all read upright.
function M.faceRotUp(dx, dy, dz, fx, fy)
	local l = math.sqrt(dx * dx + dy * dy + dz * dz)
	if l < 1e-6 then return 0.0, 0.0, 0.0 end
	local nx, ny, nz = dx / l, dy / l, dz / l
	local hx, hy, hz = fx, fy, 1.0
	local d = hx * nx + hy * ny + hz * nz
	local ux, uy, uz = hx - d * nx, hy - d * ny, hz - d * nz
	local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
	if ul < 1e-6 then ux, uy, uz, ul = 0.0, 0.0, 1.0, 1.0 end
	ux, uy, uz = ux / ul, uy / ul, uz / ul
	local p = math.deg(math.atan(nz, math.sqrt(nx * nx + ny * ny)))
	local yw = math.deg(math.atan(ny, nx))
	local sx, sy = -math.sin(math.rad(yw)), math.cos(math.rad(yw))
	local yx, yy = uy * nz - uz * ny, uz * nx - ux * nz
	return p, yw, math.deg(math.atan(ux * sx + uy * sy, yx * sx + yy * sy))
end

-- s115: location + rotation in one engine call (same final transform as the two calls; false = old two-call path, e.g. A/B)
M.PLACE_ONE = true
local function place(slot, x, y, z, hx, hy, hz, upF)
	S.loc.X, S.loc.Y, S.loc.Z = x, y, z
	local one = M.PLACE_ONE and not S.placeOneBad
	if not one then slot.comp:K2_SetWorldLocation(S.loc, false, D.hr, true) end
	local dx, dy, dz = hx - x, hy - y, hz - z
	if upF then
		S.rot.Pitch, S.rot.Yaw, S.rot.Roll = M.faceRotUp(dx, dy, dz, math.cos(math.rad(S.yaw)), math.sin(math.rad(S.yaw)))
	else
		S.rot.Yaw = math.deg(math.atan(dy, dx))
		S.rot.Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
		S.rot.Roll = 0.0
	end
	if one then
		local ok, err = pcall(slot.comp.K2_SetWorldLocationAndRotation, slot.comp, S.loc, S.rot, false, D.hr, true)
		if ok then return end
		S.placeOneBad = true
		log("one-call place failed, back to two calls: " .. tostring(err))
		slot.comp:K2_SetWorldLocation(S.loc, false, D.hr, true)
	end
	slot.comp:K2_SetWorldRotation(S.rot, false, D.hr, true)
end

-- xinput: grip edges for both hands; a grab in progress swallows its grip so neither the game nor the pickup code sees it
function M.onXInput(state)
	if not enabled() then return end
	local g = state.Gamepad
	local b = g.wButtons
	local trig = D.configui.getValue("grab_button") ~= 2 -- step 79b: default = the same hand's trigger
	if trig then
		S.tlock[1] = M.trigLock(S.tlock[1], M.handAtCard(1), g.bLeftTrigger)
		S.tlock[2] = M.trigLock(S.tlock[2], M.handAtCard(2), g.bRightTrigger)
		S.gripNow[1] = M.trigDown(S.gripNow[1], g.bLeftTrigger)
		S.gripNow[2] = M.trigDown(S.gripNow[2], g.bRightTrigger)
	else
		S.gripNow[1] = (b & XINPUT_GAMEPAD_LEFT_SHOULDER) ~= 0
		S.gripNow[2] = (b & XINPUT_GAMEPAD_RIGHT_SHOULDER) ~= 0
	end
	local pressed = S.pressed
	for h = 1, 2 do
		pressed[h] = S.gripNow[h] and not S.gripPrev[h]
		if pressed[h] then S.gripEdge[h] = true end
		S.gripPrev[h] = S.gripNow[h]
	end
	-- a FRESH press with the hand at a card arms that hand; a grab or an armed hand owns its button until released
	if S.nearHand ~= nil and pressed[S.nearHand] and S.grab == nil then S.armed = S.nearHand end
	if S.armed ~= nil and not S.gripNow[S.armed] then S.armed = nil end
	if trig then -- trigger mode: swallow only that trigger (also on the release frame); the grip always reaches the game
		local h = (S.grab ~= nil) and S.grab.hand or S.armed
		if h == nil and S.swH ~= nil then h = S.swH end
		S.swH = (S.grab ~= nil or S.armed ~= nil) and h or nil
		if h == 1 then g.bLeftTrigger = 0 elseif h == 2 then g.bRightTrigger = 0 end
		if S.tlock[1] then g.bLeftTrigger = 0 end
		if S.tlock[2] then g.bRightTrigger = 0 end
	elseif S.grab ~= nil or S.armed ~= nil then
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
	-- step 61: the selection goes back afterwards (pin, else what was selected before), so a use changes neither the
	-- use-button item nor the belt scroll
	local prev = S.pin
	if prev == nil then pcall(function() prev = uevr.api:get_engine().GameInstance.ActiveSaveSlot.SelectedConsumable end) end
	local okS, sel = pcall(selectItem, pawn, item)
	if not okS or not sel then return false, "select failed " .. tostring(sel) end
	S.restore = prev
	S.verify = {item = item, before = itemCount(item), t = os.clock() + 1.5}
	if S.useKey == nil then S.useKey = {KeyName = D.uevrUtils.fname_from_string("Gamepad_FaceButton_Top")} end
	local ok, err = pcall(function() pawn:InpActEvt_UseItem_K2Node_InputActionEvent_21(S.useKey) end)
	return ok, err
end

-- step 32/39/46/90: display-only cards under the belt row (M.wcardPos): prev cards left, next right; weapons outer, throwables inner
M.WEAPON_DROP_CM = 18.0 -- below the belt row
local function weaponCard(want, cx, cy, cz, hp, k, up)
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
		pcall(function() w.bg:SetColorAndOpacity(BG_N) w.bg:SetVisibility(k == 5 and 4 or 2) end) -- step 88: weapon/throwable = icon only
		-- step 85 (user 2026-11-17): no gold frame on the weapon/throwable cards; only the ammo card (k 5) keeps its frame
		for e = 1, 4 do pcall(function() w.edges[e]:SetVisibility(k == 5 and 4 or 2) w.edges[e]:SetColorAndOpacity(k == 5 and EDGE_S or EDGE_H) end) end
	end
	if w.item ~= item then
		w.item = item
		pcall(function() w.img:SetBrushFromTexture(w.item.ItemIcon, false) end)
	end
	if k == 3 or k == 4 then setText(w, S.wCounts[k])
	else setText(w, M.shots(S.energyNow, S.wPer[k]), k == 5) end -- step 62: shots left (0 shown on the held weapon's card)
	local fx, fy = math.cos(math.rad(S.yaw)), math.sin(math.rad(S.yaw))
	if up and k <= 4 then -- step 86: near the shoulder, relative to the eyes
		local f, l, dz = M.wcardUpPos(k, D.configui.getValue("weapon_cards_up_x") or 26.0, D.configui.getValue("weapon_cards_up_y") or 2.0, D.configui.getValue("weapon_cards_up_z") or 40.0)
		pcall(place, w, hp.X + fx * f - fy * l, hp.Y + fy * f + fx * l, hp.Z - dz, hp.X, hp.Y, hp.Z)
	else
		local f, l = M.wcardPos(k)
		pcall(place, w, cx + fx * f - fy * l, cy + fy * f + fx * l, cz - (k == 5 and M.AMMO_DROP_CM or M.WEAPON_DROP_CM), hp.X, hp.Y, hp.Z, true)
	end
	if w.scaled == nil then
		w.scaled = true
		local sc = M.CARD_CM / M.PX * (k == 5 and M.AMMO_SCALE or 1.0)
		S.scale.X, S.scale.Y, S.scale.Z = sc, sc, sc
		pcall(function() w.comp:SetWorldScale3D(S.scale) end)
	end
	show(w, true)
end

-- step 67: grip on a peek card = one scroll step toward it. Panic heal pinned: the belt's own scroll; else the game's
-- selection moves to that item (the window follows the selection).
local function peekScroll(i, h)
	local d = S.role[i] == "prev" and -1 or 1
	if S.pin ~= nil then
		S.scroll = (S.scroll or 0) + d
	else
		local pawn = uevr.api:get_local_pawn(0)
		if pawn ~= nil and S.items[i] ~= nil then selectItem(pawn, S.items[i]) end
	end
	S.refreshT = 0.0
	D.uevrUtils.triggerHapticVibration(h == 1 and Handed.Left or Handed.Right, 0, 0.04, 220, 0.6)
	log("peek scroll " .. d .. " hand=" .. (h == 1 and "L" or "R"))
end

-- step 98 (headset 2026-11-17: grabbing felt like it came from the palm): grab / zone point = controller origin moved
-- grab_point_fwd cm along the controller forward (toward the fingertips); 0 = old palm point. Returns the location
-- struct (modified in place) or nil.
M.FINGER_CM = 7.0
function M.fingerPoint(ctrl)
	if ctrl == nil then return nil end
	local p = ctrl:K2_GetComponentLocation()
	local k = M.FINGER_CM
	if D ~= nil then local v = D.configui.getValue("grab_point_fwd") if type(v) == "number" then k = v end end
	if k ~= 0 then
		local f = ctrl:GetForwardVector()
		p.X, p.Y, p.Z = p.X + f.X * k, p.Y + f.Y * k, p.Z + f.Z * k
	end
	return p
end

function M.tick(dt)
	if S.bzH ~= nil and os.clock() >= S.bzT then local h, k = S.bzH, S.bzK S.bzH = nil pcall(buzzOnce, h, k) end -- step 94
	if not enabled() then if S.shown or S.grab ~= nil then M.hideAll() end return end
	local P = M.prof -- s115: optional section timer (nil = off; set from the dev bridge)
	if P ~= nil then P() end
	local now = os.clock()
	if now > S.refreshT then
		S.refreshT = now + 0.5
		pcall(M.refresh, S.forceWalk)
		S.forceWalk = false
		for i = 1, M.MAX_CARDS do -- a card whose component died (level change) is recreated
			local s = S.slots[i]
			if s ~= nil and D.uevrUtils.getValid(s.comp) == nil then S.slots[i] = nil if S.grab ~= nil and S.grab.slot == i then S.grab = nil end end
		end
	end
	if S.verify ~= nil and now > S.verify.t then
		log(string.format("use result: count %d -> %d", S.verify.before, itemCount(S.verify.item)))
		S.verify = nil
		local back = S.restore
		S.restore = nil
		if back ~= nil and itemCount(back) > 0 then -- step 61: selection back to the pin / the earlier item
			local pawn = uevr.api:get_local_pawn(0)
			local okB = pawn ~= nil and pcall(selectItem, pawn, back)
			pcall(function() S.selAddr = back:get_address() end)
			if not okB then log("selection restore failed") end
		end
		S.refreshT = 0.0
	end
	if P ~= nil then P("belt.refresh") end
	if S.verify == nil and (S.shown or S.pin ~= nil) and now > S.selCheckT then
		S.selCheckT = now + 0.1
		pcall(function()
			local s = uevr.api:get_engine().GameInstance.ActiveSaveSlot.SelectedConsumable
			local a = s ~= nil and s:get_address() or nil
			if S.pin ~= nil then
				-- step 61 panic heal: a selection that left the pin = next / previous press -> one scroll step, re-pin
				if a ~= S.pinAddr then
					if itemCount(S.pin) <= 0 then S.refreshT = 0.0 return end -- pin ran out: refresh picks the next one
					local from, to = nil, nil
					for k = 1, S.cycN or 0 do
						if S.cyc[k] == S.pinAddr then from = k end
						if S.cyc[k] == a then to = k end
					end
					local d = S.pinFresh and 0 or M.cycleDir(S.cycN or 0, from, to)
					S.scroll = (S.scroll or 0) + d
					local pawn = uevr.api:get_local_pawn(0)
					if pawn ~= nil then selectItem(pawn, S.pin) end
					S.selAddr = S.pinAddr
					S.refreshT = 0.0
					log("panic heal: selection moved (" .. d .. "), heal item selected again")
				end
				S.pinFresh = false
			elseif a ~= S.selAddr then -- game's next/previous item changed the selection: re-centre the belt soon
				S.selAddr = a
				S.refreshT = 0.0
			end
		end)
	end
	if P ~= nil then P("belt.sel") end
	local head = D.controllers.getController(2)
	local lh, rh = D.controllers.getController(0), D.controllers.getController(1)
	if head == nil then clearInput() return end
	local hp, hr = head:K2_GetComponentLocation(), head:K2_GetComponentRotation()
	local drop = M.beltDrop(D.configui.getValue) -- step 122: seated height
	local hands = S.handPos
	hands[1], hands[2] = M.fingerPoint(lh), M.fingerPoint(rh)
	if D.configui.getValue("belt_body_yaw") ~= false then -- step 125: the belt turns with the body (hands), not the head
		local l, r = hands[1], hands[2]
		local hy = nil
		if l ~= nil and r ~= nil then hy = M.handsYaw(hp.X, hp.Y, hr.Yaw, l.X, l.Y, l.Z, r.X, r.Y, r.Z, hp.Z - drop) end
		S.yaw = M.bodyYawStep(S.yaw, hr.Yaw, hy, dt)
		if S.byLogT == nil or os.clock() > S.byLogT then
			S.byLogT = os.clock() + 5.0
			log(string.format("belt yaw %.0f head %.0f hands %s", S.yaw, hr.Yaw, hy ~= nil and string.format("%.0f", hy) or "-"))
		end
	else
		S.yaw = M.smoothYaw(S.yaw, hr.Yaw, dt, 0.45)
	end
	local bf, bs = D.configui.getValue("belt_fwd"), D.configui.getValue("belt_side")
	if type(bf) ~= "number" then bf = M.FORWARD end
	if type(bs) ~= "number" then bs = 0.0 end
	M.fwdLive, M.sideLive = bf, bs
	local cx, cy = M.anchor(hp.X, hp.Y, S.yaw, bf, bs)
	local cz = hp.Z - drop
	local fx, fy = math.cos(math.rad(S.yaw)), math.sin(math.rad(S.yaw)) -- belt forward (mouth point below)
	-- layout
	local angs = S.cardAng -- step 67: filled by refresh (M.layout)
	local shOn = D.configui.getValue("heal_gloves") ~= false -- step 122: heals on the IK gloves
	local get = D.configui.getValue -- step 122: glove heal spots (read once per frame, no tables)
	local gLx, gLy, gLz = tonumber(get("heal_gl_x")) or M.GL_L.x, tonumber(get("heal_gl_y")) or M.GL_L.y, tonumber(get("heal_gl_z")) or M.GL_L.z
	local gRx, gRy, gRz = tonumber(get("heal_gr_x")) or M.GL_R.x, tonumber(get("heal_gr_y")) or M.GL_R.y, tonumber(get("heal_gr_z")) or M.GL_R.z
	local spot = tonumber(get("heal_spot")) or 1 -- step 125: 1 above the elbows, 2 shoulders, 3 gloves
	local onSh = shOn and spot == 2 -- step 124: shoulder chain (nudges read once per frame)
	local onEl = shOn and spot == 1
	-- step 137 (user: the left elbow heal must do what the right one does): one set of offsets, mirrored by side
	local eBf, eBo, eBu = tonumber(get("heal_er_fwd")) or 0.0, tonumber(get("heal_er_out")) or 0.0, tonumber(get("heal_er_up")) or 0.0
	local sLf, sLo, sLu = tonumber(get("heal_shl_fwd")) or 0.0, tonumber(get("heal_shl_out")) or 0.0, tonumber(get("heal_shl_up")) or 0.0
	local sRf, sRo, sRu = tonumber(get("heal_shr_fwd")) or 0.0, tonumber(get("heal_shr_out")) or 0.0, tonumber(get("heal_shr_up")) or 0.0
	-- step 120: the models face with the body yaw, not the head's
	local byaw = nil
	if shOn and M.bodyYaw ~= nil then local okY, y1 = pcall(M.bodyYaw) if okY and type(y1) == "number" then byaw = y1 end end
	if byaw == nil or get("belt_body_yaw") ~= false then byaw = S.yaw end -- step 125: the belt's body yaw when on
	local shYaw = M.yawDelta(byaw, S.yaw)
	local sk = M.skin
	local skinOn = false
	if sk ~= nil then local okS, r = pcall(sk.active) skinOn = okS and r == true end
	for i = 1, S.n do
		local s = S.slots[i]
		if s == nil then s = createSlot(i) S.slots[i] = s end
		if s ~= nil then
			s.x, s.y = M.slotPos(cx, cy, S.yaw, angs[i], M.RADIUS)
			s.z = ((S.role[i] == "heal" or S.role[i] == "heal2") and S.healApart) and (cz + M.HEAL_RAISE_CM) or cz
			if skinOn then local okZ, gz = pcall(sk.grabDz) s.z = cz + (okZ and gz or -8.0) end -- step 82/88: grab sphere on the 3D model
			s.on = true
			s.r = M.reachFor(S.role[i]) -- step 93
			local sg = M.shoulderSide(shOn, S.role[i]) -- step 117: heal items on the shoulders
			s.sh = sg
			if sg ~= nil then
				local side = sg < 0 and 0 or 1
				local ox, oy, oz = gLx, gLy, gLz
				if sg > 0 then ox, oy, oz = gRx, gRy, gRz end
				local ok1, wx, wy, wz, xx, xy, xz, yx, yy, yz, zx, zy, zz = false, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
				-- step 124: shoulder chain first (IK shoulder joint, body yaw); glove frame only when off / no IK arms
				local okS, sx, sy, sz = false, nil, nil, nil
				local okE, ex, ey, ez = false, nil, nil, nil -- step 125: elbow chain
				if onEl and M.elbowLoc ~= nil then okE, ex, ey, ez, sx, sy, sz = pcall(M.elbowLoc, side) okS = okE end
				if onSh and M.shoulderLoc ~= nil then okS, sx, sy, sz = pcall(M.shoulderLoc, side) end
				if okS and type(sz) == "number" then
					local px, py, pz
					if onEl then
						local nf, no, nu = eBf, eBo, eBu
						px, py, pz = M.elbowPoint(ex, ey, ez, sx, sy, sz, byaw, sg, M.EL_ALONG, M.EL_FWD + nf, M.EL_OUT + no, M.EL_UP + nu)
					else
						local nf, no, nu = sLf, sLo, sLu
						if sg > 0 then nf, no, nu = sRf, sRo, sRu end
						px, py, pz = M.shoulderPoint(sx, sy, sz, byaw, sg, M.SH_FWD + nf, M.SH_OUT + no, M.SH_UP + nu)
					end
					local dx, dy = px - cx, py - cy
					s.shLx, s.shLy, s.shLz = dx * fx + dy * fy, dy * fx - dx * fy, pz - cz
					local gdz = -15.0
					if skinOn then local okG, g = pcall(sk.shGrabDz) if okG and type(g) == "number" then gdz = g end end
					s.x, s.y, s.z = px, py, pz + gdz -- grab sphere on the hanging model
					s.shYaw, s.glove, s.r = shYaw, false, M.SH_REACH_CM
					if S.shLogged ~= spot then S.shLogged, S.glLogged = spot, nil log(onEl and "heals hang above the IK elbows" or "heals hang from the IK shoulders") end
				else
				if M.gloveFrame ~= nil then ok1, wx, wy, wz, xx, xy, xz, yx, yy, yz, zx, zy, zz = pcall(M.gloveFrame, side) end
				if not ok1 or type(zz) ~= "number" then -- no IK arms: controller frame (Y = back along the arm, Z = up)
					ok1, wx = false, nil
					local c = side == 0 and lh or rh
					if c ~= nil then
						local okC, a1, a2, a3, b1, b2, b3, c1, c2, c3 = pcall(function()
							local cl, cf, cu = c:K2_GetComponentLocation(), c:GetForwardVector(), c:GetUpVector()
							return cl.X, cl.Y, cl.Z, -cf.X, -cf.Y, -cf.Z, cu.X, cu.Y, cu.Z
						end)
						if okC and type(c3) == "number" then
							wx, wy, wz, yx, yy, yz, zx, zy, zz = a1, a2, a3, b1, b2, b3, c1, c2, c3
							xx, xy, xz = yy * zz - yz * zy, yz * zx - yx * zz, yx * zy - yy * zx
						end
					end
				end
				s.shYaw = shYaw
				s.glove = true
				if wx ~= nil then
					s.x, s.y, s.z = M.glovePoint(wx, wy, wz, xx, xy, xz, yx, yy, yz, zx, zy, zz, ox, oy, oz)
					if S.glLogged ~= ok1 then S.glLogged = ok1 log("glove heals on the " .. (ok1 and "IK lower arms" or "controllers")) end -- step 122: logs each change
				else
					s.x, s.y, s.z = hp.X, hp.Y, hp.Z - 200.0 -- no frame this frame: out of reach
				end
				local dx, dy = s.x - cx, s.y - cy
				s.shLx, s.shLy, s.shLz = dx * fx + dy * fy, dy * fx - dx * fy, s.z - cz
				s.r = M.SH_REACH_CM
				S.shLogged = nil
				end -- step 124: glove branch
			else
				s.shLx, s.shLy, s.shLz, s.shYaw, s.glove = nil, nil, nil, nil, nil
			end
			local nb = S.noUse ~= nil and S.noUse[i] == true -- step 120: can't-use hint (grey tint; 3D: grey shell + red X)
			if s.noUse ~= nb then
				s.noUse, s.styled = nb, nil
				if s.comp ~= nil then pcall(function() s.comp:SetTintColorAndOpacity(nb and TINT_OFF or TINT_ON) end) end
			end
			local pk = S.role[i] == "prev" or S.role[i] == "next"
			if s.peek ~= pk then s.peek = pk s.scaled = nil s.mscale = nil s.styled = nil s.item = nil end -- step 88: item re-set
			if s.item ~= S.items[i] then
				s.item = S.items[i]
				s.itemAddr = nil
				pcall(function() s.itemAddr = s.item:get_address() end)
				s.shownCount = nil
				pcall(function() s.img:SetBrushFromTexture(s.item.ItemIcon, false) end)
				setModel(s)
				local okT, rk, sz = pcall(tierFor, s.item)
				if s.peek then okT = false end
				setPips(s, okT and rk or 1, okT and sz or 1)
			end
			setText(s, s.peek and 0 or (S.counts[i] or 0)) -- step 88: a peek card shows no item, count or pips
		end
	end
	for i = S.n + 1, M.MAX_CARDS do local s = S.slots[i] if s ~= nil then s.on = false show(s, false) if skinOn then pcall(sk.off, i) end end end
	if P ~= nil then P("belt.slots") end
	-- which hand is at a card (for the xinput swallow) + grab start on a fresh grip
	S.nearHand = nil
	local nearBelt = false
	for h = 1, 2 do
		local p = hands[h]
		S.atCard[h] = false
		if p ~= nil then
			if M.dist(p.X, p.Y, p.Z, cx, cy, cz) < M.RADIUS + M.NEAR_CM then nearBelt = true end
			local i = M.nearestSlot(S.slots, S.n, p.X, p.Y, p.Z, M.GRAB_CM, nil, h)
			-- step 132: hand behind the shoulder (weapon-switch zone) never grabs a heal card (not in the shoulder-hung mode)
			if i ~= nil and (S.role[i] == "heal" or S.role[i] == "heal2") then
				if S.shMod == nil then local okM, m = pcall(require, "libs/qd_shoulder") S.shMod = okM and m or false end
				local sh = S.shMod
				if spot == 2 then -- shoulder-hung heals: block a hand behind the card (swap reach), in any zone; front/side still grabs
					local yr = math.rad(hr.Yaw)
					local yfx, yfy = math.cos(yr), math.sin(yr)
					local sl = S.slots[i]
					local fh = (p.X - hp.X) * yfx + (p.Y - hp.Y) * yfy
					local fc = (sl.x - hp.X) * yfx + (sl.y - hp.Y) * yfy
					if fh < fc - M.HEAL_BEHIND_CM then i = nil end
				elseif sh and (sh.inZone(p.X, p.Y, p.Z, hp.X, hp.Y, hp.Z, hr.Yaw, 1) or sh.inZone(p.X, p.Y, p.Z, hp.X, hp.Y, hp.Z, hr.Yaw, -1)) then
					i = nil
				end
			end
			S.atCard[h] = i ~= nil or (S.grab ~= nil and S.grab.hand == h)
			if i ~= nil and S.grab == nil then
				S.nearHand = h
				if S.gripEdge[h] and S.slots[i].peek then
					pcall(peekScroll, i, h) -- step 67: a peek card scrolls, it is never held
				elseif S.gripEdge[h] then
					S.grab = {hand = h, slot = i, item = S.slots[i].item, away = false}
					D.uevrUtils.triggerHapticVibration(h == 1 and Handed.Left or Handed.Right, 0, 0.05, 200, 0.5)
					log(string.format("grab card %d hand=%s", i, h == 1 and "L" or "R"))
				end
			end
		end
		S.gripEdge[h] = false
	end
	S.atCardT = os.clock()
	-- step 21: highlight the card a grip would take (bigger model, bright card) + haptic tick when it changes
	local hl, hlHand = M.targetSlot(S.slots, S.n, hands, M.GRAB_CM, S.grab)
	if hl ~= S.hl then
		if hl ~= nil and hlHand ~= nil and S.grab == nil then
			local hr = S.role[hl] == "heal" or S.role[hl] == "heal2" -- step 93/94: heal = double tap (blind grab)
			M.buzz(hlHand, hr and "heal" or "item")
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
			local hfx, hfy = math.cos(math.rad(hr.Yaw)), math.sin(math.rad(hr.Yaw)) -- step 125: mouth = head forward (belt yaw may differ)
			local mx, my, mz = hp.X + hfx * 4.0, hp.Y + hfy * 4.0, hp.Z - 9.0
			local useNow
			useNow, g.away = M.mouthUse(M.dist(p.X, p.Y, p.Z, mx, my, mz), g.away, M.MOUTH_CM) -- step 117
			if useNow and now - S.lastUseT > 1.0 then
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
	if P ~= nil then P("belt.hands") end
	local sc = M.CARD_CM / M.PX
	S.spin = (S.spin + M.SPIN_DPS * dt) % 360.0
	local held = S.grab ~= nil and S.grab.slot or nil
	if skinOn ~= (S.skinOn == true) then -- step 82: skin switched; card placement is re-applied / the skin lets go
		S.skinOn = skinOn
		if not skinOn then pcall(sk.release) end
		for i = 1, M.MAX_CARDS do local s = S.slots[i] if s ~= nil then s.styled, s.scaled, s.mscale, s.visible = nil, nil, nil, nil end end
	end
	if skinOn then pcall(sk.frame, cx, cy, cz, S.yaw, want, shOn and S.n > 0) end
	if P ~= nil then P("belt.skinframe") end
	for i = 1, M.MAX_CARDS do -- step 31: hold/release transitions
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
			local w = want or s.sh ~= nil -- step 117: shoulder heal items always show
			local hlOn = w and (i == S.hl) and not s.held
			local selOn = s.itemAddr ~= nil and s.itemAddr == S.selAddr
			if skinOn then pcall(sk.slot, i, s, s.sh ~= nil and s.sh * 90.0 or angs[i], hlOn, selOn, w) end
			if s.held then
				if s.visible ~= "held" then
					s.visible = "held"
					pcall(function() s.comp:SetVisibility(false, false) end)
					pcall(function() s.mesh:SetVisibility(true, false) end)
				end
			elseif skinOn then -- the skin places everything
			elseif w then
				pcall(place, s, s.x, s.y, s.z, hp.X, hp.Y, hp.Z, true) -- s103: shared up, hip heal cards read upright
				if s.scaled ~= hlOn then -- nil (new card) / false / true: card scale, 1.15x when highlighted
					s.scaled = hlOn
					local k = sc * (hlOn and 1.15 or 1.0) * (s.peek and M.PEEK_SCALE or 1.0)
					S.scale.X, S.scale.Y, S.scale.Z = k, k, k
					pcall(function() s.comp:SetWorldScale3D(S.scale) end)
				end
				pcall(placeModel, s, hp.X, hp.Y, hp.Z, hlOn)
			end
			if skinOn then
				s.hl, s.sel = hlOn, selOn
			else
				if s.hl ~= hlOn or s.sel ~= selOn or s.styled == nil then
					s.hl, s.sel = hlOn, selOn
					pcall(cardStyle, s)
				end
				if not s.held then show(s, w) end
			end
		end
	end
	if P ~= nil then P("belt.cards") end
	if want and S.energy ~= nil then -- step 62: live energy for the shots-left numbers
		local okE, e = pcall(function() return S.energy.CurrentPowerCharge end)
		S.energyNow = okE and e or nil
	end
	local up, wantR, wantL = false, want, want
	pcall(function()
		up = D.configui.getValue("weapon_cards_up") ~= false
		local sh = package.loaded["libs/qd_shoulder"]
		if up and type(sh) == "table" then -- step 86: a side's cards also show while that hand is near its shoulder zone
			local mode = D.configui.getValue("weapon_cards_show") or 1
			wantR = M.wcardVisible(mode, want, sh.handNear(true))
			wantL = M.wcardVisible(mode, want, sh.handNear(false))
		end
	end)
	pcall(weaponCard, wantR, cx, cy, cz, hp, 1, up)
	pcall(weaponCard, wantR, cx, cy, cz, hp, 2, up)
	pcall(weaponCard, wantL, cx, cy, cz, hp, 3, up)
	pcall(weaponCard, wantL, cx, cy, cz, hp, 4, up)
	pcall(weaponCard, want, cx, cy, cz, hp, 5)
	if P ~= nil then P("belt.wcards") end
end

return M
