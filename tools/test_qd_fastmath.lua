-- Unit tests for libs/qd_fastmath.lua (s115 pure-Lua engine math). Run: python tools/run_tests.py
local F = require("qd_fastmath")

local failed, passed = 0, 0
local function check(name, cond)
	if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end
local function axes(p, y, r)
	local a = {F.rotAxis(p, y, r, "X")}
	local b = {F.rotAxis(p, y, r, "Y")}
	local c = {F.rotAxis(p, y, r, "Z")}
	return {a, b, c}
end
local function sameAxes(A, B, eps)
	for i = 1, 3 do for k = 1, 3 do if not near(A[i][k], B[i][k], eps) then return false end end end
	return true
end

-- deterministic pseudo-random rotators (no math.random seeding differences)
local seed = 12345
local function rnd(lo, hi) seed = (seed * 1103515245 + 12345) % 2147483648 return lo + (hi - lo) * seed / 2147483648 end
local rots = {{0, 0, 0}, {30, 40, 50}, {-60, 170, -20}, {10, -100, 120}, {80, 20, -150}, {-89, 45, 10}, {0, 450, -400}}
for _ = 1, 40 do rots[#rots + 1] = {rnd(-88, 88), rnd(-400, 400), rnd(-400, 400)} end

do -- small helpers
	check("normalizeAxis 540 -> 180", near(F.normalizeAxis(540), 180))
	check("normalizeAxis -180 -> 180", near(F.normalizeAxis(-180), 180))
	check("normalizeAxis 190 -> -170", near(F.normalizeAxis(190), -170))
	local worst = 0
	for i = -100, 100 do local v = i / 100 worst = math.max(worst, math.abs(F.fastAsin(v) - math.asin(v))) end
	check("fastAsin close to asin (" .. string.format("%.1e", worst) .. ")", worst < 1e-6)
	local px, py, pz = F.projectOnPlane(3, 4, 5, 0, 0, 1)
	check("projectOnPlane", near(px, 3) and near(py, 4) and near(pz, 0))
end

do -- quaternion <-> rotator, axes, rotate / unrotate
	local okRT, okAx, okUn = true, true, true
	for _, r in ipairs(rots) do
		local qx, qy, qz, qw = F.quatFromRot(r[1], r[2], r[3])
		local p, y, rr = F.rotFromQuat(qx, qy, qz, qw)
		if not sameAxes(axes(r[1], r[2], r[3]), axes(p, y, rr), 1e-5) then okRT = false end
		local A = axes(r[1], r[2], r[3])
		local ex = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
		for i = 1, 3 do
			local vx, vy, vz = F.rotateVec(qx, qy, qz, qw, ex[i][1], ex[i][2], ex[i][3])
			if not (near(vx, A[i][1], 1e-9) and near(vy, A[i][2], 1e-9) and near(vz, A[i][3], 1e-9)) then okAx = false end
			local ux, uy, uz = F.unrotateVec(qx, qy, qz, qw, vx, vy, vz)
			if not (near(ux, ex[i][1], 1e-9) and near(uy, ex[i][2], 1e-9) and near(uz, ex[i][3], 1e-9)) then okUn = false end
		end
	end
	check("rotator -> quat -> rotator keeps the orientation", okRT)
	check("quat rotates unit axes onto the rotation-matrix rows", okAx)
	check("unrotate undoes rotate", okUn)
end

do -- ComposeRotators(A, B) = A then B: rows(AB) = rows(A) * M(B)
	local ok = true
	for i = 1, #rots - 1 do
		local a, b = rots[i], rots[i + 1]
		local A, B = axes(a[1], a[2], a[3]), axes(b[1], b[2], b[3])
		local want = {}
		for k = 1, 3 do
			want[k] = {}
			for c = 1, 3 do want[k][c] = A[k][1] * B[1][c] + A[k][2] * B[2][c] + A[k][3] * B[3][c] end
		end
		local p, y, r = F.composeRot(a[1], a[2], a[3], b[1], b[2], b[3])
		if not sameAxes(want, axes(p, y, r), 1e-5) then ok = false end
	end
	check("composeRot matches the matrix product", ok)
	local p, y, r = F.composeRot(0, 30, 0, 0, 40, 0)
	check("compose yaw 30 + 40", near(p, 0, 1e-6) and near(y, 70, 1e-6) and near(r, 0, 1e-6))
end

do -- transform rotation round trip, MakeRotFromXZ
	local okX, okM = true, true
	for i = 1, #rots - 1 do
		local t, r = rots[i], rots[i + 1]
		local qx, qy, qz, qw = F.quatFromRot(t[1], t[2], t[3])
		local p, y, rr = F.xformRot(qx, qy, qz, qw, r[1], r[2], r[3])
		p, y, rr = F.invXformRot(qx, qy, qz, qw, p, y, rr)
		if not sameAxes(axes(r[1], r[2], r[3]), axes(p, y, rr), 1e-5) then okX = false end
		local A = axes(r[1], r[2], r[3])
		p, y, rr = F.makeRotFromXZ(A[1][1] * 3, A[1][2] * 3, A[1][3] * 3, A[3][1] * 0.5 + A[1][1] * 0.2, A[3][2] * 0.5 + A[1][2] * 0.2, A[3][3] * 0.5 + A[1][3] * 0.2)
		if not sameAxes(A, axes(p, y, rr), 1e-6) then okM = false end
	end
	check("invXformRot undoes xformRot", okX)
	check("makeRotFromXZ rebuilds the rotation (unnormalised, Z not orthogonal)", okM)
	local p, y, r = F.makeRotFromXZ(1, 0, 0, 1, 0, 0) -- parallel: fallback Z up
	check("makeRotFromXZ parallel fallback", near(p, 0) and near(y, 0) and near(r, 0))
end

print(string.format("qd_fastmath: %d passed, %d failed", passed, failed))
return failed
