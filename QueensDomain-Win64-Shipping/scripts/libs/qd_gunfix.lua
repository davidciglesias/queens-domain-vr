-- Step 138 (headset 2026-11-25, user: shots with the ranged weapons fail to connect when the target is close).
-- The gun projectile spawns with its hit box scaled to 0.1 and grows over its flight; it stops on what it touches and the
-- game then runs its own hit trace with that still small box. Close up that trace found nothing in our tests (why is not
-- proven), so nothing was damaged. Fake headset, same pose and aim: control shots at a pot 60 / 100 cm away did not break
-- it; with the re-armed, full-size box it broke one frame later, through the game's own hit code.
-- What this does: when one of the player's own shots is seen stopped, marked as hit (AlreadyHit), after a short flight,
-- and an unhit target is there (a pot that is not broken: box trace; an enemy / breakable: its collision box reaches the
-- stop point - a single trace did not find enemies in our tests), it sets the box to full size and clears AlreadyHit for
-- exactly one frame: the game's own code then applies the hit once. No double hits: the stop can show up a tick after the
-- damage, so the shot is left alone when anything near the player lost HP (or vanished) during that shot's whole life
-- (S.lastDrop vs S.born). Runs only for M.WINDOW_S after a shot. Never calls hooked functions.
local M = {}
M.WINDOW_S = 1.0    -- s after the last shot press / hold tick
M.MAX_DIST = 400.0  -- cm travelled: farther shots are left alone (misses were still seen at about 300 cm)
M.HALF = 11.0       -- cm: 10 * 1.1, the game's own full-size box
M.CHAN = 2
M.MAX_HITS = 4
M.MAX_LOGS = 20
M.FAR = 600.0       -- cm: enemies / breakables beyond this from the stop point are not looked at
M.RANGE = 1500.0    -- cm from the player: only these enemies / breakables are sampled (list refreshed every NEAR_S)
M.NEAR_S = 0.5
M.PAD = 14.0        -- cm: half 11 * 1.1 plus a little, around an enemy's / breakable's collision box
M.on = true
local S = { untilT = 0.0, st = {}, gen = {}, g = 0, pmCls = nil, kinds = {}, cls = nil, armed = 0, special = {}, skip = {}, born = {}, lastDrop = -10, hpA = {}, hpB = {}, flip = false, logs = 0, errs = 0, v = nil, hr = nil, o = nil, ks = nil, gs = nil, ig = {}, n = 0 }
M.S = S
local D = nil

-- pure helpers (unit tests) ------------------------------------------------------------------------------------------
function M.wants(stopped, alreadyHit, dist, age)
	return stopped == true and alreadyHit == true and type(dist) == "number" and dist <= M.MAX_DIST
end
-- kind: "pot" (broken flag) or "enemy" / "perm" (hp now and at the previous tick); false = no extra hit
function M.unhit(kind, broken, hp, hpPrev)
	if kind == "pot" then return broken == false end
	if kind == "enemy" or kind == "perm" then
		return type(hp) == "number" and type(hpPrev) == "number" and hp > 0 and hp >= hpPrev
	end
	return false
end
function M.inBox(x, y, z, cx, cy, cz, ex, ey, ez, pad) -- point in a box (centre, half extents) grown by pad
	return math.abs(x - cx) <= ex + pad and math.abs(y - cy) <= ey + pad and math.abs(z - cz) <= ez + pad
end
function M.ownShot(pawnAd, instAd, ownerAd) -- addresses (nil when unknown)
	return pawnAd ~= nil and (instAd == pawnAd or ownerAd == pawnAd)
end
function M.kindOf(names) -- names: the class chain, nearest first
	for i = 1, #names do
		local n = names[i]
		if n == "Pot_Base_C" then return "pot" elseif n == "EnemyBase_C" then return "enemy" elseif n == "Permabreakable_base_C" then return "perm" end
	end
	return nil
end

-- never touched: special attacks (alt-fire projectiles, e.g. the charged wave held on the gun), exploding and ground
-- travelling shots. They carry the same fields, but deal area damage after they stop (a re-arm could explode them twice)
-- or run their own hit logic; a step-127 change once killed the wave's hits.
-- By class name only: normal shotgun / electric / sniper shots also have an EnemyHittingBox, so that is no sign.
M.HANDS_OFF = { "AltFire", "Alt_Projectile", "RocketLauncher", "Travelling" }
function M.special(names) -- names: the class chain
	for i = 1, #names do
		for q = 1, #M.HANDS_OFF do
			if string.find(names[i], M.HANDS_OFF[q], 1, true) ~= nil then return true end
		end
	end
	return false
end

-- engine side --------------------------------------------------------------------------------------------------------
function M.init(d)
	D = d -- {all(), log(m), getPawn(), getWorld(), ksl(), gs(), hit, col, outs, vec(x,y,z), classes()}
	S.st, S.gen, S.g, S.untilT = {}, {}, 0, 0.0
	S.cls, S.armed, S.skip = nil, 0, {}
	S.born, S.lastDrop = {}, -10
	S.special = {}
	S.near, S.nearK, S.nearN, S.nearT = {}, {}, 0, 0.0
	return true
