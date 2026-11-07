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
end

-- Forget everything, including the cooldown. Call when the position source jumps.
function Detector:reset()
	self:resetRun()
	self.hasLast = false
	self.lastX, self.lastY, self.lastZ = 0.0, 0.0, 0.0
	self.gap = 0.0
	self.armed = true
	self.sinceFire = self.cooldown
	self.strokePeak = 0.0
	self.rejectReason = nil
	self.missPeak = 0.0  -- set when a fast stroke ended without firing; caller clears it
	self.missReason = nil
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
		if self.gap > self.maxGap then self:resetRun() end
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

	if speed > self.maxSpeed then
		self:resetRun()
		self.rejectReason = "spike"
		return false, 0.0
	end

	if speed < self.rearmSpeed then
		if self.strokePeak > 0.0 then
			self.missPeak = self.strokePeak
			self.missReason = self.rejectReason or "short"
		end
		self.strokePeak = 0.0
		self.rejectReason = nil
		self.armed = true
		self:resetRun()
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
		self.rejectReason = "inward"
		return false, 0.0
	end
	if dy / dist > self.upwardGate then
		self:resetRun()
		self.rejectReason = "upward"
		return false, 0.0
	end

	self.runTime = self.runTime + gap
	self.runTravel = self.runTravel + dist
	if speed > self.runPeak then self.runPeak = speed end

	if self.runTime >= self.minTime and self.runTravel >= self.minTravel and self.sinceFire >= self.cooldown then
		local peak = self.runPeak
		self.armed = false
		self.sinceFire = 0.0
		self.strokePeak = 0.0
		self.rejectReason = nil
		self:resetRun()
		return true, peak
	end
	return false, 0.0
end

return M
