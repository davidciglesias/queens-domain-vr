-- qd_pickup: pure target selection for left-hand item pickups (no UEVR calls; tools/test_qd_pickup.lua).
-- Copyright (C) 2026 Queen's Domain VR contributors. AGPL-3.0 (see LICENSE).
--
-- An item is a candidate when the hand is at it (proximity grab) or when either aim ray passes close to it:
-- ray 1 = from the hand along the hand's pointing direction (natural pointing), ray 2 = from the eyes along the
-- same direction (what the knife crosshair shows). Tolerance = max(item radius, baseTol) + distance * tan(cone),
-- so near items are easy to hit and far ones still need some precision. Units: cm.

local M = {}

M.defaults = {range = 350.0, near = 30.0, baseTol = 10.0, coneDeg = 6.0, sticky = 0.04}

-- tan(angle) between the ray and the item when it is inside the tolerance, else nil
local function rayScore(c, ox, oy, oz, dx, dy, dz, range, baseTol, tanCone)
	local vx, vy, vz = c.x - ox, c.y - oy, c.z - oz
	local along = vx * dx + vy * dy + vz * dz
	if along <= 0 or along > range then return nil end
	local d2 = vx * vx + vy * vy + vz * vz
	local perp = math.sqrt(math.max(0.0, d2 - along * along))
	local tol = math.max(c.r or 0.0, baseTol) + along * tanCone
	if perp > tol then return nil end
	return perp / math.max(along, 30.0)
end

-- cands[1..n] = {x, y, z, r (cm), obj}; hand h, pointing dir d (unit), eye e. current = obj selected last tick
-- (gets a stickiness bonus so the selection doesn't flicker between neighbours). Returns index, score.
function M.select(cands, n, hx, hy, hz, dx, dy, dz, ex, ey, ez, current, opts)
	opts = opts or M.defaults
	local range = opts.range or M.defaults.range
	local nearR = opts.near or M.defaults.near
	local baseTol = opts.baseTol or M.defaults.baseTol
	local tanCone = math.tan(math.rad(opts.coneDeg or M.defaults.coneDeg))
	local sticky = opts.sticky or M.defaults.sticky
	local best, bestScore = nil, math.huge
	for i = 1, n do
		local c = cands[i]
		local score = nil
		local px, py, pz = c.x - hx, c.y - hy, c.z - hz
		local hd = math.sqrt(px * px + py * py + pz * pz)
		if c.skip then -- e.g. hidden behind a wall (caller's line trace)
		elseif hd <= nearR + (c.r or 0.0) * 0.5 then
			score = -1.0 + hd / 1000.0 -- hand at the item: always wins, nearest first
		else
			score = rayScore(c, hx, hy, hz, dx, dy, dz, range, baseTol, tanCone)
			if ex ~= nil then
				local s2 = rayScore(c, ex, ey, ez, dx, dy, dz, range, baseTol, tanCone)
				if s2 ~= nil and (score == nil or s2 < score) then score = s2 end
			end
		end
		if score ~= nil then
			if current ~= nil and c.obj == current then score = score - sticky end
			if score < bestScore then best, bestScore = i, score end
		end
	end
	return best, bestScore
end

-- Rotator (degrees) that points a mesh's local +Z along (dx, dy, dz) (e.g. the engine cylinder as a beam).
function M.zAxisRot(dx, dy, dz, out)
	out = out or {}
	local h = math.sqrt(dx * dx + dy * dy)
	out.Pitch = math.deg(math.atan(-h, dz))
	out.Yaw = (h > 1e-6) and math.deg(math.atan(dy, dx)) or 0.0
	out.Roll = 0.0
	return out
end

return M
