-- Step 82: 3D belt skin for qd_belt (option belt_3d, experimental). qd_belt keeps all logic (items, selection, grab, scroll,
-- heal card, counts); this lib only shows each item's model hanging from a belt ring by a short tie, with an inverted-hull
-- outline for the grab target / use-button selection, and the count as a frameless label below the model.
-- Assets are data constants below (names generic). Log tag [BELT3D].
local M = {}

M.RING_MESH = "KnifeBelt_SM"      -- leather belt-loop mesh (short name, loaded in this game); closed loop, height along its X
M.TIE_MESH = "gd_chain_01"        -- short straight chain piece (long axis Z); fallback: engine cylinder
M.CUBE = "StaticMesh /Engine/BasicShapes/Cube.Cube"
M.CYL = "StaticMesh /Engine/BasicShapes/Cylinder.Cylinder"
M.CONE = "StaticMesh /Engine/BasicShapes/Cone.Cone" -- step 92: peek (scroll) arrowhead; tip +Z, 100 uu tall, radius 50
M.ARROW_LEN_F = 0.6    -- arrow length vs the model size option
M.ARROW_W_F = 0.55     -- base diameter vs its length
M.MAT = "Material /Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial" -- opaque, one-sided, lit, vector param "Color"
M.TAG = "qd_belt3d"
M.HANG_CM = 8.0        -- model centre this far below the strap (M.HANG_UP false)
M.HANG_UP = true       -- step 88 (user 2026-11-17): items stand above the ring (hanging below, the ring hid them)
M.UP_GAP_CM = 2.0      -- gap between the strap top and the model's bottom when standing up
M.RING_YAW = 95.0       -- deg: ring mesh turned about the vertical so its tail loops face backwards
M.RING_H_CM = 3.0      -- belt strap height
M.TILT_DEG = 35.0      -- front of the model leans up toward the eyes (option belt_3d_tilt)
M.PEEK_F = 0.6         -- peek items: smaller
M.HOVER_F = 1.25
M.CYAN_F = 0.6         -- use-button selection rim is thinner than the gold one
M.LABEL_K = 0.6        -- count label scale vs a card
M.MIN_CM = 1.5         -- thinnest extent of a flat model
M.MAX_CM = 14.0        -- longest side cap when widening a flat model
M.TIE_R_CM = 0.3
M.BAND_DEG0, M.BAND_DEG1, M.BAND_SEG_DEG = -110.0, 110.0, 12.0 -- cube band fallback (front arc)
local C_GOLD = {R = 1.0, G = 0.72, B = 0.1, A = 1.0}
local C_CYAN = {R = 0.35, G = 0.85, B = 1.0, A = 1.0}
local C_GREY = {R = 0.55, G = 0.55, B = 0.55, A = 1.0}
local C_LEATHER = {R = 0.22, G = 0.12, B = 0.06, A = 1.0}
local C_TAN = {R = 0.75, G = 0.6, B = 0.35, A = 1.0}
local C_OFF = {R = 0.3, G = 0.3, B = 0.3, A = 1.0} -- step 120: can't use now (shell)
local C_RED = {R = 0.9, G = 0.08, B = 0.06, A = 1.0} -- step 120: can't use now (X)
local COLORS = {gold = C_GOLD, cyan = C_CYAN, grey = C_GREY, off = C_OFF}
M.X_F, M.X_THICK_CM = 0.7, 0.6 -- step 120: red X arm length vs the model size, bar thickness

-- ---- pure helpers (unit tested) ----
-- uniform scale so the longest side = sizeCm; the thinnest extent is kept >= MIN_CM unless the longest side would pass MAX_CM
function M.fit(hx, hy, hz, sizeCm)
	if type(hx) ~= "number" or type(hy) ~= "number" or type(hz) ~= "number" or type(sizeCm) ~= "number" or sizeCm <= 0 then return nil end
	local mx = math.max(hx, hy, hz)
	local mn = math.min(hx, hy, hz)
	if mx < 0.01 then return nil end
	local sc = sizeCm / (2 * mx)
	if mn > 0.001 and 2 * mn * sc < M.MIN_CM then
		local s2 = M.MIN_CM / (2 * mn)
		if 2 * mx * s2 > M.MAX_CM then s2 = M.MAX_CM / (2 * mx) end
		if s2 > sc then sc = s2 end
	end
	if sc > 50.0 then sc = 50.0 end
	return sc
