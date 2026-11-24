-- Unit tests for libs/qd_armhud.lua (pure helpers). Run: python tools/run_tests.py
local a = require("qd_armhud")

local failed, passed = 0, 0
local function check(name, cond)
	if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end
local function near(x, c, eps) return type(x) == "number" and math.abs(x - c) <= (eps or 1e-6) end

do -- fraction
	check("frac half", near(a.frac(52, 104), 0.5))
	check("frac clamp low", a.frac(-6, 104) == 0.0)
	check("frac clamp high", a.frac(200, 104) == 1.0)
	check("frac no max", a.frac(5, 0) == nil and a.frac(nil, 10) == nil)
end
do -- bar stack centred
	check("bar 1 of 4", near(a.barOffset(1, 4, 0.9), -1.35))
	check("bar 4 of 4", near(a.barOffset(4, 4, 0.9), 1.35))
	check("bar stack symmetric", near(a.barOffset(2, 4, 1) + a.barOffset(3, 4, 1), 0))
end
do -- continuous fill grows from the -len/2 end
	local c, l = a.fillSpan(0.5, 8)
	check("fill half", near(c, -2) and near(l, 4))
	c, l = a.fillSpan(1, 8)
	check("fill full centred", near(c, 0) and near(l, 8))
	c, l = a.fillSpan(0, 8)
	check("fill empty at start", near(c, -4) and near(l, 0))
	c, l = a.fillSpan(nil, 8)
	check("fill nil = empty", near(l, 0))
end
do -- pips tile the bar
	local c1, p1 = a.pipSpan(1, 3, 7, 0.25)
	local c3, p3 = a.pipSpan(3, 3, 7, 0.25)
	check("pip length", near(p1, (7 - 0.5) / 3) and near(p1, p3))
	check("pip 1 starts at bar start", near(c1 - p1 / 2, -3.5))
	check("pip 3 ends at bar end", near(c3 + p3 / 2, 3.5))
