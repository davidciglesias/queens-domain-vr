-- Unit tests for libs/qd_knives.lua. Run: python tools/run_tests.py
local m = require("qd_knives")
local failed, passed = 0, 0
local function check(name, cond) if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end end

do -- visible count
	check("nil -> 0", m.visibleCount(nil) == 0)
	check("neg -> 0", m.visibleCount(-2) == 0)
	check("2 -> 2", m.visibleCount(2) == 2)
	check("cap 5", m.visibleCount(9) == 5)
	check("cap custom", m.visibleCount(9, 3) == 3)
	check("float floors", m.visibleCount(2.7) == 2)
end
do -- bones
	check("index seg0", m.boneName(1, 0) == "Finger_Index_0_L")
	check("pinky seg2", m.boneName(4, 2) == "Finger_Pinky_2_L")
	check("seg clamp hi", m.boneName(2, 7) == "Finger_Middle_2_L")
	check("seg clamp lo", m.boneName(3, -1) == "Finger_Ring_0_L")
	check("seg nil", m.boneName(1, nil) == "Finger_Index_0_L")
	check("5th = index (thumb side)", m.boneName(5, 0) == "Finger_Index_0_L" and m.SIDE[5] == -1)
	check("i out of range", m.boneName(6, 0) == nil)
end
do -- tuning
	local vals = { knife_fx = 2.5, knife_fscale = 1.5, knife_fbone = 1, knife_fy = "bad" }
	local t = m.readTuning(function(id) return vals[id] end)
	check("x read", t.x == 2.5)
	check("scale read", t.scale == 1.5 and t.seg == 1)
	check("non-number -> default", t.y == m.DEFAULTS.y)
	check("missing -> default", t.roll == m.DEFAULTS.roll)
	local t2 = m.readTuning(function(id) return vals[id] end, {})
	check("same", m.sameTuning(t, t2))
	t2.pitch = 10
	check("differs", not m.sameTuning(t, t2))
	check("nil not same", not m.sameTuning(nil, t))
end
do -- gained
	check("first read no tick", not m.gained(nil, 3))
	check("rise ticks", m.gained(2, 3))
	check("drop no tick", not m.gained(3, 2))
	check("nil cur", not m.gained(3, nil))
end

print(string.format("qd_knives: %d passed, %d failed", passed, failed))
return failed
