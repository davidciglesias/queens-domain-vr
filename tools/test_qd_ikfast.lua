-- Unit tests for libs/qd_ikfast.lua (s115 fast copies of the IK lib's per-frame solve math). Run: python tools/run_tests.py
local K = require("qd_ikfast")
local F = require("qd_fastmath")

local failed, passed = 0, 0
local function check(name, cond)
	if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end
local seed = 4242
local function rnd(lo, hi) seed = (seed * 1103515245 + 12345) % 2147483648 return lo + (hi - lo) * seed / 2147483648 end
local function unit() return K.norm(rnd(-1, 1), rnd(-1, 1), rnd(-1, 1) + 0.01) end
local function rotV(p, y, r, x, yy, z) local qx, qy, qz, qw = F.quatFromRot(p, y, r) return F.rotateVec(qx, qy, qz, qw, x, yy, z) end
local function dot(ax, ay, az, bx, by, bz) return ax * bx + ay * by + az * bz end

do -- rotFromAxisAngle = the rotation about the axis (engine FQuat::Rotator convention)
	local worst = 0
	for _ = 1, 50 do
		local ax, ay, az = unit()
		local ang = rnd(-170, 170)
		local p, y, r = K.rotFromAxisAngle(ax, ay, az, ang)
		local qx, qy, qz, qw = F.quatFromRot(p, y, r)
		local h = math.rad(ang) / 2
		local s = math.sin(h)
		local d = math.abs(qx * ax * s + qy * ay * s + qz * az * s + qw * math.cos(h)) -- |<q, q_axis>| = 1 when equal (+-q)
		worst = math.max(worst, 1 - d)
	end
	check("rotFromAxisAngle matches the axis-angle quaternion (" .. string.format("%.1e", worst) .. ")", worst < 1e-6)
	local p, y, r = K.rotFromAxisAngle(0, 0, 0, 30)
	check("rotFromAxisAngle zero axis -> zero rotator", p == 0 and y == 0 and r == 0)
end

do -- align: the bone's local direction lands on the desired direction, and its pole axis on the desired pole
	local okDir, okPole, okOrd, n = true, true, true, 0
	local axisChoice = {axis = "X", sign = 1, pole = {axis = "Y", sign = 1}}
	for _ = 1, 60 do
		local cp, cy, cr = rnd(-80, 80), rnd(-180, 180), rnd(-180, 180)
		local cdx, cdy, cdz = F.rotAxis(cp, cy, cr, "X") -- bone points along its X
		local dx, dy, dz = unit()
		local px, py, pz = unit()
		local ch, p, y, r, oSw, oTw = K.align(cp, cy, cr, cdx, cdy, cdz, dx, dy, dz, px, py, pz, axisChoice, nil, nil, 0.0)
		if ch then
			n = n + 1
			local nx, ny, nz = F.rotAxis(p, y, r, "X")
			if dot(nx, ny, nz, dx, dy, dz) < 1 - 1e-6 then okDir = false end
			local ex, ey, ez = F.projectOnPlane(px, py, pz, dx, dy, dz)
			local el = math.sqrt(dot(ex, ey, ez, ex, ey, ez))
			ex, ey, ez = K.norm(ex, ey, ez)
			local ax, ay, az = F.rotAxis(p, y, r, "Y")
			local ux, uy, uz = K.norm(F.projectOnPlane(ax, ay, az, dx, dy, dz))
			if el >= 0.15 and dot(ux, uy, uz, ex, ey, ez) < 1 - 1e-5 then okPole = false end
			if (oSw ~= 1 and oSw ~= 2) or (oTw ~= nil and oTw ~= 1 and oTw ~= 2) then okOrd = false end
			-- cached orders reproduce the same result
			local ch2, p2, y2, r2 = K.align(cp, cy, cr, cdx, cdy, cdz, dx, dy, dz, px, py, pz, axisChoice, oSw, oTw, 0.0)
			if not ch2 or not (near(p, p2, 1e-9) and near(y, y2, 1e-9) and near(r, r2, 1e-9)) then okOrd = false end
		end
	end
	check("align: bone direction reaches the target (" .. n .. " cases)", okDir and n > 40)
	check("align: pole axis turned onto the target pole", okPole)
	check("align: compose orders cached and reused", okOrd)
	local ch = K.align(0, 0, 0, 1, 0, 0, 1, 0.0001, 0, 0, 1, 0, axisChoice, nil, nil, 0.0)
	check("align: swing under IK_MIN_SWING keeps the current rotator", ch == false)
	ch = K.align(0, 0, 0, 1, 0, 0, 0.9, 0.1, 0, 0, 1, 0, axisChoice, nil, nil, 10.0)
	check("align: scope deadband swallows a small swing", ch == false)
	ch = K.align(0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, axisChoice, nil, nil, 0.0)
	check("align: zero current dir keeps the current rotator", ch == false)
end

do -- outward: perpendicular to the reach, in the anchor's hemisphere, smoothed towards the previous pole
	local ok, okS = true, true
	for _ = 1, 40 do
		local p, y, r = rnd(-30, 30), rnd(-180, 180), rnd(-30, 30)
		local rx, ry, rz = F.rotAxis(p, y, r, "Y")
		local fx, fy, fz = F.rotAxis(p, y, r, "X")
		local ux, uy, uz = F.rotAxis(p, y, r, "Z")
		local anchor = {right = 0.3, fwd = -0.2, up = -0.9}
		local wx, wy, wz = unit()
		local ox, oy, oz = K.outward(rx, ry, rz, fx, fy, fz, ux, uy, uz, anchor, nil, nil, nil, wx, wy, wz, nil, nil, nil, false)
		local apx, apy, apz = rx * 0.3 + fx * -0.2 + ux * -0.9, ry * 0.3 + fy * -0.2 + uy * -0.9, rz * 0.3 + fz * -0.2 + uz * -0.9
		if math.abs(dot(ox, oy, oz, wx, wy, wz)) > 1e-9 or dot(ox, oy, oz, apx, apy, apz) < 0 or not near(dot(ox, oy, oz, ox, oy, oz), 1, 1e-9) then ok = false end
		local sx, sy, sz = K.outward(rx, ry, rz, fx, fy, fz, ux, uy, uz, anchor, ox, oy, oz, wx, wy, wz, ox, oy, oz, false)
		if not (near(sx, ox, 1e-9) and near(sy, oy, 1e-9) and near(sz, oz, 1e-9)) then okS = false end
	end
	check("outward: unit, perpendicular to reach, anchor side", ok)
	check("outward: steady input stays put through the smoothing", okS)
	local ox, oy, oz = K.outward(0, 1, 0, 1, 0, 0, 0, 0, 1, {right = 0, fwd = 1, up = 0}, nil, nil, nil, 1, 0, 0, nil, nil, nil, true)
	check("outward: anchor along the reach falls back to -right on the left", ox == 0 and oy == -1 and oz == 0)
end

do -- twist: B = A turned about the axis by t -> t
	local ok = true
	for _ = 1, 40 do
		local ap, ay, ar = rnd(-80, 80), rnd(-180, 180), rnd(-180, 180)
		local kx, ky, kz = unit()
		local t = rnd(-170, 170)
		local tp, ty, tr = K.rotFromAxisAngle(kx, ky, kz, t)
		local bp, by, br = F.composeRot(ap, ay, ar, tp, ty, tr) -- A then the axis turn (component space)
		local d = (K.twistDeg(ap, ay, ar, bp, by, br, kx, ky, kz) - t + 540.0) % 360.0 - 180.0 -- quat sign: +-360 (lib alike)
		if not near(d, 0, 1e-3) then ok = false end -- FastAsin (engine) ~1e-4 deg
	end
	check("twistDeg recovers the turn about the axis", ok)
	check("twistDeg bad axis -> nil", K.twistDeg(0, 0, 0, 0, 0, 0, 0, 0, 0) == nil)
end

do -- twist bone rotation: zero turn rebuilds the lower arm rotation from its own axes
	local ok = true
	for _ = 1, 20 do
		local p, y, r = rnd(-80, 80), rnd(-180, 180), rnd(-180, 180)
		local qx, qy, qz, qw = F.quatFromRot(p, y, r)
		local bp, by, br = K.twistBoneRot(qx, qy, qz, qw, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0)
		for _, a in ipairs({"X", "Y", "Z"}) do
			local x1, y1, z1 = F.rotAxis(p, y, r, a)
			local x2, y2, z2 = F.rotAxis(bp, by, br, a)
			if dot(x1, y1, z1, x2, y2, z2) < 1 - 1e-9 then ok = false end
		end
		-- a turn about the bone's own X keeps X and turns Z by the angle
		local ax, ay, az = F.rotAxis(p, y, r, "X")
		local tp, ty, tr = K.twistBoneRot(qx, qy, qz, qw, 1, 0, 0, 0, 0, 1, ax, ay, az, 40)
		local zx, zy, zz = F.rotAxis(p, y, r, "Z")
		local z2x, z2y, z2z = F.rotAxis(tp, ty, tr, "Z")
		if not near(dot(zx, zy, zz, z2x, z2y, z2z), math.cos(math.rad(40)), 1e-9) then ok = false end
	end
	check("twistBoneRot rebuilds / turns about the forearm", ok)
end

print(string.format("qd_ikfast: %d passed, %d failed", passed, failed))
return failed