end
do -- pip fills
	check("pip full", a.pipFill(1, 1.3) == 1.0)
	check("pip partial fraction", near(a.pipFill(2, 1.3), 0.3))
	check("pip empty", a.pipFill(3, 1.3) == 0.0)
	check("pip recharge progress", near(a.pipFill(3, 2, 0.45), 0.45))
	check("pip progress only next", a.pipFill(4, 2, 0.45) == 0.0)
	check("pip nil count", a.pipFill(1, nil) == 0.0)
	check("charge clamp above max", a.chargeCount(11, 10) == 10)
	check("charge count in range", a.chargeCount(7, 10) == 7)
	check("charge negative", a.chargeCount(-1, 10) == 0)
	check("charge nil", a.chargeCount(nil, 10) == nil)
	check("charge no max", a.chargeCount(4, nil) == 4)
	check("next progress seconds below 1 normalised", near(a.chargeNext(0.85, 3.4), 0.25))
	check("next progress no cooldown kept", near(a.chargeNext(0.4, nil), 0.4))
	check("next progress seconds normalised", near(a.chargeNext(1.7, 3.4), 0.5))
	check("next progress clamp", a.chargeNext(9, 3.4) == 1.0 and a.chargeNext(-1, 3.4) == 0.0)
	check("next progress >1 no cooldown", a.chargeNext(2, nil) == 1.0)
	check("full at 11/10 -> all ten pips lit", a.pipFill(10, a.chargeCount(11, 10), 0.0) == 1.0)
	check("pip count cur 11 / max 10 -> 11", a.pipCount(10, 10, 11) == 11)
	check("pip count max only", a.pipCount(10, nil, nil) == 10 and a.pipCount(nil, 8, 3) == 8)
	check("pip count unknown", a.pipCount(nil, nil, nil) == nil)
	check("s114 pip max ignores seen", a.pipMax(10, 10) == 10 and a.pipMax(nil, 8) == 8 and a.pipMax(nil, nil) == nil)
	check("s114 usable full 11 seen 11 max 10 -> 10", a.usable(11, 11, 10) == 10)
	check("s114 usable after a jump -> 9", a.usable(10, 11, 10) == 9)
	check("s114 usable last unusable charge -> 0", a.usable(1, 11, 10) == 0 and a.usable(0, 11, 10) == 0)
	check("s114 usable reserve before full was seen", a.usable(7, 7, 10) == 6 and a.usable(1, 1, 10) == 0)
	check("s114 usable nil", a.usable(nil, 11, 10) == nil and a.usable(4, nil, nil) == 3)
	do -- step 114 forearm anchor math
		local function nr(x, y) return math.abs(x - y) < 1e-4 end
		local p, y, r = a.swingRot(0, 1, 0, 0, 1, 0, 110)
		check("s114 swing none", nr(p, 0) and nr(y, 0) and nr(r, 0))
		p, y, r = a.swingRot(0, 1, 0, 1, 0, 0, 110) -- forearm turned onto +X: yaw -90
		check("s114 swing yaw", nr(p, 0) and nr(y, -90) and nr(r, 0))
		p, y, r = a.swingRot(0, 1, 0, 0, 0, 1, 110) -- onto +Z: roll 90 about X
		check("s114 swing roll axis", nr(p, 0) and nr(y, 0) and nr(math.abs(r), 90))
		p, y, r = a.swingRot(0, 1, 0, 1, 1, 0, 110)
		check("s114 swing 45", nr(y, -45))
		p, y, r = a.swingRot(0, 1, 0, 1, -1, 0, 90) -- 135 deg wanted, clamped at 90
		check("s114 swing clamp", nr(y, -90))
		p, y, r = a.swingRot(0, 1, 0, 0, -1, 0, 110)
		check("s114 swing opposite = none (degenerate)", nr(p, 0) and nr(y, 0) and nr(r, 0))
		-- shoulder at origin, wrist 40 cm ahead, arm 30 + 28, pole down: elbow below the line, both lengths kept
		local ex, ey, ez = a.elbowGuess(0, 0, 0, 40, 0, 0, 30, 28, 0, 0, -1)
		local lu = math.sqrt(ex * ex + ey * ey + ez * ez)
		local lf = math.sqrt((40 - ex) ^ 2 + ey * ey + ez * ez)
		check("s114 elbow lengths", nr(lu, 30) and nr(lf, 28) and ez < 0 and nr(ey, 0))
		ex, ey, ez = a.elbowGuess(0, 0, 0, 100, 0, 0, 30, 28, 0, 0, -1) -- out of reach: on the line
		check("s114 elbow out of reach on the line", ex > 25 and ex < 31 and math.abs(ez) < 1)
		ex, ey, ez = a.elbowGuess(0, 0, 0, 40, 0, 0, 30, 28, 1, 0, 0) -- pole along the arm: degenerate, on the line
		check("s114 elbow degenerate pole", nr(ey, 0) and nr(ez, 0))
	end
	do
		local cols, rows = {}, {}
		for k = 1, 11 do local c, r, cs = a.pipCell(k, 11) cols[k] = c rows[k] = r if k == 1 then cols.n1 = cs end if k == 11 then cols.n2 = cs end end
		check("11 pips: 6 + 5 in two rows", rows[6] == 1 and rows[7] == 2 and cols[7] == 1 and cols[11] == 5 and cols.n1 == 6 and cols.n2 == 5)
		local c, r, cs = a.pipCell(6, 6)
		check("6 pips: single row", c == 6 and r == 1 and cs == 6)
		check("row offsets inside gap", a.rowOffset(1, 2, 0.9) < 0 and a.rowOffset(2, 2, 0.9) > 0 and a.rowOffset(1, 1, 0.9) == 0
			and a.rowOffset(2, 2, 0.9) + a.pipWidth(2, 0.45, 0.9) / 2 < 0.9 / 2 + 0.01 + 0.0)
	end
	check("pipFill with 11 of 11", a.pipFill(11, 11, 0) == 1.0)
	check("pipFill refilling pip", near(a.pipFill(11, 10, 0.4), 0.4) and a.pipFill(10, 10, 0.4) == 1.0 and a.pipFill(12, 10, 0.4) == 0.0)
	check("continuous threshold", a.usePips(16) and not a.usePips(17) and not a.usePips(0) and not a.usePips(nil))
	check("next zero when a charge just landed", a.nextFor(5, 4, 3.0) == 0.0 and near(a.nextFor(5, 5, 0.3), 0.3) and a.nextFor(5, nil, 0.3) == 0.3)
	check("plate behind fill", a.FILL_Z - a.THICK / 2 > a.BG_Z + a.THICK / 2)
end
do -- tuning defaults
	local t = a.readTuning(function() return nil end, {})
	check("tuning defaults", t.len == a.DEFAULTS.len and t.yaw == a.DEFAULTS.yaw and t.gap == a.DEFAULTS.gap)
	t = a.readTuning(function(id) if id == "arm_hud_len" then return 10 end end, {})
	check("tuning slider", t.len == 10)
