-- motion_melee.lua: swing detector for physical VR melee. Pure Lua, no game or UEVR dependency.
-- Feed it head and hand positions each tick (meters, tracking space). Numbers only, so it
-- allocates nothing per update. Design notes and credits: see REFERENCES.md in the project folder.
local M = {}

M.DEFAULTS = {
	fireSpeed = 2.0,    -- m/s: hand speed relative to the head that counts as swinging
	rearmSpeed = 1.2,   -- m/s: hand must slow below this before the next swing
	minTime = 0.05,     -- s above fireSpeed before a swing commits
	minTravel = 0.15,   -- m travelled above fireSpeed before a swing commits
	cooldown = 0.40,    -- s minimum between swings
	maxSpeed = 15.0,    -- m/s: faster is a tracking glitch, not a hand
	maxGap = 0.10,      -- s without fresh data: restart measuring
	inwardGate = 0.75,  -- ignore motion this directly toward the head (wind-up, pull back)
	upwardGate = 0.85,  -- ignore motion this directly upward (raising the weapon)
	lateFirePeak = 2.0, -- x fireSpeed: a stroke this fast that ended without firing (frame hitch broke its run)
	                    -- fires when it ends, if it travelled minTravel and no direction gate rejected it. 0 = off
}

local Detector = {}
Detector.__index = Detector

function M.new(overrides)
	local d = setmetatable({}, Detector)
	for k, v in pairs(M.DEFAULTS) do d[k] = v end
	if overrides then
		for k, v in pairs(overrides) do d[k] = v end
	end
	d:reset()
	return d
end

function Detector:resetRun()
	self.runTime = 0.0
	self.runTravel = 0.0
	self.runPeak = 0.0
	self.runOut = 0.0 -- m of the run's travel directed away from the head (stab measure)
	self.runDX, self.runDY, self.runDZ = 0.0, 0.0, 0.0 -- net displacement of the run (stroke direction)
end

-- Whole-stroke totals (not reset by data gaps; reset by direction gates, stroke end and fire)
function Detector:resetStroke()
	self.strokeTravel, self.strokeTime, self.strokeOut = 0.0, 0.0, 0.0
	self.strokeDX, self.strokeDY, self.strokeDZ = 0.0, 0.0, 0.0
end

function Detector:commit(travel, out, ndx, ndy, ndz)
	self.lastOutward = travel > 0.0 and out / travel or 0.0
	local net = math.sqrt(ndx * ndx + ndy * ndy + ndz * ndz)
	if net > 0.0 then
		self.lastDirX, self.lastDirY, self.lastDirZ = ndx / net, ndy / net, ndz / net
	else
		self.lastDirX, self.lastDirY, self.lastDirZ = 0.0, 0.0, 0.0
	end
	self.lastStraight = travel > 0.0 and net / travel or 0.0
	self.armed = false
	self.sinceFire = 0.0
	self.strokePeak = 0.0
	self.rejectReason = nil
	self.cooldownBlocked = false
	self:resetRun()
	self:resetStroke()
end

-- Forget everything, including the cooldown. Call when the position source jumps.
function Detector:reset()
	self:resetRun()
	self:resetStroke()
	self.lastLate = false -- last fired stroke used the late-fire rule
	self.hasLast = false
	self.lastX, self.lastY, self.lastZ = 0.0, 0.0, 0.0
	self.gap = 0.0
	self.armed = true
	self.sinceFire = self.cooldown
	self.strokePeak = 0.0
	self.rejectReason = nil
	self.missPeak = 0.0  -- set when a fast stroke ended without firing; caller clears it
	self.missReason = nil
	self.cooldownBlocked = false -- current stroke would have fired but for the cooldown
	self.lastOutward = 0.0 -- of the last fired stroke: share of travel away from the head (1 = straight thrust out, ~0 = sideways swing)
	self.lastDirX, self.lastDirY, self.lastDirZ = 0.0, 0.0, 0.0 -- of the last fired stroke: unit net direction (tracking space)
	self.lastStraight = 0.0 -- of the last fired stroke: net distance / path length (1 = straight line)
	self.speed = 0.0 -- latest measured hand speed relative to the head (m/s); 0 after a data gap
end

