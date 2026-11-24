-- Queen's Domain VR: thrown knives leave from the finger knife (plan step 64).
-- The game spawns the projectile at the camera and aims it at what the crosshair is on. Nothing safe can run before
-- its first movement step (BP-internal spawn, no hookable event), so the real path is left alone: only the visible
-- children of the projectile's root (mesh, trail) are shifted. They start at the finger knife and merge onto the real
-- path over the first metres, so hits are exactly the game's own.
local M = {}

M.CLASS = "BlueprintGeneratedClass /Game/Items/Weapons/Daggers/Dagger_Projectile_Base.Dagger_Projectile_Base_C"
M.WINDOW_S = 0.6    -- look for a new projectile this long after a left-grip press
M.CONV_MIN = 300.0  -- cm of flight over which the visual merges onto the real path = aim distance clamped to this range
M.CONV_MAX = 1500.0
M.CONV_DEFAULT = 800.0
M.MAX_S = 2.0       -- stop tracking after this long whatever happens
M.MAX_KIDS = 6

-- merge distance from the crosshair distance (nil / stale -> default)
function M.convDist(aimDist)
	if type(aimDist) ~= "number" then return M.CONV_DEFAULT end
	if aimDist < M.CONV_MIN then return M.CONV_MIN end
	if aimDist > M.CONV_MAX then return M.CONV_MAX end
	return aimDist
end

-- share of the start offset still applied after `travel` cm of real flight: 1 at the start, 0 from `conv` on
function M.weight(travel, conv)
	if type(travel) ~= "number" or type(conv) ~= "number" or conv <= 0 then return 0.0 end
	local w = 1.0 - travel / conv
	if w < 0.0 then return 0.0 end
	if w > 1.0 then return 1.0 end
	return w
end

-- a throw = a projectile that was not there at the grip press + a charge spent since then
function M.isThrow(known, chargesAtPress, chargesNow)
	return not known and type(chargesAtPress) == "number" and type(chargesNow) == "number" and chargesNow < chargesAtPress
end

-- step 79c: left-hand throw aim along the fingers (pure maths; the game script drives the aim with it) ---------------
-- UEVR's left-controller aim follows the controller's own forward axis, which runs 35 deg toward the palm of the hand
-- model. The two offsets are in the hand's frame: pitch = toward the back of the hand (up with the palm down), yaw =
-- toward the thumb. Measured live (Test 68a; controller P-14.8 Y-153.6 R34.4, hand bone P40.5 Y-69.7 R19.8): back of the
-- hand in the controller frame = fwd -0.571, right -0.804, up 0.164; fingers = fwd 0.816, right -0.535, up 0.218, which
-- is pitch 34.6, yaw 7.5 here.
M.AIM_UY, M.AIM_UZ = -0.9798, 0.1999 -- back of the hand minus its forward part, as controller (right, up); unit length
M.AIM_PITCH, M.AIM_YAW = 35.0, 7.0   -- option defaults = along the fingers
M.AIM_MAX_DEG = 90.0

-- option values -> pitch, yaw in range (bad values -> defaults)
function M.aimOffsets(p, y)
	if type(p) ~= "number" or p ~= p then p = M.AIM_PITCH end
	if type(y) ~= "number" or y ~= y then y = M.AIM_YAW end
	local m = M.AIM_MAX_DEG
	if p > m then p = m elseif p < -m then p = -m end
	if y > m then y = m elseif y < -m then y = -m end
	return p, y
end