end
function M.arm() -- a shot press or a held-fire tick; opens / extends the window (first call marks what already exists)
	if D == nil or not M.on then return end
	local now = os.clock()
	if S.cls == nil then S.cls = (D.classes ~= nil and D.classes()) or nil end
	if now > S.untilT then
		S.nearT = 0.0
		S.armed = 0
		S.skip = {}
		for k in pairs(S.st) do S.st[k], S.gen[k], S.born[k] = nil, nil, nil end
		for k in pairs(S.hpA) do S.hpA[k] = nil end -- history of an earlier window is stale
		for k in pairs(S.hpB) do S.hpB[k] = nil end
		local all = D.all()
		if all ~= nil then
			for i = 1, #all do
				pcall(function() local ad = all[i]:GetOwner():get_address() S.st[ad] = 2 S.gen[ad] = S.g end)
			end
		end
	end
	S.untilT = now + M.WINDOW_S
end
local function kind(a)
	local c = a:get_class()
	local key = c:get_address()
	local k = S.kinds[key]
	if k == nil then
		local x, n = c, 0
		k = false
		while x ~= nil and n < 12 do
			local kn = M.kindOf({ x:get_fname():to_string() })
			if kn ~= nil then k = kn break end
			x = x:get_super()
			n = n + 1
		end
		S.kinds[key] = k
	end
	return k
end
local function isSpecial(a) -- cached per class
	local c = a:get_class()
	local key = c:get_address()
	local r = S.special[key]
	if r == nil then
		local names, x, n = {}, c, 0
		while x ~= nil and n < 12 do
			n = n + 1
			names[n] = x:get_fname():to_string()
			x = x:get_super()
		end
		r = M.special(names)
		S.special[key] = r
	end
	return r
end
local function addr(o) return o ~= nil and o:get_address() or nil end
local function isOwn(a, pawnAd)
	local okI, i = pcall(function() return addr(a:GetInstigator()) end)
	local okO, o = pcall(function() return addr(a:GetOwner()) end)
	return M.ownShot(pawnAd, okI and i or nil, okO and o or nil)
end
local function readBox(a) local l = a:K2_GetActorLocation() return l.X, l.Y, l.Z end
-- enemies / breakables near the player (the full lists are too many to read every tick); list refreshed every NEAR_S
local function refresh(now)
	if now < S.nearT then return end
	S.nearT = now + M.NEAR_S
	local pl = D.getPawn():K2_GetActorLocation()
	local px, py, pz = pl.X, pl.Y, pl.Z
	local n = 0
	for _, c in pairs(S.cls or {}) do
		local all = UEVR_UObjectHook.get_objects_by_class(c.cls, false)
		for i = 1, all ~= nil and #all or 0 do
			pcall(function()
				local o = all[i]
				local l = o.RootComponent.RelativeLocation -- far cheaper than K2_GetActorLocation (5.8 -> 0.4 ms for 176 actors)
				local dx, dy, dz = l.X - px, l.Y - py, l.Z - pz
				if dx * dx + dy * dy + dz * dz > M.RANGE * M.RANGE then return end
				n = n + 1
				S.near[n], S.nearK[n] = o, c.kind
			end)
		end
	end
	for i = n + 1, S.nearN do S.near[i], S.nearK[i] = nil, nil end
	S.nearN = n
end
-- HP of every known enemy / breakable class instance at this tick -> S.hpA / S.hpB swapped (no allocation after warm-up)
local function readHP(o) return o:get_address(), o.HP end
local function sample()
	S.flip = not S.flip
	local cur = S.flip and S.hpA or S.hpB
	for k in pairs(cur) do cur[k] = nil end
	for i = 1, S.nearN do
		local ok, ad, hp = pcall(readHP, S.near[i])
		if ok then cur[ad] = hp end
	end
	local prev = S.flip and S.hpB or S.hpA
	for ad, hp in pairs(prev) do
		local h = cur[ad]
		if h == nil or h < hp then S.lastDrop = S.g end
	end
	return cur, prev
end
function M.tooLate(lastDrop, born) -- something was damaged during the shot's life (one tick of margin)
	return lastDrop >= (born or 0) - 1
end
-- true if the collision box of a living enemy / breakable with an HP history reaches the stop point
local function nearLiving(x, y, z, cur, prev)
	for i = 1, S.nearN do
		local kd = S.nearK[i]
		do
			local ok, r = pcall(function()
				local o = S.near[i]
				local ad = o:get_address()
				local h, hp = cur[ad], prev[ad]
				if h == nil then return nil end
				local l = o:K2_GetActorLocation()
				local dx, dy, dz = l.X - x, l.Y - y, l.Z - z
				if dx * dx + dy * dy + dz * dz > M.FAR * M.FAR then return nil end
				local t1, t2 = {}, {}
				o:GetActorBounds(true, t1, t2, false)
				local g, e = t1.result or t1, t2.result or t2
				if not M.inBox(x, y, z, g.X, g.Y, g.Z, e.X, e.Y, e.Z, M.PAD) then return nil end
				return M.unhit(kd, nil, h, hp)
			end)
			if ok and r == true then return true end
		end
	end
	return false