-- Returns fired, peakSpeed. peakSpeed is only meaningful when fired is true.
function Detector:update(dt, headX, headY, headZ, handX, handY, handZ)
	self.sinceFire = self.sinceFire + dt
	local x, y, z = handX - headX, handY - headY, handZ - headZ

	if not self.hasLast then
		self.hasLast = true
		self.lastX, self.lastY, self.lastZ = x, y, z
		self.gap = 0.0
		return false, 0.0
	end

	self.gap = self.gap + dt
	local dx, dy, dz = x - self.lastX, y - self.lastY, z - self.lastZ
	local distSq = dx * dx + dy * dy + dz * dz
	if distSq == 0.0 then
		-- Pose not refreshed this tick (alternate-eye rendering): measure across ticks.
		if self.gap > self.maxGap then self:resetRun() self.speed = 0.0 end
		return false, 0.0
	end

	local gap = self.gap
	self.gap = 0.0
	self.lastX, self.lastY, self.lastZ = x, y, z
	if gap > self.maxGap then
		self:resetRun()
		return false, 0.0
	end

	local dist = math.sqrt(distSq)
	local speed = dist / gap
	self.speed = speed

	if speed > self.maxSpeed then
		self:resetRun()
		self.rejectReason = "spike"
		return false, 0.0
	end

	if speed < self.rearmSpeed then
		local peak = self.strokePeak
		if peak > 0.0 and self.armed and self.rejectReason == nil and self.lateFirePeak > 0.0
			and peak >= self.fireSpeed * self.lateFirePeak and self.strokeTravel >= self.minTravel and self.sinceFire >= self.cooldown then
			self:commit(self.strokeTravel, self.strokeOut, self.strokeDX, self.strokeDY, self.strokeDZ)
			self.lastLate = true
			self.armed = true -- the stroke is already over: ready for the next one
			return true, peak
		end
		if peak > 0.0 then
			self.missPeak = peak
			self.missReason = self.rejectReason or (self.cooldownBlocked and "cooldown") or "short"
		end
		self.strokePeak = 0.0
		self.rejectReason = nil
		self.cooldownBlocked = false
		self.armed = true
		self:resetRun()
		self:resetStroke()
		return false, 0.0
	end

	if not self.armed or speed < self.fireSpeed then
		return false, 0.0
	end

	if speed > self.strokePeak then self.strokePeak = speed end

	-- Direction gates. A wind-up only restarts measuring, so it can flow into the strike.
	local radius = math.sqrt(x * x + y * y + z * z)
	if radius > 0.0 and (dx * x + dy * y + dz * z) / (dist * radius) < -self.inwardGate then
		self:resetRun()
		self:resetStroke()
		self.rejectReason = "inward"
		return false, 0.0
	end
	if dy / dist > self.upwardGate then
		self:resetRun()
		self:resetStroke()
		self.rejectReason = "upward"
		return false, 0.0
	end

	self.strokeTime = self.strokeTime + gap
	self.strokeTravel = self.strokeTravel + dist
	if radius > 0.0 then self.strokeOut = self.strokeOut + (dx * x + dy * y + dz * z) / radius end
	self.strokeDX, self.strokeDY, self.strokeDZ = self.strokeDX + dx, self.strokeDY + dy, self.strokeDZ + dz
	self.runTime = self.runTime + gap
	self.runTravel = self.runTravel + dist
	if radius > 0.0 then self.runOut = self.runOut + (dx * x + dy * y + dz * z) / radius end
	self.runDX, self.runDY, self.runDZ = self.runDX + dx, self.runDY + dy, self.runDZ + dz
	if speed > self.runPeak then self.runPeak = speed end

	if self.runTime >= self.minTime and self.runTravel >= self.minTravel and self.sinceFire >= self.cooldown then
		local peak = self.runPeak
		self:commit(self.runTravel, self.runOut, self.runDX, self.runDY, self.runDZ)
		self.lastLate = false
		return true, peak
	end
	-- step 15: a stroke that met time + travel but not the cooldown reports "cooldown", not "short", when it ends
	if self.runTime >= self.minTime and self.runTravel >= self.minTravel then self.cooldownBlocked = true end
	return false, 0.0
end

-- Charge haptics: feed the game's charge multiplier (1.0 = none) each tick.
-- update returns 0 = no pulse, 1 = step pulse (rose by `step`), 2 = cap reached (once per charge).
local ChargeHaptics = {}
ChargeHaptics.__index = ChargeHaptics
function M.newChargeHaptics(step, capEps, capTicks)
	local c = setmetatable({step = step or 0.05, capEps = capEps or 0.005, capTicks = capTicks or 10}, ChargeHaptics)
	c:reset()
	return c
