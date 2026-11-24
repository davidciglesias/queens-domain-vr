-- Unit tests for libs/qd_itemview.lua (pure helpers + the re-hang decision on a stubbed engine). Run: python tools/run_tests.py
local V = require("qd_itemview")

local failed, passed = 0, 0
local function check(name, cond)
	if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end

check("factor 10 cm = the game's own", V.factor(10) == 1.0)
check("factor 50 cm", V.factor(50) == 5.0)
check("factor default", V.factor(nil) == 5.0 and V.factor("x") == 5.0)
check("factor clamped", V.factor(1) == 1.0 and V.factor(999) == 12.0)
check("temp names", V.isTempName("SceneComponent_2147452697") and not V.isTempName("DefaultSceneRoot") and not V.isTempName("SceneComponent"))

local moved = {}
local function obj(addr, name, owner, loc)
	local o = { addr = addr, loc = loc or { X = 10, Y = 0, Z = 0 } }
	function o:get_address() return self.addr end
	function o:get_fname() return { to_string = function() return name end } end
	function o:GetOwner() return owner end
	function o:K2_GetComponentLocation() return self.loc end
	function o:K2_AttachToComponent(p, _, a) moved[#moved + 1] = { self.addr, p.addr, a } end
	function o:SetRelativeScale3D(v) self.scale = v.X end
	return o
end
local pawn, owner = obj(1, "Pawn"), obj(2, "Item")
local base, inner = obj(10, "SceneComponent_5", owner), obj(11, "SceneComponent_6", owner)
local own, arms = obj(12, "SceneComponent_7", pawn), obj(13, "Arms", pawn)
local comp = { LocalRotBase = base }
function owner:GetComponentByClass(c) return c == "CLS" and comp or nil end
local cam = obj(3, "Cam", pawn, { X = 0, Y = 0, Z = 0 })
cam.AttachChildren = { arms, own, inner, base }
pawn.FirstPersonCamera = cam
local anchor, cm = obj(50, "anchor"), 50
V.init({
	api = { get_local_pawn = function() return pawn end, find_uobject = function(_, n) return n == V.CLASSES[1] and "CLS" or nil end },
	uevrUtils = { getValid = function(x) return x end, create_component_of_class = function() return anchor end, fname_from_string = function(s) return s end },
	getValue = function() return cm end, log = function() end })
V.tick(1.0)
check("no error", V.S.err == nil)
check("anchor hung on the camera, then only LocalRotBase on the anchor", #moved == 2 and moved[1][1] == 50 and moved[1][2] == 3 and moved[1][3] == 2
	and moved[2][1] == 10 and moved[2][2] == 50 and moved[2][3] == 0)
check("anchor scale", anchor.scale == 5.0)
cam.AttachChildren = { arms, own, inner }
V.tick(1.0)
check("nothing else moved", #moved == 2)
cm = 30
V.tick(1.0)
check("distance option follows live", anchor.scale == 3.0)

print(string.format("qd_itemview: %d passed, %d failed", passed, failed))
return failed