-- world aim direction (unit x, y, z) of a controller with world rotation cp, cy, cr (pitch, yaw, roll in degrees, the
-- engine's rotator convention) after the two offsets. Offsets 0, 0 = the controller's forward axis.
function M.aimDir(cp, cy, cr, offPitch, offYaw)
	local p, y, r = math.rad(cp), math.rad(cy), math.rad(cr)
	local sp, cpp, sy, cyy, sr, crr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
	local op, oy = math.rad(offPitch or 0.0), math.rad(offYaw or 0.0)
	local lf = math.cos(op) * math.cos(oy) -- along the controller's forward
	local a, b = math.cos(op) * math.sin(oy), math.sin(op) -- toward the thumb, toward the back of the hand
	local lr = a * M.AIM_UZ + b * M.AIM_UY  -- controller right
	local lu = -a * M.AIM_UY + b * M.AIM_UZ -- controller up
	local x = cpp * cyy * lf + (sr * sp * cyy - crr * sy) * lr - (crr * sp * cyy + sr * sy) * lu
	local yy = cpp * sy * lf + (sr * sp * sy + crr * cyy) * lr + (cyy * sr - crr * sp * sy) * lu
	local z = sp * lf - sr * cpp * lr + crr * cpp * lu
	local n = math.sqrt(x * x + yy * yy + z * z)
	if n < 1e-6 then return cpp * cyy, cpp * sy, sp end
	return x / n, yy / n, z / n
end

-- direction -> control rotation pitch, yaw (degrees) and the direction again, pitch kept inside pitchMin..pitchMax (the
-- game camera's view pitch limits; nil = no limit) so the crosshair shows what the game can really aim at
function M.aimRot(x, y, z, pitchMin, pitchMax)
	if z > 1.0 then z = 1.0 elseif z < -1.0 then z = -1.0 end
	local pitch, yaw = math.deg(math.asin(z)), math.deg(math.atan(y, x))
	local lim = pitch
	if type(pitchMin) == "number" and type(pitchMax) == "number" and pitchMin < pitchMax then
		if lim < pitchMin then lim = pitchMin elseif lim > pitchMax then lim = pitchMax end
	end
	if lim ~= pitch then
		local c = math.cos(math.rad(lim))
		pitch, x, y, z = lim, c * math.cos(math.rad(yaw)), c * math.sin(math.rad(yaw)), math.sin(math.rad(lim))
	end
	return pitch, yaw, x, y, z
end

-- UEVR's view rotation offset is a pure turn about the tracking space's up axis (+Y); anything else (or a zero
-- quaternion) means the value was not read as expected and must not be written back
function M.pureYaw(x, y, z, w)
	if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" or type(w) ~= "number" then return false end
	return x * x + z * z < 0.01 and y * y + w * w > 0.9 and y * y + w * w < 1.1
end

-- view rotation offset that keeps the headset view where it is when the control yaw changes by dYawDeg (new - old):
-- UEVR shows the world at flat(view rotation) * offset * headset, and a game yaw of a is a turn of -a about +Y there, so
-- the offset has to turn by +dYaw: q' = turnY(dYaw) * q. Returns x, y, z, w (unit length).
function M.offsetTurn(x, y, z, w, dYawDeg)
	local h = math.rad(dYawDeg) * 0.5
	local c, s = math.cos(h), math.sin(h)
	local nx, ny, nz, nw = c * x + s * z, c * y + s * w, c * z - s * x, c * w - s * y
	local n = math.sqrt(nx * nx + ny * ny + nz * nz + nw * nw)
	if n < 1e-6 then return x, y, z, w end
	return nx / n, ny / n, nz / n, nw / n
end

local D = nil
local S = { untilT = 0.0, known = {}, ch0 = nil, cls = nil, clsT = 0.0, frame = 0, vframe = -10, dist = nil, distT = 0.0,
	loc = { X = 0.0, Y = 0.0, Z = 0.0 }, rel = { X = 0.0, Y = 0.0, Z = 0.0 }, bO = {}, bE = {}, bR = {},
	tr = { active = false, kid = {}, rx = {}, ry = {}, rz = {}, dx = {}, dy = {}, dz = {}, n = 0 } }
M.S = S

local function log(m) if D ~= nil and D.log ~= nil then pcall(D.log, "[THROW] " .. m) end end

function M.init(deps)
	D = deps
end

M.CENTRE_MAX = 60.0 -- cm: a bounds centre further than this from the pivot is stale (fresh projectile: near the world origin)

-- step 70: visible centre of a component (render bounds; UEVR out params come back as <table>.result), nil if unknown
-- or stale; (wx, wy, wz) = the component's pivot
local function centre(c, wx, wy, wz)
	if c == nil or D.ksl == nil or S.boundsOff then return nil end
	S.bO.result, S.bE.result = nil, nil
	local ok = pcall(function() D.ksl:GetComponentBounds(c, S.bO, S.bE, S.bR) end)
	local o = S.bO.result
	if not ok or o == nil or o.X == nil or (o.X == 0 and o.Y == 0 and o.Z == 0) then
		if not ok then S.boundsOff = true log("component bounds unavailable: pivots used") end
		return nil
	end
	local ex, ey, ez = o.X - wx, o.Y - wy, o.Z - wz
	if ex * ex + ey * ey + ez * ez > M.CENTRE_MAX * M.CENTRE_MAX then S.stale = (S.stale or 0) + 1 return nil end
	return o.X, o.Y, o.Z
end

local function isMesh(c)
	local m = false
	pcall(function() m = c.StaticMesh ~= nil end)
	return m
end

local function enabled() return D ~= nil and D.configui.getValue("throw_from_hand") ~= false end

local function class()
	if S.cls ~= nil then return S.cls end
	local now = os.clock()
	if now < S.clsT then return nil end
	S.clsT = now + 5.0
	pcall(function() S.cls = D.api:find_uobject(M.CLASS) end)
	if S.cls == nil and not S.clsLogged then S.clsLogged = true log("projectile class not found") end
	return S.cls
end

local function charges(pawn)
	local c = nil
	pcall(function() c = pawn:GetDaggerChargeComp().CurrentCharges end)
	return c
end

-- left grip pressed (xinput callback, before the game sees the press): remember what already exists
function M.arm()
	if not enabled() then return end
	local cls = class()
	local pawn = D.api:get_local_pawn(0)
	if cls == nil or pawn == nil then return end
	for k in pairs(S.known) do S.known[k] = nil end
	local all = UEVR_UObjectHook.get_objects_by_class(cls, false)
	if all ~= nil then
		for i = 1, #all do
			pcall(function() S.known[all[i]:get_address()] = true end)
		end
	end
	S.ch0 = charges(pawn)
	S.untilT = os.clock() + M.WINDOW_S
end

-- crosshair distance of the left-hand aim pass (cm)
function M.aim(dist)
	S.dist, S.distT = dist, os.clock()
end

local function place(tr, px, py, pz, w)
	local ox, oy, oz = tr.ox * w, tr.oy * w, tr.oz * w
	for i = 1, tr.n do
		S.loc.X, S.loc.Y, S.loc.Z = px + tr.dx[i] + ox, py + tr.dy[i] + oy, pz + tr.dz[i] + oz
		tr.kid[i]:K2_SetWorldLocation(S.loc, false, D.hr, true)
	end
end

local function finish()
	local tr = S.tr
	if not tr.active then return end
	tr.active = false
	for i = 1, tr.n do
		local c = tr.kid[i]
		pcall(function()
			c:SetAbsolute(false, false, false)
			S.rel.X, S.rel.Y, S.rel.Z = tr.rx[i], tr.ry[i], tr.rz[i]
			c:K2_SetRelativeLocation(S.rel, false, D.hr, true)
		end)
		tr.kid[i] = nil
	end
	tr.n = 0
	tr.a = nil
end

local function start(a, pawn, ch)
	local tr = S.tr
	if tr.active then finish() end
	local root = a.RootComponent
	local kids = root ~= nil and root.AttachChildren or nil
	if kids == nil or #kids == 0 then
		if not S.noKidsLogged then S.noKidsLogged = true log("projectile has no separate visual parts: left as is") end
		return
	end
	local p = a:K2_GetActorLocation()
	local px, py, pz = p.X, p.Y, p.Z
	local vel = a.ProjectileMovement.Velocity
	local sp = math.sqrt(vel.X * vel.X + vel.Y * vel.Y + vel.Z * vel.Z)
	-- start point: the finger knife this throw used up, else the left controller
	local kx, ky, kz = nil, nil, nil
	if D.knifePos ~= nil then
		local ok, x, y, z, kc = pcall(D.knifePos, ch + 1)
		if ok and x ~= nil then
			kx, ky, kz = x, y, z
			local cx, cy, cz = centre(kc, x, y, z) -- step 70: the knife's visible centre, not its pivot
			if cx ~= nil then kx, ky, kz = cx, cy, cz end
		end
	end
	local src = "knife"
	if kx == nil then
		local c = D.controllers.getController(0)
		if c == nil then return end
		local l = c:K2_GetComponentLocation()
		kx, ky, kz = l.X, l.Y, l.Z
		src = "hand"
	end
	tr.a = a
	tr.p0x, tr.p0y, tr.p0z = px, py, pz
	tr.lx, tr.ly, tr.lz = nil, nil, nil
	tr.conv = M.convDist((os.clock() - S.distT) < 0.5 and S.dist or nil)
	tr.t0 = os.clock()
	tr.oneShot = sp <= 1.0 -- already stuck in something (hit within its first step): shown at the hand for one frame
	local n = 0
	local mx, my, mz = nil, nil, nil
	for i = 1, math.min(#kids, M.MAX_KIDS) do
		local c = kids[i]
		pcall(function()
			local rl, wl = c.RelativeLocation, c:K2_GetComponentLocation()
			local rx, ry, rz = rl.X, rl.Y, rl.Z
			c:SetAbsolute(true, false, false)
			n = n + 1
			tr.kid[n] = c
			tr.rx[n], tr.ry[n], tr.rz[n] = rx, ry, rz
			tr.dx[n], tr.dy[n], tr.dz[n] = wl.X - px, wl.Y - py, wl.Z - pz
			if mx == nil and isMesh(c) then
				mx, my, mz = centre(c, wl.X, wl.Y, wl.Z)
				if mx == nil then mx, my, mz = wl.X, wl.Y, wl.Z end -- stale bounds: the mesh pivot is still closer than the root
			end
		end)
	end
	tr.n = n
	if n == 0 then tr.a = nil return end
	-- step 70: the projectile mesh's visible centre lands on the knife (was its root, so the mesh sat off by its own offset)
	if mx == nil then mx, my, mz = px, py, pz end
	tr.ox, tr.oy, tr.oz = kx - mx, ky - my, kz - mz
	tr.active = true
	place(tr, px, py, pz, 1.0)
	for i = 1, n do -- trail restarts at the hand (it already drew a streak from the camera)
		local c = tr.kid[i]
		pcall(function() if c.ReinitializeSystem ~= nil then c:ReinitializeSystem() end end)
	end
	if D.poke ~= nil then pcall(D.poke) end
	local off = math.sqrt(tr.ox * tr.ox + tr.oy * tr.oy + tr.oz * tr.oz)
	log(string.format("from %s: start offset %.0f cm, merge over %.0f cm, parts %d%s%s%s", src, off, tr.conv, n,
		mx ~= px and ", mesh aligned" or "", (S.stale or 0) > 0 and (" (stale bounds " .. S.stale .. ")") or "", tr.oneShot and ", already hit" or ""))
end

-- s127 discovery: how each throw ended (user saw knives fly on without damage)
local function endLog(tr, a, why, p)
	pcall(function()
		local cx, cy, cz = tr.lx or tr.p0x, tr.ly or tr.p0y, tr.lz or tr.p0z
		if p ~= nil then cx, cy, cz = p.X, p.Y, p.Z end
		local dx, dy, dz = cx - tr.p0x, cy - tr.p0y, cz - tr.p0z
		local what = ""
		if a ~= nil then
			local pa = nil
			pcall(function() pa = a:GetAttachParentActor() end)
			if pa ~= nil then what = ", stuck in " .. tostring(pa:get_class():get_fname():to_string()) end
		end
		log(string.format("end: %s after %.0f cm, %.2f s%s", why, math.sqrt(dx * dx + dy * dy + dz * dz), os.clock() - tr.t0, what))
	end)
end

local function update()
	local tr = S.tr
	local a = tr.a
	if a == nil or D.uevrUtils.getValid(a) == nil then
		endLog(tr, nil, "destroyed", nil)
		tr.active, tr.n, tr.a = false, 0, nil -- destroyed with its parts
		return
	end
	local p = a:K2_GetActorLocation()
	local vel = a.ProjectileMovement.Velocity
	local sp2 = vel.X * vel.X + vel.Y * vel.Y + vel.Z * vel.Z
	local dx, dy, dz = p.X - tr.p0x, p.Y - tr.p0y, p.Z - tr.p0z
	local w = M.weight(math.sqrt(dx * dx + dy * dy + dz * dz), tr.conv)
	tr.lx, tr.ly, tr.lz = p.X, p.Y, p.Z
	if tr.oneShot or sp2 <= 1.0 or w <= 0.0 or os.clock() - tr.t0 > M.MAX_S then
		endLog(tr, a, (tr.oneShot or sp2 <= 1.0) and "stopped" or (w <= 0.0 and "merged" or "timeout"), p)
		finish() -- parts snap back onto the real projectile (stuck in the target / merged)
		return
	end
	place(tr, p.X, p.Y, p.Z, w)
end

local function scan()
	local cls = class()
	local pawn = D.api:get_local_pawn(0)
	if cls == nil or pawn == nil then return end
	local ch = charges(pawn)
	local all = UEVR_UObjectHook.get_objects_by_class(cls, false)
	if all == nil then return end
	if ch ~= nil and S.ch0 ~= nil and ch < S.ch0 then
		for i = 1, #all do
			local a = all[i]
			local ad = a:get_address()
			if M.isThrow(S.known[ad], S.ch0, ch) then
				S.known[ad] = true
				S.ch0 = ch
				local ok, err = pcall(start, a, pawn, ch)
				if not ok then
					if S.tr.active then pcall(finish) end
					if not S.startErr then S.startErr = true log("start failed: " .. tostring(err)) end
				end
				return
			end
		end
	end
	if ch ~= nil and (S.ch0 == nil or ch > S.ch0) then S.ch0 = ch end -- a charge came back
end

local function step()
	if S.tr.active then
		local ok, err = pcall(update)
		if not ok then
			pcall(finish)
			if not S.updErr then S.updErr = true log("update failed: " .. tostring(err)) end
		end
	elseif os.clock() < S.untilT then
		if enabled() then pcall(scan) end
	end
end

-- step 112 (user: the weapon jump "spawns a sword in the air"): the game's weapon jump (game RB) plays a pooled
-- Niagara dash effect attached to a bone of the flat-screen first-person arms, ~73 cm behind / 50 cm below the camera
-- in VR. The jump itself is the pawn's dash + a charge component (it never reads the effect's location). Look only:
-- while the effect is active it is pinned to the hand that pressed (left in the new button layout), then its relative
-- transform goes back so the pool reuses it unchanged. Option dash_fx_hand.
M.DASH_WIN_S = 0.6       -- look for the active effect this long after the press
M.DASH_MAX_S = 2.0       -- stop pinning after this long whatever happens
M.DASH_ASSET = "DashFX"  -- part of the effect's Niagara system asset name
M.DASH_FWD_CM = 4.0      -- in front of the controller (toward the fingertips)
M.NIAGARA_CLASS = "Class /Script/Niagara.NiagaraComponent"
local DS = { untilT = 0.0, hand = 0, comp = nil, t0 = 0.0, relL = { X = 0.0, Y = 0.0, Z = 0.0 },
	relR = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }, loc = { X = 0.0, Y = 0.0, Z = 0.0 }, rot = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 } }
