-- Unit tests for libs/qd_statusfx.lua (pure helpers). Run: python tools/run_tests.py
local f = require("qd_statusfx")

local failed, passed = 0, 0
local function check(name, cond)
	if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end
local function near(x, c, eps) return type(x) == "number" and math.abs(x - c) <= (eps or 1e-6) end

do -- step 122e
	local r, g, b = f.colorFor("PoisonOverlaymat")
	check("colorFor: name match (case-insensitive)", near(r, 0.55) and near(g, 0.15) and near(b, 0.75))
	r, g, b = f.colorFor("SomethingElse")
	check("colorFor: default = no tint", near(r, 1) and near(g, 1) and near(b, 1))
	check("colorFor: nil name", f.colorFor(nil) ~= nil)
	check("strength: off", f.strength(0, 1) == 0.0)
	check("strength: full", near(f.strength(1, 1), 1.0))
	check("strength: pulse low = PULSE_MIN", near(f.strength(1, 0), f.PULSE_MIN))
	check("strength: clamps", near(f.strength(2, 5), 1.0) and near(f.strength(1, -1), f.PULSE_MIN))
	check("strength: half opacity", near(f.strength(0.5, 1), 0.5))
	local v, tr, tg, tb = f.pp(0, 0.5, 0.1, 0.7, 0.4)
	check("pp: zero strength = base", near(v, 0.4) and near(tr, 1) and near(tg, 1) and near(tb, 1))
	v, tr, tg, tb = f.pp(1, 0.5, 0.1, 0.7, 0.4)
	check("pp: full strength", near(v, 0.4 + f.VIG_ADD) and near(tr, 1 - 0.5 * f.TINT_K) and near(tg, 1 - 0.9 * f.TINT_K) and near(tb, 1 - 0.3 * f.TINT_K))
	check("tick without init is a no-op", pcall(f.tick, 0.1, true))
end

-- step 125: status modes (visors retired; badge = icon badge)
do
	local v, b, g = f.styleParts(1) check("mode 1 = glow only + icons", v == 0 and b and g == 2)
	v, b, g = f.styleParts(2) check("mode 2 = glow only", v == 0 and not b and g == 2)
	v, b, g = f.styleParts(3) check("mode 3 = icons only", v == 0 and b and g == 0)
	v, b, g = f.styleParts(4) check("mode 4 = glow + tint + icons", v == 0 and b and g == 1)
	v, b, g = f.styleParts(nil) check("mode nil = mode 1", v == 0 and b and g == 2)
	check("modes list matches", #f.STYLES == 4)
	local vt = f.pp(1.0, 1, 1, 1, 0.0, false)
	local vp = f.pp(1.0, 1, 1, 1, 0.0, true)
	check("plain glow stronger than tinted", vp > vt)
	local r, g2, bb, a = f.iconBack("PoisonStatusEffect", false)
	local pr, pg, pb = f.colorFor("poison")
	check("icon back uses the effect colour, darkened", math.abs(r - pr * f.ICON_BACK_K) < 1e-6 and math.abs(bb - pb * f.ICON_BACK_K) < 1e-6 and a == f.ICON_BACK_A)
	local r1, g1 = f.iconBack("UnknownThing", true)
	local r0, g0 = f.iconBack("UnknownThing", false)
	check("unknown positive = gold, negative = red", g1 > g0 and r1 > 0 and r0 > g0)
	check("one icon centred", f.iconOffset(1, 1) == 0)
	local step = f.ICON_CM + f.ICON_GAP
	check("two icons symmetric", math.abs(f.iconOffset(1, 2) + step / 2) < 1e-9 and math.abs(f.iconOffset(2, 2) - step / 2) < 1e-9)
end

-- step 126b: accessory slot ids and row offsets
check("accIndex 0 -> 1", f.accIndex(0) == 1)
check("accIndex 5 -> 6", f.accIndex(5) == 6)
check("accIndex throwable/weapon slot -> nil", f.accIndex(1000) == nil and f.accIndex(2001) == nil)
check("accIndex out of range -> nil", f.accIndex(6) == nil and f.accIndex(nil) == nil and f.accIndex(-1) == nil)
local a1, c1 = f.accOffset(1, 3)
local a3, c3 = f.accOffset(3, 3)
local a2, c2 = f.accOffset(2, 3)
check("accOffset one row centred", math.abs(a1 + a3) < 1e-9 and a2 == 0 and c1 == 0 and c3 == 0 and f.accOffset(1, 1) == 0)
local b1, d1 = f.accOffset(1, 5)
local b4, d4 = f.accOffset(4, 5)
local b5, d5 = f.accOffset(5, 5)
check("accOffset two rows: 2nd row beside, centred on its own count", d1 < 0 and d4 > 0 and math.abs(d1 + d4) < 1e-9 and math.abs(b4 + b5) < 1e-9)
local near = function(a, b) return math.abs(a - b) < 1e-6 end
local rx, ry, rz = f.rotVec(0, 90, 0, 1, 0, 0)
check("rotVec yaw 90: X -> Y", near(rx, 0) and near(ry, 1) and near(rz, 0))
rx, ry, rz = f.rotVec(90, 0, 0, 1, 0, 0)
check("rotVec pitch 90: X -> Z", near(rx, 0) and near(ry, 0) and near(rz, 1))
rx, ry, rz = f.rotVec(0, 0, 90, 0, 1, 0)
check("rotVec roll 90: Y -> -Z (UE matrix)", near(rx, 0) and near(ry, 0) and near(rz, -1))
check("no frame behind accessory icons", f.ACC_BACK == nil and f.AC[1].back == nil)
check("accTick without init is a no-op", pcall(f.accTick, 0.1, true))
print(string.format("qd_statusfx: %d passed, %d failed", passed, failed))
return failed
