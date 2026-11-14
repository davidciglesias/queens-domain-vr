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
print(string.format("qd_shoulder: %d passed, %d failed", passed, failed))
return failed
