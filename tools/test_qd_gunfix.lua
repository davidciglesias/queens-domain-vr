-- Unit tests for libs/qd_gunfix.lua (pure helpers + the re-arm decision on a stubbed engine). Run: python tools/run_tests.py
local G = require("qd_gunfix")

local failed, passed = 0, 0
local function check(name, cond)
	if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end

check("wants: stopped, close, marked as hit", G.wants(true, true, 60) == true)
check("wants: still flying", not G.wants(false, true, 60))
check("wants: AlreadyHit false", not G.wants(true, false, 60))
check("wants: far shots left alone", G.wants(true, true, 390) and not G.wants(true, true, 900))
check("wants: no distance", not G.wants(true, true, nil))
check("unhit: pot", G.unhit("pot", false) and not G.unhit("pot", true))
check("unhit: enemy whose HP did not drop", G.unhit("enemy", nil, 50, 50))
check("unhit: enemy already damaged this tick", not G.unhit("enemy", nil, 40, 50))
check("unhit: enemy without history", not G.unhit("enemy", nil, 50, nil))
check("unhit: dead enemy", not G.unhit("enemy", nil, 0, 0))
check("unhit: unknown kind", not G.unhit("wall", false, 5, 5))
check("kindOf", G.kindOf({ "X", "Pot_Base_C" }) == "pot" and G.kindOf({ "EnemyBase_C" }) == "enemy" and G.kindOf({ "X" }) == nil)
check("ownShot by instigator", G.ownShot(7, 7, nil))
check("ownShot by owner", G.ownShot(7, nil, 7))
check("ownShot: another owner", not G.ownShot(7, 9, 8))
check("ownShot: unknown pawn", not G.ownShot(nil, nil, nil))

-- stubbed engine ------------------------------------------------------------------------------------------------------
local function vec(x, y, z) return { X = x, Y = y, Z = z } end
local pawn = { get_address = function() return 1 end, K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end }
local other = { get_address = function() return 999 end }
local enemyHP = { v = 100 }
local function class(name)
	return { get_address = function() return name end, get_fname = function() return { to_string = function() return name end } end, get_super = function() return nil end }
end
local enemyCls, potCls = class("EnemyBase_C"), class("Pot_Base_C")
local enemyLoc = { v = vec(20, 0, 0) }
local enemy = setmetatable({ get_address = function() return 50 end, get_class = function() return enemyCls end,
	K2_GetActorLocation = function() return enemyLoc.v end,
	RootComponent = setmetatable({}, { __index = function(_, k) if k == "RelativeLocation" then return enemyLoc.v end end }),
	GetActorBounds = function(_, _, t1, t2) t1.X, t1.Y, t1.Z = enemyLoc.v.X, enemyLoc.v.Y, enemyLoc.v.Z t2.X, t2.Y, t2.Z = 30, 30, 60 end },
	{ __index = function(_, k) if k == "HP" then return enemyHP.v end end })
local pot = { Broken = false, get_address = function() return 60 end, get_class = function() return potCls end }
local target = nil -- the actor the stubbed trace reports once
UEVR_UObjectHook = { get_objects_by_class = function(c) if c == enemyCls then return { enemy } end return {} end }
local all = {}
local ksl = { BoxTraceSingle = function(_, _, _, _, _, _, _, _, ig)
	if target == nil then return false end
	for _, a in ipairs(ig) do if a == target then return false end end
	return true
end }
local gs = { BreakHitResult = function(_, _, ...) local o = { ... } o[10].result = target end }
local outs = {}
for q = 1, 17 do outs[q] = {} end
G.init({ all = function() return all end, log = function() end, getPawn = function() return pawn end, getWorld = function() return {} end,
	ksl = function() return ksl end, gs = function() return gs end, hit = {}, col = {}, outs = outs, vec = vec,
	classes = function() return { { cls = enemyCls, kind = "enemy" } } end })
local function shot(own, ad, dist) -- a projectile actor p and its movement component m
	local p = { AlreadyHit = true, DistanceTravelled = dist, scale = 0.1, Box = {}, ProjectileMovement = { Velocity = vec(0, 0, 0) } }
	p.ScaleUp = { Stop = function() p.timelineStopped = true end }
	p.get_address = function() return ad end
	p.get_class = function() return class(p.clsName or "Gun_Projectile_C") end
	p.GetInstigator = function() return own and pawn or other end
	p.GetOwner = function() return own and pawn or other end
	p.K2_GetActorLocation = function() return vec(0, 0, 0) end
	p.K2_GetActorRotation = function() return {} end
	p.GetActorForwardVector = function() return vec(1, 0, 0) end
	p.SetActorScale3D = function(_, v) p.scale = v.X end
	return { GetOwner = function() return p end, get_address = function() return ad + 5000 end }, p
