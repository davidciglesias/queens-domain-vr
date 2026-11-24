-- s115: pure-Lua copies of the Unreal math the IK solve runs every frame (each Kismet call is a ProcessEvent round trip).
-- Same formulas as the engine (FRotator::Quaternion, FQuat::Rotator incl. FastAsin, FRotationMatrix, MakeFromXZ),
-- numbers in / numbers out, no allocation. Used by libs/core/math_lib.lua and libs/ik.lua when their FAST flag is on.
local M = {}

local D2R, R2D = math.pi / 180.0, 180.0 / math.pi
local sin, cos, sqrt, atan, abs, fmod = math.sin, math.cos, math.sqrt, math.atan, math.abs, math.fmod

-- FRotator::NormalizeAxis: (-180, 180]
function M.normalizeAxis(a)
	a = fmod(a, 360.0)
	if a < 0.0 then a = a + 360.0 end
	if a > 180.0 then a = a - 360.0 end
	return a
end

-- FMath::FastAsin (7-degree minimax, the engine's own approximation used by FQuat::Rotator)
local FA_HALF_PI = 1.5707963050
function M.fastAsin(v)
	local nonneg = v >= 0.0
	local x = abs(v)
	local omx = 1.0 - x
	if omx < 0.0 then omx = 0.0 end
	local root = sqrt(omx)
	local r = ((((((-0.0012624911 * x + 0.0066700901) * x - 0.0170881256) * x + 0.0308918810) * x - 0.0501743046) * x
		+ 0.0889789874) * x - 0.2145988016) * x + FA_HALF_PI
	r = r * root
	if nonneg then return FA_HALF_PI - r end
	return r - FA_HALF_PI
end

-- FRotator::Quaternion -> x, y, z, w
function M.quatFromRot(p, y, r)
	local hp, hy, hr = fmod(p, 360.0) * D2R * 0.5, fmod(y, 360.0) * D2R * 0.5, fmod(r, 360.0) * D2R * 0.5
	local sp, cp, sy, cy, sr, cr = sin(hp), cos(hp), sin(hy), cos(hy), sin(hr), cos(hr)
	return cr * sp * sy - sr * cp * cy, -cr * sp * cy - sr * cp * sy, cr * cp * sy - sr * sp * cy, cr * cp * cy + sr * sp * sy
end

-- FQuat::Rotator -> pitch, yaw, roll
local SING = 0.4999995
function M.rotFromQuat(x, y, z, w)
	local st = z * x - w * y
	local yawY, yawX = 2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z)
	local yaw = atan(yawY, yawX) * R2D
	if st < -SING then
		return -90.0, yaw, M.normalizeAxis(-yaw - 2.0 * atan(x, w) * R2D)
	elseif st > SING then
		return 90.0, yaw, M.normalizeAxis(yaw - 2.0 * atan(x, w) * R2D)
	end
	return M.fastAsin(2.0 * st) * R2D, yaw, atan(-2.0 * (w * x + y * z), 1.0 - 2.0 * (x * x + y * y)) * R2D
end

-- a * b (Hamilton product, FQuat operator*)
function M.quatMul(ax, ay, az, aw, bx, by, bz, bw)
	return aw * bx + ax * bw + ay * bz - az * by,
		aw * by - ax * bz + ay * bw + az * bx,
		aw * bz + ax * by - ay * bx + az * bw,
		aw * bw - ax * bx - ay * by - az * bz
end

-- UKismetMathLibrary::ComposeRotators(A, B) = FRotator(FQuat(B) * FQuat(A))
function M.composeRot(ap, ay, ar, bp, by, br)
	local ax, ayq, az, aw = M.quatFromRot(ap, ay, ar)
	local bx, byq, bz, bw = M.quatFromRot(bp, by, br)
	return M.rotFromQuat(M.quatMul(bx, byq, bz, bw, ax, ayq, az, aw))
end

