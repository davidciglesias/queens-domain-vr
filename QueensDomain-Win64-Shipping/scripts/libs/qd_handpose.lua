-- qd_handpose: step 96 hand poses (headset 2026-11-17). Both hands open by default, fist only on grip (or while the
-- hand holds an item); a held weapon gets a steady fist. Replaces hands.handleInput, whose held-weapon branch called
-- resetAnimation(false) + a new 0.1 s lerp EVERY frame while grip was held (the weapon_grip_pose fake grip), so the
-- right hand flicked between point and grip. Here an animation only lerps when its wanted state changes.
local M = {}

-- pure: wanted finger sets for one hand. Returns mode ("weapon" | "empty"), then grip, trigger, thumb booleans
-- (weapon mode: grip = grip_weapon, trigger = trigger_weapon, thumb unused).
-- inp fields: weapon (right hand holds a weapon), weaponFist (option), trig (trigger pulled), grip (grip held),
-- holding (hand holds an item), point (knife aim point pose)
function M.decide(inp)
	if inp.weapon then
		if inp.weaponFist then return "weapon", true, true, false end
		return "weapon", true, inp.trig == true, false
	end
	if inp.holding or inp.grip then return "empty", true, true, true end
	if inp.point then return "empty", true, false, true end
	return "empty", false, false, false
end

local D = nil
local NAMES = { "grip", "trigger", "thumb" }
local WNAMES = { "grip_weapon", "trigger_weapon" }
-- per hand state: [1] left, [2] right
local S = { { mode = nil, v = {} }, { mode = nil, v = {} }, dirty = false, reT = 0.0, chT = 0.0, logged = false }
M.S = S
local HSTR = { "left", "right" }
local LERP = { duration = 0.1 }
local want = { false, false, false }

-- calls fn(animID) for every hand animation target of that hand (hands_animation targets, e.g. "right_" .. target)
local function eachId(h, fn)
	local ha = D.handsAnimation
	if ha ~= nil and ha.forEachTarget ~= nil then
		ha.forEachTarget(function(target) fn(HSTR[h] .. "_" .. target) end)
	end
end

-- one finger set to a state: instant (re-assert) or lerped (change)
local function setOne(id, name, on, instant)
	local anim = D.animation
	if instant then
		anim.animate(id, name, on and "on" or "off")
		anim.resetAnimation(id, name, on)
	else
		anim.resetAnimation(id, name, not on)
		anim.updateAnimation(id, name, on, LERP)
	end
end

-- applies hand h: offs first, then ons (the weapon and plain sets drive the same bones; last write wins)
local function apply(h, mode, instant, force)
	local st = S[h]
	local hs = HSTR[h]
	local names = mode == "weapon" and WNAMES or NAMES
	local modeChanged = st.mode ~= mode
	for pass = 1, 2 do
		local wantOn = pass == 2
		for i = 1, #names do
			local on = want[i] == true
			if on == wantOn and (force or modeChanged or st.v[i] ~= on) then
				local full = hs .. "_" .. names[i]
				eachId(h, function(id) setOne(id, full, on, instant) end)
			end
		end
	end
	st.mode = mode
	for i = 1, 3 do st.v[i] = want[i] end
end

function M.init(deps)
	D = deps
	pcall(function()
		D.uevrUtils.registerUEVRCallback("on_module_montage_change", function() S.dirty = true end)
	end)
	pcall(function()
		if D.attachments ~= nil and D.attachments.registerOnGripAnimationCallback ~= nil then
			D.attachments.registerOnGripAnimationCallback(function() S.dirty = true end)
		end
	end)
end

-- per input frame. inpL / inpR: see M.decide. Returns false when the driver is off (caller uses the old path).
function M.update(inpL, inpR, now)
	if D == nil then return false end
	pcall(D.hands.setAutoHandleInput, false)
	-- re-assert instantly after the lib re-posed (montage end / grip animation change) and every 1 s while steady
	local reassert = S.dirty or (now - S.reT > 1.0 and now - S.chT > 0.3)
	if reassert then S.dirty = false S.reT = now end
	for h = 1, 2 do
		local inp = h == 1 and inpL or inpR
		local mode, g, t, th = M.decide(inp)
		want[1], want[2], want[3] = g, t, th
		local st = S[h]
		local changed = st.mode ~= mode or st.v[1] ~= g or st.v[2] ~= t or st.v[3] ~= th
		if changed then
			S.chT = now
			apply(h, mode, false, false)
		elseif reassert then
			apply(h, mode, true, true)
		end
	end
	if not S.logged and D.log ~= nil then
		S.logged = true
		D.log("[HANDPOSE] driver on")
	end
	return true
end

function M.reset()
	for h = 1, 2 do S[h].mode = nil for i = 1, 3 do S[h].v[i] = nil end end
	S.dirty = true
end

return M