end
-- hull scale factor: at least 10 percent, at least 0.6 cm of rim
function M.hullK(sizeCm) return 1.0 + math.max(0.10, 0.6 / math.max(sizeCm, 0.1)) end
function M.hullKFor(k, factor) return 1.0 + (k - 1.0) * factor end
-- mesh/hull relative locations (pivot = bounds centre) for mesh scale sc, hull factor k, mesh bounds origin (ox, oy, oz)
function M.hullXform(sc, k, ox, oy, oz)
	return -ox * sc, -oy * sc, -oz * sc, -ox * sc * k, -oy * sc * k, -oz * sc * k, sc * k
end
-- belt-local position (x forward, y right) of a slot at angle ang (deg) on radius r, height dz
function M.slotLocal(ang, r, dz)
	local a = math.rad(ang)
	return math.cos(a) * r, math.sin(a) * r, dz
end
-- step 92: arrowhead rotation: cone tip (+Z) along the belt tangent, toward the scroll side (dir +1 = increasing angle,
-- i.e. right; -1 = left). Pitch -90 turns +Z onto +X, then yaw. Pure.
function M.arrowRot(ang, dir) return -90.0, ang + (dir < 0 and -90.0 or 90.0), 0.0 end
-- pivot rotation: front faces outward (yaw = slot angle), pitched up toward the eyes; pitch, yaw, roll
function M.modelRot(ang, tilt) return tilt, ang, 0.0 end
-- outline state: colour key (nil = none), border factor, model scale factor. Mirrors the card frames: hover = gold,
-- use-button selection = cyan, both = gold, peek = grey, held = none
function M.hullState(hover, sel, peek, held, off)
	if held then return nil, 0.0, 1.0 end
	if peek then return "grey", M.CYAN_F, 1.0 end
	if hover then return "gold", 1.0, M.HOVER_F end
	if off then return "off", 1.0, 1.0 end -- step 120: can't use now
	if sel then return "cyan", M.CYAN_F, 1.0 end
	return nil, 0.0, 1.0
end
-- rotation (pitch, yaw) that makes a widget at (px,py,pz) face (hx,hy,hz); belt-local
function M.labelRot(px, py, pz, hx, hy, hz)
	local dx, dy, dz = hx - px, hy - py, hz - pz
	return math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), math.deg(math.atan(dy, dx))
end
-- chain tie of length len hanging from the strap point: uniform scale and mesh-relative offset (half Z extent, origin)
function M.tieXform(halfZ, ox, oy, oz, len, up)
	if type(halfZ) ~= "number" or halfZ < 0.01 then return nil end
	local s = len / (2 * halfZ)
	return s, -ox * s, -oy * s, (up and len / 2 or -len / 2) - oz * s
end
-- step 88: model centre height vs the strap centre (pure): above the strap by half the model + a gap, else hanging below
function M.hangDz(sizeCm, up)
	if up then return M.RING_H_CM / 2 + M.UP_GAP_CM + sizeCm / 2 end
	return -M.HANG_CM
end
-- belt ring from a closed-loop mesh (full extents ex = height axis, ey, ez = loop plane; bounds origin o), rotated pitch 90
-- (local X -> up, local Z -> -forward). Returns sx, sy, sz, lx, ly, lz (relative loc puts the loop centre on the belt centre)
function M.ringXform(ex, ey, ez, ox, oy, oz, radius, heightCm)
	if ex < 0.01 or ey < 0.01 or ez < 0.01 then return nil end
	local sx, sy, sz = heightCm / ex, 2 * radius / ey, 2 * radius / ez
	local px, py, pz = ox * sx, oy * sy, oz * sz
	-- pitch 90: x' = -z, y' = y, z' = x
	return sx, sy, sz, pz, -py, -px
end
-- cube band fallback: chords from a0 to a1 deg on radius r. out.x/y/yaw/len filled; returns count
function M.arcSegs(a0, a1, segDeg, r, out)
	local n = math.max(1, math.ceil((a1 - a0) / segDeg - 1e-9))
	local d = (a1 - a0) / n
	for k = 1, n do
		local am = a0 + (k - 0.5) * d
		local x, y = M.slotLocal(am, r, 0)
		out.x[k], out.y[k], out.yaw[k] = x, y, am + 90.0
		out.len[k] = 2 * r * math.sin(math.rad(d) / 2) * 1.04
	end
	return n
end

-- ---- runtime ----
local D = nil
local S3 = {root = nil, strap = {}, nStrap = 0, ring = false, size = 9.0, tilt = M.TILT_DEG, drop = 60.0, gen = 0, optT = 0.0, chkT = 0.0, failT = 0.0,
	vStrap = nil, none = nil, tieTried = nil, tieMesh = nil, tieHalf = 0, tieO = nil}