-- FQuat::RotateVector / UnrotateVector
function M.rotateVec(qx, qy, qz, qw, vx, vy, vz)
	local tx, ty, tz = 2.0 * (qy * vz - qz * vy), 2.0 * (qz * vx - qx * vz), 2.0 * (qx * vy - qy * vx)
	return vx + qw * tx + (qy * tz - qz * ty), vy + qw * ty + (qz * tx - qx * tz), vz + qw * tz + (qx * ty - qy * tx)
end
function M.unrotateVec(qx, qy, qz, qw, vx, vy, vz) return M.rotateVec(-qx, -qy, -qz, qw, vx, vy, vz) end

-- InverseTransformRotation(T, R) = (T.Rotation^-1 * FQuat(R)).Rotator(); TransformRotation = (T.Rotation * FQuat(R)).Rotator()
function M.invXformRot(qx, qy, qz, qw, p, y, r)
	local bx, by, bz, bw = M.quatFromRot(p, y, r)
	return M.rotFromQuat(M.quatMul(-qx, -qy, -qz, qw, bx, by, bz, bw))
end
function M.xformRot(qx, qy, qz, qw, p, y, r)
	local bx, by, bz, bw = M.quatFromRot(p, y, r)
	return M.rotFromQuat(M.quatMul(qx, qy, qz, qw, bx, by, bz, bw))
end

-- FRotationMatrix rows: axis "X" = FRotator::Vector() (GetForwardVector), "Y" = GetRightVector, "Z" = GetUpVector
function M.rotAxis(p, y, r, axis)
	if axis == "X" then
		local pp, yy = fmod(p, 360.0) * D2R, fmod(y, 360.0) * D2R
		local cp = cos(pp)
		return cp * cos(yy), cp * sin(yy), sin(pp)
	end
	local pp, yy, rr = p * D2R, y * D2R, r * D2R
	local sp, cp, sy, cy, sr, cr = sin(pp), cos(pp), sin(yy), cos(yy), sin(rr), cos(rr)
	if axis == "Y" then return sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp end
	return -(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp
end

-- FMatrix::Rotator from the three axes (rows)
function M.rotFromAxes(xx, xy, xz, yx, yy, yz, zx, zy, zz)
	local p = atan(xz, sqrt(xx * xx + xy * xy)) * R2D
	local y = atan(xy, xx) * R2D
	local sx, sy, sz = M.rotAxis(p, y, 0.0, "Y")
	return p, y, atan(zx * sx + zy * sy + zz * sz, yx * sx + yy * sy + yz * sz) * R2D
end

local function safeNormal(x, y, z)
	local s = x * x + y * y + z * z
	if s == 1.0 then return x, y, z end
	if s < 1e-8 then return 0.0, 0.0, 0.0 end
	local k = 1.0 / sqrt(s)
	return x * k, y * k, z * k
end
M.safeNormal = safeNormal

-- UKismetMathLibrary::MakeRotFromXZ = FRotationMatrix::MakeFromXZ(X, Z).Rotator()
function M.makeRotFromXZ(ax, ay, az, bx, by, bz)
	local nx, ny, nz = safeNormal(ax, ay, az)
	local zx, zy, zz = safeNormal(bx, by, bz)
	if abs(abs(nx * zx + ny * zy + nz * zz) - 1.0) <= 1e-8 then
		if abs(nz) < 1.0 - 1e-4 then zx, zy, zz = 0.0, 0.0, 1.0 else zx, zy, zz = 1.0, 0.0, 0.0 end
	end
	local yx, yy, yz = safeNormal(zy * nz - zz * ny, zz * nx - zx * nz, zx * ny - zy * nx) -- Norm ^ NewX
	local wx, wy, wz = ny * yz - nz * yy, nz * yx - nx * yz, nx * yy - ny * yx -- NewX ^ NewY
	return M.rotFromAxes(nx, ny, nz, yx, yy, yz, wx, wy, wz)
end

-- UKismetMathLibrary::ProjectVectorOnToPlane(V, N) = V - N * (V . N)  (callers pass unit normals)
function M.projectOnPlane(vx, vy, vz, nx, ny, nz)
	local d = vx * nx + vy * ny + vz * nz
	return vx - nx * d, vy - ny * d, vz - nz * d
end

return M