end
local now = os.clock()

-- a close shot that stopped, its target not hit: re-armed for one tick only
G.arm()
local m, p = shot(true, 101, 60)
p.AlreadyHit = false
p.ProjectileMovement.Velocity = vec(500, 0, 0)
all = { m }
G.tick(now)
p.ProjectileMovement.Velocity = vec(0, 0, 0)
p.AlreadyHit = true
target = pot
G.tick(now)
check("pot: re-armed", p.AlreadyHit == false and p.scale == 1 and p.timelineStopped == true)
G.tick(now)
check("pot: AlreadyHit restored a tick later", p.AlreadyHit == true)
p.scale = 0.2
G.tick(now)
check("pot: only once", p.scale == 0.2 and p.AlreadyHit == true)

-- an enemy: found by its collision box, the HP history decides
target = nil
local m2, p2 = shot(true, 102, 60)
all = { m, m2 }
G.S.hpA, G.S.hpB = {}, {} -- no HP history yet
G.tick(now)
check("enemy: not re-armed without HP history", p2.AlreadyHit == true and p2.scale == 0.1)
local m3, p3 = shot(true, 103, 60)
all = { m, m2, m3 }
G.tick(now)
check("enemy: re-armed when HP unchanged", p3.AlreadyHit == false and p3.scale == 1)
G.tick(now)
check("enemy: only for one tick", p3.AlreadyHit == true)
enemyHP.v = 90
local m4, p4 = shot(true, 104, 60)
all = { m, m2, m3, m4 }
G.tick(now)
check("enemy: not re-armed on the tick its HP dropped", p4.AlreadyHit == true and p4.scale == 0.1)
G.tick(now)
-- headset-free trace 2026-11-25: the HP drop shows one tick before the shot shows as stopped
G.tick(now) G.tick(now)
local m11, p11 = shot(true, 111, 300)
p11.ProjectileMovement.Velocity = vec(6000, 0, 0)
all = { m11 }
enemyHP.v = 85
G.tick(now)
p11.ProjectileMovement.Velocity = vec(0, 0, 0)
G.tick(now)
check("enemy: hit a tick before the stop shows: no second hit", p11.AlreadyHit == true and p11.scale == 0.1)
G.tick(now) G.tick(now)
local m12, p12 = shot(true, 112, 300)
p12.ProjectileMovement.Velocity = vec(6000, 0, 0)
all = { m12 }
G.tick(now)
p12.ProjectileMovement.Velocity = vec(0, 0, 0)
G.tick(now)
check("enemy: next shot without damage is re-armed again", p12.AlreadyHit == false and p12.scale == 1)
G.tick(now)
check("tooLate", G.tooLate(9, 10) and G.tooLate(12, 10) and not G.tooLate(8, 10))
G.tick(now) G.tick(now)
enemyLoc.v = vec(200, 0, 0)
local m5, p5 = shot(true, 105, 60)
all = { m5 }
G.tick(now)
check("enemy: too far from the stop point", p5.AlreadyHit == true and p5.scale == 0.1)
enemyLoc.v = vec(20, 0, 0)
enemyHP.v = 0
local m9, p9 = shot(true, 109, 60)
all = { m9 }
G.tick(now)
check("enemy: dead one is left alone", p9.AlreadyHit == true and p9.scale == 0.1)
enemyHP.v = 90
G.tick(now)
check("inBox", G.inBox(5, 0, 0, 0, 0, 0, 4, 4, 4, 1) and not G.inBox(6, 0, 0, 0, 0, 0, 4, 4, 4, 1) and G.inBox(0, -5, 0, 0, 0, 0, 4, 4, 4, 1))