local C = {} -- per slot index cache
local V = {loc = {X = 0, Y = 0, Z = 0}, rot = {Pitch = 0, Yaw = 0, Roll = 0}, scl = {X = 1, Y = 1, Z = 1}}
local RL = {X = 0, Y = 0, Z = 0}
local RR = {Pitch = 0, Yaw = 0, Roll = 0}
local BAND = {x = {}, y = {}, yaw = {}, len = {}}
M.S3 = S3
M.C = C

local function log(msg) if D ~= nil and D.log ~= nil then D.log("[BELT3D] " .. msg) end end
local function radius() return (D ~= nil and D.belt ~= nil and D.belt.RADIUS) or 24.0 end

function M.init(deps)
	D = deps
	if D.belt ~= nil then D.belt.skin = M end
	log("init")
end

-- step 88: grab sphere height vs the belt row (qd_belt), from the size option
function M.grabDz() return M.hangDz(S3.size or 9.0, M.HANG_UP) end
-- step 121 (headset 2026-11-20: user wants the heals a bit below the IK shoulders, hanging on the chain from them):
-- shoulder items hang SH_HANG_CM of chain below their chain point (model centre below by that + half the model)
M.SH_HANG_CM = 6.0
function M.shoulderDz(sizeCm) return -(M.SH_HANG_CM + sizeCm / 2) end
function M.shGrabDz() return M.shoulderDz(S3.size or 9.0) end -- step 124: grab sphere of the shoulder heals (glove heals sit on their point)

function M.active()
	return D ~= nil and D.belt ~= nil and D.configui.getValue("belt_3d") == true and os.clock() >= S3.failT
end

local function noneName()
	if S3.none == nil then S3.none = D.uevrUtils.fname_from_string("") end
	return S3.none
end

local function attach(c, parent)
	c:K2_AttachToComponent(parent, noneName(), 0, 0, 0, false)
end

local function setRel(comp, x, y, z, p, yw, r, sx, sy, sz)
	V.loc.X, V.loc.Y, V.loc.Z = x, y, z
	V.rot.Pitch, V.rot.Yaw, V.rot.Roll = p, yw, r
	comp:K2_SetRelativeLocationAndRotation(V.loc, V.rot, false, D.hr, true)
	V.scl.X, V.scl.Y, V.scl.Z = sx, sy, sz
	comp:SetRelativeScale3D(V.scl)
end

local function ownerOf(comp) local o = nil pcall(function() o = comp:GetOwner() end) return o end

local function newShape(meshRef, color)
	local c = D.uevrUtils.createStaticMeshComponent(meshRef, {parent = ownerOf(S3.root), manualAttachment = true, collisionEnabled = false})
	if c == nil then return nil end
	pcall(function() c:SetCastShadow(false) end)
	if color ~= nil then
		pcall(function()
			local mat = D.api:find_uobject(M.MAT)
			local mid = mat ~= nil and c:CreateAndSetMaterialInstanceDynamicFromMaterial(0, mat) or nil
			if mid ~= nil then mid:SetVectorParameterValue("Color", color) end
		end)
	end
	pcall(attach, c, S3.root)
	return c
end

local function addStrap(c) S3.nStrap = S3.nStrap + 1 S3.strap[S3.nStrap] = c end

local function buildStrap()
	S3.nStrap, S3.ring = 0, false
	local R = radius()
	local ok = pcall(function()
		local mesh = D.uevrUtils.find_instance_of("Class /Script/Engine.StaticMesh", M.RING_MESH)
		if mesh == nil then return end
		local b = mesh:GetBounds()
		local e, o = b.BoxExtent, b.Origin
		if not (e.X < e.Y and e.X < e.Z) then log("ring mesh has unexpected bounds") return end
		local sx, sy, sz, lx, ly, lz = M.ringXform(2 * e.X, 2 * e.Y, 2 * e.Z, o.X, o.Y, o.Z, R, M.RING_H_CM)
		if sx == nil then return end
		local c = newShape(mesh, nil)
		if c == nil then return end
		local ry = math.rad(M.RING_YAW) -- turn the loop so its buckle loops sit behind the waist
		local cy, sy2 = math.cos(ry), math.sin(ry)
		setRel(c, lx * cy - ly * sy2, lx * sy2 + ly * cy, lz, 90.0, M.RING_YAW, 0.0, sx, sy, sz)
		addStrap(c)
		S3.ring = true
	end)
	if S3.ring then log("strap: belt-loop mesh") return end
	local n = M.arcSegs(M.BAND_DEG0, M.BAND_DEG1, M.BAND_SEG_DEG, R, BAND)
	for k = 1, n do
		local c = newShape(M.CUBE, C_LEATHER)
		if c ~= nil then
			setRel(c, BAND.x[k], BAND.y[k], 0.0, 0.0, BAND.yaw[k], 0.0, 0.4 / 100, BAND.len[k] / 100, M.RING_H_CM / 100)
			addStrap(c)
		end
	end
	log(string.format("strap: cube band fallback (%d segments) ok=%s", n, tostring(ok)))
