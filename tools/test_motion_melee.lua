-- Unit tests on synthetic samples. Run: python tools/run_tests.py
local mm = require("motion_melee")

local failed, passed = 0, 0
local function check(name, cond)
	if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end

-- Moves the hand at a constant velocity from (0.4, 0, 0) for `secs`, head at origin.
-- Returns fire count and last fired peak; the hand ends where it stopped, kept in d.pos.
local function run(d, secs, vx, vy, vz, hz, startX, startY, startZ, headVX)
	local dt = 1.0 / (hz or 90)
	local n = math.floor(secs / dt + 0.5)
	local x, y, z = startX or 0.4, startY or 0.0, startZ or 0.0
	local hx = 0.0
	local fires, peak = 0, 0.0
	for _ = 1, n do
		x, y, z = x + vx * dt, y + vy * dt, z + vz * dt
		hx = hx + (headVX or 0.0) * dt
		local f, p = d:update(dt, hx, 0.0, 0.0, x, y, z)
		if f then fires = fires + 1; peak = p end
	end
	d.pos = {x, y, z}
	return fires, peak
end
local function fresh(o) local d = mm.new(o); d:update(1 / 90, 0, 0, 0, 0.4, 0, 0); return d end

do -- a normal sideways swing fires exactly once and reports its speed
	local d = fresh()
	local f, p = run(d, 0.3, 0, 0, -4.0)
	check("swing fires once", f == 1)
	check("swing speed reported", math.abs(p - 4.0) < 0.01)
end
for _, hz in ipairs({45, 60, 72, 90, 120}) do
	check("fires at " .. hz .. " Hz", run(fresh(), 0.3, 0, 0, -4.0, hz) == 1)
end
do -- slow movement never fires
	check("slow reach", run(fresh(), 2.0, 0, 0, -1.0) == 0)
end
do -- a brief flick is too short (speed reached, travel not)
	local d = fresh()
	check("short flick", run(d, 0.04, 0, 0, -3.0) == 0)
	run(d, 0.3, 0, 0, 0.1, 90, d.pos[1], d.pos[2], d.pos[3])
	check("short flick reported as miss", d.missPeak > 2.9 and d.missReason == "short")
end
do -- one-frame tracking jump is not a swing
	local d = fresh()
	local f = d:update(1 / 90, 0, 0, 0, 5.4, 0, 0)
	check("tracking spike", f == false and d.rejectReason == "spike")
	check("nothing after spike", run(d, 0.2, 0, 0, -0.1, 90, 5.4) == 0)
end
do -- moving with the hand (walking in the room, leaning) does not count
	check("body carry", run(fresh(), 0.5, 3.0, 0, 0, 90, 0.4, 0, 0, 3.0) == 0)
end
do -- no second attack until the hand slows down
	local d = fresh()
	check("long fast stroke one fire", run(d, 1.5, 0, 0, -4.0) == 1)
	local d2 = fresh()
	run(d2, 0.3, 0, 0, -4.0)
	local z = d2.pos[3]
	run(d2, 0.2, 0, 0, 0.5, 90, 0.4, 0, z)
	check("second swing after rearm", run(d2, 0.3, 0, 0, 4.0, 90, 0.4, 0, z + 0.1) == 1)
end
do -- cooldown blocks a fast re-swing, then lets it through
	local d = fresh({cooldown = 1.0})
	run(d, 0.15, 0, 0, -4.0)
	local z = d.pos[3]
	run(d, 0.05, 0, 0, 0.5, 90, 0.4, 0, z)
	check("cooldown blocks", run(d, 0.2, 0, 0, 4.0, 90, 0.4, 0, z) == 0)
	run(d, 0.8, 0, 0, 0.5, 90, 0.4, 0, z)
	check("cooldown expires", run(d, 0.3, 0, 0, 4.0, 90, 0.4, 0, z) == 1)
