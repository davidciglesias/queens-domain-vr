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
M.LOW_CM = 24.0      -- ... and not lower than this below the eyes (step 97: was 36, fired with the weapon held out to the side)

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

-- step 86 pure: hand (head-yaw frame f, l toward that side, z vs eyes) within margin cm of the zone (or in it)
function M.nearZone(f, l, z, margin)
	local m = margin or 0
	if z < -(M.LOW_CM + m) then return false end
	if l < M.LAT_MIN_CM - m then return false end
	if f <= M.FWD_MAX_CM + m then return true end
	return l >= M.WIDE_CM - m and f <= M.WIDE_FWD_CM + m
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

-- step 79b: trigger as the grab button. Pure: armed from the trigger-down state (hysteresis done by the caller).
function M.stepDown(down, wasDown, inZoneNow, armed)
	if not armed and down and not wasDown and inZoneNow then armed = true end
	if armed and not down then armed = false end
	return armed
end
M.TRIG_HI, M.TRIG_LO = 128, 77
function M.trigDown(prev, v)
	if prev then return v > M.TRIG_LO end
	return v >= M.TRIG_HI
end

local D = nil
local S = {tdL = false, tdR = false, fR = 0, lR = 0, zR = 0, fX = 0, lX = 0, inZone = false, armed = false, prevGrip = false, inZoneX = false, armedX = false,
	fL = 0, lL = 0, fLX = 0, lLX = 0, zL = 0, inZoneL = false, armedL = false, inZoneLX = false, armedLX = false, prevGripL = false, daggerPending = 0}
M.S = S

-- step 92: a trigger pulled while its hand is in a zone (from rest) never reaches the game until released, even a light
-- pull below the switch threshold (left trigger = melee special attack). A pull started outside passes. Pure.
M.TRIG_REST = 30
function M.restLock(locked, inZone, v)
	if v < M.TRIG_REST then return inZone == true end
	return locked == true
end
-- step 94: switch-zone feel = the belt's "switch" pattern (long low rumble), distinct from belt item / heal ticks
function M.buzzSwitch(h)
	local bt = package.loaded["libs/qd_belt"]
	local p = bt ~= nil and bt.HAPTIC ~= nil and bt.HAPTIC.switch or nil
	if p ~= nil then pcall(D.uevrUtils.triggerHapticVibration, h == 1 and Handed.Left or Handed.Right, 0, p[1], p[2], p[3])
	else pcall(D.uevrUtils.triggerHapticVibration, h == 1 and Handed.Left or Handed.Right, 0, 0.03, 150, 0.3) end
end
function M.init(deps) D = deps end
local function enabled() return D ~= nil and D.configui.getValue("shoulder_switch") ~= false end

