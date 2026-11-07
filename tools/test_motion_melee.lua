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

print(string.format("%d passed, %d failed", passed, failed))
return failed
