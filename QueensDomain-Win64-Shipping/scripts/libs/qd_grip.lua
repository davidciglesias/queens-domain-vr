-- qd_grip: pure math for automatic weapon grips (no UEVR calls; unit tested by tools/test_qd_grip.lua).
-- Copyright (C) 2026 Queen's Domain VR contributors. AGPL-3.0 (see LICENSE).
--
-- A weapon without a saved attachments entry gets a grip computed from its static mesh bounds (mesh-local
-- Origin/BoxExtent, cm): the longest axis is the weapon's length, the blade/head lies on the side of the pivot
-- where the bounds centre is. It is oriented like a reference grip (default: the user's tuned sword, whose mesh
-- is long along -Y, wide along X), so every weapon is held the same way. Rotations are UE FRotator degrees.

local M = {}

local rad, deg = math.rad, math.deg
local AX = {"X", "Y", "Z"}
local UNIT = {X = {1, 0, 0}, Y = {0, 1, 0}, Z = {0, 0, 1}}

-- UE FRotationMatrix rows = images of the local X, Y, Z axes
function M.rotMatrix(p, y, r)
	local sp, cp = math.sin(rad(p)), math.cos(rad(p))
	local sy, cy = math.sin(rad(y)), math.cos(rad(y))
	local sr, cr = math.sin(rad(r)), math.cos(rad(r))
	return {
		{cp * cy, cp * sy, sp},
		{sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp},
		{-(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp},
	}
end

local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b) return {a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]} end
local function scale(a, k) return {a[1] * k, a[2] * k, a[3] * k} end
local function add3(a, b, c) return {a[1] + b[1] + c[1], a[2] + b[2] + c[2], a[3] + b[3] + c[3]} end
local function norm(a) local l = math.sqrt(dot(a, a)) if l < 1e-9 then return {0, 0, 0} end return scale(a, 1 / l) end

-- UE FMatrix::Rotator()
function M.matToRot(m)
	local x, yv, z = m[1], m[2], m[3]
	local pitch = deg(math.atan(x[3], math.sqrt(x[1] * x[1] + x[2] * x[2])))
	local yaw = deg(math.atan(x[2], x[1]))
	local sy = M.rotMatrix(pitch, yaw, 0)[2]
	local roll = deg(math.atan(dot(z, sy), dot(yv, sy)))
	return {Pitch = pitch, Yaw = yaw, Roll = roll}
end

-- local vector -> parent space for a rotator
function M.rotate(rot, v)
	local m = M.rotMatrix(rot.Pitch, rot.Yaw, rot.Roll)
	return add3(scale(m[1], v[1]), scale(m[2], v[2]), scale(m[3], v[3]))
end

-- Reference grip: the sword the user tuned (mesh long along -Y, wide along X; pivot at the hilt).
M.REF = {rotation = {Pitch = 0.0, Yaw = 87.1, Roll = 12.4}, location = {X = 6.0, Y = 1.855, Z = -1.4}, long = {0, -1, 0}, wide = {1, 0, 0}}

-- Directions (parent = motion controller space) the reference grip gives the weapon's length / width / thickness.
function M.refFrame(ref)
	ref = ref or M.REF
	local r = ref.rotation
	local F = M.rotate(r, ref.long)
	local W = M.rotate(r, ref.wide)
	local T = M.rotate(r, cross(ref.long, ref.wide))
	return F, W, T
end

local function get(v, a) return v[a] or v[string.lower(a)] or 0.0 end

