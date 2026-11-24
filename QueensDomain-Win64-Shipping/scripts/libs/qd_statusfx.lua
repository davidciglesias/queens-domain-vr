-- Step 122e (headset 2026-11-20c, user chose "post-process glow"): status effects (heal/buff/poison/...) draw a
-- full-screen game widget (WidgetBlueprint StatusEffectOverlay_C: one OverlayLayer image, per-effect dynamic material
-- with scalar params Opacity / Pulse / Scale, animated by the spawning actor's timelines; Test 89). UEVR shows it on
-- the UI rectangle, so its "screen edge" look lands on the rectangle's edges. With option status_fx_eyes the widget is
-- hidden (RenderOpacity 0) and its strength drives the pawn camera's post-process instead (vignette + colour tint),
-- which renders at the real edges of each eye. Polled each frame (no hooks: hooks deadlock from tick); scan 2 Hz.
local M = {}

M.WIDGET_CLASS = "WidgetBlueprintGeneratedClass /Game/Player/StatusEffectVisualizers/StatusEffectOverlay.StatusEffectOverlay_C" -- Test 90
M.CAMERA_CLASS = "Class /Script/Engine.CameraComponent"
M.SCAN_S = 0.5
M.MAX_FX = 16
-- step 123 (headset 2026-11-20d: "too weak, can barely tell"): ~2.4x vignette, ~2x tint, deeper pulse
M.VIG_ADD = 2.6   -- vignette added at full strength (on top of the camera's own value)
M.TINT_K = 0.65   -- how far the whole view tints toward the effect colour at full strength
M.PULSE_MIN = 0.4 -- strength = opacity * (PULSE_MIN + (1 - PULSE_MIN) * pulse)
-- colours by material name (lower case substring), first match wins. Test 90: the brush material is a
-- MaterialInstanceDynamic_N with no readable vector parameter, so the name comes from its Parent chain / the widget's
-- Material field (the per-effect overlay material)
M.COLORS = {
	{ "poison", 0.55, 0.15, 0.75 }, { "disease", 0.45, 0.55, 0.10 }, { "weaken", 0.45, 0.45, 0.60 },
	{ "heavy", 0.35, 0.30, 0.25 }, { "binding", 0.70, 0.55, 0.20 }, { "berserk", 0.85, 0.10, 0.05 },
	{ "ironskin", 0.65, 0.65, 0.75 }, { "radiant", 1.00, 0.85, 0.40 }, { "magicrot", 0.30, 0.65, 0.45 },
}
M.DEFAULT_COLOR = { 1.0, 1.0, 1.0 } -- unknown effect: no tint, vignette only
-- step 124 (headset 2026-11-21: tint looked odd and differed per eye, effects hard to tell apart; user asked for several
-- styles to compare): option status_fx_style picks how an active effect shows (status_fx_eyes on):
--   1 visor: the game's own overlay art (the effect widget's dynamic material, animated by the game) on a head-locked
--     quad VIS_DIST cm in front of the eyes, VIS_W x VIS_H cm (about the headset's view, so the art's edge glow lands
--     near the edges of the view). Same image in both eyes.
--   2 wide visor: the same, VIS_WIDE_K x larger: no quad edge in view, but the art's edge detail is out of view too
--     (Test 92 round 2: barely visible). Style 1 keeps 50 x 46 (art frame + quad edge inside the view, stronger)
--   3 edge glow + colour tint (post-process, step 122e/123)   4 edge glow only (no tint)
--   5 arm badge: the game art on a small square (BADGE_CM) next to the left arm HUD bars (left controller without it)
--   6 visor + arm badge
-- step 125 (headset 2026-11-21b: both visors not visible, tint differs per eye, plain glow good but weak, badge good but
-- "empty"): option status_fx_mode (new id) 1 glow + icon badge, 2 glow only, 3 icon badge only, 4 glow + tint + icons.
-- The visor code stays (unreachable) for a later retry. Icon badge = one small square per active effect on the left arm
-- HUD panel, showing the item icon the effect component links to (StatusEffectComponent_C.Item.ItemIcon, SDK), backed
-- by the effect colour.
M.STYLES = { "Edge glow + icon badge on the left arm HUD", "Edge glow only", "Icon badge only", "Edge glow + colour tint + icon badge" }
M.VIG_ADD_PLAIN = 3.4 -- glow without tint: stronger (step 125: "good but less noticeable")
M.ICON_MAX, M.ICON_CM, M.ICON_GAP, M.ICON_PX = 4, 4.5, 0.6, 60.0
M.ICON_BACK_A = 0.85 -- backing alpha (effect colour, darkened by ICON_BACK_K)
M.ICON_BACK_K = 0.55
M.COMP_SCAN_S = 5.0 -- re-list the pawn's status components (Applied is read every SCAN_S)
M.VIS_DIST, M.VIS_W, M.VIS_H = 20.0, 50.0, 46.0
M.VIS_WIDE_K = 1.12 -- 56 x 52 cm: fills the fake headset view (Test 92)
M.VIS_PX = 20.0 -- widget pixels per cm (draw size = W/H x this, component scale = 1 / this)
M.VIS_MAX = 4   -- effect layers at once
M.BADGE_CM, M.BADGE_PX = 6.0, 50.0
M.BADGE_PANEL = { 0.0, 6.5, 0.4 } -- on the arm HUD panel (along, across, up cm): beside the bars, facing up
-- (Test 92 round 2: past the bar end at -6.5 it was unseen, likely inside the glove; round 3: across 5 touched the bars,
-- backing alpha 0.75 hid the art inside the frame)
M.BADGE_BACK = { R = 0.08, G = 0.08, B = 0.08, A = 0.45 } -- dark backing under the badge art (the art is mostly light haze)
M.BADGE_CTRL = { 0.0, 0.0, 7.0 }   -- fallback on the left controller (forward, right, up cm)
-- pure: mode number -> visor (0 none / 1 normal / 2 wide), badge (bool: icon badge), glow (0 none / 1 glow + tint / 2 glow only)
function M.styleParts(style)
	style = tonumber(style) or 1
	if style == 2 then return 0, false, 2 end
	if style == 3 then return 0, true, 0 end
	if style == 4 then return 0, true, 1 end
	return 0, true, 2
end

-- pure: colour for a material name -> r, g, b
function M.colorFor(name)
	local n = string.lower(tostring(name or ""))
	for i = 1, #M.COLORS do
		local c = M.COLORS[i]
		if n:find(c[1], 1, true) then return c[2], c[3], c[4] end
	end
	return M.DEFAULT_COLOR[1], M.DEFAULT_COLOR[2], M.DEFAULT_COLOR[3]
end
-- pure: effect strength 0..1 from the widget material's Opacity and Pulse
function M.strength(op, pulse)
	op = tonumber(op) or 0.0
	pulse = tonumber(pulse) or 1.0
	if op <= 0.0 then return 0.0 end
	if op > 1.0 then op = 1.0 end
	if pulse < 0.0 then pulse = 0.0 elseif pulse > 1.0 then pulse = 1.0 end
	return op * (M.PULSE_MIN + (1.0 - M.PULSE_MIN) * pulse)
end
-- pure: post-process values for strength a and colour r,g,b over the camera's base vignette -> vignette, tr, tg, tb
function M.pp(a, r, g, b, baseVig, plain)
	local k = M.TINT_K * a
	return (baseVig or 0.0) + (plain and M.VIG_ADD_PLAIN or M.VIG_ADD) * a, 1.0 + (r - 1.0) * k, 1.0 + (g - 1.0) * k, 1.0 + (b - 1.0) * k
end

---------------------------------------------------------------- runtime (UEVR)
local D = nil
local S = { list = {}, mats = {}, n = 0, scanT = 0.0, cls = nil, camCls = nil, cam = nil, pawnAddr = nil, hidden = {}, col = {},
	base = nil, applied = false, logged = {}, errT = 0.0 }

local function log(msg) if D ~= nil and D.log ~= nil then D.log("[FX] " .. msg) end end
-- step 124 quads (visor / badge; created once, vectors reused)
local function newQuad(name, wCm, hCm, px)
	return { name = name, w = wCm, h = hCm, px = px, comp = nil, imgs = {}, mats = {}, on = {}, shown = false, failT = 0.0,
		parent = nil, variant = nil, n = 0, loc = {X = 0, Y = 0, Z = 0}, rot = {Pitch = 0, Yaw = 0, Roll = 0}, scl = {X = 1, Y = 1, Z = 1} }
end
local VS = newQuad("visor", M.VIS_W, M.VIS_H, M.VIS_PX)
local BS = newQuad("badge", M.BADGE_CM, M.BADGE_CM, M.BADGE_PX)
BS.back = M.BADGE_BACK

function M.init(deps) D = deps end

local function scan()
	if S.cls == nil then S.cls = D.uevrUtils.get_class(M.WIDGET_CLASS) end
	if S.cls == nil then return end
	local all = UEVR_UObjectHook.get_objects_by_class(S.cls, false)
	local n = 0
	if all ~= nil then
		for _, w in ipairs(all) do
			if n >= M.MAX_FX then break end
			local okN, full = pcall(function() return w:get_full_name() end)
			-- Test 90: cancelled overlays can linger; keep only the ones in the viewport (2 Hz UFunction call)
			if okN and full ~= nil and not full:find("Default__", 1, true) then
				local okV, inV = pcall(function() return w:IsInViewport() end)
				if okV and inV then n = n + 1 S.list[n] = w end
			end
		end
	end
	for i = n + 1, S.n do S.list[i] = nil end
	S.n = n
end

local function camera()
	local pawn = D.uevrUtils.get_local_pawn ~= nil and D.uevrUtils.get_local_pawn() or uevr.api:get_local_pawn(0)
	if pawn == nil then S.cam = nil return nil end
	local addr = pawn:get_address()
	if S.cam ~= nil and S.pawnAddr == addr and D.uevrUtils.getValid(S.cam) ~= nil then return S.cam end
	S.cam, S.pawnAddr, S.base = nil, addr, nil
	if S.camCls == nil then S.camCls = D.uevrUtils.get_class(M.CAMERA_CLASS) end
	if S.camCls == nil then return nil end
	S.cam = pawn:GetComponentByClass(S.camCls)
	if S.cam ~= nil then log("camera component " .. tostring(S.cam:get_full_name())) end
	return S.cam
end

local function remember(cam)
	local ps = cam.PostProcessSettings
	S.base = { w = cam.PostProcessBlendWeight, ov = ps.bOverride_VignetteIntensity, vig = ps.VignetteIntensity,
		ot = ps.bOverride_SceneColorTint, r = ps.SceneColorTint.R, g = ps.SceneColorTint.G, b = ps.SceneColorTint.B }
	log(string.format("camera post-process base: weight %.2f vignette %s/%.2f tint %s", S.base.w or -1, tostring(S.base.ov),
		S.base.vig or -1, tostring(S.base.ot)))
end

local function restoreCam()
	local cam, B = S.cam, S.base
	if cam == nil or B == nil or not S.applied then S.applied = false return end
	S.applied = false
	if D.uevrUtils.getValid(cam) == nil then return end
	local ps = cam.PostProcessSettings
	ps.bOverride_VignetteIntensity, ps.VignetteIntensity = B.ov, B.vig
	ps.bOverride_SceneColorTint = B.ot
	ps.SceneColorTint.R, ps.SceneColorTint.G, ps.SceneColorTint.B = B.r, B.g, B.b
	cam.PostProcessBlendWeight = B.w
end

-- material colour: first vector parameter of the dynamic material (or its parent), else the name table. Cached per
-- material address (one small table the first time a material is seen)
local function nameOf(o)
	local okN, n = pcall(function() return o:get_fname():to_string() end)
	return okN and tostring(n) or ""
end
-- pure-ish: first name in the list that the colour table knows (else the first name) -> name, matched
local function pickName(a, b, c, d)
	for _, n in ipairs({ a, b, c, d }) do
		if n ~= nil and n ~= "" then
			local ln = string.lower(n)
			for i = 1, #M.COLORS do if ln:find(M.COLORS[i][1], 1, true) then return n, true end end
		end
	end
	return a or "", false
end
local function colourOf(mat, w)
	local addr = mat:get_address()
	local c = S.col[addr]
	if c ~= nil then return c[1], c[2], c[3] end
	local p1, p2, wm = nil, nil, nil
	pcall(function() p1 = mat.Parent end)
	if p1 ~= nil then pcall(function() p2 = p1.Parent end) end
	pcall(function() wm = w.Material end)
	local name = pickName(p1 ~= nil and nameOf(p1) or nil, wm ~= nil and nameOf(wm) or nil, p2 ~= nil and nameOf(p2) or nil, nameOf(mat))
	local r, g, b = nil, nil, nil
	pcall(function()
		local src = mat
		for _ = 1, 3 do
			if src == nil then break end
			local arr = src.VectorParameterValues
			if arr ~= nil and #arr > 0 then
				local v = arr[1].ParameterValue
				r, g, b = v.R, v.G, v.B
				break
			end
			src = src.Parent
		end
	end)
	local how = "material"
	if type(r) ~= "number" then r, g, b = M.colorFor(name) how = "name table" end
	local mx = math.max(r, g, b, 1e-3)
	if mx > 1.0 then r, g, b = r / mx, g / mx, b / mx end -- HDR colours -> 0..1
	S.col[addr] = { r, g, b }
	log(string.format("effect material %s colour %.2f %.2f %.2f (%s)", name, r, g, b, how))
	return r, g, b
end

local function widgetFx(w)
	if not w:IsInViewport() then return 0.0 end
	local addr = w:get_address()
	if not S.hidden[addr] then
		w:SetRenderOpacity(0.0)
		S.hidden[addr] = w
		if not S.logged[addr] then S.logged[addr] = true log("overlay widget hidden -> post-process") end
	end
	local img = w.OverlayLayer
	if img == nil then return 0.0 end
	local mat = img.Brush.ResourceObject
	if mat == nil or mat.K2_GetScalarParameterValue == nil then return 0.0 end
	local a = M.strength(mat:K2_GetScalarParameterValue("Opacity"), mat:K2_GetScalarParameterValue("Pulse"))
	if a <= 0.001 then return 0.0 end
	local r, g, b = colourOf(mat, w)
	return a, r, g, b, mat
end

---------------------------------------------------------------- step 124: quads (game art on a widget component)
local function quadCreate(Q)
	if os.clock() < Q.failT or D.hosts == nil then return nil end
	Q.failT = os.clock() + 5.0
	local widget = nil
	for _, cls in ipairs(D.hosts) do
		local ok, w = pcall(D.uevrUtils.createWidget, cls)
		if ok and w ~= nil and w.WidgetTree ~= nil then widget = w break end
	end
	if widget == nil then log(Q.name .. ": no host widget") return nil end
	local ov = D.uevrUtils.spawn_object("Class /Script/UMG.Overlay", widget.WidgetTree)
	if ov == nil then log(Q.name .. ": Overlay spawn failed") return nil end
	if Q.back ~= nil then -- badge: solid dark square under the art (an Image without a brush draws its colour)
		pcall(function()
			local bg = D.uevrUtils.spawn_object("Class /Script/UMG.Image", widget.WidgetTree)
			local sl0 = ov:AddChildToOverlay(bg)
			sl0:SetHorizontalAlignment(0) sl0:SetVerticalAlignment(0)
			bg:SetColorAndOpacity(Q.back)
			Q.bgImg = bg -- step 125: icon backing colour per effect
		end)
	end
	for k = 1, (Q.layers or M.VIS_MAX) do
		local img = D.uevrUtils.spawn_object("Class /Script/UMG.Image", widget.WidgetTree)
		if img ~= nil then
			local sl = ov:AddChildToOverlay(img)
			pcall(function() sl:SetHorizontalAlignment(0) sl:SetVerticalAlignment(0) end) -- fill
			pcall(function() img:SetVisibility(2) end) -- hidden until an effect uses it
			Q.n = Q.n + 1
			Q.imgs[Q.n], Q.mats[Q.n], Q.on[Q.n] = img, nil, false
		end
	end
	widget.WidgetTree.RootWidget = ov
	local comp = D.uevrUtils.createWidgetComponent(widget, {removeFromViewport = false, twoSided = true,
		drawSize = vector_2(Q.w * Q.px, Q.h * Q.px)})
	if comp == nil then log(Q.name .. ": WidgetComponent failed") return nil end
	pcall(function() comp.BlendMode = 2 comp:SetMaterial(0, comp.TranslucentMaterial) end)
	pcall(function() comp:SetCastShadow(false) end)
	pcall(function() comp:SetCollisionEnabled(0) end)
	pcall(function() comp:SetVisibility(false, true) end)
	Q.comp, Q.widget, Q.shown, Q.failT = comp, widget, false, 0.0
	log(string.format("%s created: %d layers, %.1f x %.1f cm", Q.name, Q.n, Q.w, Q.h))
	return comp
end
-- attach Q to parent at a relative transform; re-done only when the parent or the variant changes
local function quadAttach(Q, parent, variant, x, y, z, p, yw, r, k)
	if parent == nil or Q.comp == nil then return false end
	local pa = parent:get_address()
	local par = Q.comp.AttachParent
	if par ~= nil and Q.parent == pa and Q.variant == variant and par:get_address() == pa then return true end
	Q.comp:K2_AttachToComponent(parent, D.uevrUtils.fname_from_string(""), 0, 0, 0, false)
	Q.loc.X, Q.loc.Y, Q.loc.Z = x, y, z
	Q.rot.Pitch, Q.rot.Yaw, Q.rot.Roll = p, yw, r
	Q.comp:K2_SetRelativeLocationAndRotation(Q.loc, Q.rot, false, D.hr, true)
	Q.scl.X, Q.scl.Y, Q.scl.Z = 1.0, k / Q.px, k / Q.px
	Q.comp:SetRelativeScale3D(Q.scl)
	if variant == "panel" or variant == "ctrl" or variant == "rarm" then pcall(function() Q.comp:SetWorldScale3D(Q.scl) end) end -- cm on any parent scale
	Q.parent, Q.variant = pa, variant
	log(Q.name .. " attached (" .. tostring(variant) .. ")")
	return true
end
local function quadShow(Q, v)
	if Q.shown == v or Q.comp == nil then return end
	Q.shown = v
	pcall(function() Q.comp:SetVisibility(v, true) end)
end
-- layer k of Q shows material mat (nil = hide); brush set only when the material changes
local function quadLayer(Q, k, mat)
	local img = Q.imgs[k]
	if img == nil then return end
	if mat == nil then
		if Q.on[k] then Q.on[k] = false pcall(function() img:SetVisibility(2) end) end
		return
	end
	local addr = mat:get_address()
	if Q.mats[k] ~= addr then
		Q.mats[k] = addr
		img:SetBrushFromMaterial(mat)
		log(Q.name .. " layer " .. k .. " -> effect material")
	end
	if not Q.on[k] then Q.on[k] = true pcall(function() img:SetVisibility(0) end) end
end
local function quadOff(Q)
	if Q.comp == nil then return end
	for k = 1, Q.n do quadLayer(Q, k, nil) end
	quadShow(Q, false)
end
local function quadsOff() pcall(quadOff, VS) pcall(quadOff, BS) end
---------------------------------------------------------------- step 125: icon badge (one square per active effect)
local IC = {}
for i = 1, M.ICON_MAX do
	local q = newQuad("icon" .. i, M.ICON_CM, M.ICON_CM, M.ICON_PX)
	q.back, q.layers, q.tex, q.col = M.BADGE_BACK, 1, nil, nil
	IC[i] = q
end
-- pure: backing colour for an effect: its colour table entry, else gold (positive) / red (negative), darkened
function M.iconBack(name, positive)
	local r, g, b = M.colorFor(name)
	if r == M.DEFAULT_COLOR[1] and g == M.DEFAULT_COLOR[2] and b == M.DEFAULT_COLOR[3] then
		if positive then r, g, b = 0.95, 0.75, 0.25 else r, g, b = 0.85, 0.15, 0.10 end
	end
	local k = M.ICON_BACK_K
	return r * k, g * k, b * k, M.ICON_BACK_A
end
-- pure: along-the-panel offset (cm) of icon i of n, row centred on 0
function M.iconOffset(i, n)
	return ((i - 1) - (n - 1) * 0.5) * (M.ICON_CM + M.ICON_GAP)
end
local E = { comps = {}, names = {}, pos = {}, nc = 0, compT = 0.0, pawnAddr = nil, act = {}, na = 0, n = -1, seen = {} }
-- pawn status effect components (class name has "StatusEffect", not the "...Vis" visual ones), re-listed every COMP_SCAN_S
local function effList(pawn)
	local addr = pawn:get_address()
	if E.pawnAddr == addr and os.clock() < E.compT then return end
	E.pawnAddr, E.compT = addr, os.clock() + M.COMP_SCAN_S
	local cls = D.uevrUtils.get_class("Class /Script/Engine.ActorComponent")
	if cls == nil then return end
	local arr = pawn:K2_GetComponentsByClass(cls)
	local n = 0
	for _, c in ipairs(arr or {}) do
		local okC, cn = pcall(function() return c:get_class():get_fname():to_string() end)
		if okC and cn ~= nil and cn:find("StatusEffect", 1, true) and not cn:find("Vis", 1, true) then
			local okA, ap = pcall(function() return c.Applied end)
			if okA and type(ap) == "boolean" then
				n = n + 1
				E.comps[n] = c
				local okN, fn = pcall(function() return c:get_fname():to_string() end)
				E.names[n] = (okN and fn or cn)
				local okP, ps = pcall(function() return c.EffectIsPositive end)
				E.pos[n] = okP and ps == true
			end
		end
	end
	for k = n + 1, E.nc do E.comps[k], E.names[k], E.pos[k] = nil, nil, nil end
	if n ~= E.nc then log("status components: " .. n) end
	E.nc = n
end
-- applied effects -> E.act (indices into E.comps), at most ICON_MAX
local function effScan()
	local pawn = D.uevrUtils.get_local_pawn ~= nil and D.uevrUtils.get_local_pawn() or uevr.api:get_local_pawn(0)
	if pawn == nil then E.na = 0 return end
	effList(pawn)
	local na = 0
	for k = 1, E.nc do
		local okA, ap = pcall(function() return E.comps[k].Applied end)
		if okA and ap == true and na < M.ICON_MAX then
			na = na + 1
			E.act[na] = k
			if not E.seen[E.names[k]] then
				E.seen[E.names[k]] = true
				local hasIcon = false
				pcall(function() hasIcon = E.comps[k].Item ~= nil and E.comps[k].Item.ItemIcon ~= nil end)
				log(string.format("effect on: component %d positive=%s icon=%s", k, tostring(E.pos[k]), tostring(hasIcon)))
			end
		end
	end
	E.na = na
	E.dirty = true -- icons re-set at this 2 Hz cadence only (no per-frame closures)
end
local function iconPlace(Q, i, n)
	local panel = nil
	if D.armPanel ~= nil then local okP, pnl = pcall(D.armPanel) if okP then panel = pnl end end
	local b, par, v = M.BADGE_PANEL, panel, "panel"
	if panel == nil then
		b, v = M.BADGE_CTRL, "ctrl"
		par = D.controllers ~= nil and D.controllers.getController(0) or nil
	end
	return quadAttach(Q, par, v, b[1] + M.iconOffset(i, n), b[2], b[3], 90.0, 0.0, 0.0, 1.0)
end
local function iconSet(Q, k)
	local c = E.comps[k]
	local tex = nil
	pcall(function() tex = c.Item.ItemIcon end)
	local img = Q.imgs[1]
	if img ~= nil then
		local ta = tex ~= nil and tex:get_address() or 0
		if Q.tex ~= ta then
			Q.tex = ta
			if tex ~= nil then img:SetBrushFromTexture(tex, false) img:SetVisibility(0) else img:SetVisibility(2) end
		end
	end
	if Q.col ~= k and Q.bgImg ~= nil then
		Q.col = k
		local r, g, bb, a = M.iconBack(E.names[k], E.pos[k])
		Q.bgImg:SetColorAndOpacity({ R = r, G = g, B = bb, A = a })
	end
end
local function iconsOff()
	for i = 1, M.ICON_MAX do pcall(quadShow, IC[i], false) end
	E.n, E.dirty = -1, true
end
local function iconsRun()
	local n = E.na
	if n ~= E.n then -- count changed: re-centre the row
		E.n = n
		for i = 1, M.ICON_MAX do IC[i].variant = nil end
	end
	for i = 1, M.ICON_MAX do
		local Q = IC[i]
		if i <= n then
			if Q.comp == nil then pcall(quadCreate, Q) end
			if Q.comp ~= nil then
				local okS, errS = pcall(iconSet, Q, E.act[i])
				if not okS and os.clock() > S.errT then S.errT = os.clock() + 10.0 log("icon error: " .. tostring(errS)) end
				local okA, att = pcall(iconPlace, Q, i, n)
				quadShow(Q, okA and att == true)
			end
		elseif Q.shown then quadShow(Q, false) end
	end
end
-- placement per quad: visor on the HMD; badge on the arm HUD panel, else the left controller
---------------------------------------------------------------- step 126b: equipped accessories on the right wrist
-- user 2026-11-21: "if flat applies icons/effects for equipment, show them on the right hand like the coin on the left".
-- Flat shows no equipment icons; accessories only act through effects. Runtime 2026-11-21: FS_SaveGameUtils
-- IsItemEquipped / GetItemEquipSlotID; FS_ItemData_C.EquipSlot 1 = accessories (slot ids 0, 1, 2 ..; the game took
-- up to 7 from EquipItem), 2 = throwables (1000..1002), 3 = weapons (2000..2002). Step 126e (user: the first row showed
-- the throwables): EquipSlot 2 was the throwables, accessories are 1. One square per equipped accessory (item icon) on top of the right IK lower arm by the glove (fake test
-- 2026-11-21: that anchor has no wrist roll, so its palm side always faces away; the forearm anchor's palm side was
-- hidden by the fist around the weapon -> same readable face as the charge strip, nearer the wrist).
M.ACC_MAX = 6      -- two rows of 3
M.ACC_ROW = 3
M.ACC_SLOT_TYPE = 1
M.ACC_CM, M.ACC_GAP = 3.6, 0.4
M.ACC_POS = { 0.0, 8.0, 6.5 } -- step 128 (user: 8.5 a bit too far out); step 127: right palm-side forearm anchor (across, + toward the elbow, + out of the palm side;
                              -- Test 96: at 4.5 out the 4 cm models rendered inside the gauntlet)
M.ACC_SHOW_COS, M.ACC_HIDE_COS = 0.35, 0.15 -- step 127: shown only while the palm side faces the eyes (hysteresis)
M.ACC_ROT = { 90.0, 0.0, 0.0 } -- same face as the charge strip
M.ACC_NUDGE = { 0.0, 0.0, 0.0 } -- step 128: user sliders (across, toward the elbow, out), cm, forearm spot only
M.ACC_CTRL = { -6.0, 0.0, 4.0 } -- fallback on the right controller (forward, right, up cm), facing up
M.ACC_BACK = nil -- step 126f (user): no frame behind the icons
M.ACC_MODEL_HALF = 2.0 -- step 126f (user): the item's own 3D model instead of the icon; largest half extent (cm)
M.ACC_MODEL_ROT = { 0.0, 0.0, 0.0 } -- model rotation in the arm anchor frame (P, Y, R)
M.ACC_MODEL_UP = 1.5 -- cm above the icon spot (bounds centre)
M.ACC_SCAN_S = 2.0   -- equipped check of the candidate accessories
M.ACC_LIST_S = 30.0  -- re-list the candidate accessory items (all loaded FS_ItemData_C with EquipSlot 2)
M.ITEM_CLASS = "BlueprintGeneratedClass /Game/Blueprints/ItemSystem/FS_ItemData.FS_ItemData_C"
M.UTILS_CLASS = "Class /Script/QueensDomain.FS_SaveGameUtils"
-- pure: 1..ACC_MAX from the game's accessory slot id (0, 1, ..), nil otherwise
function M.accIndex(id)
	if type(id) ~= "number" or id < 0 or id >= 1000 then return nil end
	local k = math.floor(id)
	if k >= M.ACC_MAX then return nil end
	return k + 1
end
-- pure: offsets (cm) of shown icon i of n: along the arm (rows of ACC_ROW, centred) and across (2nd row beside the 1st)
function M.accOffset(i, n)
	local per = M.ACC_ROW
	local row, col = (i - 1) // per, (i - 1) % per
	local inRow = math.min(per, n - row * per)
	local rows = (n + per - 1) // per
	local step = M.ACC_CM + M.ACC_GAP
	return (col - (inRow - 1) * 0.5) * step, (row - (rows - 1) * 0.5) * step
end
local AC = {}
-- pure: UE rotator (deg) applied to vector (x, y, z)
function M.rotVec(p, yw, r, x, y, z)
	local rp, ry, rr = math.rad(p), math.rad(yw), math.rad(r)
	local SP, CP, SY, CY, SR, CR = math.sin(rp), math.cos(rp), math.sin(ry), math.cos(ry), math.sin(rr), math.cos(rr)
	return x * CP * CY + y * (SR * SP * CY - CR * SY) + z * -(CR * SP * CY + SR * SY),
		x * CP * SY + y * (SR * SP * SY + CR * CY) + z * (CY * SR - CR * SP * SY),
		x * SP + y * -SR * CP + z * CR * CP
end
local AM = {} -- step 126f: per shown slot {comp, mesh (address), parent, variant, key, loc, rot, scl}
M.AM = AM -- step 127: bridge inspection
for i = 1, M.ACC_MAX do
	local q = newQuad("acc" .. i, M.ACC_CM, M.ACC_CM, M.ICON_PX)
	q.back, q.layers, q.tex = M.ACC_BACK, 1, nil
	AC[i] = q
	AM[i] = { comp = nil, mesh = 0, parent = nil, key = nil, shown = false, failT = 0.0,
		loc = {X = 0, Y = 0, Z = 0}, rot = {Pitch = 0, Yaw = 0, Roll = 0}, scl = {X = 1, Y = 1, Z = 1} }
end
local A = { cand = {}, nc = 0, listT = 0.0, scanT = 0.0, item = {}, nxt = {}, n = -1, dirty = true, util = nil, cls = nil, logged = -1 }
M.A = A -- step 127: bridge inspection (Test 95: models unseen)
local function accList()
	local now = os.clock()
	if now < A.listT then return end
	A.listT = now + M.ACC_LIST_S
	if A.cls == nil then A.cls = D.uevrUtils.get_class(M.ITEM_CLASS) end
	if A.util == nil then A.util = D.uevrUtils.find_default_instance(M.UTILS_CLASS) end
	if A.cls == nil or A.util == nil then return end
	local all = UEVR_UObjectHook.get_objects_by_class(A.cls, false)
	local n = 0
	for _, it in ipairs(all or {}) do
		local okE, ok = pcall(function() return it.Equippable == true and it.EquipSlot == M.ACC_SLOT_TYPE end)
		if okE and ok then n = n + 1 A.cand[n] = it end
	end
	for k = n + 1, A.nc do A.cand[k] = nil end
	A.nc = n
end
local function accScan()
	local pawn = D.uevrUtils.get_local_pawn ~= nil and D.uevrUtils.get_local_pawn() or uevr.api:get_local_pawn(0)
	if pawn == nil then return end
	accList()
	if A.util == nil then return end
	for i = 1, M.ACC_MAX do A.nxt[i] = nil end
	local u = A.util
	for k = 1, A.nc do
		local it = A.cand[k]
		local okI, on = pcall(u.IsItemEquipped, u, pawn, it)
		if okI and on == true then
			local okS, r = pcall(u.GetItemEquipSlotID, u, pawn, it, false)
			local id = okS and (type(r) == "table" and r.result or r) or nil
			local idx = M.accIndex(id)
			if idx == nil then for j = 1, M.ACC_MAX do if A.nxt[j] == nil then idx = j break end end end
			if idx ~= nil and A.nxt[idx] == nil then A.nxt[idx] = it end
		end
	end
	local n = 0
	for i = 1, M.ACC_MAX do
		local a, b = A.item[i], A.nxt[i]
		if (a == nil) ~= (b == nil) or (a ~= nil and a:get_address() ~= b:get_address()) then A.dirty = true end
		A.item[i] = b
		if b ~= nil then n = n + 1 end
	end
	if n ~= A.logged then A.logged = n log("accessories equipped: " .. n .. " (of " .. A.nc .. " known)") end
end
local function accPlace(Q, i, n)
	local par, v, b, rp = nil, "rarm", M.ACC_POS, M.ACC_ROT
	if D.rightArm ~= nil then local okP, a = pcall(D.rightArm) if okP then par = a end end
	if par == nil then
		par, v, b = D.controllers ~= nil and D.controllers.getController(1) or nil, "ctrl", M.ACC_CTRL
		local al, ac = M.accOffset(i, n)
		return quadAttach(Q, par, v, b[1] + al, b[2] + ac, b[3], 90.0, 0.0, 0.0, 1.0)
	end
	local al, ac = M.accOffset(i, n)
	local u = M.ACC_NUDGE
	return quadAttach(Q, par, v, b[1] + ac + u[1], b[2] + al + u[2], b[3] + u[3], rp[1], rp[2], rp[3], 1.0)
end
-- the item's 3D model (qd_belt.itemModel: pickup class mesh) at the icon spot; false -> no model (icon instead)
local function modelShow(R, v)
	if R.shown == v or R.comp == nil then return end
	R.shown = v
	pcall(function() R.comp:SetVisibility(v, false) end)
end
local function accModel(R, it, i, n)
	local m = nil
	if D.belt ~= nil and D.belt.itemModel ~= nil then local okM, r = pcall(D.belt.itemModel, it) m = okM and r or nil end
	if m == nil or m.mesh == nil then modelShow(R, false) return false end
	local par, v, b = nil, "rarm", M.ACC_POS
	if D.rightArm ~= nil then local okP, a = pcall(D.rightArm) if okP then par = a end end
	local al, ac = M.accOffset(i, n)
	local u = M.ACC_NUDGE
	local x, y, z = b[1] + ac + u[1], b[2] + al + u[2], b[3] + M.ACC_MODEL_UP + u[3]
	if par == nil then
		par, v, b = D.controllers ~= nil and D.controllers.getController(1) or nil, "ctrl", M.ACC_CTRL
		x, y, z = b[1] + al, b[2] + ac, b[3] + M.ACC_MODEL_UP
	end
	if par == nil then modelShow(R, false) return false end
	if R.comp == nil or D.uevrUtils.getValid(R.comp) == nil then
		R.comp, R.mesh, R.parent, R.key, R.shown = nil, 0, nil, nil, false
		if os.clock() < R.failT then return false end
		R.failT = os.clock() + 5.0
		pcall(function()
			local c = D.uevrUtils.createStaticMeshComponent(m.mesh, {parent = par:GetOwner(), manualAttachment = true, collisionEnabled = false})
			if c ~= nil then
				pcall(function() c:SetCastShadow(false) end)
				pcall(function() c:SetCollisionEnabled(0) end)
				R.comp, R.mesh = c, m.mesh:get_address()
			end
		end)
		if R.comp == nil then log("accessory model component failed") return false end
		log("accessory model created")
	end
	local ma = m.mesh:get_address()
	if R.mesh ~= ma then R.comp:SetStaticMesh(m.mesh) R.mesh = ma R.key = nil end
	local key = v .. i .. "/" .. n
	local pa = par:get_address()
	local cur = R.comp.AttachParent
	if R.key ~= key or R.parent ~= pa or cur == nil or cur:get_address() ~= pa then
		R.comp:K2_AttachToComponent(par, D.uevrUtils.fname_from_string(""), 0, 0, 0, false)
		local sc = M.ACC_MODEL_HALF / math.max(m.half, 0.01)
		local r = M.ACC_MODEL_ROT
		local p, yw, rl = r[1], r[2], r[3]
		if v == "ctrl" then p = p - 90.0 end -- the controller fallback faces up like the icon
		local ox, oy, oz = M.rotVec(p, yw, rl, m.ox * sc, m.oy * sc, m.oz * sc) -- bounds centre on the spot
		R.loc.X, R.loc.Y, R.loc.Z = x - ox, y - oy, z - oz
		R.rot.Pitch, R.rot.Yaw, R.rot.Roll = p, yw, rl
		R.comp:K2_SetRelativeLocationAndRotation(R.loc, R.rot, false, D.hr, true)
		R.scl.X, R.scl.Y, R.scl.Z = sc, sc, sc
		R.comp:SetWorldScale3D(R.scl)
		R.key, R.parent = key, pa
	end
	modelShow(R, A.seen ~= false)
	return true
end
local function accOff()
	for i = 1, M.ACC_MAX do pcall(quadShow, AC[i], false) pcall(modelShow, AM[i], false) end
	A.n, A.dirty = -1, true
	if D.rightArmRelease ~= nil then pcall(D.rightArmRelease) end
end
-- step 127: palm side turned to the eyes? (nil facing = no palm anchor: always shown)
local function accSeen()
	local f = nil
	if D.rightArmFacing ~= nil then local okF, v = pcall(D.rightArmFacing) if okF then f = v end end
	if f == nil then return true end
	if A.seen ~= false then return f > M.ACC_HIDE_COS end
	return f > M.ACC_SHOW_COS
end
local function accRun()
	local n = 0
	for i = 1, M.ACC_MAX do if A.item[i] ~= nil then n = n + 1 end end
	if n ~= A.n then A.n = n for i = 1, M.ACC_MAX do AC[i].variant = nil end end
	local j = 0
	for i = 1, M.ACC_MAX do
		local it = A.item[i]
		if it ~= nil then
			j = j + 1
			local Q = AC[j]
			local okM, hasM = pcall(accModel, AM[j], it, j, n)
			if not okM then log("accessory model error: " .. tostring(hasM)) hasM = false end
			if hasM then
				if Q.shown then quadShow(Q, false) end
			else
			if Q.comp == nil then pcall(quadCreate, Q) end
			if Q.comp ~= nil then
				pcall(function()
					local tex = it.ItemIcon
					local ta = tex ~= nil and tex:get_address() or 0
					if Q.tex ~= ta and Q.imgs[1] ~= nil then
						Q.tex = ta
						if tex ~= nil then Q.imgs[1]:SetBrushFromTexture(tex, false) Q.imgs[1]:SetVisibility(0) else Q.imgs[1]:SetVisibility(2) end
					end
				end)
				local okA, att = pcall(accPlace, Q, j, n)
				quadShow(Q, okA and att == true and A.seen ~= false)
			end
			end
		end
	end
	for k = j + 1, M.ACC_MAX do if AC[k].shown then quadShow(AC[k], false) end modelShow(AM[k], false) end
end
-- step 128: slider nudge (cm), re-placed only on change
function M.accNudge(x, y, z)
	local u = M.ACC_NUDGE
	x, y, z = tonumber(x) or 0.0, tonumber(y) or 0.0, tonumber(z) or 0.0
	if u[1] ~= x or u[2] ~= y or u[3] ~= z then
		u[1], u[2], u[3] = x, y, z A.dirty = true
		-- step 130 (user: sliders did nothing): quadAttach/accModel skip re-placing on an unchanged parent -> force it
		for k = 1, M.ACC_MAX do
			if AC[k] ~= nil then AC[k].parent = nil end
			if AM[k] ~= nil then AM[k].key = nil end
		end
	end
end
-- every tick from main (option status_acc_icons); off in menus/pause
function M.accTick(dt, on)
	if D == nil then return end
	if not on then if A.n ~= -1 then accOff() end return end
	A.scanT = A.scanT - (dt or 0.0)
	if A.scanT <= 0.0 then
		A.scanT = M.ACC_SCAN_S
		local okS, err = pcall(accScan)
		if not okS and os.clock() > S.errT then S.errT = os.clock() + 10.0 log("accessory scan error: " .. tostring(err)) end
	end
	local seen = accSeen()
	if seen ~= (A.seen ~= false) then A.seen = seen A.dirty = true end
	if A.dirty then A.dirty = false local okR, errR = pcall(accRun) if not okR then log("accessory icon error: " .. tostring(errR)) end end
end
local function placeVisor(wide)
	local head = D.controllers ~= nil and D.controllers.getController(2) or nil
	return quadAttach(VS, head, wide and "wide" or "normal", M.VIS_DIST, 0.0, 0.0, 0.0, 180.0, 0.0, wide and M.VIS_WIDE_K or 1.0)
end
local function placeBadge()
	local panel = nil
	if D.armPanel ~= nil then local okP, pnl = pcall(D.armPanel) if okP then panel = pnl end end
	if panel ~= nil then
		local b = M.BADGE_PANEL
		return quadAttach(BS, panel, "panel", b[1], b[2], b[3], 90.0, 0.0, 0.0, 1.0) -- pitch 90: front (+X) -> panel up
	end
	local ctrl = D.controllers ~= nil and D.controllers.getController(0) or nil
	local c = M.BADGE_CTRL
	return quadAttach(BS, ctrl, "ctrl", c[1], c[2], c[3], 90.0, 0.0, 0.0, 1.0)
end
-- feed the active materials to Q (nl layers in S.mats) and show it at its place
local function quadRun(Q, nl, place, arg)
	if Q.comp == nil then pcall(quadCreate, Q) if Q.comp == nil then return end end
	if nl == 0 then quadOff(Q) return end
	for k = 1, Q.n do
		local okL, errL = pcall(quadLayer, Q, k, k <= nl and S.mats[k] or nil)
		if not okL and os.clock() > S.errT then S.errT = os.clock() + 10.0 log(Q.name .. " layer error: " .. tostring(errL)) end
	end
	local okA, att = pcall(place, arg)
	if not okA and os.clock() > S.errT then S.errT = os.clock() + 10.0 log(Q.name .. " attach error: " .. tostring(att)) end
	quadShow(Q, okA and att == true)
end

local function unhideAll()
	for addr, w in pairs(S.hidden) do
		pcall(function() if D.uevrUtils.getValid(w) ~= nil then w:SetRenderOpacity(1.0) end end)
		S.hidden[addr] = nil
	end
end

-- every frame; on = option on and regular play; style = option status_fx_style (M.styleParts)
function M.tick(dt, on, style)
	if D == nil then return end
	if not on then
		if next(S.hidden) ~= nil then unhideAll() end
		restoreCam()
		quadsOff()
		iconsOff()
		return
	end
	S.scanT = S.scanT - (dt or 0.0)
	if S.scanT <= 0.0 then
		S.scanT = M.SCAN_S
		local okS, err = pcall(scan)
		if not okS and os.clock() > S.errT then S.errT = os.clock() + 10.0 log("scan error: " .. tostring(err)) end
		local okE, errE = pcall(effScan) -- step 125: applied effects for the icon badge
		if not okE and os.clock() > S.errT then S.errT = os.clock() + 10.0 log("effect scan error: " .. tostring(errE)) end
	end
	local vis, badge, glow = M.styleParts(style)
	-- strongest effect wins the colour; strengths add up (clamped); materials of active effects -> S.mats (no allocation)
	local best, sum, cr, cg, cb, nl = 0.0, 0.0, 1.0, 1.0, 1.0, 0
	for i = 1, S.n do
		local ok, a, r, g, b, mat = pcall(widgetFx, S.list[i])
		if ok and a ~= nil and a > 0.0 then
			sum = sum + a
			if a > best then best, cr, cg, cb = a, r, g, b end
			if mat ~= nil and nl < M.VIS_MAX then nl = nl + 1 S.mats[nl] = mat end
		end
	end
	for k = nl + 1, M.VIS_MAX do S.mats[k] = nil end
	if vis > 0 then quadRun(VS, nl, placeVisor, vis == 2) elseif VS.shown then quadOff(VS) end
	if BS.shown then quadOff(BS) end -- step 125: art badge replaced by the icon badge
	if badge then if E.dirty then E.dirty = false iconsRun() end elseif E.n ~= -1 then iconsOff() end
	if glow == 0 then restoreCam() return end
	if sum > 1.0 then sum = 1.0 end
	if sum <= 0.001 then restoreCam() return end
	local okC, cam = pcall(camera)
	if not okC or cam == nil then return end
	if S.base == nil then local okR = pcall(remember, cam) if not okR then return end end
	if glow == 2 then cr, cg, cb = 1.0, 1.0, 1.0 end -- glow only: no tint
	local vig, tr, tg, tb = M.pp(sum, cr, cg, cb, S.base.vig, glow == 2)
	local okA, err = pcall(function()
		local ps = cam.PostProcessSettings
		ps.bOverride_VignetteIntensity, ps.VignetteIntensity = true, vig
		ps.bOverride_SceneColorTint = true
		ps.SceneColorTint.R, ps.SceneColorTint.G, ps.SceneColorTint.B = tr, tg, tb
		if cam.PostProcessBlendWeight ~= 1.0 then cam.PostProcessBlendWeight = 1.0 end
	end)
	S.applied = true
	if not okA and os.clock() > S.errT then S.errT = os.clock() + 10.0 log("apply error: " .. tostring(err)) end
end

function M.reset() unhideAll() restoreCam() quadsOff() iconsOff() accOff() end
M.VS, M.BS, M.IC, M.E, M.AM, M.AC, M.A = VS, BS, IC, E, AM, AC, A
M.S = S
return M