end
do -- step 15: a fast stroke cut off by the cooldown ends as a "cooldown" miss (flurry diagnosis)
	local d = fresh({cooldown = 1.0})
	run(d, 0.15, 0, 0, -4.0)
	run(d, 0.05, 0, 0, 0.5, 90, d.pos[1], d.pos[2], d.pos[3])
	run(d, 0.2, 4.0, 0, 0, 90, d.pos[1], d.pos[2], d.pos[3]) -- outward (a +z return would be "inward", +y "upward")
	run(d, 0.1, 0, 0, 0.5, 90, d.pos[1], d.pos[2], d.pos[3])
	check("cooldown-blocked stroke reported as cooldown", d.missReason == "cooldown" and d.missPeak > 3.9)
	run(d, 0.04, 0, 0, -3.0, 90, d.pos[1], d.pos[2], d.pos[3])
	run(d, 0.1, 0, 0, 0.5, 90, d.pos[1], d.pos[2], d.pos[3])
	check("short stroke after a cooldown miss stays short", d.missReason == "short")
end
do -- wind-up toward the head is ignored but flows straight into the strike
	local d = mm.new()
	d:update(1 / 90, 0, 0, 0, 0.6, 0, 0)
	check("pull back ignored", run(d, 0.1, -4.0, 0, 0, 90, 0.6) == 0)
	check("pull back reason", d.rejectReason == "inward")
	check("strike after wind-up", run(d, 0.2, 0, 0, -4.0, 90, d.pos[1]) == 1)
end
do -- raising the weapon is ignored; bringing it down is a swing
	local d = fresh()
	check("raise ignored", run(d, 0.2, 0, 4.0, 0) == 0)
	check("chop fires", run(d, 0.2, 0, -4.0, 0, 90, 0.4, d.pos[2]) == 1)
end
do -- pose refreshing every second tick (alternate-eye) measures the same speed
	local d = mm.new()
	local dt, x, z, fires, peak = 1 / 180, 0.4, 0.0, 0, 0.0
	d:update(dt, 0, 0, 0, x, 0, z)
	for i = 1, 60 do
		if i % 2 == 0 then z = z - 4.0 * 2 * dt end
		local f, p = d:update(dt, 0, 0, 0, x, 0, z)
		if f then fires = fires + 1; peak = p end
	end
	check("alternate eye fires once", fires == 1)
	check("alternate eye speed", math.abs(peak - 4.0) < 0.01)
end
do -- a hitch restarts measuring rather than reading as a swing
	local d = fresh()
	local f = d:update(0.5, 0, 0, 0, 0.4, 0, -0.5)
	check("hitch no fire", f == false and d.runTime == 0.0)
end
do -- settings changed live take effect
	local d = fresh()
	d.fireSpeed = 5.0
	check("raised threshold blocks", run(d, 0.3, 0, 0, -4.0) == 0)
end
do -- reset allows firing again at once
	local d = fresh()
	run(d, 0.3, 0, 0, -4.0)
	d:reset()
	d:update(1 / 90, 0, 0, 0, 0.4, 0, 0)
	check("fires after reset", run(d, 0.3, 0, 0, -4.0) == 1)
end
do -- a forward thrust from low by the body reads as outward (stab); a sideways swing does not
	local d = mm.new()
	d:update(1 / 90, 0, 0, 0, 0.15, -0.25, 0)
	check("thrust fires", run(d, 0.2, 3.0, 0, 0, 90, 0.15, -0.25, 0) == 1)
	check("thrust outward " .. string.format("%.2f", d.lastOutward), d.lastOutward > 0.5)
	local d2 = fresh()
	run(d2, 0.3, 0, 0, -4.0)
	check("sideways swing not outward " .. string.format("%.2f", d2.lastOutward), d2.lastOutward < 0.4)
	local d3 = mm.new()
	d3:update(1 / 90, 0, 0, 0, 0.3, 0.3, 0)
	check("chop not outward", run(d3, 0.2, 0, -4.0, 0, 90, 0.3, 0.3) == 1 and d3.lastOutward < 0.4)