M.DS = DS

local function dashOn() return D ~= nil and D.configui.getValue("dash_fx_hand") ~= false end

-- game RB pressed (xinput callback): hand 0 = left, 1 = right
function M.dashArm(hand)
	if not dashOn() then return end
	DS.hand = hand or 0
	DS.untilT = os.clock() + M.DASH_WIN_S
end

local function dashActive(c)
	local a = false
	pcall(function() a = c:IsActive() == true end)
	return a
end

local function dashFind()
	local pawn = D.api:get_local_pawn(0)
	if pawn == nil then return end
	local arms = pawn.Arms
	if DS.cls == nil then DS.cls = D.api:find_uobject(M.NIAGARA_CLASS) end
	if DS.cls == nil or arms == nil then return end
	local all = UEVR_UObjectHook.get_objects_by_class(DS.cls, false)
	if all == nil then return end
	local armsAd = arms:get_address()
	for i = 1, #all do
		local c = all[i]
		local hit = false
		pcall(function()
			local p = c.AttachParent
			if p ~= nil and p:get_address() == armsAd and c.Asset ~= nil and string.find(c.Asset:get_full_name(), M.DASH_ASSET, 1, true) ~= nil then hit = true end
		end)
		if hit and dashActive(c) then
			local rl, rr = c.RelativeLocation, c.RelativeRotation
			DS.relL.X, DS.relL.Y, DS.relL.Z = rl.X, rl.Y, rl.Z
			DS.relR.Pitch, DS.relR.Yaw, DS.relR.Roll = rr.Pitch, rr.Yaw, rr.Roll
			DS.comp, DS.t0, DS.untilT = c, os.clock(), 0.0
			log("dash effect pinned to the " .. (DS.hand == 0 and "left" or "right") .. " hand")
			return
		end
	end
