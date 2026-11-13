-- Unit tests for libs/qd_grip.lua. Run: python tools/run_tests.py
local g = require("qd_grip")

local failed, passed = 0, 0
local function check(name, cond)
	if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-3) end
local function nearAng(a, b, eps) local d = (a - b + 180) % 360 - 180 return math.abs(d) <= (eps or 1e-3) end
local function nearV(a, b, eps) return near(a[1], b[1], eps) and near(a[2], b[2], eps) and near(a[3], b[3], eps) end

do -- matrix <-> rotator round trip
	for _, r in ipairs({{0, 0, 0}, {10, 20, 30}, {-45, 170, -60}, {0, 87.1, 12.4}, {80, -30, 5}}) do
		local back = g.matToRot(g.rotMatrix(r[1], r[2], r[3]))
		check("roundtrip " .. table.concat(r, ","), nearAng(back.Pitch, r[1]) and nearAng(back.Yaw, r[2]) and nearAng(back.Roll, r[3]))
	end
end

do -- the reference sword reproduces its own tuned grip
	local rot, loc, info = g.autoGrip({X = 0.001, Y = -25.84, Z = 0.048}, {X = 6.588, Y = 36.523, Z = 1.423})
	check("sword axis", info.axis == "Y" and info.sign == -1 and info.pivotGrip)
	check("sword rot", nearAng(rot.Pitch, 0, 0.01) and nearAng(rot.Yaw, 87.1, 0.01) and nearAng(rot.Roll, 12.4, 0.01))
	check("sword loc", near(loc.X, 6.0) and near(loc.Y, 1.855) and near(loc.Z, -1.4))
end

local F = g.refFrame()
do -- an X-long weapon with the pivot at the handle end points its blade like the sword
	local rot, loc, info = g.autoGrip({X = 30, Y = 0, Z = 0}, {X = 40, Y = 3, Z = 1})
	check("x-long axis", info.axis == "X" and info.sign == 1 and info.pivotGrip)
	check("x-long blade dir", nearV(g.rotate(rot, {1, 0, 0}), F, 1e-6))
	check("x-long right-handed", nearV(g.rotate(rot, {0, 0, 1}), (function() local _, _, T = g.refFrame() return T end)(), 1e-6))
end

do -- head on the -Z side, pivot in the middle -> grip moved to near the handle end (+Z)
	local rot, loc, info = g.autoGrip({X = 0, Y = 0, Z = -2}, {X = 4, Y = 10, Z = 50})
	check("centred axis", info.axis == "Z" and info.sign == -1 and not info.pivotGrip)
	check("centred blade dir", nearV(g.rotate(rot, {0, 0, -1}), F, 1e-6))
	-- grip point (12 % of 100 cm from the +Z end: bounds -52..48 -> z = 48 - 12 = 36) lands on the reference location
	local gp = g.rotate(rot, {0, 0, 36})
	check("centred grip lands on ref", near(gp[1] + loc.X, 6.0) and near(gp[2] + loc.Y, 1.855) and near(gp[3] + loc.Z, -1.4))
end

do -- ranged: barrel +X straight along the aim, taller side up, thin side right
	local rot, loc, info = g.autoGrip({X = 10, Y = 0, Z = 4}, {X = 25, Y = 2, Z = 8}, {ranged = true})
	check("gun barrel fwd", nearV(g.rotate(rot, {1, 0, 0}), {1, 0, 0}, 1e-6))
	check("gun up", nearV(g.rotate(rot, {0, 0, 1}), {0, 0, 1}, 1e-6))
	local rot2 = g.autoGrip({X = 10, Y = 0, Z = -4}, {X = 25, Y = 2, Z = 8}, {ranged = true})
	check("gun flipped up", nearV(g.rotate(rot2, {0, 0, -1}), {0, 0, 1}, 1e-6) and nearV(g.rotate(rot2, {1, 0, 0}), {1, 0, 0}, 1e-6))
end

do -- pickups: long axis through the fist, thin axis out of the palm, bounds centre on the palm (+ lift), size cap
	local H = g.HOLD
	local function n3(v) local l = math.sqrt(v[1] ^ 2 + v[2] ^ 2 + v[3] ^ 2) return {v[1] / l, v[2] / l, v[3] / l} end
	local U = n3(H.fist)
	local rot, loc, sc, info = g.pickupHold({X = -1, Y = -15, Z = 1}, {X = 6, Y = 32, Z = 5}, {scale = 1.0})
	check("hold long Y", info.axis == "Y" and info.thin == "Z" and info.scaled)
	check("hold long -> fist", nearV(g.rotate(rot, {0, 1, 0}), U, 1e-6))
	local N = g.rotate(rot, {0, 0, 1})
	check("hold thin -> out of palm", near(N[1] * U[1] + N[2] * U[2] + N[3] * U[3], 0, 1e-6) and N[3] < -0.99)
	check("hold scale cap", near(sc, H.maxSize / 64, 1e-6))
	local c = g.rotate(rot, {-1 * sc, -15 * sc, 1 * sc})
	local lift = 5 * sc
	check("hold centre on palm", near(loc.X + c[1], H.palm[1] + N[1] * lift, 1e-6) and near(loc.Y + c[2], H.palm[2] + N[2] * lift, 1e-6)
		and near(loc.Z + c[3], H.palm[3] + N[3] * lift, 1e-6))
	local rot2, _, sc2, info2 = g.pickupHold({X = 0, Y = 0, Z = 10}, {X = 5, Y = 5, Z = 5}, {scale = 0.8})
	check("hold cube keeps up axis in the fist", info2.axis == "Z" and nearV(g.rotate(rot2, {0, 0, 1}), U, 1e-6))
	check("hold small not scaled", near(sc2, 0.8) and not info2.scaled)
	local rot3, _, _, info3 = g.pickupHold({X = 0, Y = 0, Z = 0}, {X = 5, Y = 5, Z = 1})
	check("hold coin flat face out", info3.thin == "Z" and info3.axis == "X" and g.rotate(rot3, {0, 0, 1})[3] < -0.99)
end

print(string.format("qd_grip: %d passed, %d failed", passed, failed))
return failed
