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

do -- s103: late solve gate, twist bone discovery, probe math
	check("late: nothing pending", not k.lateAccept(false, 1, 1))
	check("late: wanted view", k.lateAccept(true, 1, 1))
	check("late: other view", not k.lateAccept(true, 0, 1))
	check("late: any view", k.lateAccept(true, 0, -1) and k.lateAccept(true, 3, nil))
	local names = {"Root", "UpperArm_L", "LowerArm_L", "LowerArmTwist_L", "Hand_L", "UpperArmTwist_L", "lowerarm_twist_01_r", "ForeTwist_R", "Twist_L"}
	local l, r = k.pickTwist(names, "L"), k.pickTwist(names, "r")
	check("twist left", #l == 1 and l[1] == "LowerArmTwist_L")
	check("twist right", #r == 2 and r[1] == "lowerarm_twist_01_r" and r[2] == "ForeTwist_R")
	check("twist none", #k.pickTwist({"Hand_L", "LowerArm_L"}, "L") == 0 and #k.pickTwist(nil, "L") == 0)
	check("angle 90", near(k.angleDeg(1, 0, 0, 0, 2, 0), 90))
	check("angle 0 / degenerate", near(k.angleDeg(1, 1, 0, 2, 2, 0), 0, 1e-4) and near(k.angleDeg(0, 0, 0, 1, 0, 0), 0))
	-- left shoulder at y=-20 (midline y=0), hand straight ahead; elbow 10 below and 5 outward of the line
	local drop, out = k.elbowPlace(0, -20, 0, 20, -25, -10, 40, -20, 0, 0, 0)
	check("elbow down/out", near(drop, 10) and near(out, 5))
	drop, out = k.elbowPlace(0, 20, 0, 20, 15, 5, 40, 20, 0, 0, 0)
	check("elbow up/in (right)", near(drop, -5) and near(out, -5))
end

do -- s105b hide list: whole hand (old) or the finger roots only
	local h = k.hideList("L", true, k.FINGER_ROOTS)
	check("old: hand only", #h == 1 and h[1] == "Hand_L")
	local f = k.hideList("R", false, k.FINGER_ROOTS)
	check("new: 5 finger roots", #f == 5 and f[1] == "Finger_Index_0_R" and f[5] == "Thumb_0_R")
	check("new: no hand", (function() for _, b in ipairs(f) do if b == "Hand_R" then return false end end return true end)())
	check("default keeps the hand", k.HIDE_HAND == false)
	check("no roots -> empty", #k.hideList("L", false, nil) == 0)
end

do -- s111 forearm twist: relative to the rest twist, continuous across +-180, held (never snapped) at the limit
	check("unwrapNear", near(k.unwrapNear(-170, 170), 190) and near(k.unwrapNear(10, nil), 10) and near(k.unwrapNear(350, 0), -10))
	local a, acc = k.twistStep(157, 157, nil, 150, 270)
	check("rest -> 0", near(a, 0) and near(acc, 0))
	a = k.twistStep(-205.8, 154.2, nil, 150, 270)
	check("rest offset mod 360", near(a, 0, 1e-9))
	-- sweep the hand roll -200..200 from a rest of 155: applied must follow without jumps and hold at +-150
	local prev, prevA, maxJump, rest = nil, nil, 0, 155
	for roll = -170, 200, 10 do
		local raw = k.normDeg(rest + roll) -- what the lib measures (wrapped)
		local ap
		ap, prev = k.twistStep(raw, rest, prev, 150, 270)
		if prevA ~= nil then maxJump = math.max(maxJump, math.abs(ap - prevA)) end
		prevA = ap
		if roll == 120 then check("follows past the old 100 clamp", near(ap, 120)) end
		if roll == 180 then check("held at the limit", near(ap, 150)) end
	end
	check("no jump in the sweep", maxJump <= 10 + 1e-9)
	check("unwrapped value kept", near(prev, 200))
	-- back the other way: comes back down continuously
	local ap2 = k.twistStep(k.normDeg(rest + 90), rest, prev, 150, 270)
	check("returns from the limit", near(ap2, 90))
	-- full spins re-wrap only past wrapAt
	local _, accW = k.twistStep(k.normDeg(rest + 280), rest, 265, 150, 270)
	check("re-wrap past 270", near(accW, -80))
	local apN = k.twistStep(k.normDeg(rest - 120), rest, nil, 150, 270)
	check("negative side", near(apN, -120))
end

do -- s111 elbow pole from the hand's forearm direction
	-- shoulder at origin, reach along +X (hand at 50,0,0), forearm direction from the hand goes back and down (-X,-Z)
	local s2 = math.sqrt(0.5)
	local px, py, pz = k.handPole(0, 0, 0, 1, 0, 0, 50, 0, 0, -s2, 0, -s2, 25, 0, 1, 0, 1.0, 0.15)
	check("full follow -> elbow down", near(px, 0) and near(py, 0) and near(pz, -1))
	px, py, pz = k.handPole(0, 0, 0, 1, 0, 0, 50, 0, 0, -s2, 0, -s2, 25, 0, 1, 0, 0.0, 0.15)
	check("w 0 -> body pole", near(px, 0) and near(py, 1) and near(pz, 0))
	px, py, pz = k.handPole(0, 0, 0, 1, 0, 0, 50, 0, 0, -s2, 0, -s2, 25, 0, 1, 0, 0.5, 0.15)
	check("half follow -> between, unit, perpendicular", near(px, 0) and near(py, s2, 1e-6) and near(pz, -s2, 1e-6))
	px, py, pz = k.handPole(0, 0, 0, 1, 0, 0, 50, 0, 0, -1, 0, 0, 25, 0, 1, 0, 1.0, 0.15)
	check("forearm along the reach (degenerate) -> body pole", near(px, 0) and near(py, 1) and near(pz, 0))
	px, py, pz = k.handPole(0, 0, 0, 1, 0, 0, 50, 0, 0, s2, 0, -s2, 25, 0, -1, 0, 1.0, 0.15)
	check("result perpendicular to the reach", near(px, 0) and near(math.sqrt(px * px + py * py + pz * pz), 1))
	-- opposite poles at w 0.5 cancel -> hand pole wins (no zero vector)
	px, py, pz = k.handPole(0, 0, 0, 1, 0, 0, 50, 0, 0, -s2, 0, -s2, 25, 0, 0, 1, 0.5, 0.15)
	check("cancel -> hand pole", near(pz, -1))
	-- limited to maxDeg from the body pole: hand pole straight down, body pole sideways (+Y), limit 60
	px, py, pz = k.handPole(0, 0, 0, 1, 0, 0, 50, 0, 0, -s2, 0, -s2, 25, 0, 1, 0, 1.0, 0.15, 60)
	check("limited to 60 deg", near(px, 0) and near(py, 0.5, 1e-6) and near(pz, -math.sqrt(0.75), 1e-6))
	px, py, pz = k.handPole(0, 0, 0, 1, 0, 0, 50, 0, 0, -s2, 0, -s2, 25, 0, 0, 1, 1.0, 0.15, 60)
	check("opposite hand pole -> body pole", near(px, 0) and near(py, 0) and near(pz, 1))
	px, py, pz = k.handPole(0, 0, 0, 1, 0, 0, 50, 0, 0, -s2, 0, -s2, 25, 0, s2, -s2, 1.0, 0.15, 60)
	check("inside the limit untouched", near(pz, -1))
end

check("bodyYaw nil without a rig (step 120)", k.bodyYaw() == nil)

print(string.format("qd_ik: %d passed, %d failed", passed, failed))
return failed