end

local function dashEnd()
	local c = DS.comp
	DS.comp = nil
	if c ~= nil and D.uevrUtils.getValid(c) ~= nil then
		c:K2_SetRelativeLocationAndRotation(DS.relL, DS.relR, false, D.hr, true)
	end
end

local function dashPin()
	local c = DS.comp
	if c == nil then return end
	if D.uevrUtils.getValid(c) == nil or not dashActive(c) or os.clock() - DS.t0 > M.DASH_MAX_S or not dashOn() then
		dashEnd()
		return
	end
	local ctl = D.controllers.getController(DS.hand)
	if ctl == nil then return end
	local p = ctl:K2_GetComponentLocation()
	local f = ctl:GetForwardVector()
	-- step 114 (headset 2026-11-19: effect sat too far forward and left): offsets in the controller frame (sliders)
	local cf, cr, cu = D.configui.getValue("dash_fx_fwd"), D.configui.getValue("dash_fx_right"), D.configui.getValue("dash_fx_up")
	if type(cf) ~= "number" then cf = M.DASH_FWD_CM end
	local x, y, z = p.X + f.X * cf, p.Y + f.Y * cf, p.Z + f.Z * cf
	if type(cr) == "number" and cr ~= 0 then local v = ctl:GetRightVector() x, y, z = x + v.X * cr, y + v.Y * cr, z + v.Z * cr end
	if type(cu) == "number" and cu ~= 0 then local v = ctl:GetUpVector() x, y, z = x + v.X * cu, y + v.Y * cu, z + v.Z * cu end
	DS.loc.X, DS.loc.Y, DS.loc.Z = x, y, z
	local r = ctl:K2_GetComponentRotation()
	DS.rot.Pitch, DS.rot.Yaw, DS.rot.Roll = r.Pitch, r.Yaw, r.Roll
	c:K2_SetWorldLocationAndRotation(DS.loc, DS.rot, false, D.hr, true)
