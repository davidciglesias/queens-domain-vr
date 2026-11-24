-- Unit tests for libs/qd_throw.lua (pure helpers). Run: python tools/run_tests.py
local t = require("qd_throw")

local failed, passed = 0, 0
local function check(name, cond)
	if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end
local function near(a, c, eps) return math.abs(a - c) <= (eps or 1e-6) end

do -- merge distance follows the crosshair distance, clamped
	check("conv default", t.convDist(nil) == t.CONV_DEFAULT)
	check("conv min", t.convDist(50) == t.CONV_MIN)
	check("conv max", t.convDist(100000) == t.CONV_MAX)
	check("conv inside", t.convDist(700) == 700)
end

do -- share of the start offset left after some flight
	check("weight start", near(t.weight(0, 800), 1.0))
	check("weight half", near(t.weight(400, 800), 0.5))
	check("weight end", t.weight(800, 800) == 0.0)
	check("weight past", t.weight(5000, 800) == 0.0)
	check("weight negative travel", t.weight(-10, 800) == 1.0)
	check("weight bad input", t.weight(nil, 800) == 0.0 and t.weight(10, 0) == 0.0)
end

do -- a throw = new projectile + a charge spent since the grip press
	check("throw", t.isThrow(nil, 5, 4) == true)
	check("known projectile", t.isThrow(true, 5, 4) == false)
	check("no charge spent", t.isThrow(nil, 5, 5) == false)
	check("charge came back", t.isThrow(nil, 4, 5) == false)
	check("charges unknown", t.isThrow(nil, nil, 4) == false and t.isThrow(nil, 5, nil) == false)
end

-- step 79c: left-hand aim along the fingers
local function axes(P, Y, R) -- engine rotator -> forward, right, up (independent copy of the rotation matrix)
	local p, y, r = math.rad(P), math.rad(Y), math.rad(R)
	local SP, CP, SY, CY, SR, CR = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
	return { CP * CY, CP * SY, SP }, { SR * SP * CY - CR * SY, SR * SP * SY + CR * CY, -SR * CP },
		{ -(CR * SP * CY + SR * SY), CY * SR - CR * SP * SY, CR * CP }
end
local function angle(ax, ay, az, b)
	local d = ax * b[1] + ay * b[2] + az * b[3]
	if d > 1 then d = 1 elseif d < -1 then d = -1 end
	return math.deg(math.acos(d))
end

do -- option values
	local p, y = t.aimOffsets(nil, nil)
	check("offsets default", p == t.AIM_PITCH and y == t.AIM_YAW)
	p, y = t.aimOffsets(200, -200)
	check("offsets clamped", p == 90 and y == -90)
	p, y = t.aimOffsets(0, 0)
	check("offsets zero kept", p == 0 and y == 0)
	p, y = t.aimOffsets("x", 0 / 0)
	check("offsets bad input", p == t.AIM_PITCH and y == t.AIM_YAW)
end

do -- direction: no offset = the controller's forward axis, always unit length
	for _, r in ipairs({ { 0, 0, 0 }, { -14.8, -153.6, 34.4 }, { 60, 170, -120 }, { -80, 10, 5 } }) do
		local f = axes(r[1], r[2], r[3])
		local x, y, z = t.aimDir(r[1], r[2], r[3], 0, 0)
		check("dir zero offset = forward", angle(x, y, z, f) < 0.01)
		x, y, z = t.aimDir(r[1], r[2], r[3], 35, 7)
		check("dir unit length", near(x * x + y * y + z * z, 1.0, 1e-9))
		check("dir offset angle", near(angle(x, y, z, f), math.deg(math.acos(math.cos(math.rad(35)) * math.cos(math.rad(7)))), 0.01))
	end
	local x, y, z = t.aimDir(0, 0, 0, 90, 0)
	check("pitch goes to the back of the hand", near(x, 0, 1e-9) and near(y, t.AIM_UY, 1e-3) and near(z, t.AIM_UZ, 1e-3))
	x, y, z = t.aimDir(0, 0, 0, 0, 90)
	check("yaw goes to the thumb side", near(x, 0, 1e-9) and near(y, t.AIM_UZ, 1e-3) and near(z, -t.AIM_UY, 1e-3))
end

do -- the live measurement (Test 68a): defaults put the aim on the finger axis of the hand bone (its -Y)
	local _, boneRight = axes(40.5, -69.7, 19.8)
	local fingers = { -boneRight[1], -boneRight[2], -boneRight[3] }
	local x, y, z = t.aimDir(-14.8, -153.6, 34.4, 0, 0)
	check("measured: controller aim is 35 deg off the fingers", near(angle(x, y, z, fingers), 35.3, 0.3))
	x, y, z = t.aimDir(-14.8, -153.6, 34.4, t.AIM_PITCH, t.AIM_YAW)
	check("measured: default offsets are on the fingers", angle(x, y, z, fingers) < 1.0)
	x, y, z = t.aimDir(-14.8, -153.6, 34.4, 35, 0)
	check("measured: pitch alone is 6 deg to the side", near(angle(x, y, z, fingers), 6.1, 0.5))