end
do -- step 89 compass swivel maths
	local function nr(x, y) return math.abs(x - y) < 1e-3 end
	local okR = true
	for _, t in ipairs({{0, 0, 0}, {30, 40, 50}, {-60, 170, -20}, {10, -100, 120}, {80, 20, -150}}) do
		local a1, a2, a3, b1, b2, b3 = a.rotAxes(t[1], t[2], t[3])
		local p, y, r = a.axesRot(a1, a2, a3, b1, b2, b3)
		local c1, c2, c3, d1, d2, d3 = a.rotAxes(p, y, r)
		if not (nr(a1, c1) and nr(a2, c2) and nr(a3, c3) and nr(b1, d1) and nr(b2, d2) and nr(b3, d3)) then okR = false end
	end
	check("rotAxes/axesRot round trip", okR)
	check("yaw 90 forward = +Y", select(2, a.rotAxes(0, 90, 0)) > 0.999)
	-- axis +X, face +Y, up +Z, viewer at +Z: face turns to +Z, up to -Y; the axis part of n is kept
	local n1, n2, n3, u1, u2, u3 = a.swivel(0, 1, 0, 0, 0, 1, 1, 0, 0, 5, 0, 3)
	check("swivel faces the viewer", nr(n1, 0) and nr(n2, 0) and nr(n3, 1) and nr(u2, -1) and nr(u3, 0))
	n1, n2, n3 = a.swivel(0.6, 0.8, 0, 0, 0, 1, 1, 0, 0, 0, 0, -2)
	check("swivel keeps the axis part", nr(n1, 0.6) and nr(n2, 0) and nr(n3, -0.8))
	n1 = a.swivel(0, 1, 0, 0, 0, 1, 1, 0, 0, 3, 0, 0)
	check("viewer on the axis: unchanged", nr(n1, 0))
end
do -- step 117 upper-arm anchors
	check("follow first = head", near(a.followYaw(nil, 50, 30, 540, 0.1, 20), 50))
	check("follow inside dead, no drift", near(a.followYaw(0, 20, 30, 540, 0.1, 0), 0))
	check("follow inside dead drifts", near(a.followYaw(0, 20, 30, 540, 0.1, 20), 2))
	check("follow beyond dead catches up", near(a.followYaw(0, 90, 30, 540, 1, 0), 60))
	check("follow beyond dead rate-limited", near(a.followYaw(0, 90, 30, 100, 0.1, 0), 10))
	check("follow wraps", near(a.followYaw(170, -170, 30, 540, 0.1, 20), 172))
	local function axes(p, y, r)
		local xx, xy, xz, zx, zy, zz = a.rotAxes(p, y, r)
		return xx, xy, xz, zx, zy, zz, zy * xz - zz * xy, zz * xx - zx * xz, zx * xy - zy * xx -- Y = Z x X
	end
	local function frame(ex, ey, ez, by, side, ff, ub, wy, wz)
		local _, _, _, zx, zy, zz, yx, yy, yz = axes(a.upperRot(0, 0, 0, ex, ey, ez, by, side, ff, ub))
		return near(yx, wy[1], 1e-5) and near(yy, wy[2], 1e-5) and near(yz, wy[3], 1e-5)
			and near(zx, wz[1], 1e-5) and near(zy, wz[2], 1e-5) and near(zz, wz[3], 1e-5)
	end
	check("right arm down: Y down, Z out right", frame(0, 0, -30, 0, 1, 0, 0, {0, 0, -1}, {0, 1, 0}))
	check("left arm down: Z out left", frame(0, 0, -30, 0, 0, 0, 0, {0, 0, -1}, {0, -1, 0}))
	local c, s30 = math.cos(math.rad(30)), math.sin(math.rad(30))
	check("face 30 deg forward", frame(0, 0, -30, 0, 1, 30, 0, {0, 0, -1}, {s30, c, 0}))
	check("body yaw 90: right = -X", frame(0, 0, -30, 90, 1, 0, 0, {0, 0, -1}, {-1, 0, 0}))
	local l = math.sqrt(1 + 0.09)
	check("arm forward: out + up bias", frame(30, 0, 0, 0, 1, 0, 0.3, {1, 0, 0}, {0, 1 / l, 0.3 / l}))
	check("arm out sideways: faces front", frame(0, 30, 0, 0, 1, 0, 0, {0, 1, 0}, {1, 0, 0}))
	check("zero-length arm: hangs down", frame(0, 0, 0, 0, 1, 0, 0, {0, 0, -1}, {0, 1, 0}))
	a.LOWER.on = false -- step 117-120 upper-arm mode
	local t = a.readTuning(function(id) if id == "arm_hud_upper" then return true end end, {})
	check("upper tuning mode 2 + defaults", t.fa == 2 and near(t.y, a.UPPER_DEFAULTS.y) and near(t.z, a.UPPER_DEFAULTS.z) and near(t.yaw, 90))
	t = a.readTuning(function(id) if id == "arm_hud_upper" or id == "arm_hud_forearm" then return true end if id == "arm_hud_ua_y" then return 20 end end, {})
	check("upper wins over forearm, old ua ids ignored (step 118)", t.fa == 2 and near(t.y, a.UPPER_DEFAULTS.y))
	t = a.readTuning(function(id) if id == "arm_hud_upper" then return true end if id == "arm_hud_l_y" then return 20 end if id == "arm_hud_l_roll" then return 15 end end, {})
	check("upper sliders arm_hud_l_* (step 119)", t.fa == 2 and near(t.y, 20) and near(t.roll, 15) and near(t.z, a.UPPER_DEFAULTS.z))
	do -- step 118: face toward a head point above and inside the left shoulder
		local p, y, r = a.upperRot(0, 0, 0, 0, 0, -30, 0, 0, 30, 0.3, 0, 20, 20)
		local _, _, _, zx, zy, zz = axes(p, y, r)
		check("upper face toward the head", near(zx, 0) and near(zy, 1) and near(zz, 0))
	end
	t = a.readTuning(function(id) if id == "arm_hud_upper" then return false end if id == "arm_hud_forearm" then return true end end, {})
	check("upper off: forearm mode", t.fa == 1)
	a.LOWER.on = true