function M.onXInput(state)
	if not enabled() then S.armed = false S.armedX = false S.armedL = false S.armedLX = false return end
	local g = state.Gamepad
	local b = g.wButtons
	local trig = D.configui.getValue("grab_button") ~= 2 -- step 79b: default = the same hand's trigger
	local grip = (b & XINPUT_GAMEPAD_RIGHT_SHOULDER) ~= 0
	local gripL = (b & XINPUT_GAMEPAD_LEFT_SHOULDER) ~= 0
	local wasArmed, wasArmedX = S.armed, S.armedX
	local wasArmedL, wasArmedLX = S.armedL, S.armedLX
	local trigSwallowL, trigSwallowR = false, false
	if trig then
		S.lockL = M.restLock(S.lockL, S.inZoneL or S.inZoneLX, g.bLeftTrigger)
		S.lockR = M.restLock(S.lockR, S.inZone or S.inZoneX, g.bRightTrigger)
		gripL, grip = M.trigDown(S.tdL, g.bLeftTrigger), M.trigDown(S.tdR, g.bRightTrigger)
		S.tdL, S.tdR = gripL, grip
		trigSwallowL = wasArmedL or wasArmedLX
		trigSwallowR = wasArmed or wasArmedX
	end
	-- left hand, throwables (step 45): own-side zone = previous, reach across = next; armed grip never reaches the game (no throw)
	if trig then
		S.armedL = M.stepDown(gripL, S.prevGripL, S.inZoneL, S.armedL)
		S.armedLX = M.stepDown(gripL, S.prevGripL, S.inZoneLX, S.armedLX)
	else
		b, S.armedL = M.step(b, XINPUT_GAMEPAD_LEFT_SHOULDER, M.PREV_BIT, S.inZoneL, S.prevGripL, S.armedL)
		b, S.armedLX = M.step(b, XINPUT_GAMEPAD_LEFT_SHOULDER, M.PREV_BIT, S.inZoneLX, S.prevGripL, S.armedLX)
	end
	if S.armedL then S.armedLX = false end
	if D.log ~= nil and gripL and not S.prevGripL then
		D.log(string.format("[SHOULDER] grip L left=%s (fwd=%.0f lat=%.0f) right=%s (fwd=%.0f lat=%.0f) dz=%.0f",
			tostring(S.inZoneL), S.fL, S.lL, tostring(S.inZoneLX), S.fLX, S.lLX, S.zL))
	end
	S.prevGripL = gripL
	if S.armedL and not wasArmedL then S.daggerPending = -1 if D.log ~= nil then D.log("[SHOULDER] previous throwable") end end
	if S.armedLX and not wasArmedLX then S.daggerPending = 1 if D.log ~= nil then D.log("[SHOULDER] next throwable") end end
	-- zones are disjoint (lateral sign), so at most one arms; once armed the grip is swallowed and the other step disarms
	if trig then
		S.armed = M.stepDown(grip, S.prevGrip, S.inZone, S.armed)
		S.armedX = M.stepDown(grip, S.prevGrip, S.inZoneX, S.armedX)
		if S.armed then b = b | M.NEXT_BIT end
	else
		b, S.armed = M.step(b, XINPUT_GAMEPAD_RIGHT_SHOULDER, M.NEXT_BIT, S.inZone, S.prevGrip, S.armed)
		b, S.armedX = M.step(b, XINPUT_GAMEPAD_RIGHT_SHOULDER, M.PREV_BIT, S.inZoneX, S.prevGrip, S.armedX)
	end
	if S.armed then S.armedX = false end
	if trig then -- trigger swallowed while armed and on the release frame; the grips always reach the game
		if trigSwallowL or S.armedL or S.armedLX or S.lockL then g.bLeftTrigger = 0 end
		if trigSwallowR or S.armed or S.armedX or S.lockR then g.bRightTrigger = 0 end
	end
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
	local lowCm = D.configui.getValue("shoulder_zone_low") -- step 97: zone floor below the eyes (option)
	if type(lowCm) == "number" and lowCm > 0 then M.LOW_CM = lowCm end
	local bt = package.loaded["libs/qd_belt"]
	local p = (bt ~= nil and bt.fingerPoint ~= nil) and bt.fingerPoint(rh) or rh:K2_GetComponentLocation()
	S.fR, S.lR = M.fwdLat(p.X, p.Y, hp.X, hp.Y, hr.Yaw, 1)
	S.fX, S.lX = M.fwdLat(p.X, p.Y, hp.X, hp.Y, hr.Yaw, -1)
	S.zR = p.Z - hp.Z
	local z = M.inZone(p.X, p.Y, p.Z, hp.X, hp.Y, hp.Z, hr.Yaw, 1)
	local zx = M.inZone(p.X, p.Y, p.Z, hp.X, hp.Y, hp.Z, hr.Yaw, -1) -- right hand reached across to the left shoulder
	-- step 91: a hand at a belt card (the side heal cards sit inside the zone) or holding one grabs, never switches
	local okB, atR = false, false
	if bt ~= nil and bt.handAtCard ~= nil then okB, atR = pcall(bt.handAtCard, 2) end
	if okB and atR then z, zx = false, false end
	if (z and not S.inZone) or (zx and not S.inZoneX) then M.buzzSwitch(2) end
	S.inZone, S.inZoneX = z, zx
	if lh == nil then S.inZoneL = false S.inZoneLX = false return end
	p = (bt ~= nil and bt.fingerPoint ~= nil) and bt.fingerPoint(lh) or lh:K2_GetComponentLocation()
	S.fL, S.lL = M.fwdLat(p.X, p.Y, hp.X, hp.Y, hr.Yaw, -1)
	S.fLX, S.lLX = M.fwdLat(p.X, p.Y, hp.X, hp.Y, hr.Yaw, 1)
	S.zL = p.Z - hp.Z
	local zl = M.inZone(p.X, p.Y, p.Z, hp.X, hp.Y, hp.Z, hr.Yaw, -1)
	local zlx = M.inZone(p.X, p.Y, p.Z, hp.X, hp.Y, hp.Z, hr.Yaw, 1) -- left hand reached across to the right shoulder
	local okL, atL = false, false
	if bt ~= nil and bt.handAtCard ~= nil then okL, atL = pcall(bt.handAtCard, 1) end
	if okL and atL then zl, zlx = false, false end
	if (zl and not S.inZoneL) or (zlx and not S.inZoneLX) then M.buzzSwitch(1) end
	S.inZoneL, S.inZoneLX = zl, zlx
end

-- step 86: is that hand (right = true) in / near either shoulder zone? uses the last tick's measurements
M.NEAR_MARGIN_CM = 8.0
function M.handNear(right)
	if not enabled() then return false end
	local f1, l1, z, f2, l2
	if right then f1, l1, f2, l2, z = S.fR, S.lR, S.fX, S.lX, S.zR
	else f1, l1, f2, l2, z = S.fL, S.lL, S.fLX, S.lLX, S.zL end
	return M.nearZone(f1, l1, z, M.NEAR_MARGIN_CM) or M.nearZone(f2, l2, z, M.NEAR_MARGIN_CM)
end

function M.reset() S.inZone = false S.armed = false S.inZoneX = false S.armedX = false S.prevPending = false
	S.inZoneL = false S.armedL = false S.inZoneLX = false S.armedLX = false S.daggerPending = 0 end

return M