end

local function loadTie()
	if S3.tieTried then return end
	S3.tieTried = true
	pcall(function()
		local mesh = D.uevrUtils.find_instance_of("Class /Script/Engine.StaticMesh", M.TIE_MESH)
		if mesh == nil then return end
		local b = mesh:GetBounds()
		if b.BoxExtent.Z < b.BoxExtent.X or b.BoxExtent.Z < b.BoxExtent.Y then return end
		S3.tieMesh, S3.tieHalf = mesh, b.BoxExtent.Z
		S3.tieO = {x = b.Origin.X, y = b.Origin.Y, z = b.Origin.Z}
	end)
	log("tie: " .. (S3.tieMesh ~= nil and "chain mesh" or "cylinder"))
end

local function setSlotsDirty()
	local bs = D.belt.S
	for i = 1, D.belt.MAX_CARDS do local s = bs.slots[i] if s ~= nil then s.mscale = nil s.styled = nil end end
end

local function ensure()
	local now = os.clock()
	if S3.root ~= nil and now < S3.chkT then return true end
	S3.chkT = now + 0.5
	if S3.root ~= nil and D.uevrUtils.getValid(S3.root) ~= nil then return true end
	if now < S3.failT then return false end
	for k in pairs(C) do C[k] = nil end
	S3.root, S3.nStrap, S3.vStrap = nil, 0, nil
	local r = nil
	pcall(function() r = D.uevrUtils.create_component_of_class("Class /Script/Engine.SceneComponent", true, nil, false, nil, M.TAG) end)
	if r == nil then S3.failT = now + 5.0 log("root creation failed") return false end
	S3.root = r
	loadTie()
	buildStrap()
	setSlotsDirty()
	log("root created")
	return true
end

local function setV(c, key, comp, v)
	if c[key] == v then return end
	c[key] = v
	if comp ~= nil then pcall(function() comp:SetVisibility(v, false) end) end
end

local function readOpts()
	local now = os.clock()
	if now < S3.optT then return end
	S3.optT = now + 0.5
	local sz = D.configui.getValue("belt_3d_size")
	if type(sz) ~= "number" then sz = 9.0 end
	local tl = D.configui.getValue("belt_3d_tilt")
	if type(tl) ~= "number" then tl = M.TILT_DEG end
	local dr = D.belt ~= nil and D.belt.beltDrop ~= nil and D.belt.beltDrop(D.configui.getValue) or D.configui.getValue("belt_drop") -- step 122
	if type(dr) ~= "number" then dr = 60.0 end
	if sz ~= S3.size or tl ~= S3.tilt or dr ~= S3.drop then
		S3.size, S3.tilt, S3.drop = sz, tl, dr
		S3.gen = S3.gen + 1
	end
end

-- step 123 (headset 2026-11-20d: belt + glove heals "delayed" vs the IK arms): the root is placed in the pre-engine
-- tick, so a free root trailed one frame behind walking/turning. The IK arms mesh rides the pawn root (uevrlib ik.lua
-- K2_AttachTo rootComponent); the belt root now does too (KeepWorld; the world placement below still applies). 2 Hz check.
local attT, attAddr = 0.0, nil
local function followPawn()
	local now = os.clock()
	if now < attT then return end
	attT = now + 0.5
	local pawn = D.uevrUtils.get_local_pawn()
	local rc = pawn ~= nil and pawn.RootComponent or nil
	if rc == nil then return end
	local ra = rc:get_address()
	local par = S3.root.AttachParent
	if par ~= nil and attAddr == ra and par:get_address() == ra then return end
	S3.root:K2_AttachToComponent(rc, D.uevrUtils.fname_from_string(""), 1, 1, 1, false)
	attAddr = ra
	log("root attached to the pawn")
