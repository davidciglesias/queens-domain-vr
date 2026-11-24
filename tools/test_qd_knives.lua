-- Unit tests for libs/qd_knives.lua. Run: python tools/run_tests.py
local m = require("qd_knives")
local failed, passed = 0, 0
local function check(name, cond) if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end end

do -- visible count
	check("nil -> 0", m.visibleCount(nil) == 0)
	check("neg -> 0", m.visibleCount(-2) == 0)
	check("2 -> 2", m.visibleCount(2) == 2)
	check("cap = MAX", m.visibleCount(9) == m.MAX and m.MAX == 7)
	check("finger cap 5", m.FINGER_MAX == 5 and m.visibleCount(9, m.FINGER_MAX) == 5)
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

do -- step 75: forearm row
	check("arm row centred", m.armLateral(3, 5, 1.8) == 0 and m.armLateral(1, 5, 1.8) == 3.6 and m.armLateral(5, 5, 1.8) == -3.6)
	check("row count = max charges", m.rowCount(2) == 2 and m.rowCount(0) == m.MAX and m.rowCount(nil) == m.MAX and m.rowCount(6) == 6 and m.rowCount(7) == 7 and m.rowCount(9) == m.MAX and m.rowCount(5) == 5)
	check("2-knife row centred", m.armLateral(1, 2, 2) == 1 and m.armLateral(2, 2, 2) == -1)
	local t = m.readTuning(function() return nil end, {})
	check("arm layout default on", t.fa == 1 and t.agap == m.DEFAULTS.agap)
	t = m.readTuning(function(id) if id == "knife_forearm" then return false end end, {})
	check("arm layout off", t.fa == 0)
end
do -- step 114: edge-gap row
	local function near(a, b) return math.abs(a - b) < 1e-6 end
	local ax, ay, az = m.rotXRow(0, 0, 0)
	check("rotXRow identity", near(ax, 1) and near(ay, 0) and near(az, 0))
	ax, ay, az = m.rotXRow(0, 90, 0)
	check("rotXRow yaw 90 -> local Y on -X", near(ax, 0) and near(ay, -1) and near(az, 0))
	local b = m.partBox({ 0, 0, 0 }, { 2, 1, 1 }, { 0, 0, 0 }, { 0, 0, 0 }, { 1, 1, 1 })
	check("partBox identity", near(b[1], 0) and near(b[4], 2) and near(b[5], 1))
	b = m.partBox({ 1, 0, 0 }, { 2, 1, 3 }, { 10, 0, 0 }, { 0, 90, 0 }, { 2, 2, 2 })
	check("partBox yaw 90 scale 2", near(b[1], 10) and near(b[2], 2) and near(b[4], 2) and near(b[5], 4) and near(b[6], 6))
	local lo, hi = m.spanX({ { 0, 0, 0, 2, 1, 1 }, { 3, 0, 0, 0.5, 0.5, 0.5 } }, 0, 0, 0)
	check("spanX two boxes", near(lo, -2) and near(hi, 3.5))
	check("spanX none", m.spanX(nil, 0, 0, 0) == nil and m.spanX({}, 0, 0, 0) == nil)
	lo, hi = m.spanX({ { 0, 0, 0, 2, 1, 1 } }, 0, 90, 0)
	check("spanX turned uses the other extent", near(lo, -1) and near(hi, 1))
	-- width 4 (lo -2, hi 2), gap 1 -> centres 5 apart; 3-row centred
	check("rowLateral edge gap", near(m.rowLateral(1, 3, -2, 2, 1, 1.4), 5) and near(m.rowLateral(2, 3, -2, 2, 1, 1.4), 0) and near(m.rowLateral(3, 3, -2, 2, 1, 1.4), -5))
	-- off-centre model (lo 0, hi 4): origin shifted so the model centre lands on the slot
	check("rowLateral off-centre model", near(m.rowLateral(1, 1, 0, 4, 1, 1.4), -2))
	check("rowLateral unknown -> centre spacing", near(m.rowLateral(1, 2, nil, nil, 1, 2), 1))
	check("rowFit fits", m.rowFit(3, 3, 0.3, 16) == 1.0)
	local k = m.rowFit(2, 16.4, 0.3, 16) -- widest test throwable: 2 x 16.4 cm
	check("rowFit shrinks to the max", math.abs(2 * 16.4 * k + 0.3 - 16) < 1e-6)
	check("rowFit floor + bad input", m.rowFit(5, 100, 0.3, 6) == 0.2 and m.rowFit(nil, 3, 0, 10) == 1.0 and m.rowFit(2, 0, 0, 10) == 1.0)
	local t = m.readTuning(function(id) if id == "knife_edge_gap" then return 0.5 end end, {})
	check("edge gap read + default", t.eg == 0.5 and m.readTuning(function() return nil end, {}).eg == m.DEFAULTS.eg)
end
print(string.format("qd_knives: %d passed, %d failed", passed, failed))
return failed