-- shots that are not ours, far shots, and the window
target = pot
enemyLoc.v = vec(9000, 0, 0)
local m6, p6 = shot(false, 106, 60)
all = {}
G.tick(now) G.tick(now) G.tick(now)
all = { m6 }
G.tick(now)
check("another owner's shot: never touched", p6.AlreadyHit == true and p6.scale == 0.1)
local m7, p7 = shot(true, 107, 900)
all = { m7 }
G.tick(now)
check("far shot: untouched", p7.AlreadyHit == true and p7.scale == 0.1)
local m8, p8 = shot(true, 108, 60)
all = { m8 }
G.S.untilT = 0
G.tick(now)
check("window closed: untouched", p8.AlreadyHit == true and p8.scale == 0.1)
all = { m8 }
G.arm() -- opening the window marks what already exists
G.tick(now)
check("existing shot at window start: untouched", p8.AlreadyHit == true and p8.scale == 0.1)
-- re-armed on the last tick of the window: still restored after it closed
enemyLoc.v = vec(9000, 0, 0)
target = pot
pot.Broken = false
G.S.untilT = os.clock() + 100
local m10, p10 = shot(true, 110, 60)
all = {}
G.tick(now) G.tick(now) G.tick(now)
p10.AlreadyHit = false
p10.ProjectileMovement.Velocity = vec(500, 0, 0)
all = { m10 }
G.tick(now)
p10.ProjectileMovement.Velocity = vec(0, 0, 0)
p10.AlreadyHit = true
G.tick(now)
check("late: re-armed", p10.AlreadyHit == false)
G.S.untilT = 0
G.tick(os.clock())
check("late: restored after the window", p10.AlreadyHit == true and G.S.armed == 0)
-- special attacks are never touched, whatever their state
check("special: by name", G.special({ "X_AltFireProjectile_BP_C", "Actor" }) and G.special({ "Y_C", "Z_AltFireProjectile_C" }) and not G.special({ "Gun_Projectile_C", "Actor" }))
for q, v in ipairs({ { "W_AltFireProjectile_C" }, { "E_Alt_Projectile_C" }, { "RocketLauncher_Projectile_C" }, { "P_TravellingWave_C" } }) do
	G.S.untilT = os.clock() + 100
	enemyLoc.v = vec(20, 0, 0)
	enemyHP.v = 90
	target = pot
	pot.Broken = false
	all = {}
	for _ = 1, 4 do G.tick(now) end
	local m13, p13 = shot(true, 200 + q, 60)
	p13.clsName, p13.EnemyHittingBox = v[1], {}
	p13.AlreadyHit = true -- charging on the gun: velocity 0, marked as hit, no distance yet
	p13.DistanceTravelled = 0
	p13.scale = 0.3
	all = { m13 }
	for _ = 1, 3 do G.tick(now) end
	check("special " .. q .. ": charging untouched", p13.AlreadyHit == true and p13.scale == 0.3 and p13.timelineStopped == nil and G.S.armed == 0)
	p13.AlreadyHit = false -- released and flying, then stopped with a hit next to an unhit enemy
	p13.ProjectileMovement.Velocity = vec(3000, 0, 0)
	p13.DistanceTravelled = 80
	G.tick(now)
	p13.ProjectileMovement.Velocity = vec(0, 0, 0)
	G.tick(now)
	check("special " .. q .. ": AlreadyHit not forced on", p13.AlreadyHit == false and p13.scale == 0.3)
	p13.AlreadyHit = true
	for _ = 1, 3 do G.tick(now) end
	check("special " .. q .. ": stopped untouched", p13.AlreadyHit == true and p13.scale == 0.3 and p13.timelineStopped == nil and G.S.armed == 0)
end
-- a normal shot that also has an EnemyHittingBox (shotgun, electric, sniper) still gets the fix
all = {}
for _ = 1, 4 do G.tick(now) end
G.S.untilT = os.clock() + 100
target = pot
enemyHP.v = 90
enemyLoc.v = vec(20, 0, 0)
local m14, p14 = shot(true, 300, 60)
p14.clsName, p14.EnemyHittingBox = "ShotGun_Projectile_BP_C", {}
p14.AlreadyHit = false
p14.ProjectileMovement.Velocity = vec(500, 0, 0)
all = { m14 }
G.tick(now)
p14.ProjectileMovement.Velocity = vec(0, 0, 0)
p14.AlreadyHit = true
G.tick(now)
check("normal shot with an EnemyHittingBox: re-armed", p14.AlreadyHit == false and p14.scale == 1)
G.tick(now)
check("no errors", G.S.errs == 0)

print(string.format("qd_gunfix: %d passed, %d failed", passed, failed))
return failed