end
-- once per frame: belt centre + yaw. The only transform written every frame.
function M.frame(cx, cy, cz, yaw, want, placeAlso)
	if not ensure() then return end
	readOpts()
	if want or placeAlso then -- step 117: shoulder heal items hang off the same root while the belt is hidden
		local okF, errF = pcall(followPawn)
		if not okF and attT < 1e9 then attT = os.clock() + 10.0 log("pawn attach failed: " .. tostring(errF)) end
		RL.X, RL.Y, RL.Z = cx, cy, cz
		RR.Pitch, RR.Yaw, RR.Roll = 0.0, yaw, 0.0
		S3.root:K2_SetWorldLocationAndRotation(RL, RR, false, D.hr, true)
	end
	if S3.vStrap ~= want then
		S3.vStrap = want
		for k = 1, S3.nStrap do local c = S3.strap[k] pcall(function() c:SetVisibility(want, false) end) end
	end
end

local function newC(i)
	local c = {}
	local own = ownerOf(S3.root)
	pcall(function() c.pivot = D.uevrUtils.create_component_of_class("Class /Script/Engine.SceneComponent", true, nil, false, own) end)
	if c.pivot == nil then return nil end
	pcall(attach, c.pivot, S3.root)
	C[i] = c
	return c
end

local function hullFor(c, mesh)
	if c.hull == nil or D.uevrUtils.getValid(c.hull) == nil then
		c.hull = D.uevrUtils.createStaticMeshComponent(mesh, {parent = ownerOf(S3.root), manualAttachment = true, collisionEnabled = false})
		if c.hull == nil then return nil end
		pcall(function() c.hull:SetCastShadow(false) end)
		pcall(function() c.hull:SetReverseCulling(true) end)
		pcall(attach, c.hull, c.pivot)
		c.hullMesh, c.mids, c.hullKey, c.vHull = nil, {}, nil, nil
	end
	if c.hullMesh ~= mesh then
		c.hullMesh, c.hullKey = mesh, nil
		pcall(function()
			c.hull:SetStaticMesh(mesh)
			local mat = D.api:find_uobject(M.MAT)
			local n = c.hull:GetNumMaterials()
			c.nm = 0
			if mat ~= nil then
				for j = 1, n do
					c.mids[j] = c.hull:CreateAndSetMaterialInstanceDynamicFromMaterial(j - 1, mat)
					c.nm = j
				end
			end
		end)
	end
	return c.hull
end

-- step 92: peek arrowhead (cone, tan; gold while it is the grab target); cube wedge if the cone mesh is not loaded
local function arrowColor(c, col)
	if c.arrow == nil or c.arrowCol == col then return end
	c.arrowCol = col
	pcall(function() local mid = c.arrow:GetMaterial(0) if mid ~= nil then mid:SetVectorParameterValue("Color", col) end end)
end
local function ensureArrow(c)
	if c.arrow ~= nil then return c.arrow end
	c.arrow = newShape(M.CONE, C_TAN)
	c.arrowCube = false
	if c.arrow == nil then c.arrow = newShape(M.CUBE, C_TAN) c.arrowCube = true end
	c.arrowCol = C_TAN
	log("peek arrow: " .. (c.arrow == nil and "none" or (c.arrowCube and "cube" or "cone")))
	return c.arrow
end

-- step 120: one red bar of the can't-use X (k = 1, 2), built on first need
local function ensureX(c, k)
	local key = k == 1 and "x1" or "x2"
	if c[key] ~= nil then return c[key] end
	c[key] = newShape(M.CUBE, C_RED)
	if c[key] ~= nil then pcall(function() c[key]:SetVisibility(false, false) end) end
	if k == 1 then log("can't-use X: " .. (c[key] == nil and "none" or "cube bars")) end
	return c[key]
end

local function ensureTie(c)
	if c.tie ~= nil and D.uevrUtils.getValid(c.tie) ~= nil then return c.tie end
	c.vTie = nil
	c.tie, c.tieChain = nil, false
	if S3.tieMesh ~= nil then
		c.tie = newShape(S3.tieMesh, nil)
		c.tieChain = c.tie ~= nil
	end
	if c.tie == nil then c.tie = newShape(M.CYL, C_TAN) end
	return c.tie
end

