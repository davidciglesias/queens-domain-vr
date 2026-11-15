-- qd_shoulder: right grip with the right hand at the right shoulder = D-pad right (the game's weapon switch; step 22).
-- Step 32/41: right grip with the right hand at the LEFT shoulder (reach across) = previous weapon: grip swallowed, then
-- the tick calls pawn.WeaponSelection:PreviousWeapon() (D-pad left does nothing in this game; verified Test 47).
-- Step 45: the LEFT hand mirrors it for throwables: left grip past the left shoulder = previous throwable, reach across
-- past the right shoulder = next (pawn "Select Previous DaggerType" / "Select Next Dagger Type", called from the tick).
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

-- pure: forward / lateral (toward that side) cm of the hand from the head, head-yaw frame (diagnostics, step 41)
function M.fwdLat(px, py, hx, hy, yawDeg, side)
	local r = math.rad(yawDeg)
	local fx, fy = math.cos(r), math.sin(r)
	local dx, dy = px - hx, py - hy
	return dx * fx + dy * fy, (dx * -fy + dy * fx) * (side or 1)
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
local S = {fR = 0, lR = 0, zR = 0, fX = 0, lX = 0, inZone = false, armed = false, prevGrip = false, inZoneX = false, armedX = false,
	fL = 0, lL = 0, fLX = 0, lLX = 0, zL = 0, inZoneL = false, armedL = false, inZoneLX = false, armedLX = false, prevGripL = false, daggerPending = 0}
M.S = S

function M.init(deps) D = deps end
local function enabled() return D ~= nil and D.configui.getValue("shoulder_switch") ~= false end

function M.onXInput(state)
	if not enabled() then S.armed = false S.armedX = false S.armedL = false S.armedLX = false return end
	local b = state.Gamepad.wButtons
	local grip = (b & XINPUT_GAMEPAD_RIGHT_SHOULDER) ~= 0
	local gripL = (b & XINPUT_GAMEPAD_LEFT_SHOULDER) ~= 0
	local wasArmed, wasArmedX = S.armed, S.armedX
	local wasArmedL, wasArmedLX = S.armedL, S.armedLX
	-- left hand, throwables (step 45): own-side zone = previous, reach across = next; armed grip never reaches the game (no throw)
	b, S.armedL = M.step(b, XINPUT_GAMEPAD_LEFT_SHOULDER, M.PREV_BIT, S.inZoneL, S.prevGripL, S.armedL)
	b, S.armedLX = M.step(b, XINPUT_GAMEPAD_LEFT_SHOULDER, M.PREV_BIT, S.inZoneLX, S.prevGripL, S.armedLX)
	if S.armedL then S.armedLX = false end
	if D.log ~= nil and gripL and not S.prevGripL then
		D.log(string.format("[SHOULDER] grip L left=%s (fwd=%.0f lat=%.0f) right=%s (fwd=%.0f lat=%.0f) dz=%.0f",
			tostring(S.inZoneL), S.fL, S.lL, tostring(S.inZoneLX), S.fLX, S.lLX, S.zL))
	end
	S.prevGripL = gripL
	if S.armedL and not wasArmedL then S.daggerPending = -1 if D.log ~= nil then D.log("[SHOULDER] previous throwable") end end
	if S.armedLX and not wasArmedLX then S.daggerPending = 1 if D.log ~= nil then D.log("[SHOULDER] next throwable") end end
	-- zones are disjoint (lateral sign), so at most one arms; once armed the grip is swallowed and the other step disarms
	b, S.armed = M.step(b, XINPUT_GAMEPAD_RIGHT_SHOULDER, M.NEXT_BIT, S.inZone, S.prevGrip, S.armed)
	b, S.armedX = M.step(b, XINPUT_GAMEPAD_RIGHT_SHOULDER, M.PREV_BIT, S.inZoneX, S.prevGrip, S.armedX)
	if S.armed then S.armedX = false end
	state.Gamepad.wButtons = b
	if D.log ~= nil and grip and not S.prevGrip then -- step 41 diag: every fresh right grip
		D.log(string.format("[SHOULDER] grip R right=%s (fwd=%.0f lat=%.0f) left=%s (fwd=%.0f lat=%.0f) dz=%.0f",
			tostring(S.inZone), S.fR, S.lR, tostring(S.inZoneX), S.fX, S.lX, S.zR))
	end
	S.prevGrip = grip
	if S.armed and not wasArmed and D.log ~= nil then D.log("[SHOULDER] next weapon") end
	if S.armedX and not wasArmedX then S.prevPending = true if D.log ~= nil then D.log("[SHOULDER] previous weapon") end end
end

-- per tick: zone test (no allocation), haptic tick on entering the zone
function M.tick(dt)
	if not enabled() then S.inZone = false S.inZoneX = false S.inZoneL = false S.inZoneLX = false S.prevPending = false S.daggerPending = 0 return end
	if S.daggerPending ~= 0 then
		local dir = S.daggerPending
		S.daggerPending = 0
		local ok, err = pcall(function()
			local pawn = uevr.api:get_local_pawn(0)
			if dir < 0 then pawn["Select Previous DaggerType"](pawn) else pawn["Select Next Dagger Type"](pawn) end -- real names have spaces (SDK dump shows _)
		end)
		if not ok and D.log ~= nil then D.log("[SHOULDER] dagger select failed: " .. tostring(err)) end
	end
	if S.prevPending then
		S.prevPending = false
		local ok, err = pcall(function() uevr.api:get_local_pawn(0).WeaponSelection:PreviousWeapon() end)
		if not ok and D.log ~= nil then D.log("[SHOULDER] PreviousWeapon failed: " .. tostring(err)) end
	end
	local head, rh, lh = D.controllers.getController(2), D.controllers.getController(1), D.controllers.getController(0)
	if head == nil or rh == nil then S.inZone = false S.inZoneX = false S.inZoneL = false S.inZoneLX = false return end
	local hp, hr = head:K2_GetComponentLocation(), head:K2_GetComponentRotation()
	local p = rh:K2_GetComponentLocation()
	S.fR, S.lR = M.fwdLat(p.X, p.Y, hp.X, hp.Y, hr.Yaw, 1)
	S.fX, S.lX = M.fwdLat(p.X, p.Y, hp.X, hp.Y, hr.Yaw, -1)
	S.zR = p.Z - hp.Z
	local z = M.inZone(p.X, p.Y, p.Z, hp.X, hp.Y, hp.Z, hr.Yaw, 1)
	local zx = M.inZone(p.X, p.Y, p.Z, hp.X, hp.Y, hp.Z, hr.Yaw, -1) -- right hand reached across to the left shoulder
	if (z and not S.inZone) or (zx and not S.inZoneX) then pcall(D.uevrUtils.triggerHapticVibration, Handed.Right, 0, 0.03, 150, 0.3) end
	S.inZone, S.inZoneX = z, zx
	if lh == nil then S.inZoneL = false S.inZoneLX = false return end
	p = lh:K2_GetComponentLocation()
	S.fL, S.lL = M.fwdLat(p.X, p.Y, hp.X, hp.Y, hr.Yaw, -1)
	S.fLX, S.lLX = M.fwdLat(p.X, p.Y, hp.X, hp.Y, hr.Yaw, 1)
	S.zL = p.Z - hp.Z
	local zl = M.inZone(p.X, p.Y, p.Z, hp.X, hp.Y, hp.Z, hr.Yaw, -1)
	local zlx = M.inZone(p.X, p.Y, p.Z, hp.X, hp.Y, hp.Z, hr.Yaw, 1) -- left hand reached across to the right shoulder
	if (zl and not S.inZoneL) or (zlx and not S.inZoneLX) then pcall(D.uevrUtils.triggerHapticVibration, Handed.Left, 0, 0.03, 150, 0.3) end
	S.inZoneL, S.inZoneLX = zl, zlx
end

function M.reset() S.inZone = false S.armed = false S.inZoneX = false S.armedX = false S.prevPending = false
	S.inZoneL = false S.armedL = false S.inZoneLX = false S.armedLX = false S.daggerPending = 0 end

return M