end
function ChargeHaptics:reset()
	self.lastPulse = 1.0 -- multiplier at the last pulse
	self.peak = 1.0      -- highest multiplier this charge
	self.stillTicks = 0  -- ticks the multiplier has not risen (cap detection)
	self.capped = false
end
function ChargeHaptics:update(mult)
	if type(mult) ~= "number" then return 0 end
	if mult < self.peak - 0.01 then self:reset() end -- released / reset by the game
	if mult > self.peak + 1e-6 then
		self.peak = mult
		self.stillTicks = 0
		if mult - self.lastPulse >= self.step then
			self.lastPulse = mult
			return 1
		end
		return 0
	end
	-- not rising: cap once it was rising before and stays flat for capTicks ticks
	if self.peak > 1.0 + self.capEps and not self.capped then
		self.stillTicks = self.stillTicks + 1
		if self.stillTicks >= self.capTicks then
			self.capped = true
			return 2
		end
	end
	return 0
end

-- Rush buffer: a swing during a dash is held until `earliest` s into the dash (the game ignores
-- attacks pressed earlier). If the dash ends first, the swing fires at dash end (normal attack).
-- update(dt, dashing) returns true on the tick the buffered attack should fire.
local RushBuffer = {}
RushBuffer.__index = RushBuffer
function M.newRushBuffer(earliest, maxHold)
	local r = setmetatable({earliest = earliest or 0.6, maxHold = maxHold or 1.5}, RushBuffer)
	r:reset()
	return r
end
function RushBuffer:reset()
	self.dashTime = 0.0
	self.dashing = false
	self.pending = false
	self.held = 0.0
	self.lastWasRush = false -- the last fired attack fired inside the dash
end
-- Call when a swing is detected. Returns true if it should fire now (no buffering needed).
-- enabled=false (weapon has no rush attack, e.g. spear-type dashes accept attacks at once): never buffer.
function RushBuffer:swing()
	if not self.dashing or self.enabled == false then self.lastWasRush = false return true end
	if self.dashTime >= self.earliest then self.lastWasRush = true return true end
	self.pending = true
	self.held = 0.0
	return false
end
function RushBuffer:update(dt, dashing)
	if dashing then
		if not self.dashing then self.dashTime = 0.0 end
		self.dashing = true
		self.dashTime = self.dashTime + dt
	elseif self.dashing then
		self.dashing = false
		if self.pending then self.pending = false self.lastWasRush = false return true end
	end
	if self.pending then
		self.held = self.held + dt
		if self.held > self.maxHold then self.pending = false return false end
		if self.dashTime >= self.earliest then self.pending = false self.lastWasRush = true return true end
	end
	return false
end

-- step 14: decides a game PlayerHitboxState notify Begin while our hit window logic is armed. Returns skip, dash.
-- o: wingDash (notify flag), dashing (pawn.Dashing now), openDashing (at our open), openWhy, blockArmed, dt (s since
-- our open), block (HIT_BLOCK). A dash that began after our open owns its notify, except the L2 alt attack's own
-- lunge (spear): that dash starts ~0.05 s after our "L2 stab" window, which already covers the hit -> skip it.
function M.hitNotifyBegin(o)
	local dash = o.wingDash == true
	if o.dashing == true and not o.openDashing and o.openWhy ~= "L2 stab" then dash = true end
	local skip = (not dash) and o.blockArmed == true and (o.dt or 0) < (o.block or 1.5)
	return skip, dash
end

-- step 17: weapon glow for a charge. peak = charge multiplier (1.0 = none), capped = full charge reached.
-- Ramps to `ramp` of maxGlow over `span` multiplier; full charge = maxGlow with a slow pulse (t seconds).
function M.chargeGlow(peak, capped, maxGlow, t, span, ramp)
	span, ramp = span or 0.34, ramp or 0.6
	if capped then return maxGlow * (0.8 + 0.2 * math.sin((t or 0) * 8.0)) end
	local f = ((peak or 1.0) - 1.0) / span
	if f <= 0 then return 0.0 end
	if f > 1 then f = 1 end
	return maxGlow * ramp * f
end

return M