local function relayout(c, s, ang, hlOn, selOn, held, hasM, peek)
	c.gen, c.ang, c.hl, c.sel, c.pk, c.model, c.mesh, c.held, c.hasM = S3.gen, ang, hlOn, selOn, peek, s.model, s.mesh, held, hasM
	c.fwd, c.side = D.belt.fwdLive, D.belt.sideLive -- s115: label facing follows these
	c.noUse, c.shyaw = s.noUse == true, s.shYaw -- step 120
	c.vMesh, c.vHull, c.vTie, c.vLab = nil, nil, nil, nil
	local R = radius()
	local up = M.HANG_UP
	local key, bf, mf = M.hullState(hlOn, selOn, peek, held, s.noUse == true)
	local pf = peek and M.PEEK_F or 1.0
	local px, py = M.slotLocal(ang, R, 0)
	local bz = 0.0 -- step 117: shoulder heal items stand on their own chain point (s.shL*, belt-local)
	c.shx, c.shy, c.shz = s.shLx, s.shLy, s.shLz
	if s.shLx ~= nil then px, py, bz = s.shLx, s.shLy, s.shLz end
	local sizeNow = S3.size * pf
	local m, sc = s.model, 1.0
	if hasM and not held then
		local hx, hy, hz = m.ex or m.half, m.ey or m.half, m.ez or m.half
		sc = (M.fit(hx, hy, hz, S3.size) or 1.0) * mf * pf
		sizeNow = 2 * math.max(hx, hy, hz) * sc
	end
	local dz = M.hangDz(sizeNow, up) -- step 88: model centre above (or below) the strap
	local tieUp = up
	if s.shLx ~= nil then dz, tieUp = M.shoulderDz(sizeNow), false end -- step 121: hangs below the shoulder point
	if s.glove then dz = 0.0 end -- step 122: glove heals sit on their point (no chain)
	if s.shLx ~= nil and (c.shLogM ~= s.model or c.shLogH ~= hasM) then -- step 120 discovery: right shoulder heal unseen
		c.shLogM, c.shLogH = s.model, hasM
		log(string.format("shoulder slot %s: model=%s half=%s fit=%.3f size=%.1f local %.1f %.1f %.1f dz %.1f off %s %s %s held=%s",
			tostring(s.sh), tostring(hasM), tostring(m ~= nil and m.half or nil), sc, sizeNow, px, py, bz, dz,
			tostring(m ~= nil and m.ox or nil), tostring(m ~= nil and m.oy or nil), tostring(m ~= nil and m.oz or nil), tostring(held)))
	end
	local hang = math.abs(dz)
	local tie = ensureTie(c)
	if tie ~= nil then
		if c.tieChain then
			local tsc, lx, ly, lz = M.tieXform(S3.tieHalf, S3.tieO.x, S3.tieO.y, S3.tieO.z, hang, tieUp)
			if tsc ~= nil then setRel(tie, px + lx, py + ly, bz + lz, 0.0, 0.0, 0.0, tsc, tsc, tsc) end
		else
			local r = M.TIE_R_CM * 2 / 100
			setRel(tie, px, py, bz + dz / 2, 0.0, 0.0, 0.0, r, r, hang / 100)
		end
	end
	if peek and not held then -- step 92: scroll arrowhead instead of a card
		local a = ensureArrow(c)
		if a ~= nil then
			local len = S3.size * M.ARROW_LEN_F
			local w = len * M.ARROW_W_F
			local ax, ay, az = M.slotLocal(ang, R, dz)
			local p, yw, rl = M.arrowRot(ang, ang < 0 and -1 or 1)
			if c.arrowCube then setRel(a, ax, ay, az, p, yw, 45.0, w / 100, w / 100, len / 100)
			else setRel(a, ax, ay, az, p, yw, rl, w / 100, w / 100, len / 100) end
			arrowColor(c, hlOn and C_GOLD or C_TAN)
		end
	end
	if hasM and not held then
		local longest = sizeNow
		local mx, my, mz = M.slotLocal(ang, R, dz)
		if s.shLx ~= nil then mx, my, mz = px, py, bz + dz end
		local p, yw, rl = M.modelRot(ang, S3.tilt)
		if s.shLx ~= nil and s.shYaw ~= nil then yw = yw + s.shYaw end -- step 120: shoulder items face with the body
		setRel(c.pivot, mx, my, mz, p, yw, rl, 1.0, 1.0, 1.0)
		if s.mscale == nil or c.attached ~= s.mesh then
			pcall(attach, s.mesh, c.pivot)
			c.attached = s.mesh
		end
		s.mscale = sc
		local a, b, d, hlx, hly, hlz, hs = M.hullXform(sc, M.hullKFor(M.hullK(longest), bf), m.ox, m.oy, m.oz)
		setRel(s.mesh, a, b, d, 0.0, 0.0, 0.0, sc, sc, sc)
		if key ~= nil then
			local h = hullFor(c, m.mesh)
			if h ~= nil then
				setRel(h, hlx, hly, hlz, 0.0, 0.0, 0.0, hs, hs, hs)
				if c.hullKey ~= key then
					c.hullKey = key
					local col = COLORS[key]
					for j = 1, c.nm or 0 do local mid = c.mids[j] pcall(function() mid:SetVectorParameterValue("Color", col) end) end
				end
			end
		end
	end
	-- count label below the model (standing up: above it and outward, off the eye-to-model line); an item without a
	-- model (or a peek card) sits at the model's place
	local cardCm, px64 = D.belt.CARD_CM or 12.0, D.belt.PX or 64
	local labK, ldz, lr
	if hasM then
		labK = cardCm / px64 * M.LABEL_K
		ldz = up and (dz + sizeNow / 2 + 1.0) or (dz - sizeNow / 2 - 3.2)
		lr = up and (R + 2.0) or (R - 1.5)
	else
		labK = S3.size / px64 * pf
		ldz, lr = dz, R - 1.5
	end
	local lx, ly, lz = M.slotLocal(ang, lr, ldz)
	if s.shLx ~= nil then lx, ly, lz = px, py + (ang < 0 and -2.0 or 2.0), bz + ldz end
	if c.lab ~= s.comp then
		c.lab = s.comp
		pcall(attach, s.comp, S3.root)
	end
	local hdx, hdy = -(D.belt.fwdLive or D.belt.FORWARD or 4.0), -(D.belt.sideLive or 0.0) -- head in belt-local (x fwd, y right)
	local lp, lyaw = M.labelRot(lx, ly, lz, hdx, hdy, S3.drop)
	local lroll = 0.0
	-- step 101: shared up (belt forward + world up) so the hip labels (heal cards at +-98 deg) read upright, not sideways
	if D.belt.faceRotUp ~= nil then lp, lyaw, lroll = D.belt.faceRotUp(hdx - lx, hdy - ly, S3.drop - lz, 1.0, 0.0) end
	setRel(s.comp, lx, ly, lz, lp, lyaw, lroll, labK, labK, labK)
	-- step 120: red X in front of the model (or the label) facing the eyes, while the item can't be used
	if s.noUse == true and not held and not peek then
		local xx, xy, xz = lx, ly, lz
		if hasM then xx, xy, xz = M.slotLocal(ang, R, dz) if s.shLx ~= nil then xx, xy, xz = px, py, bz + dz end end
		local tx, ty, tz = hdx - xx, hdy - xy, S3.drop - xz
		local tl = math.sqrt(tx * tx + ty * ty + tz * tz)
		local push = (hasM and sizeNow / 2 or 0.0) + 0.8
		if tl > 1e-3 then xx, xy, xz = xx + tx / tl * push, xy + ty / tl * push, xz + tz / tl * push end
		local xp, xyaw, xroll = M.labelRot(xx, xy, xz, hdx, hdy, S3.drop)
		xroll = 0.0
		if D.belt.faceRotUp ~= nil then xp, xyaw, xroll = D.belt.faceRotUp(hdx - xx, hdy - xy, S3.drop - xz, 1.0, 0.0) end
		local len = (hasM and sizeNow or S3.size) * M.X_F / 100
		local th = M.X_THICK_CM / 100
		for k = 1, 2 do
			local bar = ensureX(c, k)
			if bar ~= nil then setRel(bar, xx, xy, xz, xp, xyaw, xroll + (k == 1 and 45.0 or -45.0), th, len, th) end
		end
	end