end

local function dashStep()
	if DS.comp ~= nil then
		local ok, err = pcall(dashPin)
		if not ok then
			pcall(dashEnd)
			if not DS.err then DS.err = true log("dash effect pin failed: " .. tostring(err)) end
		end
	elseif os.clock() < DS.untilT then
		local ok, err = pcall(dashFind)
		if not ok and not DS.findErr then DS.findErr = true DS.untilT = 0.0 log("dash effect search failed: " .. tostring(err)) end
	end
end

-- once per frame from the stereo view callback: after the world tick, before this frame is drawn
function M.view()
	if D == nil or S.vframe == S.frame then return end
	S.vframe = S.frame
	step()
	dashStep()
end

-- every pre-engine tick; play = regular unpaused play. Also drives the work when no view callback arrives.
-- step 127b discovery (headset 2026-11-21c, user: gun shots did no damage, "collided with the gun"): gun shots are
-- plain actors with a ProjectileMovementComponent (Test 96: not the dagger family). On a gun trigger press (main, ranged
-- weapon) remember the existing movement components; new ones within GUN_WINDOW_S whose actor spawns within
-- GUN_NEAR_CM of the right hand are tracked up to GUN_TRACK_S: "[THROW] gun shot: spawn N cm from the right hand, M cm
-- from the eyes" and "[THROW] gun shot end: destroyed|stopped|still flying after N cm[, stuck in <class>]".
M.GUN_WINDOW_S, M.GUN_TRACK_S, M.GUN_LOG_MAX, M.GUN_MAX, M.GUN_NEAR_CM = 0.5, 2.0, 40, 4, 500.0
M.PM_CLASS = "Class /Script/Engine.ProjectileMovementComponent"
local G = { untilT = 0.0, known = {}, list = {}, logs = 0, cls = nil, potCls = nil, pot = nil, potT = 0.0 }
-- step 128b discovery (fake Test 97: pots break, dummy takes damage; ApplyHit hooks never fire = BP-internal calls,
-- removed). The user's shots stop at their spawn ~2.5 m out without breaking a vase: on each stop, log the nearest
-- breakable pot (base class found from the known pot classes' super chain) and its Broken flag now and POT_RECHECK_S later.
M.POT_CLASSES = { "BlueprintGeneratedClass /Game/Props/Pots/Pot_Small_Base.Pot_Small_Base_C",
	"BlueprintGeneratedClass /Game/Props/Pots/Pot_Tall_Base.Pot_Tall_Base_C", "BlueprintGeneratedClass /Game/Props/Pots/Pot_Fat.Pot_Fat_C" }
M.POT_BASE, M.POT_NEAR_CM, M.POT_RECHECK_S = "Pot_Base_C", 300.0, 0.5
local function potBase()
	if G.potCls ~= nil then return G.potCls end
	for _, path in ipairs(M.POT_CLASSES) do
		local c = D.api:find_uobject(path)
		while c ~= nil do
			if c:get_fname():to_string() == M.POT_BASE then G.potCls = c return c end
			c = c:get_super()
		end
	end
	return nil
end
local function potNear(x, y, z)
	local cls = potBase()
	if cls == nil then return nil, -1 end
	local all = UEVR_UObjectHook.get_objects_by_class(cls, false)
	local best, bd = nil, M.POT_NEAR_CM * M.POT_NEAR_CM
	for i = 1, #(all or {}) do
		local okP, p = pcall(function() return all[i]:K2_GetActorLocation() end)
		if okP and p ~= nil and math.abs(p.X) + math.abs(p.Y) > 500 then
			local dx, dy, dz = p.X - x, p.Y - y, p.Z - z
			local d = dx * dx + dy * dy + dz * dz
			if d < bd then best, bd = all[i], d end
		end
	end
	return best, math.sqrt(bd)
end
local function pmClass()
	if G.cls == nil then pcall(function() G.cls = D.api:find_uobject(M.PM_CLASS) end) end
	return G.cls
end
M.G = G
local function dist3(p, c)
	if p == nil or c == nil then return -1 end
	local l = c:K2_GetComponentLocation()
	local dx, dy, dz = p.X - l.X, p.Y - l.Y, p.Z - l.Z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end
function M.gunArm(fresh)
	if D == nil or G.logs >= M.GUN_LOG_MAX then return end
	local cls = pmClass()
	if cls == nil then return end
	for k in pairs(G.known) do G.known[k] = nil end
	local all = UEVR_UObjectHook.get_objects_by_class(cls, false)
	-- step 130: fresh = also track ones already near the hand (charged alt shot)
	if all ~= nil and fresh ~= true then for i = 1, #all do pcall(function() G.known[all[i]:get_address()] = true end) end end
	G.untilT = os.clock() + M.GUN_WINDOW_S
end
local function gunEnd(g, why, a)
	local what = ""
	if a ~= nil then
		pcall(function() local pa = a:GetAttachParentActor() if pa ~= nil then what = ", stuck in " .. pa:get_class():get_fname():to_string() end end)
	end
	if a ~= nil then
		pcall(function()
			local ad = a.AimDir
			what = what .. string.format(" | alreadyHit=%s water=%s travelled=%.0f impactDmg=%.1f hitRadius=%.1f aim (%.2f %.2f %.2f)",
				tostring(a.AlreadyHit), tostring(a.HitWater), a.DistanceTravelled or -1, a.Impact_Damage_Amount or -1, a.HitRadius or -1, ad.X, ad.Y, ad.Z)
			local c = a.TravelDistanceDamageCurve
			if c ~= nil then what = what .. string.format(" curve(travelled)=%.2f", c:GetFloatValue(a.DistanceTravelled)) end
			if g.hx ~= nil then -- angle between the game's aim and hand -> stop point
				local vx, vy, vz = g.lx - g.hx, g.ly - g.hy, g.lz - g.hz
				local vl, al = math.sqrt(vx * vx + vy * vy + vz * vz), math.sqrt(ad.X * ad.X + ad.Y * ad.Y + ad.Z * ad.Z)
				if vl > 1 and al > 0.01 then
					local cs = math.max(-1, math.min(1, (vx * ad.X + vy * ad.Y + vz * ad.Z) / (vl * al)))
					what = what .. string.format(" aim vs hand->stop %.0f deg", math.deg(math.acos(cs)))
				end
			end
		end)
		if why == "stopped" then
			pcall(function()
				local pot, pd = potNear(g.lx, g.ly, g.lz)
				if pot == nil then what = what .. (pd < 0 and " | pot class not loaded" or " | no pot within 3 m")
				else
					what = what .. string.format(" | nearest pot %s %.0f cm broken=%s", pot:get_class():get_fname():to_string(), pd, tostring(pot.Broken))
					if pot.Broken ~= true then G.pot, G.potT = pot, os.clock() + M.POT_RECHECK_S end
				end
			end)
		end
	end
	local dx, dy, dz = g.lx - g.x, g.ly - g.y, g.lz - g.z
	log(string.format("gun shot end: %s after %.0f cm, %.2f s%s", why, math.sqrt(dx * dx + dy * dy + dz * dz), os.clock() - g.t0, what))
end
local function gunStep()
	local now = os.clock()
	if now < G.untilT then
		local cls = pmClass()
		local all = cls ~= nil and UEVR_UObjectHook.get_objects_by_class(cls, false) or nil
		if all ~= nil then
			for i = 1, #all do
				local pm = all[i]
				local ad = pm:get_address()
				if not G.known[ad] then
					G.known[ad] = true
					local a = pm:GetOwner()
					if a ~= nil and #G.list < M.GUN_MAX and G.logs < M.GUN_LOG_MAX then
						local p = a:K2_GetActorLocation()
						local okC, dh = pcall(dist3, p, D.controllers.getController(1))
						if okC and dh >= 0 and dh <= M.GUN_NEAR_CM then
							G.logs = G.logs + 1
							local hp = D.controllers.getController(1):K2_GetComponentLocation()
							G.list[#G.list + 1] = { a = a, pm = pm, x = p.X, y = p.Y, z = p.Z, lx = p.X, ly = p.Y, lz = p.Z, t0 = now, hx = hp.X, hy = hp.Y, hz = hp.Z }
							local okH, de = pcall(dist3, p, D.controllers.getController(2))
							local v = pm.Velocity
							log(string.format("gun shot %s: spawn %.0f cm from the right hand, %.0f cm from the eyes, speed %.0f",
								a:get_class():get_fname():to_string(), dh, okH and de or -1, math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)))
						end
					end
				end
			end
		end
	end
	if G.pot ~= nil and now >= G.potT then
		local pot = G.pot
		G.pot = nil
		pcall(function() log(string.format("gun shot pot recheck: %s broken=%s", pot:get_class():get_fname():to_string(), tostring(pot.Broken))) end)
	end
	for i = #G.list, 1, -1 do
		local g = G.list[i]
		local done = nil
		if D.uevrUtils.getValid(g.a) == nil then
			done = "destroyed"
			gunEnd(g, done, nil)
		else
			local p = g.a:K2_GetActorLocation()
			g.lx, g.ly, g.lz = p.X, p.Y, p.Z
			local v = g.pm.Velocity
			if v.X * v.X + v.Y * v.Y + v.Z * v.Z <= 1.0 then done = "stopped" gunEnd(g, done, g.a)
			elseif now - g.t0 > M.GUN_TRACK_S then done = "still flying" gunEnd(g, done, nil) end
		end
		if done ~= nil then table.remove(G.list, i) end
	end
end

function M.tick(play)
	if D == nil then return end
	S.frame = S.frame + 1
	if G.untilT > 0.0 or #G.list > 0 or G.pot ~= nil then
		local okG, errG = pcall(gunStep)
		if not okG then G.untilT = 0.0 for i = #G.list, 1, -1 do G.list[i] = nil end log("gun shot tracker error: " .. tostring(errG)) end
		if os.clock() >= G.untilT then G.untilT = 0.0 end
	end
	if not play then
		if S.tr.active then pcall(finish) end
		S.untilT = 0.0
		if DS.comp ~= nil then pcall(dashEnd) end
		DS.untilT = 0.0
		return
	end
	if S.frame - S.vframe > 2 then step() dashStep() end
end

function M.reset()
	if S.tr.active then pcall(finish) end
	if DS.comp ~= nil then pcall(dashEnd) end
	DS.comp, DS.untilT = nil, 0.0
	S.tr.active, S.tr.n, S.tr.a = false, 0, nil
	S.untilT = 0.0
	for k in pairs(S.known) do S.known[k] = nil end
end

return M
