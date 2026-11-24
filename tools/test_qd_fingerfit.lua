-- tests for libs/qd_fingerfit.lua pure helpers (step 129)
local f = require("qd_fingerfit")
local passed, failed = 0, 0
local function check(name, ok) if ok then passed = passed + 1 else failed = failed + 1 print("FAIL: " .. name) end end
local function near(a, b) return math.abs(a - b) < 1e-6 end

check("lerpAng plain", near(f.lerpAng(-20, -80, 0.5), -50))
check("lerpAng shortest way over the seam", near(f.lerpAng(170, -170, 0.5), 180))
check("lerpAng extrapolates", near(f.lerpAng(0, -60, 1.5), -90))
local out = {}
local r = f.lerpRot({ 0, 10, -20 }, { 0, 10, -80 }, 0.25, out)
check("lerpRot in place", r == out and near(out[3], -35) and near(out[2], 10))

-- never touches: all bones end at the free alpha
local calls = 0
local a, fr, t = f.fitFinger(3, 0.05, 1.35, 1.0, function() calls = calls + 1 return nil end)
check("no touch -> free alpha", near(a[1], 1.0) and near(a[2], 1.0) and near(a[3], 1.0) and fr == 0 and t == 0)
check("no touch -> sweeps to max", calls == 27)

-- segment k touches once its own bone passes threshold th[k]: wraps (bone 1 stops first, outer bones keep curling)
local th = { 0.4, 0.7, 0.9 }
local function hitAt(cur, nxt, frozen)
	for k = frozen + 1, 3 do if nxt[k] > th[k] + 1e-9 then return k end end
	return nil
end
a, fr, t = f.fitFinger(3, 0.05, 1.35, 1.0, hitAt)
check("wrap: each bone stops just before its touch", near(a[1], 0.4) and near(a[2], 0.7) and near(a[3], 0.9))
check("wrap: all frozen, 3 touches", fr == 3 and t == 3)

-- middle segment touches first: bones 1+2 freeze together, tip keeps going
a, fr = f.fitFinger(3, 0.05, 1.35, 1.0, function(cur, nxt, frozen)
	if frozen < 2 and nxt[2] > 0.5 + 1e-9 then return 2 end
	return nil
end)
check("touch on segment 2 freezes bones 1-2", near(a[1], 0.5) and near(a[2], 0.5) and near(a[3], 1.0) and fr == 2)

-- touch on the very first step: finger stays open
a = f.fitFinger(3, 0.05, 1.35, 1.0, function(cur, nxt, frozen) return 3 end)
check("immediate tip touch: open", near(a[1], 0) and near(a[3], 0))

-- thin handle: touch past the default fist is kept
a = f.fitFinger(3, 0.05, 1.35, 1.0, function(cur, nxt, frozen) if nxt[1] > 1.2 + 1e-9 then return 3 end return nil end)
check("thin handle: past the fist", near(a[1], 1.2) and near(a[3], 1.2))

-- hitFn returning a frozen segment is ignored (no endless loop)
a = f.fitFinger(3, 0.05, 1.35, 1.0, function(cur, nxt, frozen) return 0 end)
check("stale segment ignored", near(a[1], 1.0))

check("tick without init is a no-op", pcall(f.tick, 0.1, true))

print(string.format("qd_fingerfit: %d passed, %d failed", passed, failed))
return failed