end
do -- step 121: IK lower-arm anchor
	local t = a.readTuning(function(id) if id == "arm_hud_upper" then return true end if id == "arm_hud_l_y" then return 40 end end, {})
	check("lower: defaults, old arm_hud_l_* ignored", t.fa == 2 and near(t.y, a.LOWER_DEFAULTS.y) and near(t.z, a.LOWER_DEFAULTS.z) and near(t.yaw, a.LOWER_DEFAULTS.yaw))
	t = a.readTuning(function(id) if id == "arm_hud_upper" then return true end if id == "arm_hud_lf_y" then return 5 end if id == "arm_hud_lf_roll" then return 30 end end, {})
	check("lower sliders arm_hud_lf_*", t.fa == 2 and near(t.y, 5) and near(t.roll, 30))
	local x1, x2, x3 = a.boneAxis(0, 90, 0, "X")
	local y1, y2, y3 = a.boneAxis(0, 90, 0, "Y")
	local z1, z2, z3 = a.boneAxis(0, 90, 0, "Z")
	check("boneAxis yaw 90: X=+Y, Y=-X, Z=up", near(x2, 1, 1e-9) and near(y1, -1, 1e-9) and near(z3, 1, 1e-9) and near(x1, 0, 1e-9))
	-- forearm from wrist (0,0,0) to elbow (0,-30,0), bone axis tilted toward the forearm: Z = its part square to it
	local p, y, r = a.lowerRot(0, 0, 0, 0, -30, 0, 0, -0.5, 1)
	local fx, fy, fz, ux, uy, uz = a.rotAxes(p, y, r)
	local vy = uz * fx - ux * fz -- (Z x X).y
	check("lowerRot: +Y toward the elbow", near(vy, -1, 1e-6))
	check("lowerRot: +Z = axis square to the forearm", near(uz, 1, 1e-6) and near(uy, 0, 1e-6))
	check("lowerRot: axis along the forearm -> nil", a.lowerRot(0, 0, 0, 0, -30, 0, 0, 1, 0) == nil)
	check("lowerRot: zero forearm -> nil", a.lowerRot(0, 0, 0, 0, 0, 0.5, 0, 0, 1) == nil)
	-- step 122: lowerAxes = the lowerRot frame as axes; gloveFrame without IK -> nil
	local xx, xy, xz, yx, yy, yz, zx, zy, zz = a.lowerAxes(0, 0, 0, 0, -30, 0, 0, -0.5, 1)
	check("lowerAxes: Y toward the elbow", near(yx, 0) and near(yy, -1) and near(yz, 0))
	check("lowerAxes: Z square to the forearm", near(zx, 0) and near(zy, 0) and near(zz, 1))
	check("lowerAxes: X = Y x Z", near(xx, -1) and near(xy, 0) and near(xz, 0))
	local p2, y2, r2 = a.lowerRot(0, 0, 0, 0, -30, 0, 0, -0.5, 1)
	local q1, q2, q3 = a.axesRot(xx, xy, xz, zx, zy, zz)
	check("lowerRot = axesRot(lowerAxes)", near(p2, q1) and near(y2, q2) and near(r2, q3))
	check("lowerAxes: degenerate -> nil", a.lowerAxes(0, 0, 0, 0, -30, 0, 0, 1, 0) == nil)
	check("gloveFrame: no deps -> nil", a.gloveFrame(0) == nil)
end
print(string.format("qd_armhud: %d passed, %d failed", passed, failed))
return failed
