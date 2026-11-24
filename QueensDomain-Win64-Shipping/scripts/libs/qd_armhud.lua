-- Queen's Domain VR: arm HUD (plan step 74). Four thin bars on the back of the left glove, Bloodborne-VR style:
-- HP (red), energy cells (blue pips), power meter / "stamina" (green), jump-sword charges (gold pips).
-- Plain engine cubes with the debug colour material, parented to a panel on the hands-lib left hand bone. Replaces the
-- game's flat status panel on the hand while option arm_hud is on (the main script hides that panel).
local M = {}

M.BONE = "Hand_L"
M.MAX_PIPS = 16      -- more than this -> drawn as one continuous bar
M.REFRESH_S = 0.1    -- value reads (10 Hz)
M.CUBE = "StaticMesh /Engine/BasicShapes/Cube.Cube" -- 100 cm cube
M.MAT = "Material /Engine/EngineDebugMaterials/DebugMeshMaterial.DebugMeshMaterial"
M.BARS = { "hp", "energy", "power", "jump" }
M.COLOR = {
	hp = { R = 0.85, G = 0.06, B = 0.05, A = 1.0 },
	energy = { R = 0.15, G = 0.55, B = 1.0, A = 1.0 },
	power = { R = 0.25, G = 0.85, B = 0.2, A = 1.0 },
	jump = { R = 1.0, G = 0.72, B = 0.1, A = 1.0 },
	bg = { R = 0.02, G = 0.02, B = 0.02, A = 1.0 },
}
-- panel on the bone (cm / degrees) and bar shape (cm). Tuned live with the arm_hud_* sliders.
M.DEFAULTS = { x = 0.0, y = -7.5, z = 2.5, pitch = 0.0, yaw = 90.0, roll = 0.0, len = 7.0, gap = 0.9, width = 0.45, fa = 0 }
M.THICK = 0.2        -- bar height off the glove (cm)
M.PIP_GAP = 0.25     -- cm between pips
M.BG_Z = -0.15       -- plate centre (thickness M.THICK: back at -0.25, front at -0.05)
M.FILL_Z = 0.15      -- fill centre (thickness M.THICK: 0.05..0.25), clearly proud of the plate
M.FILL_SORT = 1      -- translucent sort priority of the fills (plates stay 0): always drawn after the plates

-- ---- pure helpers (unit tested) ----
function M.frac(cur, max)
	if type(cur) ~= "number" or type(max) ~= "number" or max <= 0 then return nil end
	local f = cur / max
	if f < 0 then return 0.0 end
	if f > 1 then return 1.0 end
	return f
end

-- lateral offset of bar i of n (centred stack)
function M.barOffset(i, n, gap)
	return (i - (n + 1) / 2) * gap
end

-- fill of a bar starting at -len/2: returns centre offset along the bar and the fill length
function M.fillSpan(f, len)
	f = f or 0
	if f < 0 then f = 0 elseif f > 1 then f = 1 end
	local l = f * len
	return -len / 2 + l / 2, l
end

-- pip k of n along a bar of length len: centre offset and pip length
function M.pipSpan(k, n, len, gap)
	local pl = (len - (n - 1) * gap) / n
	return -len / 2 + (k - 1) * (pl + gap) + pl / 2, pl
end

-- fill of pip k (1-based) for a count that can be fractional (energy 1.3 -> pip 2 at 0.3); extra = partial progress
-- of the next pip (jump-sword recharge) when cur is whole
function M.pipFill(k, cur, extra)
	cur = cur or 0
	if cur >= k then return 1.0 end
	if cur > k - 1 then return cur - (k - 1) end
	if k == math.floor(cur) + 1 and type(extra) == "number" and extra > 0 then return math.min(extra, 1.0) end
	return 0.0
end

-- available jump charges: ChargeComp.CurrentCharges can read above MaxChargeCount (11 vs 10): clamp to [0, max]
function M.chargeCount(cur, max)
	if type(cur) ~= "number" then return nil end
	if type(max) == "number" and cur > max then cur = max end
	if cur < 0 then cur = 0 end
	return cur
end

-- pip count: the largest of the HUD max, the component max and the highest charge count seen (CurrentCharges reads 11 at
-- full while both maxes read 10). nil when nothing is known
function M.pipCount(hudMax, compMax, seen)
	local n = nil
	for _, x in ipairs({ hudMax or false, compMax or false, seen or false }) do
		if type(x) == "number" then
			x = math.floor(x + 0.5)
			if n == nil or x > n then n = x end
		end
	end
	return n
end

-- step 114 (headset 2026-11-19): CurrentCharges reads 11 at full while both maxes read 10, and the user can use only
-- 10 (the last lit pip never jumps). Pips = the max; lit = charges minus the excess seen above the max.
M.RESERVE = 1 -- charges the game keeps back (a jump needs more than this)
function M.pipMax(hudMax, compMax)
	return M.pipCount(hudMax, compMax, nil)
end
function M.usable(cur, seen, max)
	if type(cur) ~= "number" then return nil end
	-- Test 82 (fake): full = 11 with max 10, every press down to 2 -> 1 jumped, a press at 1 never did -> 1 is reserved
	local off = M.RESERVE
	if type(seen) == "number" and type(max) == "number" and seen - max > off then off = math.floor(seen - max + 0.5) end
	cur = math.floor(cur) - off
	if cur < 0 then cur = 0 end
	if type(max) == "number" and cur > max then cur = max end
	return cur
end

function M.usePips(n) return type(n) == "number" and n >= 1 and n <= M.MAX_PIPS end

-- pip k of n -> column, row (1/2) and columns in that row; two rows (ceil(n/2) first) when n > 6
function M.pipCell(k, n)
	if n <= 6 then return k, 1, n end
	local r1 = math.ceil(n / 2)
	if k <= r1 then return k, 1, r1 end
	return k - r1, 2, n - r1
end

-- lateral offset of a pip row from its bar centre, and pip plate width, for bar gap g (two rows must stay inside the gap)
function M.rowOffset(row, nrows, g)
	if nrows < 2 then return 0.0 end
	return (row == 1 and -1 or 1) * g * 0.22
end
function M.pipWidth(nrows, w, g)
	if nrows < 2 then return w end
	return math.min(w, g * 0.33)
end

-- progress of the next pip: 0 on the read where the charge count just rose (the stale value would flash the new pip)
function M.nextFor(cur, prev, p)
	if type(p) ~= "number" then return nil end
	if type(cur) == "number" and type(prev) == "number" and cur > prev then return 0.0 end
	return p
end

-- recharge progress of the next charge as 0..1. NextChargeProgress is seconds into ChargeCooldown (headset 2026-11-17:
-- read as 0..1 the pip filled in 1 s, then dropped to 1/3.4 and refilled), so always divide when a cooldown is known
function M.chargeNext(p, cooldown)
	if type(p) ~= "number" then return nil end
	if type(cooldown) == "number" and cooldown > 0 then p = p / cooldown end
	if p < 0 then return 0.0 end
	if p > 1 then return 1.0 end
	return p
end

-- ---- runtime ----
local D = nil
local S = { t = 0.0, panel = nil, hand = nil, parts = {}, vis = nil, logged = {}, val = {}, tune = {}, tuneNow = {},
	mid = {}, pipN = {}, power = nil, outA = {}, outB = {} }
local vloc, vrot, vscale = nil, nil, nil
M.S = S

local function log(m) if D ~= nil and D.log ~= nil then pcall(D.log, "[ARMHUD] " .. m) end end
local function logOnce(k, m) if not S.logged[k] then S.logged[k] = true log(m) end end

