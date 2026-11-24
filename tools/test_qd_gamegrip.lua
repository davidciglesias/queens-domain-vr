-- tests for libs/qd_gamegrip.lua pure helpers (step 126)
local g = require("qd_gamegrip")
local passed, failed = 0, 0
local function check(name, ok) if ok then passed = passed + 1 else failed = failed + 1 print("FAIL: " .. name) end end

local a = { A = { 0, 0, 0 }, B = { 10, -20, 170 } }
local b = { A = { 3, 0, 0 }, B = { 10, -20, -175 } }
check("maxDiff wraps the seam", math.abs(g.maxDiff(a, b) - 15) < 1e-9)
check("maxDiff ignores missing bones", g.maxDiff({ A = { 0, 0, 0 } }, { C = { 90, 0, 0 } }) == 0)
local c = g.copyPose(a)
c.A[1] = 99
check("copyPose is deep", a.A[1] == 0)
local dst = { A = { 1, 1, 1 }, B = { 2, 2, 2 } }
local keep = dst.A
local n = g.copyInto(dst, { A = { 5, 6, 7 }, Z = { 0, 0, 0 } })
check("copyInto: only existing bones, in place", n == 1 and dst.A == keep and dst.A[2] == 6 and dst.B[1] == 2 and dst.Z == nil)
check("tick without init is a no-op", pcall(g.tick, 0.1, true))

print(string.format("qd_gamegrip: %d passed, %d failed", passed, failed))
return failed