end

do -- direction -> control rotation, with the game's view pitch limits
	local p, y = t.aimRot(1, 0, 0)
	check("rot forward", near(p, 0) and near(y, 0))
	p, y = t.aimRot(0, 1, 0)
	check("rot yaw 90", near(p, 0) and near(y, 90))
	p, y = t.aimRot(0, -1, 0)
	check("rot yaw -90", near(y, -90))
	local c = math.cos(math.rad(30))
	p, y = t.aimRot(c * math.cos(math.rad(120)), c * math.sin(math.rad(120)), math.sin(math.rad(30)))
	check("rot pitch 30 yaw 120", near(p, 30, 1e-6) and near(y, 120, 1e-6))
	local x, yy, z
	p, y, x, yy, z = t.aimRot(c * math.cos(math.rad(120)), c * math.sin(math.rad(120)), math.sin(math.rad(30)), -20, 20)
	check("rot pitch limited", near(p, 20) and near(y, 120, 1e-6))
	check("rot limited direction", near(z, math.sin(math.rad(20)), 1e-9) and near(x * x + yy * yy + z * z, 1.0, 1e-9)
		and near(math.deg(math.atan(yy, x)), 120, 1e-6))
	p, y, x, yy, z = t.aimRot(c, 0, -0.5, -89.9, 89.9)
	check("rot inside limits untouched", near(p, -30, 1e-6) and x == c and z == -0.5)
	p = t.aimRot(0, 0, 1.0000001)
	check("rot straight up", near(p, 90))
	p = t.aimRot(c, 0, 0.5, 20, -20)
	check("rot bad limits ignored", near(p, 30, 1e-6))
end

do -- UEVR view rotation offset: pure yaw check and the turn that keeps the view still
	check("pure yaw identity", t.pureYaw(0, 0, 0, 1) == true)
	check("pure yaw turn", t.pureYaw(0, math.sin(0.7), 0, math.cos(0.7)) == true)
	check("pure yaw: tilted", t.pureYaw(math.sin(0.3), 0, 0, math.cos(0.3)) == false)
	check("pure yaw: swapped fields", t.pureYaw(1, 0, 0, 0) == false)
	check("pure yaw: zero", t.pureYaw(0, 0, 0, 0) == false)
	check("pure yaw: missing", t.pureYaw(nil, 0, 0, 1) == false)
	local x, y, z, w = t.offsetTurn(0, 0, 0, 1, 90)
	check("turn 90 from identity", near(x, 0) and near(z, 0) and near(y, math.sin(math.rad(45)), 1e-9) and near(w, math.cos(math.rad(45)), 1e-9))
	local x2, y2, z2, w2 = t.offsetTurn(x, y, z, w, -90)
	check("turn back", near(x2, 0) and near(y2, 0, 1e-9) and near(z2, 0) and near(w2, 1, 1e-9))
	-- the view's world yaw is (offset angle - control yaw): it must not change whatever the control yaw does
	local function ang(qy, qw) return math.deg(2 * math.atan(qy, qw)) end
	local function same(a, b) local d = (a - b) % 360 return d < 1e-6 or d > 360 - 1e-6 end
	local qx, qy, qz, qw, yawNow = 0, math.sin(math.rad(20)), 0, math.cos(math.rad(20)), 10.0
	local world = ang(qy, qw) - yawNow
	local ok = true
	for _, newYaw in ipairs({ 50, -170, 175, -179, 3, 359, 0.5 }) do
		qx, qy, qz, qw = t.offsetTurn(qx, qy, qz, qw, newYaw - yawNow)
		yawNow = newYaw
		ok = ok and same(ang(qy, qw) - yawNow, world) and t.pureYaw(qx, qy, qz, qw)
	end
	check("view yaw unchanged by control yaw changes", ok)
	-- same result as UEVR's own controller aim: control yaw = old yaw - old offset angle - aim angle, offset = -aim angle
	local th0, psi0, aim = 37.0, -120.0, 64.0
	local psi1 = psi0 - th0 - aim
	x, y, z, w = t.offsetTurn(0, math.sin(math.rad(th0 / 2)), 0, math.cos(math.rad(th0 / 2)), psi1 - psi0)
	check("matches UEVR controller aim", same(ang(y, w), -aim))
	x, y, z, w = t.offsetTurn(0, 0, 0, 0, 30)
	check("zero quaternion returned as is", x == 0 and y == 0 and z == 0 and w == 0)
end

print(string.format("qd_throw: %d passed, %d failed", passed, failed))
return failed
