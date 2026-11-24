-- Unit tests for libs/qd_belt3d.lua (pure helpers). Run: python tools/run_tests.py
local m = require("qd_belt3d")
local b = require("qd_belt")

local failed, passed = 0, 0
local function check(name, cond)
	if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end
local function near(x, c, eps) return type(x) == "number" and math.abs(x - c) <= (eps or 1e-6) end

do -- normalise to the size
	check("longest side = 9", near(m.fit(10, 5, 4, 9) * 20, 9))
	check("degenerate", m.fit(0, 0, 0, 9) == nil and m.fit(nil, 1, 1, 9) == nil and m.fit(1, 1, 1, 0) == nil)
	local sc = m.fit(20, 3, 10, 9) -- flat: min extent 6 * 0.225 = 1.35 cm -> widened to 1.5 cm, longest 10 cm
	check("flat widened", near(2 * 3 * sc, 1.5, 1e-6) and near(2 * 20 * sc, 10))
	check("flat widened but capped at 14", near(2 * 100 * m.fit(100, 1, 5, 9), 14.0, 1e-6))
	check("normal model untouched", near(m.fit(20, 15, 12, 9), 9 / 40))
end
do -- hull
	check("k small model floor", near(m.hullK(4), 1.15) and near(m.hullK(9), 1.10))
	check("k big model 10 percent", near(m.hullK(20), 1.10))
	check("k factor", near(m.hullKFor(1.1, 0.6), 1.06))
	local mx, my, mz, hx, hy, hz, hs = m.hullXform(0.2, 1.1, 10, -5, 3)
	check("mesh centre on pivot", near(mx + 10 * 0.2, 0) and near(my - 5 * 0.2, 0) and near(mz + 3 * 0.2, 0))
	check("hull centre on pivot", near(hx + 10 * hs, 0) and near(hy - 5 * hs, 0) and near(hz + 3 * hs, 0) and near(hs, 0.22))
end
do -- layout agrees with the belt's slot positions
	local x, y = m.slotLocal(33, 24, -8)
	local bx, by = b.slotPos(0, 0, 0, 33, 24)
	check("slotLocal = slotPos", near(x, bx) and near(y, by))
	check("height", select(3, m.slotLocal(10, 24, -8)) == -8)
	local p, yw, r = m.modelRot(-33, 35)
	check("model rotation", p == 35 and yw == -33 and r == 0)
end
do -- outline states mirror the card frames
	local k, f, mf = m.hullState(true, false, false, false)
	check("hover gold + grows", k == "gold" and f == 1.0 and mf == m.HOVER_F)
	k, f, mf = m.hullState(false, true, false, false)
	check("selected cyan thin", k == "cyan" and f == m.CYAN_F and mf == 1.0)
	k = m.hullState(true, true, false, false)
	check("both = gold", k == "gold")
	check("peek grey, no growth", select(1, m.hullState(true, true, true, false)) == "grey" and select(3, m.hullState(true, true, true, false)) == 1.0)
	-- step 120: can't-use shell: below hover and peek, above selection; held = none
	check("off beats selection", select(1, m.hullState(false, true, false, false, true)) == "off")
	check("hover beats off", select(1, m.hullState(true, false, false, false, true)) == "gold")
	check("held: no off shell", select(1, m.hullState(false, false, false, true, true)) == nil)
	check("off shell no growth", select(3, m.hullState(false, false, false, false, true)) == 1.0)
	check("held none", m.hullState(true, true, false, true) == nil)
	check("idle none", m.hullState(false, false, false, false) == nil)
end
do -- label faces the head
	local p, y = m.labelRot(24, 0, -68, 0, 0, 0)
	check("label looks inward and up", near(y, 180) and p > 60 and p < 80)
	p, y = m.labelRot(0, 10, 0, 0, 0, 0)
	check("label yaw left", near(y, -90) and near(p, 0))
end
do -- chain tie
	local s, lx, ly, lz = m.tieXform(41, 1, 2, 3, 8)
	check("tie length", near(2 * 41 * s, 8))
	check("tie hangs below the strap", near(lz + 3 * s, -4) and near(lx + 1 * s, 0) and near(ly + 2 * s, 0))
	check("tie degenerate", m.tieXform(0, 0, 0, 0, 8) == nil)
	local s2, _, _, lz2 = m.tieXform(41, 1, 2, 3, 8, true) -- step 88: standing up
	check("tie rises above the strap", near(lz2 + 3 * s2, 4))
	check("step 121: shoulder item hangs below its point", near(m.shoulderDz(10), -(m.SH_HANG_CM + 5)))
	check("hangDz up clears the strap", near(m.hangDz(10, true), m.RING_H_CM / 2 + m.UP_GAP_CM + 5))
	check("hangDz down = -HANG_CM", near(m.hangDz(10, false), -m.HANG_CM))
	local ap, ay = m.arrowRot(60, 1)
	check("s92 next arrow points along increasing angle", near(ap, -90) and near(ay, 150))
	ap, ay = m.arrowRot(-60, -1)
	check("s92 prev arrow points along decreasing angle", near(ay, -150))
end
do -- ring: the loop centre lands on the belt centre; extents reach the radius
	local sx, sy, sz, lx, ly, lz = m.ringXform(6, 15, 28, 0, 3.5, -11.5, 24, 3)
	check("ring height", near(6 * sx, 3))
	check("ring round", near(15 * sy, 48) and near(28 * sz, 48))
	-- bounds centre (0, 3.5, -11.5) scaled, rotated pitch 90 (x' = -z, y' = y, z' = x), plus the loc = 0
	local px, py, pz = 0 * sx, 3.5 * sy, -11.5 * sz
	check("ring centred", near(lx + (-pz), 0) and near(ly + py, 0) and near(lz + px, 0))
	check("ring degenerate", m.ringXform(0, 1, 1, 0, 0, 0, 24, 3) == nil)
end
do -- cube band fallback
	local out = {x = {}, y = {}, yaw = {}, len = {}}
	local n = m.arcSegs(-110, 110, 12, 24, out)
	check("band count", n == 19)
	check("band symmetric", near(out.y[1], -out.y[n], 1e-9) and near(out.x[1], out.x[n], 1e-9))
	check("band tangent yaw", near(out.yaw[(n + 1) // 2], 90.0, 1e-6))
	check("band chord length", near(out.len[1], 2 * 24 * math.sin(math.rad(220 / 19) / 2) * 1.04))
	check("band single", m.arcSegs(0, 5, 12, 24, out) == 1)
end

print(string.format("test_qd_belt3d: %d passed, %d failed", passed, failed))
return failed