end
-- targets near the stop point; ok = at least one is a legitimate, not-yet-hit target
local function targetAt(a, cur, prev)
	local t = { found = false, what = "" }
	local lx, ly, lz = readBox(a)
	if nearLiving(lx, ly, lz, cur, prev) then t.found = true t.what = "enemy or breakable" return t end
	local x, y, z = readBox(a)
	local f = a:GetActorForwardVector()
	local rot = a:K2_GetActorRotation()
	local v = D.vec
	local s, e, half = v(x, y, z), v(x + f.X, y + f.Y, z + f.Z), v(M.HALF, M.HALF, M.HALF)
	local ig = { D.getPawn() }
	for k = 1, M.MAX_HITS do
		local ksl, gs = D.ksl(), D.gs()
		if ksl.BoxTraceSingle(ksl, D.getWorld(), s, e, half, rot, M.CHAN, false, ig, 0, D.hit, true, D.col, D.col, 0.0) ~= true then break end
		local o = D.outs
		gs:BreakHitResult(D.hit, o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8], o[9], o[10], o[11], o[12], o[13], o[14], o[15], o[16], o[17])
		local act = o[10].result
		if act == nil then break end
		ig[#ig + 1] = act
		local okK, kd = pcall(kind, act)
		if okK and kd then
			local ad = act:get_address()
			local broken = nil
			if kd == "pot" then broken = act.Broken end
			if kd == "pot" and M.unhit(kd, broken) then t.found = true t.what = kd return t end
		end
	end
	return t
end
local function rearm(a)
	pcall(function() a.ScaleUp:Stop() end)
	a:SetActorScale3D(S.v)
	a.AlreadyHit = false
end
local function step(pmc, cur, prev, pawnAd, g) -- one projectile
	local a = pmc:GetOwner()
	if a == nil then return true end
	local ad = a:get_address()
	local st = S.st[ad]
	if st == 2 then S.gen[ad] = g return end
	if st == nil or st == 1 or st == 3 then
		S.gen[ad] = g
		if st == nil then S.born[ad] = g end
		if st == 3 then -- re-armed last frame: the game had its one tick
			a.AlreadyHit = true
			S.st[ad] = 2
			S.armed = S.armed - 1
			return
		end
		if a.AlreadyHit == nil or a.DistanceTravelled == nil or a.ScaleUp == nil or a.Box == nil then S.st[ad] = 2 return end
		if st == nil then -- special attack, or its class unreadable: hands off
			local okC, sp = pcall(isSpecial, a)
			if not okC or sp then S.st[ad] = 2 return end
		end
		if st == nil and not isOwn(a, pawnAd) then S.st[ad] = 2 return end
		local vel = a.ProjectileMovement.Velocity
		local stopped = vel.X * vel.X + vel.Y * vel.Y + vel.Z * vel.Z < 1.0
		if M.wants(stopped, a.AlreadyHit, a.DistanceTravelled) then
			local t = not M.tooLate(S.lastDrop, S.born[ad]) and targetAt(a, cur, prev) or nil
			if t ~= nil and t.found then
				rearm(a)
				S.st[ad] = 3
				S.armed = S.armed + 1
				if S.logs < M.MAX_LOGS then S.logs = S.logs + 1 D.log(string.format("[GUNFIX] re-armed a stopped shot (travelled %.0f cm): target %s", a.DistanceTravelled, t.what)) end
			else S.st[ad] = 2 end
		elseif stopped then S.st[ad] = 2
		else S.st[ad] = 1 end
	end
end
function M.tick(now)
	if D == nil or not M.on then return end
	now = now or os.clock()
	if now > S.untilT and S.armed <= 0 then return end -- a re-armed shot is always restored, even past the window
	local ok, err = pcall(function()
		if S.v == nil then S.v = D.vec(1.0, 1.0, 1.0) end
		S.g = S.g + 1
		local g = S.g
		refresh(now)
		local cur, prev = sample()
		local pawnAd = addr(D.getPawn())
		local all = D.all()
		if all ~= nil then
			for i = 1, #all do
				local c = all[i]
				local ca = c:get_address()
				if S.skip[ca] ~= true then -- templates without an owner are most of the list, and GetOwner is the slow part
					local okS, none = pcall(step, c, cur, prev, pawnAd, g)
					if okS and none then S.skip[ca] = true end
				end
			end
		end
		for k, v in pairs(S.gen) do
			if v ~= g then -- the projectile is gone
				if S.st[k] == 3 then S.armed = S.armed - 1 end
				S.gen[k], S.st[k], S.born[k] = nil, nil, nil
			end
		end
	end)
	if not ok then
		S.errs = S.errs + 1
		if S.errs == 1 and D.log then D.log("[GUNFIX] error: " .. tostring(err)) end
		if S.errs >= 5 then M.on = false end
	end
end
return M
