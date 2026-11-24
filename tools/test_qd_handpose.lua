-- Unit tests for libs/qd_handpose.lua. Run: python tools/run_tests.py
package.loaded["qd_handpose"] = nil
local m = require("qd_handpose")
local failed, passed = 0, 0
local function check(name, cond) if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end end

do -- decide
	local md, g, t, th = m.decide({})
	check("default open", md == "empty" and not g and not t and not th)
	md, g, t, th = m.decide({ grip = true })
	check("grip = fist", md == "empty" and g and t and th)
	md, g, t = m.decide({ trig = true })
	check("trigger alone stays open", md == "empty" and not g and not t)
	md, g, t = m.decide({ holding = true })
	check("holding = fist", g and t)
	md, g, t, th = m.decide({ point = true })
	check("point = grip, index out", g and not t and th)
	md, g, t = m.decide({ weapon = true, weaponFist = true })
	check("weapon fist steady", md == "weapon" and g and t)
	md, g, t = m.decide({ weapon = true, weaponFist = false, trig = false })
	check("weapon no fist: index follows trigger", md == "weapon" and g and not t)
end

do -- runtime: lerps only on change, never every frame
	local calls = { upd = 0, anim = 0 }
	local fake = {
		hands = { setAutoHandleInput = function() end },
		handsAnimation = { forEachTarget = function(cb) cb("hands") end },
		animation = {
			resetAnimation = function() end,
			updateAnimation = function() calls.upd = calls.upd + 1 end,
			animate = function() calls.anim = calls.anim + 1 end,
		},
		uevrUtils = { registerUEVRCallback = function() end },
	}
	m.init(fake)
	m.reset()
	m.S.dirty = false
	local L, R = {}, { weapon = true, weaponFist = true }
	m.update(L, R, 0.0)
	local first = calls.upd
	check("first frame poses both hands", first > 0)
	for i = 1, 20 do m.update(L, R, 0.01 * i) end
	check("steady weapon fist: no new lerps", calls.upd == first)
	L.grip = true
	m.update(L, R, 0.25)
	check("left grip lerps once", calls.upd > first)
	local n = calls.upd
	m.update(L, R, 0.26)
	check("held grip: no repeat", calls.upd == n)
	m.S.dirty = true
	m.update(L, R, 0.27)
	check("dirty = instant re-assert", calls.anim > 0 and calls.upd == n)
end

print(string.format("qd_handpose: %d passed, %d failed", passed, failed))
return failed
