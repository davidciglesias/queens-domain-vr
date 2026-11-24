-- Unit tests for libs/qd_belt.lua (layout math). Run: python tools/run_tests.py
local b = require("qd_belt")

local failed, passed = 0, 0
local function check(name, cond)
	if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end
local function near(a, c, eps) return math.abs(a - c) <= (eps or 1e-6) end

do -- slot angles are centred and evenly spaced
	local a1 = b.slotAngles(1, 26)
	check("one slot centred", #a1 == 1 and near(a1[1], 0))
	local a4 = b.slotAngles(4, 20)
	check("four slots", #a4 == 4 and near(a4[1], -30) and near(a4[2], -10) and near(a4[3], 10) and near(a4[4], 30))
	check("zero slots", #b.slotAngles(0) == 0)
end

do -- slot position: yaw 0 faces +X, a positive angle goes to +Y (UE right)
	local x, y = b.slotPos(100, 200, 0, 0, 24)
	check("ahead", near(x, 124) and near(y, 200))
	x, y = b.slotPos(0, 0, 0, 90, 10)
	check("right", near(x, 0, 1e-9) and near(y, 10))
	x, y = b.slotPos(0, 0, 90, 0, 10)
	check("yaw 90", near(x, 0, 1e-9) and near(y, 10))
end

do -- yaw smoothing wraps across +-180 and converges
	check("first value", b.smoothYaw(nil, 50, 0.1) == 50)
	local y = b.smoothYaw(170, -170, 10.0, 0.4)
	check("wrap converges", near(math.abs(y), 170, 1e-3) and y < 0)
	local h = b.smoothYaw(170, -170, 0.4, 0.4) -- one tau: ~63 % of the 20 degree step, across the seam
	check("wrap partial", h > 170 or h < -170)
	check("no dt no move", near(b.smoothYaw(10, 40, 0, 0.4), 10))
end

do -- nearest slot within reach, off slots ignored
	local slots = {{x = 0, y = 0, z = 0, on = true}, {x = 10, y = 0, z = 0, on = true}, {x = 20, y = 0, z = 0, on = false}}
	check("nearest", b.nearestSlot(slots, 3, 8, 0, 0, 14) == 2)
	check("out of reach", b.nearestSlot(slots, 3, 50, 0, 0, 14) == nil)
	check("off ignored", b.nearestSlot(slots, 3, 20, 0, 0, 5) == nil)
	-- step 93: per-slot reach, capped upward
	local hs = {{x = 0, y = 0, z = 0, on = true, r = b.reachFor("heal")}}
	check("s93 heal reach below", b.nearestSlot(hs, 1, 0, 0, -24, 14) == 1)
	check("s93 heal reach side", b.nearestSlot(hs, 1, 0, 24, 0, 14) == 1)
	check("s93 heal reach up capped", b.nearestSlot(hs, 1, 0, 0, 15, 14) == nil and b.nearestSlot(hs, 1, 0, 0, 13, 14) == 1)
	local H = b.HAPTIC -- step 94: three distinct feels
	check("s94 heal double, others single", H.heal[4] > 0 and H.item[4] == 0 and H.switch[4] == 0)
	check("s94 switch longest", H.switch[1] > H.heal[1] and H.heal[1] > H.item[1])
	check("s93 peek stays small", b.reachFor("next") == b.GRAB_CM and b.reachFor("item") > b.GRAB_CM)
	local mix = {{x = 0, y = 0, z = 0, on = true, r = 19}, {x = 30, y = 0, z = 0, on = true, r = 25}}
	check("s93 relative reach picks heal at the seam", b.nearestSlot(mix, 2, 14, 0, 0, 14) == 2 and b.nearestSlot(mix, 2, 12, 0, 0, 14) == 1)
end

do -- step 8: walking the game's cycle collects each quick-slot item once
	local ring, k = {"a", "b", "c"}, 0
	local seen, n = b.walkCycle(function() k = k % #ring + 1 return ring[k] end)
	check("walk ring", n == 3 and seen.a and seen.b and seen.c)
	local calls = 0
	seen, n = b.walkCycle(function() calls = calls + 1 return nil end)
	check("walk empty", n == 0 and next(seen) == nil and calls == 1)
	k = 0
	seen, n = b.walkCycle(function() k = k + 1 return k end, 5) -- never repeats: stops at the limit
	check("walk limit", n == 5)
	k = 0
	seen, n = b.walkCycle(function() k = k + 1 return (k == 1) and "x" or "y" end) -- x -> y -> y (stuck)
	check("walk stuck", n == 2 and seen.x and seen.y)
	check("slots default", b.slotCount(nil) == b.MAX_SLOTS)
	check("slots clamp", b.slotCount(0) == 1 and b.slotCount(9) == b.MAX_SLOTS and b.slotCount(3.7) == 3)
end

do -- step 8b: window follows the selection, circular
	local s, c = b.window(3, 2, 5)
	check("window fits", s == 1 and c == 3)
	s, c = b.window(30, 10, 5)
	check("window centred", s == 8 and c == 5)
	s, c = b.window(30, 1, 5)
	check("window wraps low", s == 29 and c == 5)
	s, c = b.window(30, 30, 5)
	check("window wraps high", s == 28 and c == 5)
	s, c = b.window(30, nil, 5)
	check("window no selection", s == 1 and c == 5)
	s, c = b.window(10, 5, 4)
	check("window even", s == 4 and c == 4)
	s, c = b.window(0, nil, 5)
	check("window empty", c == 0)
end

do -- step 21: model template name, model scale, highlighted slot
	check("template name", b.meshTemplateName("BlueprintGeneratedClass /Game/A/B_C.B_C") == "StaticMeshComponent /Game/A/B_C.B_C.PickupGraphics_GEN_VARIABLE")
	check("template bad", b.meshTemplateName("nonsense") == nil and b.meshTemplateName(nil) == nil)
	check("scale fits", near(b.meshScale(9.0, 4.5), 0.5))
	check("scale degenerate", b.meshScale(0.0, 4.5) == nil and b.meshScale(nil, 4.5) == nil)
	check("scale capped", b.meshScale(0.05, 4.5) == 50.0)
	local slots = {{x = 0, y = 0, z = 0, on = true}, {x = 20, y = 0, z = 0, on = true}, {x = 40, y = 0, z = 0, on = false}}
	local i, h = b.targetSlot(slots, 3, {nil, {X = 18, Y = 0, Z = 0}}, 14)
	check("target right hand", i == 2 and h == 2)
	i, h = b.targetSlot(slots, 3, {{X = 3, Y = 0, Z = 0}, {X = 15, Y = 0, Z = 0}}, 14)
	check("target nearer hand wins", i == 1 and h == 1)
	i = b.targetSlot(slots, 3, {{X = 40, Y = 0, Z = 0}, nil}, 14)
	check("target hidden slot ignored", i == nil)
	i, h = b.targetSlot(slots, 3, {nil, nil}, 14, {slot = 3, hand = 1})
	check("target grab", i == 3 and h == 1)
end

do -- step 39: previous / next slot weapon
	local a, w2, c = {}, {}, {}
	local p, n = b.neighbours({a, w2, c}, 3, c, 2)
	check("neighbours wrap next", p == w2 and n == a)
	p, n = b.neighbours({a, w2, c}, 3, a, 0)
	check("neighbours wrap prev", p == c and n == w2)
	p, n = b.neighbours({a, w2}, 2, a, 0)
	check("two weapons: both sides the other", p == w2 and n == w2)
	p, n = b.neighbours({a}, 1, a, 0)
	check("one weapon: none", p == nil and n == nil)
	p, n = b.neighbours({a, w2, c}, 3, {}, 1)
	check("cur not in list: slot index", p == a and n == c)
	p, n = b.neighbours({}, 0, a, 0)
	check("empty list", p == nil and n == nil)
end
do -- step 46: lower card row + sorted insert
	local f1, l1 = b.wcardPos(1)
	local f2, l2 = b.wcardPos(2)
	local f3, l3 = b.wcardPos(3)
	local f4, l4 = b.wcardPos(4)
	check("row order left to right: w prev, t prev, t next, w next (step 90)", l1 < l3 and l3 < 0 and 0 < l4 and l4 < l2)
	check("row symmetric", l1 == -l2 and l3 == -l4 and f1 == f2 and f3 == f4)
	check("cards don't overlap", (l3 - l1) >= b.CARD_CM and (l4 - l3) >= b.CARD_CM)
	local L, K, n = {}, {}, 0
	n = b.sortedInsert(L, K, n, "c", 1002)
	n = b.sortedInsert(L, K, n, "a", 1000)
	n = b.sortedInsert(L, K, n, "b", 1001)
	check("sortedInsert orders by id", n == 3 and L[1] == "a" and L[2] == "b" and L[3] == "c")
end
do -- step 86: cards up near the shoulders
	local f1, l1, d1 = b.wcardUpPos(1, 25, 12, 20)
	local f2, l2 = b.wcardUpPos(2, 25, 12, 20)
	local f3, l3 = b.wcardUpPos(3, 25, 12, 20)
	local f4, l4 = b.wcardUpPos(4, 25, 12, 20)
	check("up: weapons right, throwables left", l1 > 0 and l2 > 0 and l3 < 0 and l4 < 0)
	check("up: prev outside, next inside", l1 > l2 and l3 < l4)
	check("up: mirrored", l1 == -l3 and l2 == -l4 and f1 == 20 and f4 == 20 and d1 == 12)
	check("up: pair gap = UP_GAP_CM, no overlap", math.abs((l1 - l2) - b.UP_GAP_CM) < 1e-9 and b.UP_GAP_CM >= b.CARD_CM)
	check("up: centred on lateral option", math.abs((l1 + l2) / 2 - 25) < 1e-9)
end
do -- step 49: tier rank among same-model items by sort order
	local keys = {"a", "h", "h", "b", "h"}
	local sorts = {5, 1003, 1001, 7, 1002}
	local r1, z1 = b.tierRank(keys, sorts, 5, 3)
	local r2, z2 = b.tierRank(keys, sorts, 5, 5)
	local r3, z3 = b.tierRank(keys, sorts, 5, 2)
	check("tier lowest", r1 == 1 and z1 == 3)
	check("tier mid", r2 == 2 and z2 == 3)
	check("tier top", r3 == 3 and z3 == 3)
	local r4, z4 = b.tierRank(keys, sorts, 5, 1)
	check("single tier", r4 == 1 and z4 == 1)
	local r5 = b.tierRank({"x", "x"}, {1, 1}, 2, 2)
	check("equal sort: list order", r5 == 2)
end
do -- step 58: heal card
	check("heal field tier 1", b.healField("item_heal_herb") == "HealingHerb1HealAmount")
	check("heal field tier 3", b.healField("item_heal_potion_3") == "HealingPotion3HealAmount")
	check("heal field other", b.healField("item_cure_poison") == nil and b.healField(nil) == nil)
	check("heal field near miss", b.healField("item_healx") == nil)
	-- herb 30/60/90, potion 50/100/200, one non-healing (false)
	local am = {30, 60, 90, 50, 100, 200, false}
	check("pick weakest", b.healPick(am, {true, true, true, true, true, true, true}, 7) == 1)
	check("pick across families", b.healPick(am, {false, true, true, true, true, true, true}, 7) == 4)
	check("pick next", b.healPick(am, {false, true, true, false, true, true, true}, 7) == 2)
	check("pick none", b.healPick(am, {false, false, false, false, false, false, true}, 7) == nil)
	check("pick tie keeps first", b.healPick({5, 5}, {true, true}, 2) == 1)
	check("s91 pick strongest", b.healPick(am, {true, true, true, true, true, true, true}, 7, true) == 6)
	check("s91 strongest of owned", b.healPick(am, {true, true, true, true, true, false, true}, 7, true) == 5)
	check("s91 strongest none", b.healPick(am, {false, false, false, false, false, false, true}, 7, true) == nil)
end
do -- step 61: next / previous detection from a selection change in the quick cycle
	check("dir next", b.cycleDir(6, 2, 3) == 1)
	check("dir prev", b.cycleDir(6, 2, 1) == -1)
	check("dir wrap next", b.cycleDir(6, 6, 1) == 1)
	check("dir wrap prev", b.cycleDir(6, 1, 6) == -1)
	check("dir same", b.cycleDir(6, 4, 4) == 0)
	check("dir two entries = next", b.cycleDir(2, 1, 2) == 1 and b.cycleDir(2, 2, 1) == 1)
	check("dir unknown", b.cycleDir(6, nil, 3) == 0 and b.cycleDir(6, 3, nil) == 0 and b.cycleDir(1, 1, 1) == 0)
	check("dir jump takes the short way", b.cycleDir(8, 1, 3) == 1 and b.cycleDir(8, 1, 7) == -1)
end

do -- step 61: belt scroll anchor
	check("anchor keeps", b.anchorPos(8, 3, 5, 0) == 3)
	check("anchor scroll next", b.anchorPos(8, 3, 3, 1) == 4)
	check("anchor scroll prev wraps", b.anchorPos(8, 1, 1, -1) == 8)
	check("anchor scroll next wraps", b.anchorPos(8, 8, 8, 1) == 1)
	check("anchor lost uses last", b.anchorPos(8, nil, 5, 0) == 5)
	check("anchor lost clamps", b.anchorPos(4, nil, 7, 0) == 4)
	check("anchor first time", b.anchorPos(4, nil, nil, 0) == 1)
	check("anchor empty", b.anchorPos(0, nil, 2, 1) == nil)
end

do -- step 62: shots left from energy cells
	check("shots half cells", b.shots(0.6157, 0.5) == 1)
	check("shots rifle", b.shots(3, 0.0625) == 48)
	check("shots exact", b.shots(1.5, 0.5) == 3)
	check("shots float noise", b.shots(0.4999999, 0.5) == 1 and b.shots(0.49, 0.5) == 0)
	check("shots none", b.shots(0, 0.5) == 0)
	check("shots melee", b.shots(2, nil) == nil and b.shots(2, 0) == nil and b.shots(nil, 0.5) == nil)
	local f, l = b.wcardPos(5)
	check("ammo card centred", l == 0 and f == b.AMMO_FWD_CM)
end
do -- step 67: arrows layout (heal right, 3 items centred, peek cards each side)
	local A, R = {}, {}
	local n = b.layout(true, 3, true, true, A, R)
	check("arrows full n", n == 6)
	check("arrows heal left (s91)", R[1] == "heal" and near(A[1], -b.HEAL_DEG) and A[1] < -(b.ARROW_DEG + b.STEP_DEG * 0.9))
	local A5, R5 = {}, {}
	local n5 = b.layout(true, 5, false, true, A5, R5) -- step 71: 5 items + heal set apart, no peeks
	check("s71 five items + heal", n5 == 6 and R5[1] == "heal" and R5[6] == "item" and near(A5[2], -2 * b.STEP_DEG) and near(A5[6], 2 * b.STEP_DEG))
	check("s71 heal past first item", A5[1] <= A5[2] - b.STEP_DEG * 0.99)
	check("s71 heal raise set", b.HEAL_RAISE_CM > 0)
	check("arrows items centred", R[2] == "item" and near(A[2], -b.STEP_DEG) and near(A[3], 0) and near(A[4], b.STEP_DEG))
	check("arrows peeks", R[5] == "prev" and near(A[5], -b.ARROW_DEG) and R[6] == "next" and near(A[6], b.ARROW_DEG))
	check("peeks outside items", b.ARROW_DEG > b.STEP_DEG)
	do -- step 79b: 3 slots + peeks, heal clear of the +60 peek, peekWindow
		check("s79b heal clear of prev peek", -b.ARROW_DEG - A[1] >= b.STEP_DEG)
		local st, cnt, pp, pn = b.peekWindow(5, 3, 3)
		check("s79b peekWindow 5/3", st == 2 and cnt == 3 and pp == 1 and pn == 5)
		local _, _, p2 = b.peekWindow(3, 2, 3)
		check("s79b no peeks when all fit", p2 == nil)
		check("s79b max cards", b.MAX_CARDS >= 6)
		check("s79b trig press", b.trigDown(false, 200) and not b.trigDown(false, 100))
		check("s79b trig hysteresis", b.trigDown(true, 100) and not b.trigDown(true, 60) and not b.trigDown(false, 100))
	end
	n = b.layout(false, 2, false, true, A, R)
	check("arrows two items no heal", n == 2 and near(A[1], -b.STEP_DEG / 2) and near(A[2], b.STEP_DEG / 2) and R[1] == "item")
	n = b.layout(true, 4, false, false, A, R)
	check("old layout heal leftmost", n == 5 and R[1] == "heal" and near(A[1], -2 * b.STEP_DEG) and near(A[5], 2 * b.STEP_DEG) and R[5] == "item")
	n = b.layout(true, 0, false, true, A, R)
	check("arrows heal only", n == 1 and R[1] == "heal")
	n = b.layout(true, 3, true, true, A, R, true) -- step 91: weak heal left, strong heal right, last
	-- step 92: trigger rest lock (pull from rest at a card = never reaches the game until released)
	check("s92 rest at card locks", b.trigLock(false, true, 0) == true)
	check("s92 pull keeps lock after leaving", b.trigLock(true, false, 200) == true)
	check("s92 release away unlocks", b.trigLock(true, false, 10) == false)
	check("s92 pull from away stays open at a card", b.trigLock(false, true, 200) == false)
	check("s91 two heals", n == 7 and R[1] == "heal" and R[7] == "heal2" and near(A[7], -A[1]) and A[7] > b.ARROW_DEG and n <= b.MAX_CARDS)
	n = b.layout(true, 4, false, false, A, R, true)
	check("s91 old layout heal2 rightmost", n == 6 and R[6] == "heal2" and near(A[6], 2.5 * b.STEP_DEG) and R[1] == "heal")
	local st, c, pp, pn = b.peekWindow(8, 4, 3)
	check("peek window", st == 3 and c == 3 and pp == 2 and pn == 6)
	st, c, pp, pn = b.peekWindow(8, 1, 3)
	check("peek window wraps", st == 8 and c == 3 and pp == 7 and pn == 3)
	st, c, pp, pn = b.peekWindow(3, 2, 3)
	check("peek none when all fit", c == 3 and pp == nil and pn == nil)
	st, c, pp, pn = b.peekWindow(4, 2, 3)
	check("peek four = same item both sides", c == 3 and pp == 4 and pn == 4)
end
do
	check("wcardVisible near", b.wcardVisible(1,false,false)==false and b.wcardVisible(1,true,false)==true and b.wcardVisible(1,false,true)==true and b.wcardVisible(nil,false,true)==true)
	check("wcardVisible always/never", b.wcardVisible(2,false,false)==true and b.wcardVisible(3,true,true)==false)
end
do -- step 101: under-belt cards share the up direction (belt forward +X)
	local a = require("qd_armhud")
	local function upOf(dx, dy, dz)
		local p, y, r = b.faceRotUp(dx, dy, dz, 1.0, 0.0)
		local _, _, _, zx, zy, zz = a.rotAxes(p, y, r)
		return zx, zy, zz
	end
	local p0, y0, r0 = b.faceRotUp(-50, 0, 0, 1.0, 0.0)
	check("faceRotUp eye level = plain look-at", math.abs(p0) < 1e-6 and math.abs(math.abs(y0) - 180) < 1e-6 and math.abs(r0) < 1e-6)
	local ax, ay, az = upOf(-20, -25, 70) -- card below, right of centre; vector to the eyes
	local bx, by, bz = upOf(-20, 25, 70)
	local function noTwist(ux, uy, uz, nx, ny, nz) -- up in the plane of the face normal and the shared hint (1,0,1)
		local cx, cy, cz = ny * 1 - nz * 0, nz * 1 - nx * 1, nx * 0 - ny * 1
		return math.abs(ux * cx + uy * cy + uz * cz) < 1e-6
	end
	check("faceRotUp side cards: up from the shared hint", noTwist(ax, ay, az, -20, -25, 70) and noTwist(bx, by, bz, -20, 25, 70))
	check("faceRotUp side cards mirror", math.abs(ay + by) < 1e-6 and math.abs(ax - bx) < 1e-6)
	check("faceRotUp side cards: up toward belt forward", ax > 0.5 and bx > 0.5)
	local nx, ny, nz = -20, -25, 70
	check("faceRotUp up perpendicular to the face", math.abs(ax * nx + ay * ny + az * nz) < 1e-6)
end
do -- step 109 anchor
	local x, y = b.anchor(10, 20, 0, 4, 0)
	check("anchor fwd4 side0 = old", near(x, 14) and near(y, 20))
	x, y = b.anchor(10, 20, 90, 4, 0)
	check("anchor old at yaw 90", near(x, 10) and near(y, 24))
	x, y = b.anchor(10, 20, 0, -10, 0)
	check("anchor fwd -10 moves back", near(x, 0) and near(y, 20))
	x, y = b.anchor(10, 20, 0, 4, 5)
	check("anchor side +5 = right (+Y at yaw 0)", near(x, 14) and near(y, 25))
	x, y = b.anchor(0, 0, 90, 0, 5)
	check("anchor side +5 at yaw 90 = -X", near(x, -5) and near(y, 0))
end
do -- step 117 shoulder heal items
	check("shoulder: weak heal left", b.shoulderSide(true, "heal") == -1)
	check("shoulder: strong heal right", b.shoulderSide(true, "heal2") == 1)
	check("shoulder: items stay", b.shoulderSide(true, "item") == nil and b.shoulderSide(true, "prev") == nil)
	check("shoulder: option off", b.shoulderSide(false, "heal") == nil)
	-- step 122: glove heals (point in the forearm frame, other hand only) + seated belt height
	local x, y, z = b.glovePoint(10, 20, 30, 1, 0, 0, 0, 1, 0, 0, 0, 1, 2, 5, 8)
	check("glovePoint: offsets along the axes", near(x, 12) and near(y, 25) and near(z, 38))
	x, y, z = b.glovePoint(0, 0, 0, 0, 1, 0, -1, 0, 0, 0, 0, 1, 2, 5, 0)
	check("glovePoint: turned frame", near(x, -5) and near(y, 2) and near(z, 0))
	check("ownGlove: left hand vs left heal", b.ownGlove({ sh = -1, glove = true }, 1) == true)
	check("ownGlove: right hand vs left heal", b.ownGlove({ sh = -1, glove = true }, 2) == false)
	check("ownGlove: shoulder heal takes either hand", b.ownGlove({ sh = -1, glove = false }, 1) == false)
	-- step 124: shoulder chain point in the body-yaw frame
	x, y, z = b.shoulderPoint(100, 200, 50, 0, -1, 3, 4, 13)
	check("shoulderPoint: yaw 0 left: fwd +X, out = -Y", near(x, 103) and near(y, 196) and near(z, 63))
	x, y, z = b.shoulderPoint(100, 200, 50, 0, 1, 3, 4, 13)
	check("shoulderPoint: yaw 0 right: out = +Y", near(x, 103) and near(y, 204))
	x, y, z = b.shoulderPoint(0, 0, 0, 90, 1, 3, 4, 0)
	check("shoulderPoint: yaw 90 right: fwd +Y, out -X", near(x, -4) and near(y, 3) and near(z, 0))
	-- step 125: elbow chain point (along the upper arm from the elbow, then body-frame offsets)
	x, y, z = b.elbowPoint(0, 0, 0, 0, 0, 30, 0, -1, 6, 0, 4, 0)
	check("elbowPoint: 6 up the arm, 4 out left", near(x, 0) and near(y, -4) and near(z, 6))
	x, y, z = b.elbowPoint(0, 0, 0, 0, 0, 3, 0, 1, 6, 0, 0, 0)
	check("elbowPoint: clamped at the shoulder", near(z, 3))
	x, y, z = b.elbowPoint(5, 5, 5, 5, 5, 5, 90, 1, 6, 2, 0, 1)
	check("elbowPoint: zero-length arm -> offsets only", near(x, 5) and near(y, 7) and near(z, 6))
	-- step 125: belt body yaw from the hands
	check("handsYaw: hands lowered -> nil", b.handsYaw(0, 0, 0, 30, -10, -60, 30, 10, -60, -60) == nil)
	check("handsYaw: hands close to the head -> nil", b.handsYaw(0, 0, 0, 5, -3, 0, 5, 3, 0, -60) == nil)
	check("handsYaw: hands behind -> nil", b.handsYaw(0, 0, 0, -30, -10, -20, -30, 10, -20, -60) == nil)
	check("handsYaw: hands in front, head turned 40 -> 0", near(b.handsYaw(0, 0, 40, 30, -10, -20, 30, 10, -20, -60), 0))
	local yw = b.bodyYawStep(nil, 30, nil, 0.1)
	check("bodyYawStep: first = head", near(yw, 30))
	yw = b.bodyYawStep(0, 40, 0, 1.0)
	check("bodyYawStep: look right, hands forward -> stays", near(yw, 0))
	yw = b.bodyYawStep(0, 40, 60, 0.1)
	check("bodyYawStep: hands turned 60 -> moves 12 (rate 120/s)", near(yw, 12))
	yw = b.bodyYawStep(0, 40, 60, 10)
	check("bodyYawStep: catches the hands up to the dead zone", near(yw, 45))
	yw = b.bodyYawStep(0, 100, nil, 0.0)
	check("bodyYawStep: neck limit pushes past 65", near(yw, 35))
	yw = b.bodyYawStep(0, 20, nil, 1.0)
	check("bodyYawStep: slow drift to the head without hands", near(yw, b.BODY.DRIFT))
	yw = b.bodyYawStep(170, -170, -170, 10)
	check("bodyYawStep: across the seam (15 short of the hands)", near(yw, 175))
	check("ownGlove: right hand vs right heal", b.ownGlove({ sh = 1, glove = true }, 2) == true)
	check("ownGlove: belt card / no hand", b.ownGlove({}, 1) == false and b.ownGlove({ sh = 1 }, nil) == false)
	local gs = { { on = true, x = 0, y = 0, z = 0, sh = -1, glove = true }, { on = true, x = 30, y = 0, z = 0 } }
	check("nearestSlot: left hand skips its own glove heal", b.nearestSlot(gs, 2, 0, 0, 0, 10) == 1 and b.nearestSlot(gs, 2, 0, 0, 0, 10, nil, 1) == nil)
	check("nearestSlot: right hand takes the left glove heal", b.nearestSlot(gs, 2, 0, 0, 0, 10, nil, 2) == 1)
	local bt, bh = b.targetSlot(gs, 2, { { X = 0, Y = 0, Z = 0 }, { X = 29, Y = 0, Z = 0 } }, 10, nil)
	check("targetSlot: own glove heal ignored, other hand's card wins", bt == 2 and bh == 2)
	local cfg = { belt_drop = 55, belt_drop_seated = 33, seated_play = false }
	local get = function(k) return cfg[k] end
	check("beltDrop: standing", near(b.beltDrop(get), 55))
	cfg.seated_play = true
	check("beltDrop: seated", near(b.beltDrop(get), 33))
	cfg.belt_drop_seated = nil
	check("beltDrop: seated default", near(b.beltDrop(get), 35))
	-- step 120: body frame delta + can't-use hint
	check("yawDelta plain", near(b.yawDelta(30, 10), 20))
	check("yawDelta wraps", near(b.yawDelta(-170, 170), 20) and near(b.yawDelta(170, -170), -20))
	check("yawDelta 180", near(b.yawDelta(180, 0), 180))
	check("usable: healer at full HP = no", b.usableNow(true, 100, 100, false, nil) == false)
	check("usable: healer hurt = yes", b.usableNow(true, 60, 100, false, nil) == true)
	check("usable: healer, max unknown = yes", b.usableNow(true, 100, nil, false, nil) == true)
	check("usable: global off = no", b.usableNow(false, 10, 100, true, nil) == false)
	check("usable: own check false = no", b.usableNow(false, 10, 100, false, false) == false)
	check("usable: other item at full HP = yes", b.usableNow(false, 100, 100, false, nil) == true)
	check("canUseFn match", select(2, b.canUseFn("abc_tp_x", {{"_tp_", "fn", "CanTp"}})) == "CanTp" and b.canUseFn("abc", {{"_tp_", "fn", "CanTp"}}) == nil)
	check("canUseFn nil key", b.canUseFn(nil, {{"a", "fn", "F"}}) == nil)
	check("canUseFn real table: cure potion vs poison cure", select(2, b.canUseFn("item_cure_potion")) == "CanUsePanacea" and select(2, b.canUseFn("item_cure_poison")) == "PoisonStatusEffect")
	check("canUseFn real table: infinite teleport", select(2, b.canUseFn("item_inf_returngem")) == "CanUseTeleportItem" and b.canUseFn("item_heal_herb") == nil)
	check("canUseFn real table: buff kind", b.canUseFn("item_iron_potion") == "busy" and b.canUseFn("item_ratpod") == nil)
	check("checkFlag need/busy/fn", b.checkFlag("need", false) == false and b.checkFlag("busy", true) == false and b.checkFlag("busy", false) == true and b.checkFlag("fn", true) == true and b.checkFlag(nil, true) == nil)
	local u, a = b.mouthUse(10, false, 17)
	check("grabbed next to the mouth: no use yet", u == false and a == false)
	u, a = b.mouthUse(20, a, 17)
	check("left the mouth zone: armed", u == false and a == true)
	u, a = b.mouthUse(10, a, 17)
	check("back at the mouth: used", u == true)
	u = b.mouthUse(16.9, true, 17)
	check("belt grab path unchanged", u == true)
	check("shoulder reach small", b.SH_REACH_CM < b.REACH_HEAL_CM)
end
print(string.format("qd_belt: %d passed, %d failed", passed, failed))
return failed