end

-- per slot per frame: allocation free unless something changed
function M.slot(i, s, ang, hlOn, selOn, want)
	if S3.root == nil or s == nil or s.comp == nil then return end
	local c = C[i] or newC(i)
	if c == nil then return end
	if s.styled == nil then -- frameless: no card fill or frame bars; step 88: a peek card is an empty grey card (no item)
		s.styled = true
		local pk = s.peek == true
		if s.bg ~= nil then pcall(function() s.bg:SetVisibility(2) end) end -- step 92: peeks are 3D arrows, no card
		if s.edges ~= nil then for k = 1, 4 do pcall(function() s.edges[k]:SetVisibility(2) end) end end
	end
	local held = s.held == true
	local hasM = s.model ~= nil and s.mesh ~= nil
	local peek = s.peek == true
	if c.gen ~= S3.gen or c.ang ~= ang or c.hl ~= hlOn or c.sel ~= selOn or c.pk ~= peek or c.model ~= s.model or c.mesh ~= s.mesh
		or (s.mscale == nil and hasM and not held) or c.hasM ~= hasM or c.held ~= held or c.lab ~= s.comp
		or c.fwd ~= D.belt.fwdLive or c.side ~= D.belt.sideLive
		or c.shx ~= s.shLx or c.shy ~= s.shLy or c.shz ~= s.shLz
		or c.noUse ~= (s.noUse == true) or c.shyaw ~= s.shYaw then
		-- s115: s.mscale (model scale pending) only matters for a shown model: slots without one (or held) re-laid out every frame
		local ok, err = pcall(relayout, c, s, ang, hlOn, selOn, held, hasM, peek)
		if not ok then log("relayout failed: " .. tostring(err)) end
	end
	local on = want and not held
	-- step 120c (Test 87: a held shoulder item was re-hidden every frame; shoulder slots re-lay out each frame and reset
	-- the cache): the belt owns a held mesh's visibility; cache unknown so release re-applies it
	if held then c.vMesh = nil else setV(c, "vMesh", hasM and s.mesh or nil, on and hasM) end
	setV(c, "vTie", c.tie, on and not s.glove) -- step 122: glove heals have no chain
	if c.hull ~= nil then setV(c, "vHull", c.hull, on and hasM and c.hullKey ~= nil and M.hullState(hlOn, selOn, peek, held, s.noUse == true) ~= nil) end
	local xOn = on and not peek and s.noUse == true -- step 120
	if c.x1 ~= nil then setV(c, "vX1", c.x1, xOn) end
	if c.x2 ~= nil then setV(c, "vX2", c.x2, xOn) end
	if not held then setV(c, "vLab", s.comp, on and not peek and (not hasM or (s.shownCount or 0) >= 1)) end
	if c.arrow ~= nil then setV(c, "vArr", c.arrow, on and peek) end