-- origin/extent: mesh-local bounds (tables with X, Y, Z). opts.ranged: barrel straight along the aim, thin side
-- axis to the right, taller side up (towards the bounds centre). opts.ref: reference grip (M.REF layout).
-- Returns rotation {Pitch, Yaw, Roll}, location {X, Y, Z} and an info table.
function M.autoGrip(origin, extent, opts)
	opts = opts or {}
	local o = {get(origin, "X"), get(origin, "Y"), get(origin, "Z")}
	local e = {math.abs(get(extent, "X")), math.abs(get(extent, "Y")), math.abs(get(extent, "Z"))}
	local order = {1, 2, 3}
	table.sort(order, function(i, j) if e[i] == e[j] then return i < j end return e[i] > e[j] end)
	local a, w, t = order[1], order[2], order[3]
	local length = 2 * e[a]
	local tol = math.max(1.0, 0.03 * length)
	local s = (o[a] > tol) and 1 or -1 -- blade/head side of the pivot (pivot centred -> -1, like the sword)
	local u1 = scale(UNIT[AX[a]], s)
	local F, W, T
	local u2
	if opts.ranged then
		F, W, T = {1, 0, 0}, {0, 1, 0}, {0, 0, 1}
		u2 = UNIT[AX[t]] -- thinnest axis -> right
		local up = (o[w] >= 0) and 1 or -1 -- taller side (barrel above the grip) -> up
		if dot(cross(u1, u2), scale(UNIT[AX[w]], up)) < 0 then u2 = scale(u2, -1) end
	else
		F, W, T = M.refFrame(opts.ref)
		u2 = UNIT[AX[w]]
	end
	local u3 = cross(u1, u2)
	-- rows = images of local X, Y, Z: R(v) = F (u1.v) + W (u2.v) + T (u3.v)
	local rows = {}
	for k = 1, 3 do
		local ek = UNIT[AX[k]]
		rows[k] = add3(scale(F, dot(u1, ek)), scale(W, dot(u2, ek)), scale(T, dot(u3, ek)))
	end
	local rot = M.matToRot(rows)
	-- grip point: the pivot when it sits near the handle end (normal for weapon meshes), else 12 % up from the end
	local c = s * o[a] -- bounds centre along the blade direction
	local handleEnd = c - e[a]
	local refLoc = (opts.ref and opts.ref.location) or M.REF.location
	local sc = opts.scale or 1.0
	local loc = {X = refLoc.X, Y = refLoc.Y, Z = refLoc.Z}
	local pivotGrip = (-handleEnd) <= 0.35 * length and handleEnd <= 0.5
	if not pivotGrip then
		local g = handleEnd + math.max(6.0, 0.12 * length)
		local gl = {0, 0, 0}
		gl[a] = s * g
		gl[w], gl[t] = o[w], o[t]
		local gp = M.rotate(rot, scale(gl, sc))
		loc.X, loc.Y, loc.Z = refLoc.X - gp[1], refLoc.Y - gp[2], refLoc.Z - gp[3]
	end
	return rot, loc, {axis = AX[a], sign = s, wide = AX[w], thin = AX[t], length = length, pivotGrip = pivotGrip,
		blade = scale(norm(F), 1)}
end

-- Pickups held in the left hand (parent = the hand mesh's "Hand_L" socket; found in game: +X thumb side, -Y towards the
-- fingers, -Z out of the palm). palm/fist/out come from the original modder's hand-tuned items: median bounds centre
-- (4, -9, -5), and items long along their own up axis (bottles) point that axis along (0.85, -0.5, 0.05).
M.HOLD = {palm = {4.0, -9.0, -5.0}, fist = {0.85, -0.5, 0.05}, out = {0.0, 0.0, -1.0}, maxSize = 35.0}

-- An item without a tuned grip: its longest axis goes through the fist (an item as tall as it is long keeps its own up
-- axis there), its thinnest axis faces out of the palm, its bounds centre sits on the palm, and it is scaled down so its
-- longest side is at most maxSize cm. origin/extent: mesh-local bounds; opts.scale: current relative scale (uniform).
-- Returns rotation, location, scale and an info table.
function M.pickupHold(origin, extent, opts)
	opts = opts or {}
	local h = opts.hold or M.HOLD
	local o = {get(origin, "X"), get(origin, "Y"), get(origin, "Z")}
	local e = {math.abs(get(extent, "X")), math.abs(get(extent, "Y")), math.abs(get(extent, "Z"))}
	local big = math.max(e[1], e[2], e[3])
	local a = 3
	if e[3] < 0.95 * big then a = (e[1] >= e[2]) and 1 or 2 end
	local r1, r2 = a % 3 + 1, (a + 1) % 3 + 1
	local t = (e[r1] <= e[r2]) and r1 or r2
	local s0 = opts.scale or 1.0
	local maxSize = opts.maxSize or h.maxSize
	local size = 2 * big * s0
	local sc = s0
	if size > maxSize and size > 0 then sc = s0 * maxSize / size end
	local U = norm(h.fist)
	local N = h.out
	N = norm(add3(N, scale(U, -dot(N, U)), {0, 0, 0}))
	local Tv = cross(U, N)
	local u1, u2 = UNIT[AX[a]], UNIT[AX[t]]
	local u3 = cross(u1, u2)
	local rows = {}
	for k = 1, 3 do
		local ek = UNIT[AX[k]]
		rows[k] = add3(scale(U, dot(u1, ek)), scale(N, dot(u2, ek)), scale(Tv, dot(u3, ek)))
	end
	local rot = M.matToRot(rows)
	local c = M.rotate(rot, scale(o, sc))
	local lift = e[t] * sc
	local P = h.palm
	local loc = {X = P[1] + N[1] * lift - c[1], Y = P[2] + N[2] * lift - c[2], Z = P[3] + N[3] * lift - c[3]}
	return rot, loc, sc, {axis = AX[a], thin = AX[t], size = size, scaled = sc ~= s0}
end

return M
