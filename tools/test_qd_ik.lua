-- Unit tests for libs/qd_ik.lua (pure math). Run: python tools/run_tests.py
local k = require("qd_ik")

local failed, passed = 0, 0
local function check(name, cond)
	if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end
local function near(a, c, eps) return math.abs(a - c) <= (eps or 1e-6) end

do -- shoulder yaw: free inside the dead zone, catches up at a limited rate outside it, wraps at +-180
	check("first sample snaps", near(k.followYaw(nil, 30, 40, 240, 0.01), 30))
	check("inside dead zone", near(k.followYaw(0, 39, 40, 240, 0.1), 0))
	check("rate limited", near(k.followYaw(0, 90, 40, 240, 0.1), 24))
	check("stops at the edge", near(k.followYaw(0, 50, 40, 240, 1.0), 10))
	check("negative side", near(k.followYaw(0, -60, 40, 240, 1.0), -20))
	check("wraps", near(k.followYaw(170, -170, 10, 1000, 1.0), -180) or near(k.followYaw(170, -170, 10, 1000, 1.0), 180))
	check("drift inside the dead zone", near(k.followYaw(0, 30, 40, 240, 0.5, 20), 10))
	check("drift stops under the head", near(k.followYaw(0, 5, 40, 240, 1.0, 20), 5))
	check("drift negative", near(k.followYaw(0, -30, 40, 240, 0.5, 20), -10))
	check("a hair outside the dead zone still drifts", near(k.followYaw(0, 40.01, 40, 240, 0.5, 20), 10))
	check("normDeg", near(k.normDeg(270), -90) and near(k.normDeg(-190), 170))
end

do -- state machine
	check("off, nothing", k.decide(false, true, false, false) == nil)
	check("off, rig -> destroy", k.decide(false, true, true, false) == "destroy")
	check("on, play -> create", k.decide(true, true, false, false) == "create")
	check("on, menu, no rig", k.decide(true, false, false, false) == nil)
	check("on, play, rig -> place", k.decide(true, true, true, false) == "place")
	check("on, menu, rig -> hide", k.decide(true, false, true, false) == "hide")
	check("on, menu, hidden", k.decide(true, false, true, true) == nil)
	check("on, play, hidden -> show", k.decide(true, true, true, true) == "show")
end

do -- mesh origin: shoulder midpoint ends up behind/below the eyes whatever the yaw
	local function mid(ex, ey, ez, yaw, mx, my, mz, sc, back, drop, off)
		local x, y, z, myaw = k.meshOrigin(ex, ey, ez, yaw, mx, my, mz, sc, back, drop, off)
		local a = math.rad(myaw)
		return x + (math.cos(a) * mx - math.sin(a) * my) * sc, y + (math.sin(a) * mx + math.cos(a) * my) * sc, z + mz * sc, myaw
	end
	local x, y, z, myaw = mid(100, 200, 300, 0, 3, -7, -15, 1.2, 9, 21, -90)
	check("yaw 0", near(x, 91) and near(y, 200) and near(z, 279) and near(myaw, -90))
	x, y, z, myaw = mid(100, 200, 300, 90, 3, -7, -15, 1.2, 9, 21, -90)
	check("yaw 90", near(x, 100) and near(y, 191) and near(z, 279) and near(myaw, 0))
	x, y, z = k.meshOrigin(0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0)
	check("identity", near(x, 0) and near(y, 0) and near(z, 0))
end

do -- reach: a hand beyond the arm length pulls the shoulder exactly far enough; the pull is capped
	local dx, dy, dz = k.reachShift(0, 0, 0, 50, 0, 0, 60)
	check("in reach", near(dx, 0) and near(dy, 0) and near(dz, 0))
	dx, dy, dz = k.reachShift(0, 0, 0, 80, 0, 0, 60)
	check("pull forward", near(dx, 20) and near(dy, 0) and near(dz, 0))
	dx, dy, dz = k.reachShift(10, 10, 10, 10, 10, -90, 60)
	check("pull down", near(dx, 0) and near(dy, 0) and near(dz, -40))
	local x, y, z = k.clampLen(30, 40, 0, 25)
	check("clamp", near(x, 15) and near(y, 20) and near(z, 0))
	x, y, z = k.clampLen(3, 4, 0, 25)
	check("no clamp", near(x, 3) and near(y, 4))
	x, y, z = k.toWorld(100, 200, 300, 90, 10, 0, 5, 2)
	check("toWorld", near(x, 100) and near(y, 220) and near(z, 310))
end

print(string.format("qd_ik: %d passed, %d failed", passed, failed))
return failed
