-- qd_shoulder: right grip with the right hand at the right shoulder = D-pad right (the game's weapon switch; step 22).
-- While armed the grip is swallowed and D-pad right mirrors it until the grip is released.
local M = {}

M.SIDE_CM = 18.0   -- shoulder: this far right of the head
M.DROP_CM = 18.0   -- ... this far below it
M.BACK_CM = 4.0    -- ... and this far behind it
M.ZONE_CM = 16.0   -- hand within this distance of the shoulder point is "at the shoulder"

-- pure: shoulder point for head position + yaw (UE: yaw 0 faces +X, right = +Y at yaw 0)
function M.shoulderPos(hx, hy, hz, yawDeg)
	local r = math.rad(yawDeg)
	local fx, fy = math.cos(r), math.sin(r)
	local rx, ry = -fy, fx
	return hx + rx * M.SIDE_CM - fx * M.BACK_CM, hy + ry * M.SIDE_CM - fy * M.BACK_CM, hz - M.DROP_CM
end

-- pure: is hand point within the zone?
function M.inZone(px, py, pz, hx, hy, hz, yawDeg)
	local sx, sy, sz = M.shoulderPos(hx, hy, hz, yawDeg)
	local dx, dy, dz = px - sx, py - sy, pz - sz
	return dx * dx + dy * dy + dz * dz <= M.ZONE_CM * M.ZONE_CM
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
local S = {inZone = false, armed = false, prevGrip = false}
M.S = S

function M.init(deps) D = deps end
local function enabled() return D ~= nil and D.configui.getValue("shoulder_switch") ~= false end

function M.onXInput(state)
	if not enabled() then S.armed = false return end
	local b = state.Gamepad.wButtons
	local grip = (b & XINPUT_GAMEPAD_RIGHT_SHOULDER) ~= 0
	local wasArmed = S.armed
	state.Gamepad.wButtons, S.armed = M.step(b, XINPUT_GAMEPAD_RIGHT_SHOULDER, 0x0008, S.inZone, S.prevGrip, S.armed)
	S.prevGrip = grip
	if S.armed and not wasArmed and D.log ~= nil then D.log("[SHOULDER] weapon switch") end
end

-- per tick: zone test (no allocation), haptic tick on entering the zone
function M.tick(dt)
	if not enabled() then S.inZone = false return end
	local head, rh = D.controllers.getController(2), D.controllers.getController(1)
	if head == nil or rh == nil then S.inZone = false return end
	local hp, hr, p = head:K2_GetComponentLocation(), head:K2_GetComponentRotation(), rh:K2_GetComponentLocation()
	local z = M.inZone(p.X, p.Y, p.Z, hp.X, hp.Y, hp.Z, hr.Yaw)
	if z and not S.inZone then pcall(D.uevrUtils.triggerHapticVibration, Handed.Right, 0, 0.03, 150, 0.3) end
	S.inZone = z
end

function M.reset() S.inZone = false S.armed = false end

return M