end

-- slot beyond the current item count: its hull / tie / mesh hide (the belt hides the label)
function M.off(i)
	local c = C[i]
	if c == nil then return end
	setV(c, "vHull", c.hull, false)
	setV(c, "vTie", c.tie, false)
	if c.arrow ~= nil then setV(c, "vArr", c.arrow, false) end
	if c.x1 ~= nil then setV(c, "vX1", c.x1, false) end
	if c.x2 ~= nil then setV(c, "vX2", c.x2, false) end
	c.vMesh, c.vLab = nil, nil
end

-- everything hidden; caches cleared so the next frame re-applies visibility
function M.hide()
	if S3.root == nil then return end
	S3.vStrap = false
	for k = 1, S3.nStrap do local c = S3.strap[k] pcall(function() c:SetVisibility(false, false) end) end
	for _, c in pairs(C) do
		if c.hull ~= nil then pcall(function() c.hull:SetVisibility(false, false) end) end
		if c.tie ~= nil then pcall(function() c.tie:SetVisibility(false, false) end) end
		if c.arrow ~= nil then pcall(function() c.arrow:SetVisibility(false, false) end) end
		if c.x1 ~= nil then pcall(function() c.x1:SetVisibility(false, false) end) end
		if c.x2 ~= nil then pcall(function() c.x2:SetVisibility(false, false) end) end
		c.vMesh, c.vHull, c.vTie, c.vLab, c.vArr, c.vX1, c.vX2 = nil, nil, nil, nil, nil, nil, nil
	end
end

-- skin switched off: models and labels back to the card belt's own placement
function M.release()
	if D == nil or D.belt == nil then return end
	local bs = D.belt.S
	for i, c in pairs(C) do
		local s = bs.slots[i]
		if s ~= nil then
			if c.attached ~= nil and s.mesh == c.attached and not s.held then pcall(function() s.mesh:K2_DetachFromComponent(1, 1, 1, false) end) end
			if c.lab ~= nil and s.comp == c.lab then pcall(function() s.comp:K2_DetachFromComponent(1, 1, 1, false) end) end
			s.mscale, s.styled, s.scaled, s.visible = nil, nil, nil, nil
		end
		c.attached, c.lab, c.mesh, c.model = nil, nil, nil, nil
	end
	M.hide()
end

-- level change: our actor dies with the level (or here); the belt drops its slots itself
function M.reset()
	pcall(function()
		if S3.root ~= nil and D.uevrUtils.getValid(S3.root) ~= nil then
			local o = S3.root:GetOwner()
			if o ~= nil then o:K2_DestroyActor() end
		end
	end)
	S3.root, S3.nStrap, S3.vStrap, S3.tieTried = nil, 0, nil, nil
	for k in pairs(C) do C[k] = nil end
end

return M
