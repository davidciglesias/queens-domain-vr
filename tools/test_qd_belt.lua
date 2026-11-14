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

print(string.format("qd_belt: %d passed, %d failed", passed, failed))
return failed