end
do -- net stroke direction + straightness (stab axis check uses them)
	local d = mm.new()
	d:update(1 / 90, 0, 0, 0, 0.15, -0.25, 0)
	run(d, 0.2, 3.0, 0, 0, 90, 0.15, -0.25, 0)
	check("thrust dir along +x " .. string.format("%.2f", d.lastDirX), d.lastDirX > 0.99)
	check("thrust straight " .. string.format("%.2f", d.lastStraight), d.lastStraight > 0.99)
	local d2 = fresh()
	run(d2, 0.3, 0, 0, -4.0)
	check("sideways dir along -z", d2.lastDirZ < -0.99 and math.abs(d2.lastDirX) < 0.01)
end
do -- live speed (hit window closes when it drops), cleared by a data gap
	local d = fresh()
	run(d, 0.1, 0, 0, -4.0)
	check("speed tracks hand " .. string.format("%.2f", d.speed), math.abs(d.speed - 4.0) < 0.05)
	for _ = 1, 20 do d:update(1 / 90, 0, 0, 0, 0.4, 0, 0.5) end
	check("speed 0 after gap", d.speed == 0.0)
end
do -- no allocation in the hot path
	local d = fresh()
	collectgarbage("collect")
	collectgarbage("stop")
	local before = collectgarbage("count")
	local z = 0.0
	for i = 1, 20000 do
		z = z + (i % 50 < 25 and -0.05 or 0.002)
		d:update(1 / 90, 0.0, 0.0, 0.0, 0.4, 0.0, z)
	end
	local grew = collectgarbage("count") - before
	collectgarbage("restart")
	check("no allocation (grew " .. grew .. " KB)", grew < 1.0)
end

-- test 20: late fire. A frame hitch (gap > maxGap) restarts the run, so a fast stroke can end "short";
-- if its peak is >= lateFirePeak x fireSpeed and the whole stroke travelled minTravel, it fires when it ends.
local function hitchStroke(d, speed, startX, dirX, dirZ)
	local x, z, fires, peak = startX, 0.0, 0, 0.0
	local function step(dt, dist)
		x, z = x + dirX * dist, z + dirZ * dist
		local f, p = d:update(dt, 0, 0, 0, x, 0, z)
		if f then fires = fires + 1 peak = p end
	end
	step(1 / 90, speed / 90) step(1 / 90, speed / 90) -- 2 fast frames (run too short to commit)
	step(0.15, speed * 0.15)                         -- hitch: one 150 ms frame (run restarts)
	step(1 / 90, speed / 90) step(1 / 90, speed / 90) -- 2 more fast frames
	for _ = 1, 5 do step(1 / 90, 0.0005) end         -- stop
	return fires, peak
end
do
	local d = fresh()
	local f, p = hitchStroke(d, 5.0, 0.4, 0.0, -1.0)
	check("late fire: fast stroke broken by a hitch fires once", f == 1 and d.lastLate == true and math.abs(p - 5.0) < 0.01)
	check("late fire: stroke direction kept", d.lastDirZ < -0.99)
end
do
	local d = fresh()
	local f = hitchStroke(d, 3.0, 0.4, 0.0, -1.0)
	check("late fire: below 2x fireSpeed stays a miss", f == 0 and d.missReason == "short")
end
do
	local d = fresh()
	local f = hitchStroke(d, 6.0, 0.6, -1.0, 0.0) -- straight toward the head: wind-up gate
	check("late fire: never for gated (inward) strokes", f == 0)
end
do
	local d = fresh({lateFirePeak = 0})
	local f = hitchStroke(d, 5.0, 0.4, 0.0, -1.0)
	check("late fire: lateFirePeak 0 disables it", f == 0)
end
do -- a normal swing still commits early (not late)
	local d = fresh()
	local f = run(d, 0.3, 0, 0, -4.0)
	check("normal swing is not a late fire", f == 1 and d.lastLate == false)
end

do -- charge haptics: delay at 1.0, linear rise, cap at 1.333 (D2 curve)
	local c = mm.newChargeHaptics(0.05)
	local steps, caps, capAt = 0, 0, nil
	local dt = 1 / 90
	for i = 1, math.floor(4.5 / dt) do
		local t = i * dt
		local m = t < 0.4 and 1.0 or math.min(1.333, 1.0 + (t - 0.4) * 0.11)
		local r = c:update(m)
		if r == 1 then steps = steps + 1 elseif r == 2 then caps = caps + 1; capAt = capAt or t end
	end
	check("charge: step pulses while rising", steps == 6)
	check("charge: one cap pulse", caps == 1 and capAt and capAt > 3.4 and capAt < 3.6)
	check("charge: no pulse at 1.0 hold", mm.newChargeHaptics():update(1.0) == 0)
	c:update(1.0) -- release resets
	check("charge: reset on release", c.peak == 1.0 and not c.capped)
	check("charge: nil multiplier ignored", c:update(nil) == 0)
