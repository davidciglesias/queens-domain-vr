-- Unit tests for libs/qd_pickup.lua. Run: python tools/run_tests.py
local pk = require("qd_pickup")
local g = require("qd_grip")

local failed, passed = 0, 0
local function check(name, cond)
	if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end

-- hand at (0, 20, 100), eyes at (0, 0, 160), pointing along +X
local function sel(cands, dx, dy, dz, current, opts)
	return pk.select(cands, #cands, 0, 20, 100, dx or 1, dy or 0, dz or 0, 0, 0, 160, current, opts)
end

do -- pointing straight at an item 1.5 m away selects it; an item 1 m off to the side does not
	local c = {{x = 150, y = 20, z = 100, r = 8, obj = "a"}, {x = 150, y = 120, z = 100, r = 8, obj = "b"}}
	local i = sel(c)
	check("straight hit", i == 1)
end

do -- the eye ray (crosshair) also selects: item on the eye line, 60 cm above the hand line
	local c = {{x = 200, y = 0, z = 160, r = 8, obj = "a"}}
	check("eye ray", sel(c) == 1)
	check("no eye ray -> miss", pk.select(c, 1, 0, 20, 100, 1, 0, 0, nil, nil, nil, nil) == nil)
end

do -- behind the hand or beyond range: nothing
	check("behind", sel({{x = -100, y = 20, z = 100, r = 8}}) == nil)
	check("too far", sel({{x = 500, y = 20, z = 100, r = 8}}) == nil)
end

do -- proximity: hand right at an item wins over a well-aimed far one
	local c = {{x = 200, y = 20, z = 100, r = 8, obj = "far"}, {x = 10, y = 35, z = 95, r = 8, obj = "near"}}
	check("proximity wins", sel(c) == 2)
end

do -- tolerance grows with distance: 25 cm off at 2 m is in, 25 cm off at 0.6 m is out
	check("far tolerant", sel({{x = 200, y = 45, z = 100, r = 5}}) == 1)
	check("near strict", sel({{x = 60, y = 45 + 20, z = 100, r = 5}}) == nil)
end

do -- stickiness: the current target keeps the selection against a marginally better neighbour
	local c = {{x = 150, y = 26, z = 100, r = 8, obj = "a"}, {x = 150, y = 24, z = 100, r = 8, obj = "b"}}
	check("best without current", sel(c) == 2)
	check("sticky current", sel(c, nil, nil, nil, "a") == 1)
end

do -- skipped (occluded) candidates are ignored, even at the hand
	local c = {{x = 150, y = 20, z = 100, r = 8, skip = true}, {x = 150, y = 30, z = 100, r = 8}, {x = 5, y = 20, z = 100, skip = true}}
	check("skip", sel(c) == 2)
end

do -- beam rotation: +Z of the rotated mesh points along the requested direction
	for _, d in ipairs({{1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {0, 0, -1}, {0.6, -0.48, 0.64}}) do
		local r = pk.zAxisRot(d[1], d[2], d[3])
		local z = g.rotate(r, {0, 0, 1})
		check("zAxisRot " .. table.concat(d, ","), math.abs(z[1] - d[1]) < 1e-6 and math.abs(z[2] - d[2]) < 1e-6 and math.abs(z[3] - d[3]) < 1e-6)
	end
end

print(string.format("qd_pickup: %d passed, %d failed", passed, failed))
return failed