-- step 89 compass swivel (pure). Forward (X) and up (Z) unit axes of a rotator, UE FRotationMatrix rows.
function M.rotAxes(p, y, r)
	local sp, cp = math.sin(math.rad(p)), math.cos(math.rad(p))
	local sy, cy = math.sin(math.rad(y)), math.cos(math.rad(y))
	local sr, cr = math.sin(math.rad(r)), math.cos(math.rad(r))
	return cp * cy, cp * sy, sp, -(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp
end
-- rotator (pitch, yaw, roll) from unit forward X and up Z (UE FMatrix::Rotator; Y = Z x X)
function M.axesRot(xx, xy, xz, zx, zy, zz)
	local p = math.deg(math.atan(xz, math.sqrt(xx * xx + xy * xy)))
	local yw = math.deg(math.atan(xy, xx))
	local sx, sy = -math.sin(math.rad(yw)), math.cos(math.rad(yw))
	local yx, yy = zy * xz - zz * xy, zz * xx - zx * xz
	return p, yw, math.deg(math.atan(zx * sx + zy * sy, yx * sx + yy * sy))
end
local function rodrigues(x, y, z, ax, ay, az, c, s)
	local d = (x * ax + y * ay + z * az) * (1 - c)
	return x * c + (ay * z - az * y) * s + ax * d, y * c + (az * x - ax * z) * s + ay * d, z * c + (ax * y - ay * x) * s + az * d
end
-- turn face normal n and up u about unit axis a so n's part across a points along v (pure; v or n along a: unchanged)
function M.swivel(nx, ny, nz, ux, uy, uz, ax, ay, az, vx, vy, vz)
	local na, va = nx * ax + ny * ay + nz * az, vx * ax + vy * ay + vz * az
	local px, py, pz = nx - na * ax, ny - na * ay, nz - na * az
	local qx, qy, qz = vx - va * ax, vy - va * ay, vz - va * az
	if px * px + py * py + pz * pz < 1e-8 or qx * qx + qy * qy + qz * qz < 1e-8 then return nx, ny, nz, ux, uy, uz end
	local s = ax * (py * qz - pz * qy) + ay * (pz * qx - px * qz) + az * (px * qy - py * qx)
	local th = math.atan(s, px * qx + py * qy + pz * qz)
	local c, sn = math.cos(th), math.sin(th)
	local n1, n2, n3 = rodrigues(nx, ny, nz, ax, ay, az, c, sn)
	local u1, u2, u3 = rodrigues(ux, uy, uz, ax, ay, az, c, sn)
	return n1, n2, n3, u1, u2, u3
end

function M.init(deps)
	D = deps
	vloc = { X = 0.0, Y = 0.0, Z = 0.0 }
	vrot = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
	vscale = { X = 1.0, Y = 1.0, Z = 1.0 }
end

function M.enabled() return D ~= nil and D.configui.getValue("arm_hud") ~= false end

local IDS_UA = { x = "arm_hud_l_x", y = "arm_hud_l_y", z = "arm_hud_l_z", pitch = "arm_hud_l_pitch", yaw = "arm_hud_l_yaw", roll = "arm_hud_l_roll" }
local IDS_LF = { x = "arm_hud_lf_x", y = "arm_hud_lf_y", z = "arm_hud_lf_z", pitch = "arm_hud_lf_pitch", yaw = "arm_hud_lf_yaw", roll = "arm_hud_lf_roll" }
function M.readTuning(get, out)
	local d = M.DEFAULTS
	local function v(id, def) local r = get(id) if type(r) ~= "number" then return def end return r end
	out.x, out.y, out.z = v("arm_hud_x", d.x), v("arm_hud_y", d.y), v("arm_hud_z", d.z)
	out.pitch, out.yaw, out.roll = v("arm_hud_pitch", d.pitch), v("arm_hud_yaw", d.yaw), v("arm_hud_roll", d.roll)
	out.fa = get("arm_hud_forearm") == true and 1 or 0
	if get("arm_hud_upper") == true then out.fa = 2 end -- step 117: upper arm wins
	if out.fa == 2 then
		local u, k = M.UPPER_DEFAULTS, IDS_UA -- step 118 defaults; step 119 (user 2026-11-20): sliders again, new ids (old arm_hud_ua_* stale)
		if M.LOWER.on then u, k = M.LOWER_DEFAULTS, IDS_LF end -- step 121: IK lower arm, new ids (arm_hud_l_* stale)
		out.x, out.y, out.z = v(k.x, u.x), v(k.y, u.y), v(k.z, u.z)
		out.pitch, out.yaw, out.roll = v(k.pitch, u.pitch), v(k.yaw, u.yaw), v(k.roll, u.roll)
	elseif out.fa == 1 then -- step 114: own offsets on the forearm anchor (the hand ones stay for switching back)
		local f = M.FORE_DEFAULTS
		out.x, out.y, out.z = v("arm_hud_fa_x", f.x), v("arm_hud_fa_y", f.y), v("arm_hud_fa_z", f.z)
		out.pitch, out.yaw, out.roll = v("arm_hud_fa_pitch", f.pitch), v("arm_hud_fa_yaw", f.yaw), v("arm_hud_fa_roll", f.roll)
	end
	out.len, out.gap, out.width = v("arm_hud_len", d.len), d.gap, d.width
	return out
end

local function sameTuning(a, b)
	if a == nil or b == nil then return false end
	for k in pairs(M.DEFAULTS) do if a[k] ~= b[k] then return false end end
	return true
end

local function newCube(owner, color, key)
	local c = D.uevrUtils.createStaticMeshComponent(M.CUBE, { parent = owner, manualAttachment = true, collisionEnabled = false })
	if c == nil then return nil end
	pcall(function() c:SetCastShadow(false) end)
	pcall(function()
		local mat = D.api:find_uobject(M.MAT)
		local mid = mat ~= nil and c:CreateAndSetMaterialInstanceDynamicFromMaterial(0, mat) or nil
		if mid ~= nil then mid:SetVectorParameterValue("Color", color) S.mid[key] = mid end
	end)
	return c
end

local function destroy()
	for k, c in pairs(S.parts) do
		pcall(function() c:K2_DestroyComponent(c) end)
		S.parts[k] = nil
	end
	if S.panel ~= nil then pcall(function() S.panel:K2_DestroyComponent(S.panel) end) end
	S.panel, S.hand, S.vis = nil, nil, nil
	for k in pairs(S.pipN) do S.pipN[k] = nil end
	for k in pairs(S.mid) do S.mid[k] = nil end
	S.tune = {}
end

-- part keys: <bar>_bg, <bar>_fill (continuous) or <bar>_p<k>_bg / <bar>_p<k> (pips)
local function part(key, color)
	local c = S.parts[key]
	if c ~= nil and D.uevrUtils.getValid(c) ~= nil then return c end
	c = newCube(S.hand:GetOwner(), color, key)
	if c == nil then return nil end
	-- step 137 (headset: HP red sometimes black by angle): the bar material is translucent + unlit, so parts sort by centre
	-- distance, not depth; a partly filled bar's centre can be farther than its plate's and the plate drew over it. Fills last.
	if key:sub(-3) ~= "_bg" then pcall(function() c:SetTranslucentSortPriority(M.FILL_SORT) end) end
	pcall(function() c:K2_AttachToComponent(S.panel, D.uevrUtils.fname_from_string(""), 0, 0, 0, false) end)
	S.parts[key] = c
	S.vis = nil
	return c
end

-- place a cube in panel space: centre (along, across, up) and size (cm)
local function put(c, a, b, u, la, lb, lu)
	if c == nil then return end
	vloc.X, vloc.Y, vloc.Z = a, b, u
	vrot.Pitch, vrot.Yaw, vrot.Roll = 0.0, 0.0, 0.0
	c:K2_SetRelativeLocationAndRotation(vloc, vrot, false, D.hr, true)
	vscale.X, vscale.Y, vscale.Z = math.max(la, 0.001) / 100, lb / 100, lu / 100
	c:SetRelativeScale3D(vscale)
end

-- ---- step 114: forearm anchors (headset 2026-11-19: HUD on the forearm's flat area, turning with the forearm) ----
-- A scene component on the glove's hand bone whose relative rotation each frame swings the bone's forearm axis (rest,
-- +Y = toward the elbow) onto the real forearm direction: wrist bends no longer tilt what sits on it, wrist roll still
-- does (the forearm skin near the wrist rolls with the hand). Forearm direction: IK arms on = the IK mesh elbow
-- (LowerArm bone) -> wrist; off = an elbow guessed from the head pose (two-bone solve, elbow down and out).
M.FORE = { bone = { [0] = "Hand_L", [1] = "Hand_R" }, lower = { [0] = "LowerArm_L", [1] = "LowerArm_R" },
	rest = { [0] = { 0.0, 1.0, 0.0 }, [1] = { 0.0, 1.0, 0.0 } }, MAX_DEG = 110.0,
	DROP = 21.0, BACK = 9.0, SIDE = 17.0, LU = 30.0, LF = 28.0, POLE_OUT = 0.6, POLE_BACK = 0.3 }
-- forearm-mode panel offsets on the anchor (cm / deg): bars along the forearm, on its back
M.FORE_DEFAULTS = { x = 0.0, y = 12.0, z = 4.5, pitch = 0.0, yaw = 90.0, roll = 0.0 }

-- elbow of a two-bone arm from shoulder S to wrist H (upper lu, fore lf), bent toward pole p (pure; world cm)
function M.elbowGuess(sx, sy, sz, hx, hy, hz, lu, lf, px, py, pz)
	local dx, dy, dz = hx - sx, hy - sy, hz - sz
	local L = math.sqrt(dx * dx + dy * dy + dz * dz)
	if L < 1e-6 then return sx, sy, sz - lu end
	local ux, uy, uz = dx / L, dy / L, dz / L
	local lo, hi = math.abs(lu - lf) + 0.01, lu + lf - 0.01
	if L < lo then L = lo elseif L > hi then L = hi end
	local a = (lu * lu - lf * lf + L * L) / (2.0 * L)
	local h = math.sqrt(math.max(0.0, lu * lu - a * a))
	local pu = px * ux + py * uy + pz * uz
	local qx, qy, qz = px - pu * ux, py - pu * uy, pz - pu * uz
	local q = math.sqrt(qx * qx + qy * qy + qz * qz)
	if q < 1e-6 then return sx + ux * a, sy + uy * a, sz + uz * a end
	return sx + ux * a + qx / q * h, sy + uy * a + qy / q * h, sz + uz * a + qz / q * h
end
-- rotator of the shortest rotation taking unit rest r onto t (both in the bone frame), at most maxDeg (pure)
function M.swingRot(rx, ry, rz, tx, ty, tz, maxDeg)
	local tl = math.sqrt(tx * tx + ty * ty + tz * tz)
	if tl < 1e-6 then return 0.0, 0.0, 0.0 end
	tx, ty, tz = tx / tl, ty / tl, tz / tl
	local kx, ky, kz = ry * tz - rz * ty, rz * tx - rx * tz, rx * ty - ry * tx
	local s = math.sqrt(kx * kx + ky * ky + kz * kz)
	if s < 1e-6 then return 0.0, 0.0, 0.0 end
	local ang = math.atan(s, rx * tx + ry * ty + rz * tz)
	local mx = math.rad(maxDeg or 180.0)
	if ang > mx then ang = mx end
	kx, ky, kz = kx / s, ky / s, kz / s
	local c, sn = math.cos(ang), math.sin(ang)
	local x1, x2, x3 = rodrigues(1.0, 0.0, 0.0, kx, ky, kz, c, sn)
	local z1, z2, z3 = rodrigues(0.0, 0.0, 1.0, kx, ky, kz, c, sn)
	return M.axesRot(x1, x2, x3, z1, z2, z3)
end

local FA = { [0] = { comp = nil, hand = nil, want = false, users = {}, logged = false, err = false },
	[1] = { comp = nil, hand = nil, want = false, users = {}, logged = false, err = false } }
M.FA = FA
local faLoc = { X = 0.0, Y = 0.0, Z = 0.0 }
local faRot = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
local faScale = { X = 1.0, Y = 1.0, Z = 1.0 }
local faNames = {}
local function faName(s)
	local n = faNames[s]
	if n == nil then n = D.uevrUtils.fname_from_string(s) faNames[s] = n end
	return n
end
-- anchor component for side 0 left / 1 right on that hands-lib hand (created on demand); nil when it can't be made.
-- who (step 116): user key (HUD/strip = default, cuff throwables = "knives"); the anchor turns while any user wants it
function M.foreAnchor(side, hand, who)
	local A = FA[side]
	if hand == nil then return nil end
	A.users[who or "_"] = true
	if A.comp ~= nil and A.hand == hand and D.uevrUtils.getValid(A.comp) ~= nil then A.want = true return A.comp end
	if A.comp ~= nil then pcall(function() A.comp:K2_DestroyComponent(A.comp) end) A.comp = nil end
	local c = D.uevrUtils.create_component_of_class("Class /Script/Engine.SceneComponent", true, nil, false, hand:GetOwner())
	if c == nil then logOnce("nofore" .. side, "forearm anchor creation failed") return nil end
	c:K2_AttachToComponent(hand, faName(M.FORE.bone[side]), 2, 2, 2, false)
	c:K2_SetRelativeLocationAndRotation(faLoc, faRot, false, D.hr, true)
	c:SetWorldScale3D(faScale)
	A.comp, A.hand, A.want = c, hand, true
	log("forearm anchor on " .. M.FORE.bone[side])
	return c
end
function M.foreRelease(side, who)
	local A = FA[side]
	A.users[who or "_"] = nil
	A.want = next(A.users) ~= nil
end
-- forearm direction (world unit vector, wrist -> elbow) for a side; hand bone location hx/hy/hz
local function foreDir(side, hx, hy, hz)
	local ex, ey, ez = nil, nil, nil
	local ik = D.ik ~= nil and D.ik() or nil
	if ik ~= nil and ik.exists() and ik.boneLoc ~= nil then
		local e = ik.boneLoc(M.FORE.lower[side])
		if e ~= nil then ex, ey, ez = e.X, e.Y, e.Z end
	end
	if ex == nil then
		local head = D.controllers ~= nil and D.controllers.getController(2) or nil
		if head == nil then return nil end
		local hp, hr = head:K2_GetComponentLocation(), head:K2_GetComponentRotation()
		local fy, cy = math.sin(math.rad(hr.Yaw)), math.cos(math.rad(hr.Yaw))
		local sg = side == 0 and -1.0 or 1.0 -- right vector (-sin, cos)
		local F = M.FORE
		local sx = hp.X - cy * F.BACK + (-fy) * sg * F.SIDE
		local sy = hp.Y - fy * F.BACK + cy * sg * F.SIDE
		local sz = hp.Z - F.DROP
		ex, ey, ez = M.elbowGuess(sx, sy, sz, hx, hy, hz, F.LU, F.LF,
			(-fy) * sg * F.POLE_OUT - cy * F.POLE_BACK, cy * sg * F.POLE_OUT - fy * F.POLE_BACK, -1.0)
	end
	local dx, dy, dz = ex - hx, ey - hy, ez - hz
	local l = math.sqrt(dx * dx + dy * dy + dz * dz)
	if l < 1.0 then return nil end
	return dx / l, dy / l, dz / l
end
local function foreSide(side)
	local A = FA[side]
	if not A.want or A.comp == nil or A.hand == nil then return end
	if D.uevrUtils.getValid(A.comp) == nil then A.comp = nil return end
	local bn = faName(M.FORE.bone[side])
	local hl, hr = A.hand:GetSocketLocation(bn), A.hand:GetSocketRotation(bn)
	if hl == nil or hr == nil then return end
	local dx, dy, dz = foreDir(side, hl.X, hl.Y, hl.Z)
	if dx == nil then return end
	local x1, x2, x3, z1, z2, z3 = M.rotAxes(hr.Pitch, hr.Yaw, hr.Roll)
	local y1, y2, y3 = z2 * x3 - z3 * x2, z3 * x1 - z1 * x3, z1 * x2 - z2 * x1
	local r = M.FORE.rest[side]
	local p, y, ro = M.swingRot(r[1], r[2], r[3], dx * x1 + dy * x2 + dz * x3, dx * y1 + dy * y2 + dz * y3, dx * z1 + dy * z2 + dz * z3, M.FORE.MAX_DEG)
	faRot.Pitch, faRot.Yaw, faRot.Roll = p, y, ro
	A.comp:K2_SetRelativeLocationAndRotation(faLoc, faRot, false, D.hr, true)
	if not A.logged then
		A.logged = true
		local ik = D.ik ~= nil and D.ik() or nil
		log(string.format("forearm anchor %s: swing p %.1f y %.1f r %.1f (%s)", side == 0 and "L" or "R", p, y, ro,
			(ik ~= nil and ik.exists()) and "IK elbow" or "guessed elbow"))
	end
end
-- ---- step 117: upper-arm anchors (headset 2026-11-19c: the forearm turns with wrist roll -> hard to read in a hurry) ----
-- A world-placed scene component (own actor): origin at the shoulder, +Y toward the elbow, +Z out of the arm (body side,
-- turned FACE_FWD deg toward the front, UP_BIAS up). Wrist roll never reaches it. Shoulder/elbow: IK arms on = IK mesh
-- UpperArm/LowerArm bones; off = shoulder from the eyes + a dead-zone body yaw, elbow from M.elbowGuess to the wrist.
-- Placed once per frame from the post stereo-view callback (after the IK late solve and the pawn's move this frame);
-- foreTick places it itself when no view callback came.
M.UPPER = { bone = { [0] = "UpperArm_L", [1] = "UpperArm_R" }, FACE_FWD = 30.0, UP_BIAS = 0.3,
	DEAD = 30.0, RATE = 540.0, DRIFT = 20.0, TAG = "qd_upperarm" }
M.UPPER_DEFAULTS = { x = 0.0, y = 10.0, z = 6.0, pitch = 0.0, yaw = 90.0, roll = 0.0 } -- step 118: fixed (no sliders)
-- step 121 (headset 2026-11-20: the arm HUD did not ride the IK arm; user: on the IK lower arm, close to the glove).
-- IK arms on: the anchor rides the IK LowerArm bone: origin at the wrist (IK Hand bone), +Y toward the elbow, +Z =
-- bone axis Z_AXIS (x Z_SIGN) made square to the forearm -> it turns only with the IK forearm (no head term; the
-- forearm twist bones that follow the wrist roll are not used). IK arms off: wrist from the glove, guessed elbow,
-- face toward the eyes. Same anchor table/API as the step 117 upper-arm anchor (upperAnchor / upperRelease).
M.LOWER = { on = true, bone = { [0] = "LowerArm_L", [1] = "LowerArm_R" }, hand = { [0] = "Hand_L", [1] = "Hand_R" },
	Z_AXIS = { [0] = "Z", [1] = "Z" }, Z_SIGN = { [0] = 1.0, [1] = 1.0 } }
M.LOWER_DEFAULTS = { x = 0.0, y = 18.875, z = 4.5, pitch = 0.0, yaw = 90.0, roll = 0.0 }   -- left HP HUD (arm_hud_lf_*)
M.LOWER_R_DEFAULTS = { x = 0.0, y = 8.0, z = 4.5, pitch = 90.0, yaw = 0.0, roll = 0.0 } -- right charge strip (arm_hud_rf_*)
-- world unit vector of a rotator's local axis "X" / "Y" / "Z" (pure; Y = Z x X)
function M.boneAxis(p, y, r, axis)
	local x1, x2, x3, z1, z2, z3 = M.rotAxes(p, y, r)
	if axis == "X" then return x1, x2, x3 end
	if axis == "Z" then return z1, z2, z3 end
	return z2 * x3 - z3 * x2, z3 * x1 - z1 * x3, z1 * x2 - z2 * x1
end
-- lower-arm frame (pure): wrist w -> elbow e (world cm) = +Y, face = axis a made square to it = +Z -> pitch, yaw, roll
-- (nil when the forearm is shorter than 1 cm or a lies along it)
-- step 122: the same frame as unit axes (pure): X, Y, Z (9 numbers), nil like lowerRot
function M.lowerAxes(wx, wy, wz, ex, ey, ez, ax, ay, az)
	local yx, yy, yz = ex - wx, ey - wy, ez - wz
	local l = math.sqrt(yx * yx + yy * yy + yz * yz)
	if l < 1.0 then return nil end
	yx, yy, yz = yx / l, yy / l, yz / l
	local d = ax * yx + ay * yy + az * yz
	local zx, zy, zz = ax - d * yx, ay - d * yy, az - d * yz
	local zl = math.sqrt(zx * zx + zy * zy + zz * zz)
	if zl < 1e-3 then return nil end
	zx, zy, zz = zx / zl, zy / zl, zz / zl
	return yy * zz - yz * zy, yz * zx - yx * zz, yx * zy - yy * zx, yx, yy, yz, zx, zy, zz -- X = Y x Z
end
function M.lowerRot(wx, wy, wz, ex, ey, ez, ax, ay, az)
	local xx, xy, xz, _, _, _, zx, zy, zz = M.lowerAxes(wx, wy, wz, ex, ey, ez, ax, ay, az)
	if xx == nil then return nil end
	return M.axesRot(xx, xy, xz, zx, zy, zz)
end

function M.normDeg(a) return (a + 180.0) % 360.0 - 180.0 end
-- body yaw following the head (pure): free inside dead deg, catches up at rate deg/s beyond it, drifts at drift deg/s
function M.followYaw(body, head, dead, rate, dt, drift)
	if body == nil then return M.normDeg(head) end
	local d = M.normDeg(head - body)
	local ad = math.abs(d)
	local step = math.min(ad, drift * dt)
	if ad > dead then step = math.max(step, math.min(ad - dead, rate * dt)) end
	return M.normDeg(body + (d > 0 and step or -step))
end
-- upper-arm frame (pure): shoulder s -> elbow e (world cm), body yaw deg, side 0 left / 1 right -> pitch, yaw, roll
-- step 118 (headset 2026-11-19d: not visible, the face pointed out to the side): with a head point h the face (Z) turns to the eyes
function M.upperRot(sx, sy, sz, ex, ey, ez, bodyYaw, side, faceFwd, upBias, hx, hy, hz)
	local yx, yy, yz = ex - sx, ey - sy, ez - sz
	local l = math.sqrt(yx * yx + yy * yy + yz * yz)
	if l < 1.0 then yx, yy, yz = 0.0, 0.0, -1.0 else yx, yy, yz = yx / l, yy / l, yz / l end
	local b, a = math.rad(bodyYaw), math.rad(faceFwd or 0.0)
	local fx, fy = math.cos(b), math.sin(b)
	local sg = side == 0 and -1.0 or 1.0 -- right vector (-fy, fx)
	local ox, oy, oz = -fy * sg * math.cos(a) + fx * math.sin(a), fx * sg * math.cos(a) + fy * math.sin(a), upBias or 0.0
	if hx ~= nil then ox, oy, oz = hx - sx, hy - sy, hz - sz end
	local d = ox * yx + oy * yy + oz * yz
	local zx, zy, zz = ox - d * yx, oy - d * yy, oz - d * yz
	local zl = math.sqrt(zx * zx + zy * zy + zz * zz)
	if zl < 1e-4 then -- outward along the arm: face the front
		d = fx * yx + fy * yy
		zx, zy, zz = fx - d * yx, fy - d * yy, -d * yz
		zl = math.sqrt(zx * zx + zy * zy + zz * zz)
		if zl < 1e-4 then zx, zy, zz, zl = 0.0, 0.0, 1.0, 1.0 end
	end
	zx, zy, zz = zx / zl, zy / zl, zz / zl
	return M.axesRot(yy * zz - yz * zy, yz * zx - yx * zz, yx * zy - yy * zx, zx, zy, zz) -- X = Y x Z
end

local UA = { [0] = { comp = nil, hand = nil, want = false, users = {}, logged = false, err = false },
	[1] = { comp = nil, hand = nil, want = false, users = {}, logged = false, err = false } }
M.UA = UA
local UAS = { bodyYaw = nil, dt = 0.0, frame = 0, done = -1, cb = false, failT = 0.0 }
M.UAS = UAS
local uaLoc = { X = 0.0, Y = 0.0, Z = 0.0 }
local uaRot = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
-- anchor for side 0 left / 1 right (created on demand, own actor); hand = that hands-lib hand (wrist for the guess)
function M.upperAnchor(side, hand, who)
	local A = UA[side]
	A.users[who or "_"] = true
	A.want, A.hand = true, hand
	if A.comp ~= nil and D.uevrUtils.getValid(A.comp) ~= nil then return A.comp end
	A.comp = nil
	local now = os.clock()
	if now < UAS.failT then return nil end
	local c = nil
	pcall(function() c = D.uevrUtils.create_component_of_class("Class /Script/Engine.SceneComponent", true, nil, false, nil, M.UPPER.TAG) end)
	if c == nil then UAS.failT = now + 5.0 logOnce("noupper" .. side, "upper-arm anchor creation failed") return nil end
	pcall(function() c:SetWorldScale3D(faScale) end)
	A.comp, A.logged = c, false
	log("upper-arm anchor " .. (side == 0 and "L" or "R") .. " created")
	return c
end
function M.upperRelease(side, who)
	local A = UA[side]
	A.users[who or "_"] = nil
	A.want = next(A.users) ~= nil
end
local function upperSide(side, hp, bodyYaw)
	local A = UA[side]
	if A.comp == nil then return end
	if D.uevrUtils.getValid(A.comp) == nil then A.comp = nil return end
	local sx, sy, sz, ex, ey, ez, src = nil, nil, nil, nil, nil, nil, "guessed"
	local ik = D.ik ~= nil and D.ik() or nil
	local L = M.LOWER
	if L.on and ik ~= nil and ik.exists() and ik.boneLoc ~= nil and ik.boneRot ~= nil then -- step 121: IK lower arm
		local w, e, br = ik.boneLoc(L.hand[side]), ik.boneLoc(L.bone[side]), ik.boneRot(L.bone[side])
		if w ~= nil and e ~= nil and br ~= nil then
			local ax, ay, az = M.boneAxis(br.Pitch, br.Yaw, br.Roll, L.Z_AXIS[side])
			local sn = L.Z_SIGN[side]
			local p, y, r = M.lowerRot(w.X, w.Y, w.Z, e.X, e.Y, e.Z, ax * sn, ay * sn, az * sn)
			if p ~= nil then
				uaLoc.X, uaLoc.Y, uaLoc.Z = w.X, w.Y, w.Z
				uaRot.Pitch, uaRot.Yaw, uaRot.Roll = p, y, r
				A.comp:K2_SetWorldLocationAndRotation(uaLoc, uaRot, false, D.hr, true)
				if not A.logged then -- once: bone axes vs the forearm / world up / the eyes (to pick Z_AXIS)
					A.logged = true
					local fx, fy, fz = e.X - w.X, e.Y - w.Y, e.Z - w.Z
					local fl = math.max(1e-3, math.sqrt(fx * fx + fy * fy + fz * fz))
					local vx, vy, vz = hp.X - w.X, hp.Y - w.Y, hp.Z - w.Z
					local vl = math.max(1e-3, math.sqrt(vx * vx + vy * vy + vz * vz))
					local t = {}
					for _, an in ipairs({ "X", "Y", "Z" }) do
						local bx, by, bz = M.boneAxis(br.Pitch, br.Yaw, br.Roll, an)
						t[#t + 1] = string.format("%s fore %.2f up %.2f eye %.2f", an, (bx * fx + by * fy + bz * fz) / fl, bz, (bx * vx + by * vy + bz * vz) / vl)
					end
					log(string.format("lower-arm anchor %s on the IK %s: p %.1f y %.1f r %.1f, forearm %.1f cm, Z=%s%s | %s",
						side == 0 and "L" or "R", L.bone[side], p, y, r, fl, sn < 0 and "-" or "+", L.Z_AXIS[side], table.concat(t, " | ")))
				end
				return
			end
		end
	end
	if not L.on and ik ~= nil and ik.exists() and ik.boneLoc ~= nil then
		local s, e = ik.boneLoc(M.UPPER.bone[side]), ik.boneLoc(M.FORE.lower[side])
		if s ~= nil and e ~= nil then sx, sy, sz, ex, ey, ez, src = s.X, s.Y, s.Z, e.X, e.Y, e.Z, "IK" end
	end
	local b = math.rad(bodyYaw)
	local fx, fy = math.cos(b), math.sin(b)
	local sg = side == 0 and -1.0 or 1.0
	if sx == nil then
		local F = M.FORE
		sx, sy, sz = hp.X - fx * F.BACK - fy * sg * F.SIDE, hp.Y - fy * F.BACK + fx * sg * F.SIDE, hp.Z - F.DROP
		local w = nil
		if A.hand ~= nil and D.uevrUtils.getValid(A.hand) ~= nil then w = A.hand:GetSocketLocation(faName(M.FORE.bone[side])) end
		if w == nil then
			local c = D.controllers ~= nil and D.controllers.getController(side) or nil
			if c ~= nil then w = c:K2_GetComponentLocation() end
		end
		if w == nil then return end
		ex, ey, ez = M.elbowGuess(sx, sy, sz, w.X, w.Y, w.Z, F.LU, F.LF,
			-fy * sg * F.POLE_OUT - fx * F.POLE_BACK, fx * sg * F.POLE_OUT - fy * F.POLE_BACK, -1.0)
		if L.on then sx, sy, sz = w.X, w.Y, w.Z end -- step 121: no IK arms: wrist -> guessed elbow, face the eyes
	end
	local p, y, r = M.upperRot(sx, sy, sz, ex, ey, ez, bodyYaw, side, M.UPPER.FACE_FWD, M.UPPER.UP_BIAS, hp.X, hp.Y, hp.Z)
	uaLoc.X, uaLoc.Y, uaLoc.Z = sx, sy, sz
	uaRot.Pitch, uaRot.Yaw, uaRot.Roll = p, y, r
	A.comp:K2_SetWorldLocationAndRotation(uaLoc, uaRot, false, D.hr, true)
	if not A.logged then
		A.logged = true
		log(string.format("upper-arm anchor %s placed: p %.1f y %.1f r %.1f, arm %.1f cm (%s)", side == 0 and "L" or "R", p, y, r,
			math.sqrt((ex - sx) ^ 2 + (ey - sy) ^ 2 + (ez - sz) ^ 2), src))
	end
end
-- step 118: shoulder joint of the IK arm (world cm) for side 0 left / 1 right, nil without IK arms
function M.shoulderLoc(side)
	local ik = D ~= nil and D.ik ~= nil and D.ik() or nil
	if ik == nil or not ik.exists() or ik.boneLoc == nil then return nil end
	local s = ik.boneLoc(M.UPPER.bone[side])
	if s == nil then return nil end
	return s.X, s.Y, s.Z
end
-- step 125: elbow (LowerArm bone) and shoulder (UpperArm bone) joints of the IK arm (world cm), nil without IK arms
function M.elbowLoc(side)
	local ik = D ~= nil and D.ik ~= nil and D.ik() or nil
	if ik == nil or not ik.exists() or ik.boneLoc == nil then return nil end
	local e, s = ik.boneLoc(M.LOWER.bone[side]), ik.boneLoc(M.UPPER.bone[side])
	if e == nil or s == nil then return nil end
	return e.X, e.Y, e.Z, s.X, s.Y, s.Z
end
-- step 122 (headset 2026-11-20c: heals on the IK gloves): the IK lower-arm frame of the HUD anchor, as numbers:
-- wrist (Hand bone, world cm), X, Y (toward the elbow), Z (face) unit axes = 12 numbers; nil without IK arms
function M.gloveFrame(side)
	local ik = D ~= nil and D.ik ~= nil and D.ik() or nil
	local L = M.LOWER
	if ik == nil or not ik.exists() or ik.boneLoc == nil or ik.boneRot == nil then return nil end
	local w, e, br = ik.boneLoc(L.hand[side]), ik.boneLoc(L.bone[side]), ik.boneRot(L.bone[side])
	if w == nil or e == nil or br == nil then return nil end
	local ax, ay, az = M.boneAxis(br.Pitch, br.Yaw, br.Roll, L.Z_AXIS[side])
	local sn = L.Z_SIGN[side]
	local xx, xy, xz, yx, yy, yz, zx, zy, zz = M.lowerAxes(w.X, w.Y, w.Z, e.X, e.Y, e.Z, ax * sn, ay * sn, az * sn)
	if xx == nil then return nil end
	return w.X, w.Y, w.Z, xx, xy, xz, yx, yy, yz, zx, zy, zz
end
-- once per frame: from the post stereo-view callback, else from foreTick for a frame the callback missed
-- step 127 (headset 2026-11-21c: accessories always on top of the arm; user: under the forearm, only there when
-- looked at, like the compass/coin): palm-side anchor. Y = wrist (IK Hand bone) -> elbow (IK LowerArm bone), face (Z)
-- = the controller's palm side (right hand -Y, left +Y) squared to the forearm, so it rolls with the wrist.
-- No IK arms: controller location, elbow PALM.FALLBACK_CM back along the controller. M.palmFacing(side) = cos of the
-- angle between the face and the eyes (callers hide what is not turned toward the eyes).
M.PALM = { TAG = "qd_palmarm", AXIS_SIGN = { [0] = 1.0, [1] = -1.0 }, FALLBACK_CM = 25.0 }
local PA = { [0] = { comp = nil, want = false, users = {}, logged = false, err = false, facing = nil },
	[1] = { comp = nil, want = false, users = {}, logged = false, err = false, facing = nil } }
M.PA = PA
function M.palmAnchor(side, who)
	local A = PA[side]
	A.users[who or "_"] = true
	A.want = true
	if A.comp ~= nil and D.uevrUtils.getValid(A.comp) ~= nil then return A.comp end
	A.comp = nil
	local now = os.clock()
	if now < UAS.failT then return nil end
	local c = nil
	pcall(function() c = D.uevrUtils.create_component_of_class("Class /Script/Engine.SceneComponent", true, nil, false, nil, M.PALM.TAG) end)
	if c == nil then UAS.failT = now + 5.0 logOnce("nopalm" .. side, "palm-side anchor creation failed") return nil end
	pcall(function() c:SetWorldScale3D(faScale) end)
	A.comp, A.logged, A.facing = c, false, nil
	log("palm-side anchor " .. (side == 0 and "L" or "R") .. " created")
	return c
end
function M.palmRelease(side, who)
	local A = PA[side]
	A.users[who or "_"] = nil
	A.want = next(A.users) ~= nil
end
function M.palmFacing(side) return PA[side].facing end
local function palmSide(side, hp)
	local A = PA[side]
	if A.comp == nil then return end
	if D.uevrUtils.getValid(A.comp) == nil then A.comp = nil return end
	local c = D.controllers ~= nil and D.controllers.getController(side) or nil
	if c == nil then return end
	local rv = c:GetRightVector()
	local sn = M.PALM.AXIS_SIGN[side]
	local ax, ay, az = rv.X * sn, rv.Y * sn, rv.Z * sn
	local wx, wy, wz, ex, ey, ez, src = nil, nil, nil, nil, nil, nil, "IK"
	local ik = D.ik ~= nil and D.ik() or nil
	local L = M.LOWER
	if ik ~= nil and ik.exists() and ik.boneLoc ~= nil then
		local w, e = ik.boneLoc(L.hand[side]), ik.boneLoc(L.bone[side])
		if w ~= nil and e ~= nil then wx, wy, wz, ex, ey, ez = w.X, w.Y, w.Z, e.X, e.Y, e.Z end
	end
	if wx == nil then
		local p, f = c:K2_GetComponentLocation(), c:GetForwardVector()
		local k = M.PALM.FALLBACK_CM
		wx, wy, wz, ex, ey, ez, src = p.X, p.Y, p.Z, p.X - f.X * k, p.Y - f.Y * k, p.Z - f.Z * k, "controller"
	end
	local xx, xy, xz, _, _, _, zx, zy, zz = M.lowerAxes(wx, wy, wz, ex, ey, ez, ax, ay, az)
	if xx == nil then return end
	local p, y, r = M.axesRot(xx, xy, xz, zx, zy, zz)
	uaLoc.X, uaLoc.Y, uaLoc.Z = wx, wy, wz
	uaRot.Pitch, uaRot.Yaw, uaRot.Roll = p, y, r
	A.comp:K2_SetWorldLocationAndRotation(uaLoc, uaRot, false, D.hr, true)
	local vx, vy, vz = hp.X - wx, hp.Y - wy, hp.Z - wz
	local vl = math.max(1e-3, math.sqrt(vx * vx + vy * vy + vz * vz))
	A.facing = (zx * vx + zy * vy + zz * vz) / vl
	if not A.logged then
		A.logged = true
		log(string.format("palm-side anchor %s placed (%s): p %.1f y %.1f r %.1f, facing the eyes %.2f", side == 0 and "L" or "R", src, p, y, r, A.facing))
	end
end
function M.upperLate()
	if D == nil or UAS.done == UAS.frame then return end
	UAS.done = UAS.frame
	if not UA[0].want and not UA[1].want and not PA[0].want and not PA[1].want then return end
	local head = D.controllers ~= nil and D.controllers.getController(2) or nil
	if head == nil then return end
	local hp, hr = head:K2_GetComponentLocation(), head:K2_GetComponentRotation()
	for side = 0, 1 do
		if PA[side].want then
			local ok, err = pcall(palmSide, side, hp)
			if not ok and not PA[side].err then PA[side].err = true log("palm-side anchor error: " .. tostring(err)) end
		end
	end
	if not UA[0].want and not UA[1].want then return end
	local U = M.UPPER
	UAS.bodyYaw = M.followYaw(UAS.bodyYaw, hr.Yaw, U.DEAD, U.RATE, UAS.dt, U.DRIFT)
	for side = 0, 1 do
		if UA[side].want then
			local ok, err = pcall(upperSide, side, hp, UAS.bodyYaw)
			if not ok and not UA[side].err then UA[side].err = true log("upper-arm anchor error: " .. tostring(err)) end
		end
	end
end

-- every pre-engine tick (not throttled): turn the wanted anchors
function M.foreTick(dt)
	if D == nil then return end
	if not UAS.cb then
		UAS.cb = true
		local okR = pcall(function() D.uevrUtils.registerPostCalculateStereoViewCallback(function() pcall(M.upperLate) end, -10) end)
		log("upper-arm late callback " .. tostring(okR))
	end
	pcall(M.upperLate) -- the previous frame, if the view callback did not run
	UAS.frame, UAS.dt = UAS.frame + 1, dt or 0.0
	for side = 0, 1 do
		if FA[side].want then
			local ok, err = pcall(foreSide, side)
			if not ok and not FA[side].err then FA[side].err = true log("forearm anchor error: " .. tostring(err)) end
		end
	end
end

local function ensurePanel(hand)
	local up = D.configui.getValue("arm_hud_upper") == true -- step 117
	local fa = not up and D.configui.getValue("arm_hud_forearm") == true
	local parent = nil
	if up then parent = M.upperAnchor(0, hand) else M.upperRelease(0) end
	if fa then parent = M.foreAnchor(0, hand) else M.foreRelease(0) end
	if parent == nil then fa, up = false, false end
	if up then fa = 2 end
	if S.hand ~= nil and S.hand == hand and S.fa == fa and S.parent == parent and S.panel ~= nil and D.uevrUtils.getValid(S.panel) ~= nil then return true end
	destroy()
	S.hand, S.fa, S.parent = hand, fa, parent
	local p = D.uevrUtils.create_component_of_class("Class /Script/Engine.SceneComponent", true, nil, false, hand:GetOwner())
	if p == nil then logOnce("nopanel", "panel component creation failed") return false end
	if fa then
		p:K2_AttachToComponent(parent, D.uevrUtils.fname_from_string(""), 2, 2, 2, false)
	else
		p:K2_AttachToComponent(hand, D.uevrUtils.fname_from_string(M.BONE), 2, 2, 2, false)
	end
	S.panel = p
	log("panel on " .. (fa == 2 and (M.LOWER.on and "the left lower-arm anchor" or "the left upper-arm anchor") or fa and "the left forearm anchor" or M.BONE))
	return true
end

local function placePanel(t)
	vloc.X, vloc.Y, vloc.Z = t.x, t.y, t.z
	vrot.Pitch, vrot.Yaw, vrot.Roll = t.pitch, t.yaw, t.roll
	S.panel:K2_SetRelativeLocationAndRotation(vloc, vrot, false, D.hr, true)
	vscale.X, vscale.Y, vscale.Z = 1.0, 1.0, 1.0
	S.panel:SetWorldScale3D(vscale) -- cm sizes regardless of the hand mesh scale
	for k in pairs(M.DEFAULTS) do S.tune[k] = t[k] end
	S.layoutDirty = true
end

-- ---- values (each read in pcall; unknown sources logged once, bar then stays empty) ----
local function funcByPattern(obj, pat)
	local found = nil
	pcall(function()
		local c = obj:get_class()
		while c ~= nil and found == nil do
			local f = c:get_children()
			while f ~= nil do
				local n = f:get_fname():to_string()
				if n:find(pat) then found = n break end
				f = f:get_next()
			end
			c = c:get_super()
		end
	end)
	return found
end

local function readValues(pawn)
	local v = S.val
	v.hp, v.hpMax = nil, nil
	pcall(function() v.hp = pawn.Health end)
	pcall(function()
		local a, b = S.outA, S.outB
		a.result, b.result = nil, nil
		pawn:GetMaxHP(false, a, b)
		v.hpMax = a.result
	end)
	local sc = nil
	pcall(function() sc = pawn.HUD.StatusCluster end)
	v.en, v.enMax = nil, nil
	pcall(function() v.en = pawn.EnergyChargeLogic.CurrentPowerCharge end)
	pcall(function()
		local eh = sc.EnergyHUD
		local cs = nil
		pcall(function() cs = eh.ClipSize end)
		if type(cs) == "number" and cs > 0 then v.enMax = cs else v.enMax = eh.PipHolder:GetChildrenCount() end
	end)
	-- power meter ("stamina"): the game's own fill multiplier, function name resolved once (SDK shows it sanitised)
	v.pw = nil
	if S.power == nil then
		S.power = funcByPattern(pawn, "^Get.Power.Meter") or false
		log("power meter function: " .. tostring(S.power))
	end
	if S.power then
		pcall(function()
			local a = S.outA
			a.result = nil
			pawn[S.power](pawn, a)
			v.pw = a.result
		end)
	end
	v.js, v.jsMax, v.jsNext = nil, nil, nil
	local cmax, cdn, ccur, cprog, hmax = nil, nil, nil, nil, nil
	pcall(function()
		local h = sc.FSChargeHUD
		pcall(function() hmax = h.CurrentMaxChargeCount end)
		local cc = nil
		pcall(function() cc = h.ChargeComp end)
		if cc ~= nil then
			if S.jsComp ~= cc then S.jsComp, S.jsSeen, S.jsPrev = cc, nil, nil end
			pcall(function() ccur = cc.CurrentCharges end)
			pcall(function() cmax = cc.MaxChargeCount end)
			pcall(function() cdn = cc.ChargeCooldown end)
			pcall(function() cprog = cc.NextChargeProgress end)
		end
		if type(ccur) == "number" then
			if S.jsSeen == nil or ccur > S.jsSeen then S.jsSeen = ccur end
			v.js = M.usable(ccur, S.jsSeen, M.pipMax(hmax, cmax)) or math.max(0, math.floor(ccur))
			v.jsNext = M.nextFor(v.js, S.jsPrev, M.chargeNext(cprog, cdn))
			S.jsPrev = v.js
		else -- component unreadable: the HUD's event-driven (possibly stale) count
			pcall(function() v.js = h.LastChargeCount end)
		end
		v.jsMax = M.pipMax(hmax, cmax) or M.pipCount(nil, nil, S.jsSeen)
	end)
	if not S.logged.vals and v.hp ~= nil then
		S.logged.vals = true
		log(string.format("values hp %s/%s energy %s/%s power %s jump %s/%s next %s (comp cur %s max %s prog %s cd %s)", tostring(v.hp), tostring(v.hpMax),
			tostring(v.en), tostring(v.enMax), tostring(v.pw), tostring(v.js), tostring(v.jsMax), tostring(v.jsNext),
			tostring(ccur), tostring(cmax), tostring(cprog), tostring(cdn)))
	end
end

-- ---- drawing ----
-- switch a bar between pips (n >= 1) and the continuous bar (n = 0): hide leftover parts (no ghost pips / double bars)
local function setMode(name, n)
	if S.pipN[name] == n then return end
	for k = 1, M.MAX_PIPS do
		for _, sfx in ipairs({ "_p" .. k .. "_bg", "_p" .. k }) do
			local c = S.parts[name .. sfx]
			if c ~= nil then
				if k > n then pcall(function() c:SetHiddenInGame(true, false) end)
				elseif S.vis then pcall(function() c:SetHiddenInGame(false, false) end) end
			end
		end
	end
	for _, sfx in ipairs({ "_bg", "_fill" }) do
		local c = S.parts[name .. sfx]
		if c ~= nil then
			if n > 0 then pcall(function() c:SetHiddenInGame(true, false) end)
			elseif S.vis then pcall(function() c:SetHiddenInGame(false, false) end) end
		end
	end
	S.pipN[name] = n
	S.layoutDirty = true
end

local function drawContinuous(name, b, f, t)
	setMode(name, 0)
	local bg = part(name .. "_bg", M.COLOR.bg)
	local fill = part(name .. "_fill", M.COLOR[name])
	if S.layoutDirty then put(bg, 0.0, b, M.BG_Z, t.len, t.width, M.THICK) end
	local c, l = M.fillSpan(f, t.len)
	put(fill, c, b, M.FILL_Z, l, t.width * 0.8, M.THICK)
end

local function drawPips(name, b, cur, max, extra, t)
	local n = math.floor(max + 0.5)
	setMode(name, n)
	local nrows = n > 6 and 2 or 1
	local w = M.pipWidth(nrows, t.width, t.gap)
	for k = 1, n do
		local col, row, cols = M.pipCell(k, n)
		local a, pl = M.pipSpan(col, cols, t.len, M.PIP_GAP)
		local bb = b + M.rowOffset(row, nrows, t.gap)
		local bg = part(name .. "_p" .. k .. "_bg", M.COLOR.bg)
		local fill = part(name .. "_p" .. k, M.COLOR[name])
		if S.layoutDirty then put(bg, a, bb, M.BG_Z, pl, w, M.THICK) end
		local f = M.pipFill(k, cur, extra)
		put(fill, a - pl / 2 + pl * f / 2, bb, M.FILL_Z, pl * f, w * 0.8, M.THICK)
	end
end

local function draw(t)
	local v = S.val
	local n = #M.BARS
	-- bars stacked across the back of the hand in M.BARS order
	local b1, b2, b3, b4 = M.barOffset(1, n, t.gap), M.barOffset(2, n, t.gap), M.barOffset(3, n, t.gap), M.barOffset(4, n, t.gap)
	drawContinuous("hp", b1, M.frac(v.hp, v.hpMax) or 0, t)
	if type(v.enMax) == "number" and M.usePips(math.floor(v.enMax + 0.5)) then
		drawPips("energy", b2, v.en, v.enMax, nil, t)
	else
		drawContinuous("energy", b2, M.frac(v.en, v.enMax) or 0, t)
	end
	drawContinuous("power", b3, type(v.pw) == "number" and math.max(0, math.min(1, v.pw)) or 0, t)
	if type(v.jsMax) == "number" and M.usePips(math.floor(v.jsMax + 0.5)) then
		drawPips("jump", b4, v.js, v.jsMax, v.jsNext, t)
	else
		drawContinuous("jump", b4, M.frac(v.js, v.jsMax) or 0, t)
	end
	S.layoutDirty = false
end

local function setVis(on)
	if S.vis == on then return end
	S.vis = on
	if S.panel ~= nil then pcall(function() S.panel:SetHiddenInGame(not on, true) end) end
	if on then -- pips beyond the current count stay hidden
		for name, n in pairs(S.pipN) do
			for k = n + 1, M.MAX_PIPS do
				for _, sfx in ipairs({ "_p" .. k .. "_bg", "_p" .. k }) do
					local c = S.parts[name .. sfx]
					if c ~= nil then pcall(function() c:SetHiddenInGame(true, false) end) end
				end
			end
			if n > 0 then
				for _, sfx in ipairs({ "_bg", "_fill" }) do
					local c = S.parts[name .. sfx]
					if c ~= nil then pcall(function() c:SetHiddenInGame(true, false) end) end
				end
			end
		end
	end
end

-- every pre-engine tick; play = regular unpaused play
function M.tick(dt, play)
	if D == nil then return end
	S.t = S.t + (dt or 0)
	if S.t < M.REFRESH_S then return end
	S.t = 0.0
	local hand = nil
	pcall(function() hand = D.hands.getHandComponent(Handed.Left) end)
	local on = M.enabled() and play and hand ~= nil and D.uevrUtils.getValid(hand) ~= nil
	if on and D.configui.getValue("left_hand_hidden") ~= true then
		local hv = true
		pcall(function() hv = hand.bVisible ~= false end)
		on = hv -- menus hide the hand: hide with it
	end
	if not on then setVis(false) M.foreRelease(0) M.upperRelease(0) return end
	if not ensurePanel(hand) then return end
	M.readTuning(D.configui.getValue, S.tuneNow)
	if not sameTuning(S.tune, S.tuneNow) then placePanel(S.tuneNow) end
	local pawn = D.api:get_local_pawn(0)
	if pawn == nil then return end
	readValues(pawn)
	draw(S.tuneNow)
	setVis(true)
end

-- ---- step 76: coin counter under the compass (palm side: only seen with the hand turned) ----
M.COIN_KEY = "Coin"   -- the coin item's object name (Test 66b discovery)
M.COIN_CM = 3.5       -- card width
M.COIN_BELOW_CM = 4.5 -- below the compass centre, in the compass plane
M.COIN_MESH = "StaticMesh /Game/Items/Treasure/Coins/Coin_00_SM.Coin_00_SM"
M.COIN_MAT = "MaterialInstanceConstant /Game/Items/Treasure/Coins/Coin_00_MI.Coin_00_MI"
M.COIN_DIAM_CM = 2.5  -- the mesh is ~10 cm across
M.COIN_MESH_CM = 10.0
M.COIN_SPIN = 0.0     -- deg/s; 0 = static (user 2026-11-17: no spinning below the cuff)
M.COIN_YAW = 0.0      -- static, face-on (user 2026-11-17: no rim turn needed)
M.COIN_PITCH = 90.0   -- step 100: the disc lies in the mesh X/Y plane (thin along Z); the compass widget plane is its
                      -- Y/Z plane (faces +X) -> pitch 90 lays the coin face in the compass plane (headset: edge was seen)
M.COIN_UP_CM = 0.7    -- coin centre above the card centre (the number sits bottom right of the card)
local C = { t = 0.0, item = nil, findT = 0.0, card = nil, parent = nil, vis = nil, count = nil,
	coin = nil, coinTry = 0.0, coinFail = false, angle = 0.0, cs = 1.0, loc = { X = 0.0, Y = 0.0, Z = 0.0 },
	rot = { Pitch = 0.0, Yaw = 0.0, Roll = 90.0 }, scl = { X = 1.0, Y = 1.0, Z = 1.0 }, frameHidden = false }
M.C = C

local function findCoin(pawn)
	if C.item ~= nil or os.clock() < C.findT then return C.item end
	C.findT = os.clock() + 5.0
	pcall(function()
		local cls = pawn.CurrentInHandWeapon.ItemData:get_class()
		local all = UEVR_UObjectHook.get_objects_by_class(cls, false)
		for i = 1, #all do
			if all[i]:get_fname():to_string() == M.COIN_KEY then C.item = all[i] break end
		end
	end)
	logOnce("coin", "coin item " .. (C.item ~= nil and "found" or "not found (retrying)"))
	if C.item == nil then S.logged.coin = nil end
	return C.item
end

local function coinVis(on)
	if C.vis == on or C.card == nil then return end
	C.vis = on
	pcall(function() C.card.comp:SetVisibility(on, true) end)
	if C.coin ~= nil then pcall(function() C.coin:SetVisibility(on, false) end) end
end

-- the card without its frame/background (read-only use of qd_belt's slot fields; our instance only)
local function stripFrame(card, hideIcon)
	pcall(function() if card.bg ~= nil then card.bg:SetVisibility(2) end end)
	pcall(function() if card.edges ~= nil then for k = 1, #card.edges do card.edges[k]:SetVisibility(2) end end end)
	pcall(function() if hideIcon and card.img ~= nil then card.img:SetVisibility(2) end end)
end

local function ensureCoin(owner)
	if C.coin ~= nil and D.uevrUtils.getValid(C.coin) ~= nil then return C.coin end
	C.coin = nil
	if C.coinFail or os.clock() < C.coinTry then return nil end
	C.coinTry = os.clock() + 5.0
	local c = nil
	pcall(function()
		c = D.uevrUtils.createStaticMeshComponent(M.COIN_MESH, { parent = owner, manualAttachment = true, collisionEnabled = false })
	end)
	if c == nil then
		C.coinFail = true
		log("coin model failed to load (icon without frame)")
		return nil
	end
	pcall(function() c:SetCastShadow(false) end)
	pcall(function() c:SetCollisionEnabled(0) end)
	pcall(function()
		local mat = D.api:find_uobject(M.COIN_MAT)
		if mat ~= nil then c:SetMaterial(0, mat) end
	end)
	C.coin, C.parent = c, nil
	log("coin model created")
	return c
end

-- spin about the vertical axis of the compass plane (disc stands on edge: roll 90, yaw advances)
local function spinCoin(dt)
	if M.COIN_SPIN == 0 or C.coin == nil or C.vis ~= true or C.parent == nil then return end
	C.angle = (C.angle + M.COIN_SPIN * (dt or 0)) % 360.0
	C.rot.Yaw = C.angle
	pcall(function() C.coin:K2_SetRelativeLocationAndRotation(C.loc, C.rot, false, D.hr, true) end)
end

function M.coinTick(dt, play)
	if D == nil or D.belt == nil then return end
	C.t = C.t + (dt or 0)
	pcall(spinCoin, dt)
	if C.t < 0.5 then return end
	C.t = 0.0
	local compass = D.compass ~= nil and D.compass() or nil
	local on = play and D.configui.getValue("coin_counter") ~= false and compass ~= nil and D.uevrUtils.getValid(compass) ~= nil
	if on then
		local cv = true
		pcall(function() cv = compass.bVisible ~= false end)
		on = cv
	end
	if not on then coinVis(false) return end
	local pawn = D.api:get_local_pawn(0)
	if pawn == nil then return end
	local item = findCoin(pawn)
	if item == nil then coinVis(false) return end
	if C.card == nil or D.uevrUtils.getValid(C.card.comp) == nil then
		C.card, C.parent = D.belt.counterCard(), nil
		if C.card == nil then return end
		C.vis = nil
		C.frameHidden = false
	end
	local coin = ensureCoin(C.card.comp:GetOwner())
	if not C.frameHidden then
		stripFrame(C.card, coin ~= nil)
		C.frameHidden = coin ~= nil or C.coinFail
	end
	if coin ~= nil and C.parent == compass and C.coinParent ~= compass then C.parent = nil end
	if C.parent ~= compass then
		local ok = pcall(function()
			C.card.comp:K2_AttachToComponent(compass, D.uevrUtils.fname_from_string(""), 0, 0, 0, false)
			local cs = compass:K2_GetComponentScale().X
			if cs == nil or cs <= 0 then cs = 0.01 end
			vloc.X, vloc.Y, vloc.Z = 0.0, 0.0, -M.COIN_BELOW_CM / cs
			vrot.Pitch, vrot.Yaw, vrot.Roll = 0.0, 0.0, 0.0
			C.card.comp:K2_SetRelativeLocationAndRotation(vloc, vrot, false, D.hr, true)
			local s = M.COIN_CM / 64 / cs -- belt cards are 64 px
			vscale.X, vscale.Y, vscale.Z = s, s, s
			C.card.comp:SetRelativeScale3D(vscale)
			if coin ~= nil then
				coin:K2_AttachToComponent(compass, D.uevrUtils.fname_from_string(""), 0, 0, 0, false)
				C.cs = cs
				C.loc.X, C.loc.Y, C.loc.Z = 0.0, 0.0, (M.COIN_UP_CM - M.COIN_BELOW_CM) / cs
				local k = M.COIN_DIAM_CM / M.COIN_MESH_CM / cs
				C.scl.X, C.scl.Y, C.scl.Z = k, k, k
				coin:SetRelativeScale3D(C.scl)
				if M.COIN_SPIN == 0 then C.rot.Yaw = M.COIN_YAW end
				if M.COIN_SPIN == 0 then C.rot.Pitch, C.rot.Roll = M.COIN_PITCH, 0.0 end -- roll 90 (spin mode) stood the disc sideways
				coin:K2_SetRelativeLocationAndRotation(C.loc, C.rot, false, D.hr, true)
				C.coinParent = compass
			end
		end)
		if ok then C.parent = compass log("coin counter under the compass, model " .. tostring(coin ~= nil)) end
	end
	local n = nil
	pcall(function()
		local gi = D.api:get_engine().GameViewport.World.OwningGameInstance
		n = gi:ReadInventoryItemCount(item)
	end)
	local icon = nil
	pcall(function() icon = item.ItemIcon end)
	D.belt.counterSet(C.card, icon, n or 0)
	coinVis(true)
end

function M.reset()
	destroy()
	for side = 0, 1 do -- step 114
		local A = FA[side]
		if A.comp ~= nil then pcall(function() A.comp:K2_DestroyComponent(A.comp) end) end
		A.comp, A.hand, A.want, A.logged = nil, nil, false, false
		local U = UA[side] -- step 117
		if U.comp ~= nil then pcall(function() local o = U.comp:GetOwner() if o ~= nil then o:K2_DestroyActor() end end) end
		U.comp, U.hand, U.want, U.logged = nil, nil, false, false
		for k in pairs(U.users) do U.users[k] = nil end
	end
	UAS.bodyYaw = nil
	if C.card ~= nil then coinVis(false) end
	if C.coin ~= nil then pcall(function() C.coin:K2_DestroyComponent(C.coin) end) C.coin, C.coinParent = nil, nil end
end

return M
