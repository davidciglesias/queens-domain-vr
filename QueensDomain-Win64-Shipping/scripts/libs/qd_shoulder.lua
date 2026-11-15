-- qd_shoulder: right grip with the right hand at the right shoulder = D-pad right (the game's weapon switch; step 22).
-- Step 32: left grip with the left hand at the left shoulder = previous weapon: grip swallowed, then the tick calls
-- pawn.WeaponSelection:PreviousWeapon() (D-pad left does nothing in this game; verified Test 47).
-- While armed the grip is swallowed and the D-pad bit mirrors it until the grip is released.
local M = {}

M.SIDE_CM = 18.0   -- shoulder point (kept for reference/tests): this far right of the head
M.DROP_CM = 18.0   -- ... this far below it
M.BACK_CM = 4.0    -- ... and this far behind it
-- Step 38 (headset 2026-11-15: "anything past the shoulders"): the zone is a region, not a sphere. In head-yaw frame:
M.LAT_MIN_CM = 10.0  -- hand at least this far to that side of the head centre
M.FWD_MAX_CM = 8.0   -- ... and no further forward than this (behind / beside the body = past the shoulder)
M.WIDE_CM = 38.0     -- ... or arm out to the side: this far out, up to WIDE_FWD_CM forward
M.WIDE_FWD_CM = 30.0
M.LOW_CM = 36.0      -- ... and not lower than this below the eyes (keeps the belt / hips out)

M.NEXT_BIT = 0x0008 -- D-pad right
M.PREV_BIT = 0x0000 -- no button: previous weapon is a direct call (see tick)

-- pure: shoulder point for head position + yaw (UE: yaw 0 faces +X, right = +Y at yaw 0); side 1 right (default), -1 left
function M.shoulderPos(hx, hy, hz, yawDeg, side)
	local r = math.rad(yawDeg)
	local fx, fy = math.cos(r), math.sin(r)
	local k = side or 1
	local rx, ry = -fy * k, fx * k
	return hx + rx * M.SIDE_CM - fx * M.BACK_CM, hy + ry * M.SIDE_CM - fy * M.BACK_CM, hz - M.DROP_CM
end

-- pure: is the hand point past the shoulder on that side? (head position + yaw; side 1 right, -1 left)
function M.inZone(px, py, pz, hx, hy, hz, yawDeg, side)
	if pz - hz < -M.LOW_CM then return false end
	local r = math.rad(yawDeg)
	local fx, fy = math.cos(r), math.sin(r)
	local k = side or 1
	local dx, dy = px - hx, py - hy
	local f = dx * fx + dy * fy
	local l = (dx * -fy + dy * fx) * k
	if l < M.LAT_MIN_CM then return false end
	if f <= M.FWD_MAX_CM then return true end
	return l >= M.WIDE_CM and f <= M.WIDE_FWD_CM
end

-- pure: one xinput step. Returns new buttons, armed. Fresh grip press in zone arms; armed swallows grip and holds D-pad right.
function M.step(buttons, gripBit, dpadBit, inZoneNow, wasPressed, armed)
	local grip = (buttons & gripBit) ~= 0
	if not armed and grip and not wasPressed and inZoneNow then armed = true end
	if armed and not grip then armed = false end
	if armed then buttons = (buttons & ~gripBit) | dpadBit end
	return buttons, armed
end

local D = nil
local S = {inZone = false, armed = false, prevGrip = false, inZoneL = false, armedL = false, prevGripL = false}
M.S = S

function M.init(deps) D = deps end
local function enabled() return D ~= nil and D.configui.getValue("shoulder_switch") ~= false end

function M.onXInput(state)
	if not enabled() then S.armed = false S.armedL = false return end
	local b = state.Gamepad.wButtons
	local grip = (b & XINPUT_GAMEPAD_RIGHT_SHOULDER) ~= 0
	local gripL = (b & XINPUT_GAMEPAD_LEFT_SHOULDER) ~= 0
	local wasArmed, wasArmedL = S.armed, S.armedL
	b, S.armed = M.step(b, XINPUT_GAMEPAD_RIGHT_SHOULDER, M.NEXT_BIT, S.inZone, S.prevGrip, S.armed)
	b, S.armedL = M.step(b, XINPUT_GAMEPAD_LEFT_SHOULDER, M.PREV_BIT, S.inZoneL, S.prevGripL, S.armedL)
	state.Gamepad.wButtons = b
	S.prevGrip, S.prevGripL = grip, gripL
	if S.armed and not wasArmed and D.log ~= nil then D.log("[SHOULDER] next weapon") end
	if S.armedL and not wasArmedL then S.prevPending = true if D.log ~= nil then D.log("[SHOULDER] previous weapon") end end
end

-- per tick: zone test (no allocation), haptic tick on entering the zone
function M.tick(dt)
	if not enabled() then S.inZone = false S.inZoneL = false S.prevPending = false return end
	if S.prevPending then
		S.prevPending = false
		local ok, err = pcall(function() uevr.api:get_local_pawn(0).WeaponSelection:PreviousWeapon() end)
		if not ok and D.log ~= nil then D.log("[SHOULDER] PreviousWeapon failed: " .. tostring(err)) end
	end
	local head, rh, lh = D.controllers.getController(2), D.controllers.getController(1), D.controllers.getController(0)
	if head == nil then S.inZone = false S.inZoneL = false return end
	local hp, hr = head:K2_GetComponentLocation(), head:K2_GetComponentRotation()
	local z = false
	if rh ~= nil then local p = rh:K2_GetComponentLocation() z = M.inZone(p.X, p.Y, p.Z, hp.X, hp.Y, hp.Z, hr.Yaw, 1) end
	if z and not S.inZone then pcall(D.uevrUtils.triggerHapticVibration, Handed.Right, 0, 0.03, 150, 0.3) end
	S.inZone = z
	local zl = false
	if lh ~= nil then local p = lh:K2_GetComponentLocation() zl = M.inZone(p.X, p.Y, p.Z, hp.X, hp.Y, hp.Z, hr.Yaw, -1) end
	if zl and not S.inZoneL then pcall(D.uevrUtils.triggerHapticVibration, Handed.Left, 0, 0.03, 150, 0.3) end
	S.inZoneL = zl
end

function M.reset() S.inZone = false S.armed = false S.inZoneL = false S.armedL = false S.prevPending = false end

return M
