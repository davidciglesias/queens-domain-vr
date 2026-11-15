-- Unit tests for libs/qd_shoulder.lua. Run: python tools/run_tests.py
local m = require("qd_shoulder")
local failed, passed = 0, 0
local function check(name, cond) if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end end
local function near(a, c) return math.abs(a - c) <= 1e-6 end
local G, DP = 0x0200, 0x0008

do -- yaw 0: right = +Y, back = -X
	local x, y, z = m.shoulderPos(0, 0, 100, 0)
	check("shoulder yaw0", near(x, -m.BACK_CM) and near(y, m.SIDE_CM) and near(z, 100 - m.DROP_CM))
	x, y = m.shoulderPos(0, 0, 100, 90) -- facing +Y: right = -X
	check("shoulder yaw90", near(x, -m.SIDE_CM) and near(y, -m.BACK_CM))
end
do -- zone
	local sx, sy, sz = m.shoulderPos(0, 0, 100, 0)
	check("at shoulder", m.inZone(sx, sy, sz, 0, 0, 100, 0))
	check("left shoulder out", not m.inZone(sx, -sy, sz, 0, 0, 100, 0))
	check("hip out", not m.inZone(sx, sy, sz - 40, 0, 0, 100, 0))
end
do -- step
	local b, a = m.step(G, G, DP, true, false, false)
	check("fresh press in zone arms + swaps", a and b == DP)
	b, a = m.step(G, G, DP, false, true, true)
	check("held after leaving zone stays armed", a and b == DP)
	b, a = m.step(0, G, DP, false, true, true)
	check("release disarms", not a and b == 0)
	b, a = m.step(G, G, DP, true, true, false)
	check("grip held into zone does not arm", not a and b == G)
	b, a = m.step(G, G, DP, false, false, false)
	check("press out of zone passes", not a and b == G)
	b, a = m.step(G | 0x1000, G, DP, true, false, false)
	check("other buttons kept", a and b == (DP | 0x1000))
end
do -- step 32: left shoulder mirrors the right one
	local sx, sy, sz = m.shoulderPos(0, 0, 100, 0, -1)
	check("left shoulder yaw0", near(sx, -m.BACK_CM) and near(sy, -m.SIDE_CM) and near(sz, 100 - m.DROP_CM))
	check("left zone", m.inZone(sx, sy, sz, 0, 0, 100, 0, -1) and not m.inZone(sx, -sy, sz, 0, 0, 100, 0, -1))
	local b, a2 = m.step(0x0100, 0x0100, m.PREV_BIT, true, false, false)
	check("left grip arms prev, grip swallowed", a2 and b == 0)
end
do -- step 38: region "past the shoulder" (head at 0,0,100 facing +X; right = +Y)
	check("behind right shoulder", m.inZone(-15, 20, 95, 0, 0, 100, 0, 1))
	check("over right shoulder, above head", m.inZone(-5, 15, 125, 0, 0, 100, 0, 1))
	check("arm out to the right, a bit forward", m.inZone(20, 45, 80, 0, 0, 100, 0, 1))
	check("hand in front of chest out", not m.inZone(30, 15, 80, 0, 0, 100, 0, 1))
	check("hand at the belt out", not m.inZone(0, 25, 55, 0, 0, 100, 0, 1))
	check("centre behind head out", not m.inZone(-15, 5, 100, 0, 0, 100, 0, 1))
	check("left hand past left shoulder", m.inZone(-10, -25, 90, 0, 0, 100, 0, -1))
	check("right hand reached across to left shoulder", m.inZone(-5, -15, 85, 0, 0, 100, 0, -1))
	check("right hand at right shoulder not in left zone", not m.inZone(-10, 20, 90, 0, 0, 100, 0, -1))
	check("left zone ignores the right side", not m.inZone(-10, 25, 90, 0, 0, 100, 0, -1))
	check("yaw 90: right = -X", m.inZone(-25, -10, 95, 0, 0, 100, 90, 1) and not m.inZone(25, -10, 95, 0, 0, 100, 90, 1))
end
print(string.format("qd_shoulder: %d passed, %d failed", passed, failed))
return failed