end
do -- rush buffer
	local dt = 1 / 90
	local function dash(r, len, swingAt)
		local firedAt
		for i = 1, math.floor(1.5 / dt) do
			local t = i * dt
			if math.abs(t - swingAt) < dt / 2 and r:swing() then firedAt = t end
			if r:update(dt, t <= len) then firedAt = firedAt or t end
		end
		return firedAt
	end
	check("rush: no dash fires at once", mm.newRushBuffer(0.6):swing() == true)
	local r = mm.newRushBuffer(0.6)
	local t = dash(r, 0.85, 0.2)
	check("rush: early swing buffered to earliest", t and t >= 0.6 and t < 0.62 and r.lastWasRush)
	r = mm.newRushBuffer(0.6)
	t = dash(r, 0.85, 0.7)
	check("rush: late swing fires immediately", t and math.abs(t - 0.7) < dt and r.lastWasRush)
	r = mm.newRushBuffer(0.6)
	t = dash(r, 0.4, 0.2)
	check("rush: short dash fires at dash end", t and t > 0.4 and t < 0.42 and not r.lastWasRush)
	r = mm.newRushBuffer(0.6, 0.1)
	t = dash(r, 0.85, 0.2)
	check("rush: maxHold drops a stale swing", t == nil)
	r = mm.newRushBuffer(0.6) r.enabled = false
	t = dash(r, 0.33, 0.1)
	check("rush: disabled (spear-type) fires at once in the dash", t and math.abs(t - 0.1) < dt and not r.lastWasRush)
	r = mm.newRushBuffer(0.6) r.enabled = false
	t = dash(r, 0.85, 0.2)
	check("rush: disabled never buffers", t and math.abs(t - 0.2) < dt and not r.pending)
end

do -- step 14: game hit-notify decision
	local function d(o) o.block = 1.5 if o.blockArmed == nil then o.blockArmed = true end return mm.hitNotifyBegin(o) end
	local skip, dash = d({dashing = true, openDashing = false, openWhy = "L2 stab", dt = 0.04})
	check("notify: L2 lunge dash notify skipped", skip and not dash)
	skip, dash = d({dashing = true, openDashing = false, openWhy = "swing", dt = 0.04})
	check("notify: dash begun after a swing passes", not skip and dash)
	skip, dash = d({dashing = true, openDashing = true, openWhy = "swing", dt = 0.3})
	check("notify: swing made during a dash skips", skip and not dash)
	skip, dash = d({wingDash = true, openWhy = "L2 stab", dt = 0.04})
	check("notify: wing dash hitbox always passes", not skip and dash)
	skip = d({openWhy = "swing", dt = 0.4})
	check("notify: plain late window skipped", skip)
	skip = d({openWhy = "swing", dt = 1.6})
	check("notify: after HIT_BLOCK passes", not skip)
	skip = d({openWhy = "L2 stab", dt = 0.04, blockArmed = false, dashing = true})
	check("notify: not armed passes", not skip)
end

do -- step 17: charge glow
	local g = mm.chargeGlow
	check("glow: none", g(1.0, false, 3) == 0)
	check("glow: half ramp", math.abs(g(1.17, false, 3) - 0.9) < 1e-6)
	check("glow: ramp clamps", math.abs(g(2.0, false, 3) - 1.8) < 1e-6)
	local v = g(1.3, true, 3, 0.2)
	check("glow: capped near max", v >= 2.4 - 1e-6 and v <= 3.0 + 1e-6)
	check("glow: nil peak", g(nil, false, 3) == 0)
end

print(string.format("%d passed, %d failed", passed, failed))
return failed
