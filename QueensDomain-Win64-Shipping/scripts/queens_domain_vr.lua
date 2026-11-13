local api = uevr.api
local vr = uevr.params.vr
local params = uevr.params
local callbacks = params.sdk.callbacks

local controllers = require('libs/controllers')
local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local hands = require('libs/hands')
local mathLib = require("libs/core/math_lib")
local handsAnimation = require('libs/hands_animation')
local attachments = require('libs/attachments')
local plugin = require('libs/core/plugin')
local motionMelee = require("libs/motion_melee")
local interaction = require("libs/interaction")
-- test 20: new state/functions live in one table (the main chunk is at Lua's 200-local limit)
local T20 = {grip = require("libs/qd_grip"), pickup = require("libs/qd_pickup"), xHeld = false, heldT = 0.0, aimFails = 0, aimRetryT = 0.0}
-- a script reload keeps the world (and our old helper meshes); on a fresh game start no motion controller exists yet
pcall(function() local mc = uevrUtils.find_all_of("Class /Script/HeadMountedDisplay.MotionControllerComponent", false) T20.reloaded = mc ~= nil and #mc > 0 end)

--local interaction = require("libs/interaction")
kismet_math_library = uevrUtils.find_default_instance("Class /Script/Engine.KismetMathLibrary")
local zero_color = uevrUtils.get_reuseable_struct_object("ScriptStruct /Script/CoreUObject.LinearColor")
local hitresult_c = uevrUtils.find_required_object("ScriptStruct /Script/Engine.HitResult")
local empty_hitresult = StructObject.new(hitresult_c)
local reusable_hit_result = uevrUtils.get_reuseable_struct_object("ScriptStruct /Script/Engine.HitResult")

local normalPlay = false

local swingNotifyHook = false
local activeWeapon = nil
local activeWeaponMesh = nil
local activeLeftWeaponMesh = nil

local interactBuzzed = false
--dodge

local DODGE_FORCE = 2400.0  
local DODGE_COOLDOWN = 0.5 
local dodgeCooldownRemaining = 0.0

local STICK_DEADZONE = 7849.0 
local STICK_MAX = 32767.0

local dodgeWasHeld = false
local frameDodgeHeld = false
local lastLoggedButtons = -1
local inputIndex = nil -- xinput user_index that carries real data (callback also fires with an all-zero state)
local rtLowSince = nil -- RT release debounce start (meleeClock)
local l2DodgeHeld = false
-- test 16: L2 + physical stab. L2 held only arms (l2StabSeen = meleeClock while held); checkMeleeSwing turns an outward thrust into the alt attack
local l2StabArmed, l2StabSeen, l2StabReleaseIn, l2StabWeapon = false, -1.0, 0.0, nil
local rsDodgeHeld, rsDodgePressed = false, false
local dbgLastWeaponMesh = nil
local rtPressedAt = 0.0
local rtSwingReleased = false -- RT charge already released by a swing; skip AttackReleased on trigger up

--pickables

local needToPupolatePickables = true
local currentLevelPickables = {}
local currentAvailablePickable = nil
local pickableHeld = false
local physicalPickablePickup = false
local inPickupDialog = false
local pickupFlyDuration = 0.25
local pickupFlyLerpID = "pickup_fly_in"
local pickupFlyState = nil
local currentPickup = nil
local currentPickupMesh = nil

local leftShoulderButtonHeld = false
local aButtonHeld = false

local rightTriggerHeld = false
local leftTriggerHeld = false
local rightThumbHeld = false
local backHeld = false


local levelPickupableMaxDist = 100000 --km

local currentAreaMusic = nil
local lastTouchedSaveArea = nil

local pickableClassNames = {
"BlueprintGeneratedClass /Game/Blueprints/ItemPickup_Base.ItemPickup_Base_C"
}

--left hand laser
local showLaser = false
interaction.init()
interaction.showInteractionLaser(false)

--hud
local currentStatusBar = nil
local currentHealthBar = nil
local currentAmmoBar = nil
local currentWeaponChargeBar = nil
local currentRootElement = nil
local currentConsumableBar = nil
local currentCompass = nil
local currentCompassWidgetComponent = nil


local configDefinition = {
	{
		panelLabel = "Queen's Domain VR", 
		saveFile = "user_configuration", 
		layout = {
			{
				widgetType = "slider_int",
				id = "loc_x",
				label = "x",
				initialValue = 0,
				range = {"-50", "50"}
			},
			{
				widgetType = "slider_int",
				id = "loc_y",
				label = "y",
				initialValue = 0,
				range = {"-50", "50"}
			},
			{
				widgetType = "slider_int",
				id = "loc_z",
				label = "z",
				initialValue = 0,
				range = {"-50", "50"}
			},
			{
				widgetType = "slider_int",
				id = "rot_yaw",
				label = "yaw",
				initialValue = 0,
				range = {"-180", "360"}
			},
			{
				widgetType = "slider_int",
				id = "rot_roll",
				label = "roll",
				initialValue = 0,
				range = {"-180", "360"}
			},
			{
				widgetType = "slider_int",
				id = "rot_pitch",
				label = "pitch",
				initialValue = 0,
				range = {"-180", "360"}
			},
			{
				widgetType = "slider_float",
				id = "scale",
				label = "scale",
				initialValue = 0,
				range = {"0", "10"}
			},
			{
				widgetType = "text",
				label = "=== Accessibility ===",
			},	
			{
				widgetType = "checkbox",
				id = "frame_layout",
				label = "Steam Frame layout (B = dodge; X/Y interact; no stick-gesture dodge)",
				initialValue = true
			},
			{
				widgetType = "slider_float",
				id = "ui_y_offset",
				label = "UI vertical offset (dialogue text; + raises)",
				initialValue = 0.3,
				range = {-1.0, 1.0}
			},
			{
				widgetType = "checkbox",
				id = "verical_status_bar",
				label = "Verical Status Bar (unused: HP HUD now on left hand)",
				initialValue = false
			},
			{ widgetType = "checkbox", id = "aim_dot", label = "Knife aim: grey dot instead of laser", initialValue = true },
			{ widgetType = "slider_float", id = "aim_dot_size", label = "Knife aim dot size", initialValue = 1.0, range = {0.2, 4.0} },
			-- test 8
			{ widgetType = "checkbox", id = "hide_knife_model", label = "Hide 3D knife model in left hand", initialValue = false },
			{ widgetType = "checkbox", id = "no_late_update", label = "Disable controller late-update (weapon follows HMD fix?)", initialValue = true },
			{ widgetType = "checkbox", id = "roomscale", label = "Roomscale movement (A/B test for weapon drift)", initialValue = false },
			{ widgetType = "checkbox", id = "l2_native_dodge", label = "L2 = weapon alt attack (sword: forward stab, spear: stab then back off) toward where you look", initialValue = true },
			{ widgetType = "checkbox", id = "rstick_turn", label = "Right stick = smooth turn left/right (off = right stick dodge below)", initialValue = true },
			{ widgetType = "slider_float", id = "rstick_turn_speed", label = "Smooth turn speed (x game turn rate)", initialValue = 1.0, range = {0.2, 2.0} },
			{ widgetType = "checkbox", id = "rstick_dodge", label = "Right stick = directional dodge (only when smooth turn is off)", initialValue = true },
			-- test 16
			{ widgetType = "checkbox", id = "l2_stab_gesture", label = "Alt attack = hold L2 + stab with right hand (needs Motion Controls Melee; off = L2 alone)", initialValue = true },
			{ widgetType = "slider_float", id = "stab_outward", label = "Stab detection: min share of hand motion away from head (0 = off; rejected real pokes)", initialValue = 0.0, range = {0.0, 0.95} },
			-- test 17
			{ widgetType = "slider_float", id = "stab_axis", label = "Stab detection: min alignment of hand motion toward the weapon tip (0 = off: any stroke with L2 held = alt attack)", initialValue = 0.0, range = {0.0, 0.95} },
			-- test 19
			{ widgetType = "checkbox", id = "motion_hit_window", label = "Hits during the whole physical swing (opens the hit window at swing start, closes when the hand slows)", initialValue = false },
			{ widgetType = "checkbox", id = "crosshair_on_top", label = "Game crosshair drawn on top of scenery", initialValue = true },
			{ widgetType = "checkbox", id = "weapon_fov_fix", label = "Undo the game's first-person weapon FOV squash (weapon drift/swim fix)", initialValue = true },
			{ widgetType = "slider_float", id = "weapon_fpfov", label = "Weapon FOV value (0 = auto: game camera FOV, worked at 100; game uses 60)", initialValue = 0.0, range = {0.0, 160.0} },
			{ widgetType = "checkbox", id = "game_crosshair", label = "Game crosshair in 3D at knife aim point (hides the left-eye-only copy)", initialValue = true },
			{ widgetType = "checkbox", id = "game_crosshair_gaze", label = "Game crosshair where you look when not knife-aiming", initialValue = true },
			{ widgetType = "slider_float", id = "crosshair_size", label = "Game crosshair size", initialValue = 1.0, range = {0.2, 4.0} },
			{ widgetType = "checkbox", id = "crosshair_bold", label = "Game crosshair: bold + dark outline", initialValue = true },
			-- test 20
			{ widgetType = "checkbox", id = "pickup_assist", label = "Easy pickups: point left hand or crosshair at an item (beam shows it), grip or X grabs", initialValue = true },
			{ widgetType = "checkbox", id = "pickup_auto_take", label = "Grabbed item goes straight to the inventory (off = press A to take it)", initialValue = true },
			{ widgetType = "checkbox", id = "pickup_auto_hold", label = "Items without a hand-tuned grip are held upright in the fist, shrunk to hand size", initialValue = true },
			{ widgetType = "checkbox", id = "belt", label = "Consumable belt: owned items hang at your waist (look down); grip one, bring it to your mouth to use it", initialValue = true },
			{ widgetType = "slider_int", id = "belt_slots", label = "Belt cards: N quick-slot items around the game's current item (its next/previous item buttons scroll the belt)", initialValue = 5, range = {1, 5} },
			{ widgetType = "slider_float", id = "belt_drop", label = "Belt height: cm below your eyes", initialValue = 60.0, range = {30.0, 95.0} },
			-- step 3: IK arms (libs/qd_ik.lua). The IK lib is only loaded when this is on at script load
			{ widgetType = "checkbox", id = "ik_arms", label = "IK arms (experimental): arms follow your hands. Needs motion controls melee; turning it on needs a game restart", initialValue = false },
			{ widgetType = "checkbox", id = "pickup_beam", label = "Pickup beam from the left hand to the targeted item", initialValue = true },
			{ widgetType = "slider_float", id = "pickup_cone", label = "Pickup aim tolerance (degrees, on top of 10 cm)", initialValue = 6.0, range = {1.0, 20.0} },
			{ widgetType = "slider_float", id = "pickup_range", label = "Pickup reach (m)", initialValue = 3.5, range = {1.0, 8.0} },
			{ widgetType = "checkbox", id = "auto_grip", label = "Auto grip for weapons with no saved grip (computed from the weapon's shape)", initialValue = true },
			{ widgetType = "checkbox", id = "hit_haptics", label = "Weapon hand vibrates when a hit lands", initialValue = true },
			-- test 9: usable-item HUD (ConsumableHUD) on the left hand, tweak live
			{ widgetType = "text", label = "--- Item HUD on left hand ---" },
			{ widgetType = "slider_float", id = "item_hud_x", label = "Item HUD X (forward)", initialValue = 3.1, range = {-40, 40} },
			{ widgetType = "slider_float", id = "item_hud_y", label = "Item HUD Y (right)", initialValue = -4.24, range = {-40, 40} },
			{ widgetType = "slider_float", id = "item_hud_z", label = "Item HUD Z (up)", initialValue = 7.51, range = {-40, 40} },
			{ widgetType = "slider_float", id = "item_hud_pitch", label = "Item HUD pitch", initialValue = 158.0, range = {-180, 180} },
			{ widgetType = "slider_float", id = "item_hud_yaw", label = "Item HUD yaw", initialValue = -4.0, range = {-180, 180} },
			{ widgetType = "slider_float", id = "item_hud_roll", label = "Item HUD roll", initialValue = 165.0, range = {-180, 180} },
			{ widgetType = "slider_float", id = "item_hud_rx", label = "Item HUD extra rot about hand X (forward)", initialValue = 0.0, range = {-180, 180} },
			{ widgetType = "checkbox", id = "plain_weapon_mat", label = "Plain material on held weapon (old sway workaround)", initialValue = false },
			{ widgetType = "slider_float", id = "compass_dx", label = "Compass offset X (cm)", initialValue = -3.28, range = {-15, 15} },
			{ widgetType = "slider_float", id = "compass_dy", label = "Compass offset Y (cm)", initialValue = 3.47, range = {-15, 15} },
			{ widgetType = "slider_float", id = "compass_dz", label = "Compass offset Z (cm)", initialValue = -1.12, range = {-15, 15} },
			{ widgetType = "slider_float", id = "compass_rx", label = "Compass extra rot about hand X", initialValue = 5.6, range = {-180, 180} },
			{ widgetType = "slider_float", id = "compass_ry", label = "Compass extra rot about hand Y", initialValue = 4.5, range = {-180, 180} },
			{ widgetType = "slider_float", id = "compass_rz", label = "Compass extra rot about hand Z", initialValue = 20.25, range = {-180, 180} },
			{ widgetType = "slider_float", id = "item_hud_ry", label = "Item HUD extra rot about hand Y (right)", initialValue = 0.0, range = {-180, 180} },
			{ widgetType = "slider_float", id = "item_hud_rz", label = "Item HUD extra rot about hand Z (up)", initialValue = 0.0, range = {-180, 180} },
			{ widgetType = "slider_float", id = "item_icon_dx", label = "Item icon nudge X (px)", initialValue = 0.0, range = {-200, 200} },
			{ widgetType = "slider_float", id = "item_icon_dy", label = "Item icon nudge Y (px)", initialValue = 0.0, range = {-200, 200} },
			{ widgetType = "slider_float", id = "item_hud_scale", label = "Item HUD scale", initialValue = 0.03, range = {0.005, 0.15} },
			-- test 7: HP HUD (StatusCluster) on the left hand, tweak live (cm / degrees, relative to the left controller)
			{ widgetType = "text", label = "--- HP HUD on left hand ---" },
			{ widgetType = "slider_float", id = "hp_hud_x", label = "HP HUD X (forward)", initialValue = 8.63, range = {-40, 40} },
			{ widgetType = "slider_float", id = "hp_hud_y", label = "HP HUD Y (right)", initialValue = 3.0, range = {-40, 40} },
			{ widgetType = "slider_float", id = "hp_hud_z", label = "HP HUD Z (up)", initialValue = 10.0, range = {-40, 40} },
			{ widgetType = "slider_float", id = "hp_hud_pitch", label = "HP HUD pitch", initialValue = -178.28, range = {-180, 180} },
			{ widgetType = "slider_float", id = "hp_hud_yaw", label = "HP HUD yaw", initialValue = -2.0, range = {-180, 180} },
			{ widgetType = "slider_float", id = "hp_hud_roll", label = "HP HUD roll", initialValue = -156.99, range = {-180, 180} },
			{ widgetType = "slider_float", id = "hp_hud_rx", label = "HP HUD extra rot about hand X (forward)", initialValue = 0.0, range = {-180, 180} },
			{ widgetType = "slider_float", id = "hp_hud_ry", label = "HP HUD extra rot about hand Y (right)", initialValue = 0.0, range = {-180, 180} },
			{ widgetType = "slider_float", id = "hp_hud_rz", label = "HP HUD extra rot about hand Z (up)", initialValue = 0.0, range = {-180, 180} },
			{ widgetType = "slider_float", id = "hp_hud_scale", label = "HP HUD scale", initialValue = 0.05, range = {0.005, 0.15} },
			
			{
				widgetType = "text",
				label = "=== GamePlay ===",
			},
			{
				widgetType = "checkbox",
				id = "6dof_right",
				label = "Motion Controls Melee (experimental)",
				initialValue = false
			},
			{
				widgetType = "slider_float",
				id = "motion_swing_speed",
				label = "swing speed threshold (m/s)",
				initialValue = 2.0,
				range = {1.0, 6.0}
			},
			{
				widgetType = "slider_float",
				id = "motion_swing_cooldown",
				label = "swing cooldown (s)",
				initialValue = 0.4,
				range = {0.1, 1.5}
			},
			{
				widgetType = "checkbox",
				id = "debug_hitboxes",
				label = "Show debug hitboxes (wireframe)",
				initialValue = false
			},
			{
				widgetType = "slider_float",
				id = "hitbox_forward_offset",
				label = "SPEAR hitbox offset (cm, - = toward hand)",
				initialValue = 0.0,
				range = {-80, 60}
			},
			{
				widgetType = "slider_float",
				id = "spear_reach",
				label = "SPEAR hitbox extra reach past tip (cm)",
				initialValue = 0.0,
				range = {0, 150}
			},
			{
				widgetType = "slider_float",
				id = "blade_offset",
				label = "BLADE hitbox offset (cm, - = toward hand)",
				initialValue = 0.0,
				range = {-80, 60}
			},
			{
				widgetType = "slider_float",
				id = "blade_reach",
				label = "BLADE hitbox extra reach past tip (cm)",
				initialValue = 0.0,
				range = {0, 150}
			},
			{ widgetType = "slider_float", id = "blade_side", label = "BLADE hitbox side shift (cm, across blade width)", initialValue = 0.0, range = {-40, 40} },
			{ widgetType = "slider_float", id = "blade_flat", label = "BLADE hitbox flat shift (cm, through blade face)", initialValue = 0.0, range = {-40, 40} },
			{
				widgetType = "checkbox",
				id = "charge_on_swing",
				label = "Hold RT to charge, swing to release",
				initialValue = true
			},
			{ widgetType = "checkbox", id = "charge_haptics", label = "Weapon hand pulses while charging (strong at full)", initialValue = true },
			{ widgetType = "checkbox", id = "rush_buffer", label = "Swing during a dash waits for the rush attack window", initialValue = true },
			{ widgetType = "slider_float", id = "rush_earliest", label = "Rush window opens (s into the dash, sword-type weapons only)", initialValue = 0.6, range = {0.2, 1.0} },
			{
				widgetType = "checkbox",
				id = "disable_dodge",
				label = "Disable Dodging",
				initialValue = false
			}
			--[[{
				widgetType = "checkbox",
				id = "constant_attack",
				label = "No cooldown between attacks",
				initialValue = true
			}]]
		}
	}
}

configui.create(configDefinition)



configui.onUpdate("loc_x", function() currentPickupMesh:K2_SetRelativeLocation({X = configui.getValue("loc_x"),Y = configui.getValue("loc_y"), Z = configui.getValue("loc_z")},true, empty_hitresult, true)
	currentPickupMesh:K2_SetRelativeRotation({Yaw = configui.getValue("rot_yaw"), Roll = configui.getValue("rot_roll"), Pitch = configui.getValue("rot_pitch")},true, empty_hitresult, true)  end)
configui.onUpdate("loc_y", function() currentPickupMesh:K2_SetRelativeLocation({X = configui.getValue("loc_x"),Y = configui.getValue("loc_y"), Z = configui.getValue("loc_z")},true, empty_hitresult, true)
	currentPickupMesh:K2_SetRelativeRotation({Yaw = configui.getValue("rot_yaw"), Roll = configui.getValue("rot_roll"), Pitch = configui.getValue("rot_pitch")},true, empty_hitresult, true) end)
configui.onUpdate("loc_z", function() currentPickupMesh:K2_SetRelativeLocation({X = configui.getValue("loc_x"),Y = configui.getValue("loc_y"), Z = configui.getValue("loc_z")},true, empty_hitresult, true)
	currentPickupMesh:K2_SetRelativeRotation({Yaw = configui.getValue("rot_yaw"), Roll = configui.getValue("rot_roll"), Pitch = configui.getValue("rot_pitch")},true, empty_hitresult, true)  end)
configui.onUpdate("rot_pitch", function() currentPickupMesh:K2_SetRelativeLocation({X = configui.getValue("loc_x"),Y = configui.getValue("loc_y"), Z = configui.getValue("loc_z")},true, empty_hitresult, true)
	currentPickupMesh:K2_SetRelativeRotation({Yaw = configui.getValue("rot_yaw"), Roll = configui.getValue("rot_roll"), Pitch = configui.getValue("rot_pitch")},true, empty_hitresult, true)  end)
configui.onUpdate("rot_yaw", function() currentPickupMesh:K2_SetRelativeLocation({X = configui.getValue("loc_x"),Y = configui.getValue("loc_y"), Z = configui.getValue("loc_z")},true, empty_hitresult, true)
	currentPickupMesh:K2_SetRelativeRotation({Yaw = configui.getValue("rot_yaw"), Roll = configui.getValue("rot_roll"), Pitch = configui.getValue("rot_pitch")},true, empty_hitresult, true) end)
configui.onUpdate("rot_roll", function() currentPickupMesh:K2_SetRelativeLocation({X = configui.getValue("loc_x"),Y = configui.getValue("loc_y"), Z = configui.getValue("loc_z")},true, empty_hitresult, true)
	currentPickupMesh:K2_SetRelativeRotation({Yaw = configui.getValue("rot_yaw"), Roll = configui.getValue("rot_roll"), Pitch = configui.getValue("rot_pitch")},true, empty_hitresult, true)  end)
configui.onUpdate("rot_roll", function() currentPickupMesh:K2_SetRelativeLocation({X = configui.getValue("loc_x"),Y = configui.getValue("loc_y"), Z = configui.getValue("loc_z")},true, empty_hitresult, true)
	currentPickupMesh:K2_SetRelativeRotation({Yaw = configui.getValue("rot_yaw"), Roll = configui.getValue("rot_roll"), Pitch = configui.getValue("rot_pitch")},true, empty_hitresult, true)  end)
configui.onUpdate("scale", function() currentPickupMesh.RelativeScale3D = {X= configui.getValue("scale"), Y = configui.getValue("scale"), Z = configui.getValue("scale")} end)


uevrUtils.setDeveloperMode(true)
attachments.init()



function hookFuntionsForRuntimeGeneratedClasses()
	if swingNotifyHook == false then
		hook_function("BlueprintGeneratedClass /Game/Items/Weapons/WeaponScriptBase.WeaponScriptBase_C", "OnNotifyBegin_BBD82C9E43AB0CB100ED8387EBE1942F", false,
			function(fn, obj, locals, result)
				print("in OnNotifyBegin_BBD82C9E43AB0CB100ED8387EBE1942F")
				attachHitboxesToWeaponTip()
				pcall(meleeLogNotify, "Begin")
			end,
			function(fn, obj, locals, result)
				--print("in F_Success")
				attachHitboxesToWeaponTip()
			end, -- no post-hook needed
		true)
		hook_function("BlueprintGeneratedClass /Game/Items/Weapons/WeaponScriptBase.WeaponScriptBase_C", "OnNotifyEnd_BBD82C9E43AB0CB100ED8387EBE1942F", false,
			function(fn, obj, locals, result)
				print("in OnNotifyEnd_BBD82C9E43AB0CB100ED8387EBE1942F")
				attachHitboxesToWeaponTip()
				pcall(meleeLogNotify, "End")
			end,
			function(fn, obj, locals, result)
				--print("in F_Success")
				attachHitboxesToWeaponTip()
			end, -- no post-hook needed
		true)
		local okH, errH = pcall(hookHitWindow)
		if not okH then uevr.params.functions.log_info("[MELEE] HIT hooks error " .. tostring(errH)) end
		swingNotifyHook = true
	end
end

-- test 20: auto grip (auto_grip). A weapon mesh with no attachments entry gets one from qd_grip.autoGrip (static mesh
-- bounds), oriented like the user's sword entry (reference); gun scripts (GunBase_WeaponScript_C) barrel-straight.
-- Saved entries (user-tuned or generated earlier) are never touched. Known ids: read once from the saved parameters.
T20.agKnown, T20.agDone, T20.agErrLogged = nil, {}, false
T20.AG_REF_ID = "RustySword_WeaponVisuals_C_RustySword"
function T20.agRef()
	local e = T20.agKnown ~= nil and T20.agKnown[T20.AG_REF_ID] or nil
	if e == nil or type(e.rotation) ~= "table" or type(e.location) ~= "table" then return nil end
	return {rotation = {Pitch = e.rotation[1], Yaw = e.rotation[2], Roll = e.rotation[3]},
		location = {X = e.location[1], Y = e.location[2], Z = e.location[3]}, long = T20.grip.REF.long, wide = T20.grip.REF.wide}
end
function T20.agIsRanged(weapon) -- class chain contains GunBase_WeaponScript_C (name from the SDK; path not assumed)
	if weapon == nil then return false end
	local ok, r = pcall(function()
		local cls = weapon:get_class()
		for _ = 1, 12 do
			if cls == nil then return false end
			if cls:get_fname():to_string() == "GunBase_WeaponScript_C" then return true end
			cls = cls:get_super_struct()
		end
		return false
	end)
	return ok and r == true
end
function autoGripEnsure(mesh, weapon)
	if mesh == nil then return end
	local asset = mesh.StaticMesh or mesh.SkeletalMesh -- skeletal weapon meshes: same bounds call
	if asset == nil then return end
	if T20.agKnown == nil then
		T20.agKnown = {}
		local okJ, p = pcall(json.load_file, "attachments_parameters.json")
		if okJ and type(p) == "table" and type(p.attachmentOffsets) == "table" then
			for _, e in ipairs(p.attachmentOffsets) do if e.id ~= nil then T20.agKnown[e.id] = e end end
		end
	end
	local id = attachments.getAttachmentIDFromAttachment(mesh)
	if id == nil or T20.agDone[id] then return end
	T20.agDone[id] = true
	if T20.agKnown[id] ~= nil then return end
	local b = asset:GetBounds()
	if b == nil or b.BoxExtent == nil then return end
	local ranged = T20.agIsRanged(weapon)
	local s = mesh.RelativeScale3D
	local sc = (s ~= nil and s.X ~= nil and s.X > 0.01) and s.X or 1.0
	local rot, loc, info = T20.grip.autoGrip(b.Origin, b.BoxExtent, {ranged = ranged, ref = T20.agRef(), scale = sc})
	attachments.addAttachmentToConfig(mesh)
	attachments.setAttachmentOffset(id, loc, {X = rot.Pitch, Y = rot.Yaw, Z = rot.Roll}, {X = sc, Y = sc, Z = sc})
	T20.agKnown[id] = {id = id, auto = true}
	uevr.params.functions.log_info(string.format("[GRIP] auto %s ranged=%s axis=%s%s len=%.0f pivotGrip=%s rot=(%.1f,%.1f,%.1f) loc=(%.1f,%.1f,%.1f) scale=%.2f",
		id, tostring(ranged), info.sign < 0 and "-" or "+", info.axis, info.length, tostring(info.pivotGrip), rot.Pitch, rot.Yaw, rot.Roll, loc.X, loc.Y, loc.Z, sc))
end

attachments.registerOnGripUpdateCallback(function()
	if isInCutScene() or isInSaveMenu() or isInShopMenu() or isInInventoryMenu() or normalPlay == false then return nil end

    local weaponMesh = getWeaponMesh()
	if weaponMesh ~= nil and configui.getValue("auto_grip") ~= false then
		local okG, errG = pcall(autoGripEnsure, weaponMesh, activeWeapon)
		if not okG and not T20.agErrLogged then T20.agErrLogged = true uevr.params.functions.log_info("[GRIP] auto error: " .. tostring(errG)) end
	end
	
	local leftWeaponMesh = getLeftHandWeaponMesh()
	
    local rightHandComponent = nil
   	local leftHandComponent = nil
    
    rightHandComponent = controllers.getController(1)
    leftHandComponent = controllers.getController(0)
	    
    local weaponAttachSocket = "Hand_R" 
	local weaponAttachSocketLeft = "Hand_L" 
	if configui.getValue("6dof_right") == nil or configui.getValue("6dof_right") == false then
		return nil, rightHandComponent, weaponAttachSocket, leftHandComponent and leftWeaponMesh, leftWeaponMesh and leftHandComponent, weaponAttachSocketLeft, defaultAttachOptions
	else 
		return weaponMesh, rightHandComponent, weaponAttachSocket, leftHandComponent and leftWeaponMesh, leftWeaponMesh and leftHandComponent, weaponAttachSocketLeft, defaultAttachOptions
	end
    --return weaponMesh, rightHandComponent, weaponAttachSocket--, weaponMesh, leftHandComponent, weaponAttachSocketLeft, defaultAttachOptions

end)


--weapons
function getLeftHandWeaponMesh()
	local pawn = api:get_local_pawn(0)
	if pawn ~= nil then
		--print("in getWeaponMesh")
		if pawn.Daggervisuals ~= nil then
			if pawn.Daggervisuals.Mesh ~= nil then
				local previousActiveLeftWeaponMesh = activeLeftWeaponMesh
				activeLeftWeaponMesh = pawn.Daggervisuals.Mesh
				if activeLeftWeaponMesh ~= nil and (previousActiveLeftWeaponMesh == nil or (showLaser == false and configui.getValue("frame_layout") ~= false)) then
					-- test 7: with frame_layout the knife laser (aim = left hand) stays on; R3 no longer turns it off
					showLaser = true
					interaction.showInteractionLaser(not aimDotEnabled()) -- aim stays on the left hand; visible laser only if aim dot is off
					pcall(function() uevr.params.functions.log_info("[LASER] knife aim on (left hand), laser visible=" .. tostring(not aimDotEnabled())) end)
				end
			end			
			return activeLeftWeaponMesh
		end	
	end
	activeLeftWeaponMesh = nil
	return nil 
end

function getWeaponMesh()
	local pawn = api:get_local_pawn(0)
	if pawn ~= nil then
		--print("in getWeaponMesh")
		if pawn.CurrentInHandWeapon ~= nil then
			activeWeapon = pawn.CurrentInHandWeapon
			if pawn.CurrentInHandWeapon.CurrentVisuals ~= nil and pawn.CurrentInHandWeapon.CurrentVisuals.Mesh ~= nil then
				activeWeaponMesh = pawn.CurrentInHandWeapon.CurrentVisuals.Mesh 
			elseif pawn.CurrentInHandWeapon.CurrentVisuals ~= nil then
				-- fallback: base visuals class has no Mesh prop; try SocketComp / GetMeshes
				pcall(function()
					local v = pawn.CurrentInHandWeapon.CurrentVisuals
					local m = v.SocketComp
					if m == nil then
						local arr = {}
						v:GetMeshes(arr)
						m = arr[1]
					end
					if m ~= nil then
						if activeWeaponMesh ~= m then uevr.params.functions.log_info("[MELEE] mesh via SocketComp/GetMeshes fallback") end
						activeWeaponMesh = m
					end
				end)
			end
			
			return activeWeaponMesh

		end	
	end
	activeWeapon = nil
	activeWeaponMesh = nil
	return nil 
end


function isMainMenu()
	local pawn = api:get_local_pawn(0)
	return pawn == nil or string.find(pawn:get_full_name(),"TitleScreen")
end

function isInCutScene()
	local pawn = api:get_local_pawn(0)
	if pawn ~= nil then	
		return pawn.CurrentCustsceneManager ~= nil or pawn.InIntroCutscene == true
	end
	return false
end

function isInSaveMenu()
	local pawn = api:get_local_pawn(0)
	if pawn ~= nil then	
		return pawn.CurrentSaveMenu ~= nil
	end
	return false
end

function isInShopMenu()
	local pawn = api:get_local_pawn(0)
	if pawn ~= nil then	
		return pawn.CurrentShopMenu ~= nil
	end
	return false
end


function isInInventoryMenu()
	local pawn = api:get_local_pawn(0)
	if pawn ~= nil then	
		return pawn.CurrentGameMenu ~= nil
	end
	return false
end


function applyMainMenuSettings() 
	normalPlay = false

	vr.set_mod_value("VR_2DScreenMode", false)
	--vr.set_mod_value("UI_Distance", 2.0)

	vr.set_mod_value("VR_AimMethod", "0")
	vr.set_mod_value("VR_RoomscaleMovement", "0")
	vr.set_mod_value("VR_DecoupledPitch", "0")
				
	--vr.set_mod_value("VR_CameraForwardOffset", "0.000000")
	--vr.set_mod_value("VR_CameraRightOffset", "0.000000")
	--vr.set_mod_value("VR_CameraUpOffset", "0.000000")				
	--vr.set_mod_value("VR_LerpCameraYaw", "false")

	
    vr.set_mod_value("VR_DecoupledPitchUIAdjust", "false")

	UEVR_UObjectHook.set_disabled(true)
	showLaser = false
	interaction.showInteractionLaser(false)
	if pickupAssistClear ~= nil then pcall(pickupAssistClear) end

end

function applyMenuSettings() 
	--ik.destroyAll()
	normalPlay = false
	vr.set_mod_value("VR_2DScreenMode", true)
	vr.set_mod_value("UI_Distance", 2.8)
	vr.set_mod_value("UI_FollowView", "true")

	vr.set_mod_value("VR_AimMethod", "0")
	vr.set_mod_value("VR_RoomscaleMovement", "0")
	vr.set_mod_value("VR_DecoupledPitch", "0")
				
	vr.set_mod_value("VR_CameraForwardOffset", "0.000000")
	vr.set_mod_value("VR_CameraRightOffset", "0.000000")
	vr.set_mod_value("VR_CameraUpOffset", "0.000000")				
	vr.set_mod_value("VR_LerpCameraYaw", "false")
	
    vr.set_mod_value("VR_DecoupledPitchUIAdjust", "true")
	
	
	local pawn = api:get_local_pawn(0)
	if pawn ~= nil and pawn.Arms ~=nil then		
		pawn.Arms:SetRenderInMainPass(false)
		pawn.Arms:SetRenderCustomDepth(false)		
	end
	
	UEVR_UObjectHook.set_disabled(true)
	hands.hideHands(true)
	showLaser = false
	interaction.showInteractionLaser(false)
	if pickupAssistClear ~= nil then pcall(pickupAssistClear) end
	
end
function applyCinematicSettings() 
	--ik.destroyAll()
	normalPlay = false
	vr.set_mod_value("VR_2DScreenMode", true)
	vr.set_mod_value("UI_Distance", 2.8)
	vr.set_mod_value("UI_FollowView", "true")

	vr.set_mod_value("VR_AimMethod", "0")
	vr.set_mod_value("VR_RoomscaleMovement", "0")
	vr.set_mod_value("VR_DecoupledPitch", "0")
				
	vr.set_mod_value("VR_CameraForwardOffset", "0.000000")
	vr.set_mod_value("VR_CameraRightOffset", "0.000000")
	vr.set_mod_value("VR_CameraUpOffset", "0.000000")				
	vr.set_mod_value("VR_LerpCameraYaw", "false")
	
    vr.set_mod_value("VR_DecoupledPitchUIAdjust", "true")
	
	--[[
	local pawn = api:get_local_pawn(0)
	if pawn ~= nil and pawn.Arms ~=nil then		
		pawn.Arms:SetRenderInMainPass(true)
		pawn.Arms:SetRenderCustomDepth(true)		
	end
	]]
	UEVR_UObjectHook.set_disabled(true)
	hands.hideHands(true)
	showLaser = false
	interaction.showInteractionLaser(false)
	if pickupAssistClear ~= nil then pcall(pickupAssistClear) end
end

function isRegularPlay() 
	return true
end

local cooldownLoggedFor = nil
function disbaleAttackCooldown()
	if configui.getValue("6dof_right") ~= nil and configui.getValue("6dof_right") == true then
		-- R2 spam fix (2026-11-07): the original profile zeroed the attack block duration (spam, no charge). Now the game's own value is kept; only logged.
		if activeWeapon ~= nil and cooldownLoggedFor ~= activeWeapon then
			cooldownLoggedFor = activeWeapon
			pcall(function() uevr.params.functions.log_info(string.format("[MELEE] weapon NormalAttackBlockDurationBase=%s (left untouched)", tostring(activeWeapon.NormalAttackBlockDurationBase))) end)
		end
		if configui.getValue("constant_attack") == true then 
			if activeWeapon ~= nil then
				activeWeapon.NormalAttackBlockDurationBase = 0.0
			end
		else
			if activeWeapon ~= nil then
				activeWeapon.NormalAttackBlockDurationBase = 0.6
			end
		end
	end
end


function disbaleMeleeFX()
	if configui.getValue("6dof_right") ~= nil and configui.getValue("6dof_right") == true then
		if activeWeapon ~= nil then
			if activeWeapon.MeleeFXColor1 ~= nil then
				activeWeapon.MeleeFXColor1.A = 0
			end
			if activeWeapon.MeleeFXColor2 ~= nil then
				activeWeapon.MeleeFXColor2.A = 0
			end
		end	
	end
end

function speedupAttackComboAnims()
	if configui.getValue("6dof_right") ~= nil and configui.getValue("6dof_right") == true then
		local attackComboTArr = plugin.getProperty(activeWeapon, "AttackCombo")
		--print("attackComboTArr", attackComboTArr[2].Montage_2_59B3A20F47B965673C1AF39ACCD1AB11.RateScale)
		if attackComboTArr ~= nil then
			for i = 1, #attackComboTArr do
			--for _,attackAnim in ipairs(attackComboTArr) do --starts from 0...
				local attackAnim = attackComboTArr[i]
				attackAnim.Montage_2_59B3A20F47B965673C1AF39ACCD1AB11.RateScale = 3.0
			end
		end
	end
end


--[[rustysword:
BoxExtent:
X = 6.588, Y = 36.523, Z = 1.423 
Origin:
X = 0.001, Y = -25.840, Z = 0.048

Size
BoxExtent is a half-size, so the full mesh is:

Axis	Half	Full	    What it is
X	    6.588	13.18 cm	width
Y	    36.523	73.05 cm	length ← the blade axis
Z	    1.423	2.85 cm	    thickness

So: a long, flat blade — 73 cm long, 13 cm wide, under 3 cm thick. The weapon's local Y axis is its length axis.

Where the origin is?
The bounds corners are Origin ± BoxExtent:

X:  0.001 ± 6.588   →  [-6.59 , +6.59]
Y: -25.840 ± 36.523 →  [-62.36, +10.68]
Z:  0.048 ± 1.423   →  [-1.38 , +1.47]

So for Y:
     +10.68  ──┐  ← 10.7 cm from origin to this end
                  │
   ORIGIN (0,0,0) ─┤  ← the staticMesh's pivot
                  │
        -62.36  ──┘  ← 62.4 cm from origin to this end


The origin sits 10.7 cm from the +Y end and 62.4 cm from the -Y end — i.e. 14.6% of the way along the weapon from the +Y tip.

For a weapon mesh, the pivot is normally placed at the grip. 
Reading it that way: you have a 10.7 cm handle behind the grip and a 62.4 cm blade forward in -Y. 
A one-handed arming sword / short sword / cleaver — the 13 cm width is a broad blade.

The other reading — origin at the tip — would mean a 73 cm weapon with 62 cm of handguard behind it, which makes no sense for a melee weapon. 

So: origin ≈ the hilt, blade runs toward -Y.

The bounds centre is at Y = -25.84, which is not the origin. 
That's the middle of the whole mesh (grip included), i.e. roughly 25 cm down the blade from the hilt.

so where to place the center of the hit box?:

-- mid-blade (what Origin gives you)
{ X = 0.001, Y = -25.840, Z = 0.048 }
-- further out toward the tip (roughly the forward third of the blade)
{ X = 0.0, Y = -42.0, Z = 0.0 }
-- right at the tip
{ X = 0.0, Y = -62.36, Z = 0.0 }

and 2 possible sizes for the 1st 2 options (right at the tip is irelevant)

-- full mesh (what you have now)
{ X = 6.588, Y = 36.523, Z = 1.423 }
-- blade only, last ~40 cm of the weapon
{ X = 6.588, Y = 20.0, Z = 1.423 }

we'll go with 1st option for simlicity for now...

]]
local hbCache = {mesh = nil, oX = 0, oY = 0, oZ = 0, ext = {X = 0, Y = 0, Z = 0}, box = {X = 0, Y = 0, Z = 0}, center = {X = 0, Y = 0, Z = 0}, axis = "X", sign = 1}
local hbZeroRot = {Pitch = 0, Yaw = 0, Roll = 0}
function attachHitboxesToWeaponTip()
	if configui.getValue("6dof_right") ~= nil and configui.getValue("6dof_right") == true then
		local pawn = api:get_local_pawn(0)
		if pawn ~= nil and pawn.Arms ~= nil and 
			activeWeaponMesh~= nil and activeWeaponMesh.StaticMesh ~= nil and 
			activeWeaponMesh.StaticMesh.ExtendedBounds ~= nil and 
			activeWeaponMesh.StaticMesh.ExtendedBounds.BoxExtent ~= nil and
			activeWeaponMesh.StaticMesh.ExtendedBounds.Origin ~= nil then
			-- prefer render bounds (StaticMesh:GetBounds) over ExtendedBounds (may be padded -> hitbox looked too far forward); cached per mesh
			if hbCache.mesh ~= activeWeaponMesh.StaticMesh then
				hbCache.mesh = activeWeaponMesh.StaticMesh
				local ext = activeWeaponMesh.StaticMesh.ExtendedBounds
				local o, e = ext.Origin, ext.BoxExtent
				local src = "extended"
				local okB, b = pcall(function() return activeWeaponMesh.StaticMesh:GetBounds() end)
				if okB and b ~= nil and b.BoxExtent ~= nil and b.BoxExtent.X ~= nil then o, e, src = b.Origin, b.BoxExtent, "render" end
				hbCache.oX, hbCache.oY, hbCache.oZ = o.X, o.Y, o.Z
				hbCache.ext.X, hbCache.ext.Y, hbCache.ext.Z = e.X, e.Y, e.Z
				-- long axis = largest extent (spear mesh is X-long, other blades Y-long); tip = side of the pivot the bounds centre lies on
				pcall(function()
					local ce = hbCache.ext
					local axis = "X"
					if ce.Y > ce[axis] then axis = "Y" end
					if ce.Z > ce[axis] then axis = "Z" end
					local oa = (axis == "X" and hbCache.oX) or (axis == "Y" and hbCache.oY) or hbCache.oZ
					hbCache.axis = axis
					hbCache.sign = (oa < -1.0) and -1 or 1
				end)
				pcall(function() uevr.params.functions.log_info(string.format("[DBG] hitbox bounds src=%s origin=(%.1f,%.1f,%.1f) extent=(%.1f,%.1f,%.1f) extendedOrigin=(%.1f,%.1f,%.1f) extendedExtent=(%.1f,%.1f,%.1f) longAxis=%s%s", src, o.X, o.Y, o.Z, e.X, e.Y, e.Z, ext.Origin.X, ext.Origin.Y, ext.Origin.Z, ext.BoxExtent.X, ext.BoxExtent.Y, ext.BoxExtent.Z, hbCache.sign < 0 and "-" or "+", hbCache.axis)) end)
			end
			local activeWeaponMeshBounds = hbCache.box
			local activeLeftWeaponMeshCenter = hbCache.center
			-- per class: X-long mesh = spear (thrust), otherwise blade
			local isSpear = hbCache.axis == "X"; weaponIsSpear = isSpear
			local reach = configui.getValue(isSpear and "spear_reach" or "blade_reach") or 0.0
			local fwd = configui.getValue(isSpear and "hitbox_forward_offset" or "blade_offset") or 0.0
			activeWeaponMeshBounds.X, activeWeaponMeshBounds.Y, activeWeaponMeshBounds.Z = hbCache.ext.X, hbCache.ext.Y, hbCache.ext.Z
			activeLeftWeaponMeshCenter.X, activeLeftWeaponMeshCenter.Y, activeLeftWeaponMeshCenter.Z = hbCache.oX, hbCache.oY, hbCache.oZ
			-- reach grows only the tip end (back end stays at the hand); offset slides the whole box along the blade
			local a = hbCache.axis
			activeWeaponMeshBounds[a] = activeWeaponMeshBounds[a] + reach * 0.5
			activeLeftWeaponMeshCenter[a] = activeLeftWeaponMeshCenter[a] + hbCache.sign * (fwd + reach * 0.5)
			if not isSpear then
				-- side = wider of the two short axes, flat = thinner one (mesh-local units, same as offset/reach)
				pcall(function()
					local o1, o2 = "X", "Z"
					if a == "X" then o1, o2 = "Y", "Z" elseif a == "Z" then o1, o2 = "X", "Y" end
					if hbCache.ext[o2] > hbCache.ext[o1] then o1, o2 = o2, o1 end
					activeLeftWeaponMeshCenter[o1] = activeLeftWeaponMeshCenter[o1] + (configui.getValue("blade_side") or 0.0)
					activeLeftWeaponMeshCenter[o2] = activeLeftWeaponMeshCenter[o2] + (configui.getValue("blade_flat") or 0.0)
				end)
			end

			if pawn.NormalHitbox ~=nil then
				--pawn.NormalHitbox:DetachFromParent()
				--[[pawn.NormalHitbox:K2_AttachToComponent(pawn.Arms,
					uevrUtils.fname_from_string("WeaponTip"),
					2, -- SnapToTarget Location
					2, -- SnapToTarget Rotation
					2, -- SnapToTarget Scale  - inherits the weapon's scale
					false
				)]]
				if pawn.NormalHitbox.AttachParent ~= activeWeaponMesh then
					pawn.NormalHitbox:K2_AttachToComponent(activeWeaponMesh,
						uevrUtils.fname_from_string(""),
						2, -- SnapToTarget Location
						2, -- SnapToTarget Rotation
						2, -- SnapToTarget Scale  - inherits the weapon's scale
						false
					)
				end
				pawn.NormalHitbox:SetBoxExtent(activeWeaponMeshBounds, true)
				pawn.NormalHitbox:K2_SetRelativeLocation(activeLeftWeaponMeshCenter, false, reusable_hit_result, true)
				pcall(function() pawn.NormalHitbox:K2_SetRelativeRotation(hbZeroRot, false, reusable_hit_result, true) end)
			end
			if pawn.DefaultHitbox ~=nil then
				--pawn.DefaultHitbox:DetachFromParent()			
				if pawn.DefaultHitbox.AttachParent ~= activeWeaponMesh then
					pawn.DefaultHitbox:K2_AttachToComponent(activeWeaponMesh,
						uevrUtils.fname_from_string(""),
						2, -- SnapToTarget Location
						2, -- SnapToTarget Rotation
						2, -- SnapToTarget Scale  - inherits the weapon's scale
						false
					)
				end
				pawn.DefaultHitbox:SetBoxExtent(activeWeaponMeshBounds, true)
				pawn.DefaultHitbox:K2_SetRelativeLocation(activeLeftWeaponMeshCenter, false, reusable_hit_result, true)
				pcall(function() pawn.DefaultHitbox:K2_SetRelativeRotation(hbZeroRot, false, reusable_hit_result, true) end)
			end
			--[[if pawn.ParryHitbox ~=nil and pawn.ParryHitbox.AttachParent ~= activeWeaponMesh then
				--pawn.ParryHitbox:DetachFromParent()			
				pawn.ParryHitbox:K2_AttachToComponent(activeWeaponMesh,
					uevrUtils.fname_from_string(""),
					2, -- SnapToTarget Location
					2, -- SnapToTarget Rotation
					2, -- SnapToTarget Scale  - inherits the weapon's scale
					false
				)
				pawn.ParryHitbox:SetBoxExtent(activeWeaponMeshBounds, true)
				pawn.ParryHitbox:K2_SetRelativeLocation(activeLeftWeaponMeshCenter, false, reusable_hit_result, true)
			end]]
		end
	end
end

-- Debug hitbox visuals: wireframe cubes parented to the real hitbox components + weapon mesh origin marker.
local dbgBoxes = {}
local dbgAcc = 0.0
local function dbgEnsure(key, parent, scale)
	local c = dbgBoxes[key]
	if c == nil or uevrUtils.getValid(c) == nil then
		c = uevrUtils.createStaticMeshComponent("StaticMesh /Engine/BasicShapes/Cube.Cube", {visible=true, collisionEnabled=false})
		if c == nil then return end
		local mat = uevrUtils.getLoadedAsset("Material /Engine/EngineDebugMaterials/WireframeMaterial.WireframeMaterial")
		if mat ~= nil then c:SetMaterial(0, mat) end
		c.BoundsScale = 10
		dbgBoxes[key] = c
	end
	if c.AttachParent ~= parent then
		c:K2_AttachToComponent(parent, uevrUtils.fname_from_string(""), 0, 0, 0, false)
		c:K2_SetRelativeLocation({X=0,Y=0,Z=0}, false, reusable_hit_result, true)
		c:K2_SetRelativeRotation({Pitch=0,Yaw=0,Roll=0}, false, reusable_hit_result, true)
	end
	c:SetRelativeScale3D(scale)
end
local function dbgHide()
	for _, c in pairs(dbgBoxes) do
		pcall(function() c:SetVisibility(false) end)
	end
end
local function dbgLogPositions(tag)
	pcall(function()
		local pawn = api:get_local_pawn(0)
		local function loc(c)
			if c == nil then return "nil" end
			local l = c:K2_GetComponentLocation()
			return string.format("(%.1f,%.1f,%.1f)", l.X, l.Y, l.Z)
		end
		local ext = "nil"
		if activeWeaponMesh ~= nil and activeWeaponMesh.StaticMesh ~= nil then
			local b = activeWeaponMesh.StaticMesh.ExtendedBounds
			ext = string.format("origin=(%.1f,%.1f,%.1f) extent=(%.1f,%.1f,%.1f)", b.Origin.X, b.Origin.Y, b.Origin.Z, b.BoxExtent.X, b.BoxExtent.Y, b.BoxExtent.Z)
		end
		uevr.params.functions.log_info(string.format("[DBG] %s weaponMesh=%s normalHB=%s defaultHB=%s hbParentIsMesh=%s %s", tag, loc(activeWeaponMesh), loc(pawn and pawn.NormalHitbox), loc(pawn and pawn.DefaultHitbox), tostring(pawn ~= nil and pawn.NormalHitbox ~= nil and pawn.NormalHitbox.AttachParent == activeWeaponMesh), ext))
		-- rotations (P,Y,R) + scale: does the hitbox stay rigid to the mesh, or follow the head?
		local function rot(c)
			if c == nil then return "nil" end
			local r = c:K2_GetComponentRotation()
			return string.format("(%.0f,%.0f,%.0f)", r.Pitch, r.Yaw, r.Roll)
		end
		local hb = pawn and pawn.NormalHitbox
		local rel, sc = "nil", "nil"
		if hb ~= nil then
			local r = hb.RelativeRotation
			if r ~= nil then rel = string.format("(%.0f,%.0f,%.0f)", r.Pitch, r.Yaw, r.Roll) end
			local s = hb:K2_GetComponentScale()
			if s ~= nil then sc = string.format("(%.2f,%.2f,%.2f)", s.X, s.Y, s.Z) end
		end
		uevr.params.functions.log_info(string.format("[DBG] %s rot mesh=%s normalHB=%s hbRel=%s hbScale=%s head=%s axis=%s%s", tag, rot(activeWeaponMesh), rot(hb), rel, sc, rot(controllers.getController(2)), hbCache.sign < 0 and "-" or "+", hbCache.axis))
	end)
end
local function updateDebugHitboxes(delta)
	dbgAcc = dbgAcc + delta
	if dbgAcc < 0.25 then return end
	dbgAcc = 0.0
	if configui.getValue("debug_hitboxes") ~= true then
		if next(dbgBoxes) ~= nil then dbgHide() end
		return
	end
	local pawn = api:get_local_pawn(0)
	if pawn == nil then return end
	local function boxFor(key, hb)
		if hb ~= nil and hb.BoxExtent ~= nil then
			local e = hb.BoxExtent
			dbgEnsure(key, hb, {X=e.X/50, Y=e.Y/50, Z=e.Z/50})
			dbgBoxes[key]:SetVisibility(true)
		elseif dbgBoxes[key] ~= nil then
			dbgBoxes[key]:SetVisibility(false)
		end
	end
	boxFor("normal", pawn.NormalHitbox)
	boxFor("default", pawn.DefaultHitbox)
	if activeWeaponMesh ~= nil then
		dbgEnsure("origin", activeWeaponMesh, {X=0.05, Y=0.05, Z=0.05}) -- small cube at the weapon mesh pivot
		dbgBoxes["origin"]:SetVisibility(true)
	elseif dbgBoxes["origin"] ~= nil then
		dbgBoxes["origin"]:SetVisibility(false)
	end
	if dbgLastWeaponMesh ~= activeWeaponMesh then
		dbgLastWeaponMesh = activeWeaponMesh
		dbgLogPositions("weapon changed")
	end
end

-- Motion melee: swing -> AttackPressed/AttackReleased. Detector: libs/motion_melee.lua
local MELEE_RELEASE_DELAY = 0.05 -- s between AttackPressed and AttackReleased
local MELEE_SYNTHETIC_SPEED = 4.0 -- m/s
local MELEE_SYNTHETIC_TIME = 0.25 -- s
local swingDetector = motionMelee.new()
-- step 6: in T20 (main chunk is at Lua's 200-local limit). haptics: pulse per +0.05 multiplier, strong at cap; rush: swing in a dash waits for the rush window
T20.S6 = {haptics = motionMelee.newChargeHaptics(0.05), rush = motionMelee.newRushBuffer(0.6), out = {}, keysLogged = false, keysMsg = nil}
local meleeClock = 0.0
local meleeHeadPos = nil
local meleeHandPos = nil
local meleeHeadRot = nil
local meleeHandRot = nil
local meleePressedWeapon = nil
local meleeReleaseIn = 0.0
local meleeSyntheticLeft = 0.0
local meleeSyntheticAt = 0.0
local meleeSwingCount = 0

chargeLastRelease = 0.0
-- step 6 (I2): the game's hold-charge damage multiplier (1.0 .. ~1.333). D2: out params land under key `result`.
-- T20.S6.keysMsg is logged by the melee tick (meleeLog is defined further down)
function T20.S6.mult(pawn)
	for k in pairs(T20.S6.out) do T20.S6.out[k] = nil end
	local ret = pawn:CalculateChargeMultiplier_Impure(T20.S6.out)
	local m = T20.S6.out.result or T20.S6.out.Mult or T20.S6.out[1]
	if type(m) ~= "number" and type(ret) == "number" then m = ret end
	if type(m) ~= "number" and not T20.S6.keysLogged then
		T20.S6.keysLogged = true
		local keys = ""
		for k, v in pairs(T20.S6.out) do keys = keys .. tostring(k) .. "=" .. tostring(v) .. " " end
		T20.S6.keysMsg = "charge mult unreadable: ret=" .. tostring(ret) .. " out={" .. keys .. "}"
	end
	return m
end
local function chargeInfo()
	chargeLastRelease = meleeClock - rtPressedAt
	local ok, s = pcall(function()
		local pawn = api:get_local_pawn(0)
		local extra = ""
		pcall(function() extra = extra .. " pawnAtk=" .. tostring(pawn.AttackPressed) end)
		pcall(function() local m = pawn:GetMesh().AnimScriptInstance:GetCurrentActiveMontage(); extra = extra .. " montage=" .. (m and m:get_fname():to_string() or "none") end)
		local okM, m = pcall(T20.S6.mult, pawn)
		return string.format("mult=%s%s", okM and tostring(m) or "err", extra)
	end)
	return ok and s or "mult=?"
end

-- test 12: charge debug bars (wireframe) on the weapon mesh: LIVE bar grows 10 cm per second of RT hold (4 s max); LAST bar keeps the length of the last release.
-- Bars are sized in world units (SetWorldScale3D) so the mesh's own scale doesn't matter; offset along mesh-local Z (short axis) and X.
local chargeBars = {}
local chargeScale = {X = 0.02, Y = 0.02, Z = 0.01}
local chargeLastShown, chargeLiveShown = -1, -1
local function chargeBarEnsure(key, localX)
	local c = chargeBars[key]
	if c == nil or uevrUtils.getValid(c) == nil then
		c = uevrUtils.createStaticMeshComponent("StaticMesh /Engine/BasicShapes/Cube.Cube", {visible=true, collisionEnabled=false})
		if c == nil then return nil end
		local mat = uevrUtils.getLoadedAsset("Material /Engine/EngineDebugMaterials/WireframeMaterial.WireframeMaterial")
		if mat ~= nil then c:SetMaterial(0, mat) end
		c.BoundsScale = 10
		chargeBars[key] = c
		chargeLastShown, chargeLiveShown = -1, -1
	end
	if c.AttachParent ~= activeWeaponMesh then
		chargeLastShown, chargeLiveShown = -1, -1
		c:K2_AttachToComponent(activeWeaponMesh, uevrUtils.fname_from_string(""), 0, 0, 0, false)
		local ms = activeWeaponMesh:K2_GetComponentScale().X
		if ms == nil or ms <= 0.001 then ms = 1 end
		c:K2_SetRelativeLocation({X = localX / ms, Y = 0, Z = 12 / ms}, false, reusable_hit_result, true)
		c:K2_SetRelativeRotation({Pitch = 0, Yaw = 0, Roll = 0}, false, reusable_hit_result, true)
	end
	return c
end
function updateChargeBars()
	if configui.getValue("debug_hitboxes") ~= true or activeWeaponMesh == nil then
		for _, c in pairs(chargeBars) do c:SetVisibility(false) end
		return
	end
	local live = rightTriggerHeld and (meleeClock - rtPressedAt) or 0.0
	if live > 4 then live = 4 end
	if math.abs(live - chargeLiveShown) > 0.02 then
		chargeLiveShown = live
		local c = chargeBarEnsure("live", 0)
		if c ~= nil then
			chargeScale.Z = 0.01 + live * 0.1
			c:SetWorldScale3D(chargeScale)
			c:SetVisibility(true)
		end
	end
	local last = chargeLastRelease > 4 and 4 or chargeLastRelease
	if math.abs(last - chargeLastShown) > 0.02 then
		chargeLastShown = last
		local c = chargeBarEnsure("last", 8)
		if c ~= nil then
			chargeScale.Z = 0.01 + last * 0.1
			c:SetWorldScale3D(chargeScale)
			c:SetVisibility(true)
		end
	end
end
local function meleeLog(message)
	uevr.params.functions.log_info(string.format("[MELEE] t=%.3f %s", meleeClock, message))
end

local function meleeHitboxState()
	local pawn = api:get_local_pawn(0)
	if pawn == nil or activeWeaponMesh == nil then return "no-pawn-or-mesh" end
	local normalAttached = pawn.NormalHitbox ~= nil and pawn.NormalHitbox.AttachParent == activeWeaponMesh
	local defaultAttached = pawn.DefaultHitbox ~= nil and pawn.DefaultHitbox.AttachParent == activeWeaponMesh
	return "normalHitbox=" .. tostring(normalAttached) .. " defaultHitbox=" .. tostring(defaultAttached)
end

function meleeLogNotify(phase)
	meleeLog("OnNotify" .. phase .. " " .. meleeHitboxState())
end

-- test 19: motion-driven hit window (motion_hit_window). The game opens the hit window from the attack animation 0.25 s
-- (sword) / 0.6 s (club) after the swing commits, when the hand has already stopped. Instead: "Activate Hitbox" right
-- after our attack call, keep it open while the hand moves fast (min HIT_MIN, max HIT_MAX), then DeactivateHitbox.
-- The game's own Activate within HIT_BLOCK s of our open (= its late window for that attack) and its Deactivate while
-- ours is open are skipped (pre-hook returns false). "[MELEE] HIT ..." log lines, incl. every HandleHit.
local HIT_MIN, HIT_MAX, HIT_BLOCK = 0.2, 0.8, 1.5
local hitWin = {weapon = nil, t = 0.0, openClock = -100.0, ours = false, hits = 0, blocked = 0}
local function hitWinOn() return configui.getValue("motion_hit_window") == true and configui.getValue("6dof_right") == true end
local function hbCollision()
	local pawn = api:get_local_pawn(0)
	if pawn == nil then return "ce=?" end
	local a, b = "-", "-"
	pcall(function() a = tostring(pawn.NormalHitbox:GetCollisionEnabled()) end)
	pcall(function() b = tostring(pawn.DefaultHitbox:GetCollisionEnabled()) end)
	return "ce=" .. a .. "/" .. b
end
local function hitWinClose(why)
	local w = hitWin.weapon
	if w == nil then return end
	hitWin.weapon = nil
	hitWin.ours = true
	local ok, err = pcall(function() w:DeactivateHitbox() end)
	hitWin.ours = false
	meleeLog(string.format("HIT window close (%s) dur=%.2f hits=%d blocked=%d %s%s", why, hitWin.t, hitWin.hits, hitWin.blocked, hbCollision(), ok and "" or (" err=" .. tostring(err))))
end
local function hitWinOpen(weapon, why)
	if weapon == nil or not hitWinOn() then return end
	if hitWin.weapon ~= nil then hitWinClose("reopen") end
	pcall(attachHitboxesToWeaponTip)
	hitWin.ours = true
	local ok, err = pcall(function() weapon["Activate Hitbox"](weapon) end)
	hitWin.ours = false
	if not ok then meleeLog("HIT activate error " .. tostring(err)) return end
	hitWin.weapon, hitWin.t, hitWin.openClock, hitWin.hits, hitWin.blocked = weapon, 0.0, meleeClock, 0, 0
	hitWin.blockArmed = true -- test 20: skip only the next game activation (this attack's), not a later trigger attack
	meleeLog("HIT window open (" .. why .. ") " .. hbCollision())
end
local function hitWinTick(delta)
	if hitWin.weapon == nil then return end
	hitWin.t = hitWin.t + delta
	if activeWeapon ~= hitWin.weapon then hitWinClose("weapon changed")
	elseif hitWin.t >= HIT_MAX then hitWinClose("max")
	elseif hitWin.t >= HIT_MIN and (swingDetector.speed or 0) < swingDetector.rearmSpeed then hitWinClose("slow") end
end
-- hooks (registered from hookFuntionsForRuntimeGeneratedClasses); pre-hook returning false skips the game's call
function hookHitWindow()
	local cls = "BlueprintGeneratedClass /Game/Items/Weapons/WeaponScriptBase.WeaponScriptBase_C"
	local okA = hook_function(cls, "Activate Hitbox", false, function(fn, obj, locals, result)
		if hitWin.ours then return end
		local dt = meleeClock - hitWin.openClock
		if hitWinOn() and dt < HIT_BLOCK and hitWin.blockArmed then
			hitWin.blockArmed = false
			hitWin.blocked = hitWin.blocked + 1
			meleeLog(string.format("HIT game Activate skipped dt=%.2f", dt))
			return false
		end
		meleeLog(string.format("HIT game Activate dt=%.2f %s", dt, hbCollision()))
	end, nil, false)
	local okD = hook_function(cls, "DeactivateHitbox", false, function(fn, obj, locals, result)
		if hitWin.ours then return end
		if hitWin.weapon ~= nil and hitWinOn() then
			meleeLog(string.format("HIT game Deactivate skipped (ours open %.2f s)", hitWin.t))
			return false
		end
	end, nil, false)
	local okH = hook_function(cls, "HandleHit", false, nil, function(fn, obj, locals, result)
		hitWin.hits = hitWin.hits + 1
		local dmg = "?"
		pcall(function() dmg = tostring(locals.Successfully_Damaged) end)
		-- test 20: hit haptics on the weapon hand (hit_haptics): strong on damage, light on any other contact
		if configui.getValue("hit_haptics") ~= false and obj == activeWeapon then
			pcall(function()
				if locals.Successfully_Damaged == true then uevrUtils.triggerHapticVibration(Handed.Right, 0, 0.09, 180, 0.9)
				elseif locals.HitAnything == true then uevrUtils.triggerHapticVibration(Handed.Right, 0, 0.04, 220, 0.35) end
			end)
		end
		meleeLog(string.format("HIT HandleHit sinceOpen=%.2f ourOpen=%s damaged=%s", meleeClock - hitWin.openClock, tostring(hitWin.weapon ~= nil), dmg))
	end, false)
	meleeLog("HIT hooks activate=" .. tostring(okA) .. " deactivate=" .. tostring(okD) .. " handleHit=" .. tostring(okH))
end

local function meleeFire(speed, source)
	if activeWeapon == nil then
		meleeLog(source .. " swing ignored: no weapon speed=" .. string.format("%.2f", speed))
		return
	end
	if rightTriggerHeld and not rtSwingReleased and configui.getValue("charge_on_swing") ~= false then
		-- RT held = charging; the swing releases the charged attack (trigger-up then sends nothing)
		attachHitboxesToWeaponTip()
		dbgLogPositions("charged swing")
		rtSwingReleased = true
		local ci = chargeInfo()
		activeWeapon:AttackReleased()
		hitWinOpen(activeWeapon, "charged swing")
		meleeLog(string.format("charged swing release held=%.2fs %s speed=%.2f %s", meleeClock - rtPressedAt, source, speed, ci))
		return
	end
	if rightTriggerHeld or meleeReleaseIn > 0.0 then
		meleeLog(source .. " swing ignored: attack button busy")
		return
	end
	attachHitboxesToWeaponTip()
	dbgLogPositions("swing")
	meleePressedWeapon = activeWeapon
	meleeReleaseIn = MELEE_RELEASE_DELAY
	meleeSwingCount = meleeSwingCount + 1
	activeWeapon:AttackPressed()
	meleeLog(string.format("swing #%d %s speed=%.2f threshold=%.2f out=%.2f%s %s", meleeSwingCount, source, speed, swingDetector.fireSpeed, swingDetector.lastOutward or 0.0, swingDetector.lastLate and " LATE" or "", meleeHitboxState()))
end

-- test 16: L2 held + outward thrust = native alt attack (same call as the old L2 press), released after a tap
local L2_STAB_RELEASE = 0.1
-- test 17: test 16 log showed sideways swipes with out 0.4-0.8 (a swipe starts by extending the arm). A poke moves the
-- weapon along its own length, a swipe across it: |cos| between the stroke's net direction and the weapon's long axis.
-- Tracking -> UE local is (-z, x, y) (verified live vs the motion controller components), then rotate by the yaw
-- between the HMD's tracking forward and the head component's world forward. Returns nil if unknown.
local function stabAxisAlign()
	local d = swingDetector
	if meleeHeadRot == nil or activeWeaponMesh == nil then return nil end
	local head = controllers.getController(2)
	if head == nil then return nil end
	local x, y, z, w = meleeHeadRot.X, meleeHeadRot.Y, meleeHeadRot.Z, meleeHeadRot.W
	local hfx, hfz = -2 * (x * z + w * y), -(1 - 2 * (x * x + y * y)) -- HMD -Z axis (tracking x, z)
	local th = math.rad(head:K2_GetComponentRotation().Yaw) - math.atan(hfx, -hfz)
	local lx, ly, lz = -d.lastDirZ, d.lastDirX, d.lastDirY
	local c, s = math.cos(th), math.sin(th)
	local r = activeWeaponMesh:K2_GetComponentRotation()
	local a
	if hbCache.axis == "X" then a = kismet_math_library:GetForwardVector(r)
	elseif hbCache.axis == "Y" then a = kismet_math_library:GetRightVector(r)
	else a = kismet_math_library:GetUpVector(r) end
	local dot = (lx * c - ly * s) * a.X + (lx * s + ly * c) * a.Y + lz * a.Z
	return math.abs(dot), dot * (hbCache.sign < 0 and -1 or 1)
end
local function l2StabFire(speed, source)
	if activeWeapon == nil then return end
	local out, need = swingDetector.lastOutward or 0.0, configui.getValue("stab_outward") or 0.4
	local axNeed = configui.getValue("stab_axis") or 0.6
	local okA, ax, axSigned = pcall(stabAxisAlign)
	if not okA then meleeLog("L2 stab axis error " .. tostring(ax)) ax = nil end
	local axTxt = ax ~= nil and string.format("axis=%.2f tip=%.2f need=%.2f", ax, axSigned, axNeed) or "axis=n/a"
	local stTxt = string.format("straight=%.2f", swingDetector.lastStraight or 0)
	if (need > 0 and out < need) or (ax ~= nil and axNeed > 0 and axSigned < axNeed) then -- test 19: signed (toward the tip; pull-backs rejected)
		meleeLog(string.format("L2 stab rejected %s out=%.2f need=%.2f %s %s speed=%.2f", source, out, need, axTxt, stTxt, speed))
		return
	end
	if l2StabReleaseIn > 0.0 then meleeLog("L2 stab ignored: alt attack still held") return end
	local ok, err = pcall(startNativeDodge, 0, "L2stab")
	if not ok then meleeLog("L2 stab error " .. tostring(err)) return end
	l2StabWeapon = activeWeapon
	l2StabReleaseIn = L2_STAB_RELEASE
	hitWinOpen(activeWeapon, "L2 stab")
	meleeLog(string.format("L2 stab -> AltAttackPressed %s out=%.2f %s %s speed=%.2f", source, out, axTxt, stTxt, speed))
end
local function l2StabRelease(delta)
	if l2StabReleaseIn <= 0.0 then return end
	l2StabReleaseIn = l2StabReleaseIn - delta
	if l2StabReleaseIn > 0.0 then return end
	l2StabReleaseIn = 0.0
	local w = l2StabWeapon
	l2StabWeapon = nil
	if w ~= nil then pcall(function() w:AltAttackReleased() end) meleeLog("L2 stab AltAttackReleased") end
end

local function meleeRelease(delta)
	if meleeReleaseIn <= 0.0 then return end
	meleeReleaseIn = meleeReleaseIn - delta
	if meleeReleaseIn <= 0.0 then
		meleeReleaseIn = 0.0
		local weapon = meleePressedWeapon
		meleePressedWeapon = nil
		if weapon ~= nil then
			weapon:AttackReleased()
			meleeLog("AttackReleased")
			hitWinOpen(weapon, "swing")
		end
	end
end

-- step 6 (I2): charge haptics while RT charges; rush buffer releases a swing held during a dash
function T20.S6.tick(delta)
	local pawn = api:get_local_pawn(0)
	if pawn == nil then return end
	if T20.S6.keysMsg ~= nil then meleeLog(T20.S6.keysMsg) T20.S6.keysMsg = nil end
	if rightTriggerHeld and not rtSwingReleased and configui.getValue("charge_haptics") ~= false then
		local r = T20.S6.haptics:update(T20.S6.mult(pawn))
		if r == 1 then uevrUtils.triggerHapticVibration(Handed.Right, 0, 0.03, 160, 0.25)
		elseif r == 2 then
			uevrUtils.triggerHapticVibration(Handed.Right, 0, 0.15, 120, 1.0)
			meleeLog(string.format("charge full mult=%.3f held=%.2fs", T20.S6.haptics.peak, meleeClock - rtPressedAt))
		end
	elseif T20.S6.haptics.peak ~= 1.0 then
		T20.S6.haptics:reset()
	end
	T20.S6.rush.earliest = configui.getValue("rush_earliest") or 0.6
	-- step 9: only sword-type weapons (DashHitboxBonusRange) have a rush window; spear-type dashes accept attacks at once
	if T20.S6.rushFor ~= activeWeapon then
		T20.S6.rushFor = activeWeapon
		local okR, bonus = pcall(function() return activeWeapon ~= nil and activeWeapon.DashHitboxBonusRange or nil end)
		T20.S6.rush.enabled = okR and bonus ~= nil
		meleeLog("rush window " .. (T20.S6.rush.enabled and "on" or "off (no rush attack)") .. " for this weapon")
	end
	if T20.S6.rush:update(delta, pawn.Dashing == true) then
		meleeLog(string.format("buffered swing fires: %s dashT=%.2f", T20.S6.rush.lastWasRush and "RUSH" or "after dash", T20.S6.rush.dashTime))
		meleeFire(0.0, T20.S6.rush.lastWasRush and "rush" or "post-dash")
	end
end

function checkMeleeSwing(delta)
	meleeClock = meleeClock + delta
	meleeRelease(delta)
	l2StabRelease(delta)
	if configui.getValue("6dof_right") ~= true then hitWinClose("motion off") return end

	local speedSetting = configui.getValue("motion_swing_speed")
	if speedSetting ~= nil then swingDetector.fireSpeed = speedSetting end
	local cooldownSetting = configui.getValue("motion_swing_cooldown")
	if cooldownSetting ~= nil then swingDetector.cooldown = cooldownSetting end

	local fired, speed = false, 0.0
	local source = "motion"
	if meleeSyntheticLeft > 0.0 then
		-- Debug hotkey: a fake hand path through the same detector and attack call.
		source = "synthetic"
		meleeSyntheticAt = meleeSyntheticAt + delta
		meleeSyntheticLeft = meleeSyntheticLeft - delta
		fired, speed = swingDetector:update(delta, 0.0, 0.0, 0.0, 0.4, 0.0, -MELEE_SYNTHETIC_SPEED * meleeSyntheticAt)
		if meleeSyntheticLeft <= 0.0 then swingDetector:reset() end
	else
		if meleeHeadPos == nil then
			meleeHeadPos, meleeHandPos = Vector3f.new(0, 0, 0), Vector3f.new(0, 0, 0)
			meleeHeadRot, meleeHandRot = Quaternionf.new(0, 0, 0, 0), Quaternionf.new(0, 0, 0, 0)
		end
		vr.get_pose(vr.get_hmd_index(), meleeHeadPos, meleeHeadRot)
		vr.get_pose(vr.get_right_controller_index(), meleeHandPos, meleeHandRot)
		fired, speed = swingDetector:update(delta, meleeHeadPos.X, meleeHeadPos.Y, meleeHeadPos.Z, meleeHandPos.X, meleeHandPos.Y, meleeHandPos.Z)
	end

	local okW, errW = pcall(hitWinTick, delta)
	if not okW and not T20.hitTickErr then T20.hitTickErr = true meleeLog("HIT tick error " .. tostring(errW)) end
	local okC, errC = pcall(T20.S6.tick, delta)
	if not okC and not T20.chargeTickErr then T20.chargeTickErr = true meleeLog("charge/rush tick error " .. tostring(errC)) end
	if swingDetector.missPeak > 0.0 then
		meleeLog(string.format("no swing: peak=%.2f reason=%s", swingDetector.missPeak, tostring(swingDetector.missReason)))
		swingDetector.missPeak = 0.0
	end
	if fired then
		-- test 20: guns (class chain has GunBase_WeaponScript_C) fire from the trigger only, never from a swing
		if T20.rangedFor ~= activeWeapon then T20.rangedFor, T20.ranged = activeWeapon, T20.agIsRanged(activeWeapon) end
		if T20.ranged then meleeLog(string.format("swing ignored: ranged weapon (peak %.2f)", speed)) return end
		-- L2 counts as held only while the xinput callback keeps seeing it (a menu could swallow the release)
		if l2StabArmed and meleeClock - l2StabSeen < 0.25 then l2StabFire(speed, source)
		elseif configui.getValue("rush_buffer") ~= false and not T20.S6.rush:swing() then
			meleeLog(string.format("swing buffered for rush: dashT=%.2f speed=%.2f", T20.S6.rush.dashTime, speed))
		else meleeFire(speed, T20.S6.rush.lastWasRush and (source .. " rush") or source) end
	end
end

register_key_bind("F8", function()
	local ok, err = pcall(function()
		if configui.getValue("6dof_right") ~= true then
			meleeLog("F8 ignored: motion controls melee is off")
			return
		end
		swingDetector:reset()
		meleeSyntheticAt = 0.0
		meleeSyntheticLeft = MELEE_SYNTHETIC_TIME
		meleeLog("F8 synthetic swing started")
	end)
	if not ok then print("[MELEE] F8 error", err) end
end)

local meleeErrorLogged = false
function meleeReportError(err)
	if meleeErrorLogged then return end
	meleeErrorLogged = true
	pcall(meleeLog, "ERROR (shown once): " .. tostring(err))
end

pcall(meleeLog, "motion melee loaded; F8 = synthetic swing")

-- test 12: Euler sliders gimbal-lock near pitch 90 (yaw and roll share an axis) -> extra rotation about the hand's own X/Y/Z axes,
-- applied in hand space on top of the Euler base: final = Rz(rz) * Ry(ry) * Rx(rx) * Rbase (UE FRotator<->FQuat formulas)
local function rotToQuat(p, y, r)
	local d = math.pi / 360
	local sp, cp, sy, cy, sr, cr = math.sin(p * d), math.cos(p * d), math.sin(y * d), math.cos(y * d), math.sin(r * d), math.cos(r * d)
	return cr * sp * sy - sr * cp * cy, -cr * sp * cy - sr * cp * sy, cr * cp * sy - sr * sp * cy, cr * cp * cy + sr * sp * sy
end
local function qmul(ax, ay, az, aw, bx, by, bz, bw)
	return aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
		aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz
end
local function quatToRot(x, y, z, w)
	local st = z * x - w * y
	local yaw = math.atan(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
	local pitch, roll
	if st < -0.4999995 then pitch, roll = -90, -yaw - 2 * math.atan(x, w)
	elseif st > 0.4999995 then pitch, roll = 90, yaw - 2 * math.atan(x, w)
	else pitch, roll = math.deg(math.asin(2 * st)), math.atan(-2 * (w * x + y * z), 1 - 2 * (x * x + y * y)) end
	roll = math.deg(roll)
	return {Pitch = pitch, Yaw = math.deg(yaw), Roll = roll}
end
function hudRotation(p, y, r, rx, ry, rz)
	if (rx or 0) == 0 and (ry or 0) == 0 and (rz or 0) == 0 then return {Pitch = p, Yaw = y, Roll = r} end
	local bx, by, bz, bw = rotToQuat(p, y, r)
	local x1, y1, z1, w1 = rotToQuat(0, 0, rx or 0)
	local x2, y2, z2, w2 = rotToQuat(ry or 0, 0, 0)
	local x3, y3, z3, w3 = rotToQuat(0, rz or 0, 0)
	local qx, qy, qz, qw = qmul(x1, y1, z1, w1, bx, by, bz, bw)
	qx, qy, qz, qw = qmul(x2, y2, z2, w2, qx, qy, qz, qw)
	qx, qy, qz, qw = qmul(x3, y3, z3, w3, qx, qy, qz, qw)
	return quatToRot(qx, qy, qz, qw)
end

-- test 7: HP HUD transform from sliders; re-applied only when a slider changes (no per-tick allocation)
hpHudComponent = nil
hpHudLast = nil
local hpHudKeys = {"hp_hud_x", "hp_hud_y", "hp_hud_z", "hp_hud_pitch", "hp_hud_yaw", "hp_hud_roll", "hp_hud_scale", "hp_hud_rx", "hp_hud_ry", "hp_hud_rz"}
local hpHudVals = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
function applyHpHudTransform()
	if hpHudComponent == nil then return end
	local changed = hpHudLast == nil
	for i = 1, 10 do
		local v = configui.getValue(hpHudKeys[i]) or 0
		if v ~= hpHudVals[i] then hpHudVals[i] = v; changed = true end
	end
	if not changed then return end
	hpHudLast = true
	local s = hpHudVals[7]
	if s <= 0 then s = 0.05 end
	uevrUtils.set_component_relative_transform(hpHudComponent, {X=hpHudVals[1], Y=hpHudVals[2], Z=hpHudVals[3]}, hudRotation(hpHudVals[4], hpHudVals[5], hpHudVals[6], hpHudVals[8], hpHudVals[9], hpHudVals[10]), {s, s, s})
	uevr.params.functions.log_info(string.format("[HUD] hp on left pos=(%.2f,%.2f,%.2f) rot=(%.1f,%.1f,%.1f) scale=%.3f", hpHudVals[1], hpHudVals[2], hpHudVals[3], hpHudVals[4], hpHudVals[5], hpHudVals[6], s))
end

-- test 9: same for the usable-item HUD; also logs when its item icon shows/hides (checked every 1 s)
itemHudComponent = nil
itemHudLast = nil
local itemHudKeys = {"item_hud_x", "item_hud_y", "item_hud_z", "item_hud_pitch", "item_hud_yaw", "item_hud_roll", "item_hud_scale", "item_hud_rx", "item_hud_ry", "item_hud_rz", "item_icon_dx", "item_icon_dy"}
local itemHudVals = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
local itemIconT, itemIconLastVis = 0, nil
itemIconLayoutDone = false
function applyItemHudTransform(delta)
	if itemHudComponent == nil then return end
	itemIconT = itemIconT + (delta or 0)
	if itemIconT > 1 then
		itemIconT = 0
		pcall(function()
			local w = pawn.HUD.ConsumableHUD
			local v = w.ItemIcon:GetVisibility()
			-- test 11: empty item slot shows as a bare square on the hand -> hide the whole HUD component while no item icon is shown
			if v ~= 1 and v ~= 2 and not itemIconLayoutDone then
				-- the icon slot is anchored bottom-centre while the frame is top-left (made for a full-screen HUD) -> centre it on the frame, plus nudge sliders
				local fs, is = w.ItemFrame.Slot, w.ItemIcon.Slot
				local o = fs.LayoutData.Offsets
				local sz = is.LayoutData.Offsets.Right
				is:SetAnchors({Minimum = {X = 0, Y = 0}, Maximum = {X = 0, Y = 0}})
				is:SetAlignment({X = 0.5, Y = 0.5})
				is:SetPosition({X = o.Left + (itemHudVals[11] or 0), Y = o.Top + (itemHudVals[12] or 0)})
				is:SetSize({X = sz, Y = sz})
				itemIconLayoutDone = true
				uevr.params.functions.log_info(string.format("[HUD] item icon re-slotted at (%.0f,%.0f) size %.0f", o.Left + (itemHudVals[11] or 0), o.Top + (itemHudVals[12] or 0), sz))
			end
			local want = true -- test 15: show the item HUD frame even with 0 units
			if itemHudComponent:IsVisible() ~= want then itemHudComponent:SetVisibility(want, false) end
			if v ~= itemIconLastVis then
				itemIconLastVis = v
				uevr.params.functions.log_info(string.format("[HUD] item icon vis=%s hudVis=%s compVisible=%s", tostring(v), tostring(w:GetVisibility()), tostring(itemHudComponent:IsVisible())))
			end
		end)
	end
	local changed = itemHudLast == nil
	for i = 1, 12 do
		local v = configui.getValue(itemHudKeys[i]) or 0
		if v ~= itemHudVals[i] then itemHudVals[i] = v; changed = true end
	end
	if not changed then return end
	itemHudLast = true
	local s = itemHudVals[7]
	if s <= 0 then s = 0.03 end
	uevrUtils.set_component_relative_transform(itemHudComponent, {X=itemHudVals[1], Y=itemHudVals[2], Z=itemHudVals[3]}, hudRotation(itemHudVals[4], itemHudVals[5], itemHudVals[6], itemHudVals[8], itemHudVals[9], itemHudVals[10]), {s, s, s})
	itemIconLayoutDone = false -- re-apply icon nudge
end

-- test 7 diagnostic: does the weapon follow the HMD? Logs when head yaw moves >15 deg (max every 0.5 s, 80 lines)
local diagT, diagYaw, diagCount = 0, nil, 0
function hmdFollowDiag(delta)
	if diagCount >= 80 or activeWeaponMesh == nil then return end
	diagT = diagT + (delta or 0)
	if diagT < 0.5 then return end
	local head = controllers.getController(2)
	if head == nil then return end
	local hr = head:K2_GetComponentRotation()
	if diagYaw ~= nil and math.abs(((hr.Yaw - diagYaw + 540) % 360) - 180) < 15 then return end
	diagT, diagYaw, diagCount = 0, hr.Yaw, diagCount + 1
	local rc = controllers.getController(1, true)
	local cr = rc and rc:K2_GetComponentRotation()
	local mr = activeWeaponMesh:K2_GetComponentRotation()
	local rr = activeWeaponMesh.RelativeRotation
	local pawnYaw, ctrlYaw = -999, -999
	pcall(function() pawnYaw = api:get_local_pawn(0):K2_GetActorRotation().Yaw end)
	pcall(function() ctrlYaw = uevr.api:get_player_controller(0):GetControlRotation().Yaw end)
	local parent = "?"
	pcall(function() parent = activeWeaponMesh.AttachParent and activeWeaponMesh.AttachParent:get_fname():to_string() or "nil" end)
	uevr.params.functions.log_info(string.format("[DIAG] head=(%.0f,%.0f) rCtrl=%s mesh=(%.0f,%.0f,%.0f) meshRel=(%.0f,%.0f,%.0f) parent=%s pawnYaw=%.0f ctrlYaw=%.0f laser=%s",
		hr.Pitch, hr.Yaw, cr and string.format("(%.0f,%.0f,%.0f)", cr.Pitch, cr.Yaw, cr.Roll) or "nil", mr.Pitch, mr.Yaw, mr.Roll,
		rr and rr.Pitch or 0, rr and rr.Yaw or 0, rr and rr.Roll or 0, parent, pawnYaw, ctrlYaw, tostring(showLaser)))
end

-- test 12: weapon seems to move with the HMD -> disable the motion controllers' low-latency (late) update; checkbox no_late_update (re-applied every 2 s)
local llT = 0
function applyLateUpdate(delta)
	llT = llT + (delta or 0)
	if llT < 2 then return end
	llT = 0
	local want = configui.getValue("no_late_update") ~= false
	for i = 0, 1 do
		local c = controllers.getController(i, true)
		if c ~= nil and c.bDisableLowLatencyUpdate ~= want then c.bDisableLowLatencyUpdate = want end
	end
	-- test 13 forced r.ScreenPercentage here; removed in test 18 (the game's own resolution setting fixes it)
end

-- test 8 diagnostic: weapon drifts opposite to head translation? Logs world positions when the head moves >8 cm (max 60 lines)
local posT, posLast, posCount = 0, nil, 0
function hmdPosDiag(delta)
	if posCount >= 60 or activeWeaponMesh == nil then return end
	posT = posT + (delta or 0)
	if posT < 0.4 then return end
	posT = 0
	local head = controllers.getController(2)
	if head == nil then return end
	local h = head:K2_GetComponentLocation()
	if posLast ~= nil then
		local dx, dy, dz = h.X - posLast.X, h.Y - posLast.Y, h.Z - posLast.Z
		if dx * dx + dy * dy + dz * dz < 64 then return end
	end
	posLast, posCount = h, posCount + 1
	local rc = controllers.getController(1, true)
	local r = rc and rc:K2_GetComponentLocation() or h
	local m = activeWeaponMesh:K2_GetComponentLocation()
	local p, cam = h, h
	pcall(function() p = api:get_local_pawn(0):K2_GetActorLocation() end)
	pcall(function() cam = uevr.api:get_player_controller(0).PlayerCameraManager:GetCameraLocation() end)
	uevr.params.functions.log_info(string.format("[POS] head=(%.0f,%.0f,%.0f) cam-head=(%.0f,%.0f,%.0f) rCtrl-pawn=(%.0f,%.0f,%.0f) mesh-rCtrl=(%.0f,%.0f,%.0f) head-pawn=(%.0f,%.0f,%.0f) roomscale=%s",
		h.X, h.Y, h.Z, cam.X - h.X, cam.Y - h.Y, cam.Z - h.Z, r.X - p.X, r.Y - p.Y, r.Z - p.Z, m.X - r.X, m.Y - r.Y, m.Z - r.Z,
		h.X - p.X, h.Y - p.Y, h.Z - p.Z, tostring(configui.getValue("roomscale") ~= false)))
end

-- test 8: hide the 3D knife in the left hand (pickup code toggles RenderInMainPass too; we only touch it while it differs)
local knifeHiddenByUs = false
function updateKnifeModelVisibility()
	local m = activeLeftWeaponMesh
	if m == nil then knifeHiddenByUs = false return end
	if configui.getValue("hide_knife_model") ~= false then
		if m.bRenderInMainPass then m:SetRenderInMainPass(false) m:SetRenderCustomDepth(false) end
		knifeHiddenByUs = true
	elseif knifeHiddenByUs then
		m:SetRenderInMainPass(true) m:SetRenderCustomDepth(true)
		knifeHiddenByUs = false
	end
end

-- test 9: native L2 dodge goes backward from the pawn/aim facing -> face the HMD yaw first, keep aim on the HMD for 0.8 s
-- test 9b: directional = same native dodge with the pawn turned so its "backward" points where we want; pawn yaw is
-- decoupled from the controller for 0.8 s (bUseControllerRotationYaw / bOrientRotationToMovement off), then restored.
nativeDodgeAimLeft = 0
weaponIsSpear = nil
dodgeFlip = {} -- per weapon: true = dashes toward pawn facing (learned)
dodgeWeapon = "?"
dodgeStick = nil
local dodgeSaved, dodgeStartPos, dodgeWantYaw = nil, nil, 0
function restoreDodgeFacing()
	if dodgeSaved == nil then return end
	local pawn = api:get_local_pawn(0)
	if pawn ~= nil then
		pcall(function() pawn.bUseControllerRotationYaw = dodgeSaved[1] end)
		pcall(function() pawn.CharacterMovement.bOrientRotationToMovement = dodgeSaved[2] end)
		pcall(function()
			local p = pawn:K2_GetActorLocation()
			local dx, dy = p.X - dodgeStartPos.X, p.Y - dodgeStartPos.Y
			uevr.params.functions.log_info(string.format("[DODGE] end moved=%.0fcm moveYaw=%.0f wantYaw=%.0f", math.sqrt(dx * dx + dy * dy), math.deg(math.atan(dy, dx)), dodgeWantYaw))
		end)
		pcall(function()
			local d = pawn.LastDashMoveDir
			uevr.params.functions.log_info(string.format("[DODGE] dash Dashing=%s dir=(%.2f,%.2f,%.2f) dist=%s speedMult=%s",
				tostring(pawn.Dashing), d.X, d.Y, d.Z, tostring(pawn.DashDistanceTravelled), tostring(pawn.DashSpeedMult)))
		end)
	end
	dodgeSaved = nil
end
-- offsetDeg = dodge direction relative to HMD yaw (180 = backward, 0 = forward, 90 = right)
function startNativeDodge(offsetDeg, src)
	local head = controllers.getController(2)
	local pawn = api:get_local_pawn(0)
	if head == nil or pawn == nil or activeWeapon == nil then return end
	local yaw = head:K2_GetComponentRotation().Yaw
	dodgeWantYaw = yaw + offsetDeg
	dodgeWeapon = "?"
	pcall(function() dodgeWeapon = activeWeapon:get_full_name():match("([%w_]+)$") or "?" end)
	local facing = dodgeWantYaw -- test 14: native alt attack = weapon move (sword stabs forward, spear stabs then backs off); pawn faces the wanted direction
	nativeDodgeAimLeft = 0.8
	vr.set_mod_value("VR_AimMethod", "1")
	local before = pawn:K2_GetActorRotation().Yaw
	if dodgeSaved == nil then
		local u, o = true, false
		pcall(function() u = pawn.bUseControllerRotationYaw end)
		pcall(function() o = pawn.CharacterMovement.bOrientRotationToMovement end)
		dodgeSaved = {u, o}
	end
	pcall(function() pawn.bUseControllerRotationYaw = false end)
	pcall(function() pawn.CharacterMovement.bOrientRotationToMovement = false end)
	pcall(function() pawn:K2_SetActorRotation(uevrUtils.rotator(0, facing, 0), false) end)
	dodgeStartPos = pawn:K2_GetActorLocation()
	-- test 11: the game dashes toward the LEFT-stick direction (backward only when neutral) -> spoof the left stick for the RS dodge
	if src == "RS" then
		local r = math.rad(offsetDeg)
		local t = os.clock()
		dodgeStick = {x = math.floor(math.sin(r) * 30000), y = math.floor(math.cos(r) * 30000), untilT = t + 0.7, fireT = t + 0.12, relT = t + 0.3}
	else
		activeWeapon:AltAttackPressed()
	end
	uevr.params.functions.log_info(string.format("[DODGE] native src=%s hmdYaw=%.0f offset=%.0f facing=%.0f pawnYawBefore=%.0f useCtrlYaw=%s orient=%s",
		src, yaw, offsetDeg, facing, before, tostring(dodgeSaved[1]), tostring(dodgeSaved[2])))
end

-- test 8 discovery: dump HUD widgets (find the game's own aim marker + why ConsumableHUD looks empty).
-- Runs once 3 s after knife aim turns on; F9 runs it again.
local hudDumpPending, hudDumpDone, hudDumpT = false, false, 0
local VIS = {[0]="Vis", [1]="Collapsed", [2]="Hidden", [3]="HitTestInv", [4]="SelfHitTestInv"}
local function hudLog(s) uevr.params.functions.log_info("[HUDDUMP] " .. s) end
local function widgetInfo(w)
	local cls, vis, parent = "?", "?", "?"
	pcall(function() cls = w:get_class():get_fname():to_string() end)
	pcall(function() local v = w:GetVisibility() vis = VIS[v] or tostring(v) end)
	pcall(function() local pw = w:GetParent() parent = pw and pw:get_fname():to_string() or "none" end)
	local sz = ""
	pcall(function() local d = w:GetDesiredSize() sz = string.format(" desired=%.0fx%.0f", d.X, d.Y) end)
	local op = ""
	pcall(function() op = string.format(" opacity=%.2f", w:GetRenderOpacity()) end)
	return cls .. " vis=" .. vis .. " parent=" .. parent .. sz .. op
end
local function dumpTree(root, label)
	local lines = 0
	local function visit(w, depth)
		if lines >= 150 or depth > 7 or uevrUtils.getValid(w) == nil then return end
		lines = lines + 1
		hudLog(label .. " " .. string.rep(". ", depth) .. w:get_fname():to_string() .. " [" .. widgetInfo(w) .. "]")
		pcall(function()
			if w.WidgetTree ~= nil and w.WidgetTree.RootWidget ~= nil then visit(w.WidgetTree.RootWidget, depth + 1) end
		end)
		pcall(function()
			local n = w:GetChildrenCount()
			for i = 0, (n or 0) - 1 do visit(w:GetChildAt(i), depth + 1) end
		end)
		pcall(function() if w.GetContent ~= nil then visit(w:GetContent(), depth + 1) end end)
	end
	visit(root, 0)
end
function hudDump()
	local pawn = api:get_local_pawn(0)
	if pawn == nil or pawn.HUD == nil then hudLog("no pawn.HUD") return end
	local hud = pawn.HUD
	hudLog("HUD " .. hud:get_full_name())
	-- every widget-valued property on the HUD class (includes widgets we removed from the HUD tree)
	pcall(function()
		local widgetClass = uevrUtils.get_class("Class /Script/UMG.Widget")
		local prop = hud:get_class():get_child_properties()
		while prop ~= nil do
			pcall(function()
				if prop:get_class():get_name() == "ObjectProperty" then
					local name = prop:get_fname():to_string()
					local v = hud[name]
					if v ~= nil and (widgetClass == nil or v:is_a(widgetClass)) then hudLog("prop " .. name .. " [" .. widgetInfo(v) .. "]") end
				end
			end)
			prop = prop:get_next()
		end
	end)
	pcall(function() dumpTree(hud.WidgetTree.RootWidget, "hud") end)
	for _, n in ipairs({"ConsumableHUD", "CompassWidget", "StatusCluster"}) do
		pcall(function() if hud[n] ~= nil then dumpTree(hud[n], n) end end)
	end
	hudLog("done")
end
function hudDumpTick(delta)
	if hudDumpDone then return end
	if not hudDumpPending then
		if showLaser then hudDumpPending, hudDumpT = true, 0 end
		return
	end
	hudDumpT = hudDumpT + (delta or 0)
	if hudDumpT < 3.0 then return end
	hudDumpT = 0
	local p = api:get_local_pawn(0)
	if p == nil or p.HUD == nil or p.HUD.ConsumableHUD == nil then return end -- retry every 3 s until the HUD exists
	hudDumpDone = true
	pcall(hudDump)
end
register_key_bind("F9", function() pcall(hudDump) end)
-- F10 (test 13): list visible mesh components near the right hand or owned by the pawn, to find the head-locked sword.
function meshDump()
	local log = function(s) uevr.params.functions.log_info("[MESHDUMP] " .. s) end
	local rc, head, pawn = controllers.getController(1), controllers.getController(2), api:get_local_pawn(0)
	if rc == nil then log("no right controller") return end
	local rl, hl = rc:K2_GetComponentLocation(), head and head:K2_GetComponentLocation()
	log(string.format("rHand=(%.0f,%.0f,%.0f) head=%s", rl.X, rl.Y, rl.Z, hl and string.format("(%.0f,%.0f,%.0f)", hl.X, hl.Y, hl.Z) or "nil"))
	local n = 0
	for _, cls in ipairs({"Class /Script/Engine.StaticMeshComponent", "Class /Script/Engine.SkeletalMeshComponent"}) do
		for _, c in ipairs(uevrUtils.find_all_of(cls, false) or {}) do
			pcall(function()
				if n >= 45 or not c:IsVisible() then return end
				local owner = c:GetOwner()
				local l = c:K2_GetComponentLocation()
				local dx, dy, dz = l.X - rl.X, l.Y - rl.Y, l.Z - rl.Z
				local d = math.sqrt(dx * dx + dy * dy + dz * dz)
				local mine = pawn ~= nil and owner ~= nil and owner:get_full_name() == pawn:get_full_name()
				if d > 200 and not mine then return end
				n = n + 1
				local mesh = "?"
				pcall(function() mesh = (c.StaticMesh or c.SkeletalMesh or c.SkeletalMeshAsset):get_fname():to_string() end)
				local par = "none"
				pcall(function() par = c:GetAttachParent():get_fname():to_string() end)
				local own = "?"
				pcall(function() own = owner:get_fname():to_string() end)
				log(string.format("%s %s owner=%s parent=%s mesh=%s d=%.0f mainPass=%s", c:get_class():get_fname():to_string(), c:get_fname():to_string(), own, par, mesh, d, tostring(c.bRenderInMainPass)))
			end)
		end
	end
	log("done n=" .. n)
end
register_key_bind("F10", function() pcall(meshDump) end)
-- Select/Back has no binding source in VR: open the inventory/journal via the pawn (F7 to test, Back bit 0x0020 if it ever arrives)
local lastInvOpen = 0
function openInventory(src)
	local pawn = api:get_local_pawn(0)
	if pawn == nil or os.clock() - lastInvOpen < 0.5 then return end
	lastInvOpen = os.clock()
	-- test 20: items/equipment screen = GameMenu_C, opened by the game's "Status" action (pawn:OpenStatus); pause menu as fallback
	local how = "OpenStatus"
	local ok, err = pcall(function() pawn:OpenStatus() end)
	if not ok then how = "OpenPauseMenu(false)" ok, err = pcall(function() pawn:OpenPauseMenu(false) end) end
	pcall(function() uevr.params.functions.log_info(string.format("[INV] %s src=%s ok=%s %s", how, src, tostring(ok), tostring(err or ""))) end)
end
register_key_bind("F7", function() pcall(openInventory, "F7") end)

-- test 7: knife aim dot instead of the laser: small sphere where the left-hand aim ray hits (aim method 3 = left hand while showLaser)
local aimDot, aimDotVisible, aimDotLogged = nil, false, false
local aimStart, aimEnd, aimScale = {X=0,Y=0,Z=0}, {X=0,Y=0,Z=0}, {X=0.1,Y=0.1,Z=0.1}
local aimIgnore, aimColor = {}, {R=0,G=0,B=0,A=0}
local AIM_MAX = 5000.0
local aimObjTypes, aimObjOk = {0, 1, 2, 3, 4}, true -- EObjectTypeQuery: WorldStatic, WorldDynamic, Pawn, PhysicsBody, Vehicle
local aimHit2 = StructObject.new(hitresult_c) -- second hit result
function aimDotEnabled()
	return configui.getValue("aim_dot") ~= false
end
local function hideAimDot()
	if aimDot ~= nil and aimDotVisible then pcall(function() aimDot:SetVisibility(false) end) end
	aimDotVisible = false
end
-- test 16: the game's crosshair is drawn on the HUD canvas, which VR shows in the left eye only. Its material is
-- UI-domain (can't go on a mesh), so: UMG Image with the same MID on a world WidgetComponent at the aim point
-- (game keeps updating the MID: colour/interact state). Canvas copy hidden via BaseCrosshairSize = 0.
local XHAIR_PX, XHAIR_RAD = 64, 0.06 -- widget render size (px); apparent width at size 1 (test 18: was 0.028, barely visible)
local XHAIR_PAD = 6 -- px: bold mode draws the crosshair inset by this, a dark copy fills the whole widget behind it
local XHAIR_HOSTS = { -- any game UserWidget class can host: its tree root is replaced by our Image
	"WidgetBlueprintGeneratedClass /Game/UI/Widgets/UIAspectRatioBox.UIAspectRatioBox_C",
	"WidgetBlueprintGeneratedClass /Game/UI/Widgets/Core/InputViewIcon.InputViewIcon_C",
}
local xhair = {comp = nil, img = nil, mid = nil, visible = false, retryT = 0.0, hidT = 0.0, base = nil, logged = false}
local xhairScale = {X = 1, Y = 1, Z = 1}
local xhairRot = {Pitch = 0, Yaw = 0, Roll = 0}
regularPlayLast = false -- set by the pre-tick branch (1 tick late)
local function xhairWanted() return configui.getValue("game_crosshair") ~= false end
local function xhairHud()
	local pc = uevr.api:get_player_controller(0)
	local hud = pc ~= nil and pc.MyHUD or nil
	if hud == nil or hud.Crosshairmat == nil then return nil end
	return hud
end
local function xhairHide()
	if xhair.comp ~= nil and xhair.visible then pcall(function() xhair.comp:SetVisibility(false, false) end) end
	xhair.visible = false
end
local function xhairCanvas(hud, hide) -- ~1/s; the HUD may reset the size
	local s = hud.BaseCrosshairSize
	if hide then
		if (s.X == 0 and s.Y == 0) or (xhair.hideFails or 0) >= 3 then return end
		xhair.base = {X = s.X, Y = s.Y}
		pcall(function() s.X = 0 s.Y = 0 end)
		if hud.BaseCrosshairSize.X ~= 0 then pcall(function() hud.BaseCrosshairSize = vector_2(0, 0) end) end
		if hud.BaseCrosshairSize.X ~= 0 then xhair.hideFails = (xhair.hideFails or 0) + 1 end
		uevr.params.functions.log_info(string.format("[XHAIR] canvas size %.0fx%.0f -> %.0f (0 = hidden) fails=%d", xhair.base.X, xhair.base.Y, hud.BaseCrosshairSize.X, xhair.hideFails or 0))
	elseif xhair.base ~= nil and s.X == 0 then
		pcall(function() s.X = xhair.base.X s.Y = xhair.base.Y end)
		if hud.BaseCrosshairSize.X == 0 then pcall(function() hud.BaseCrosshairSize = vector_2(xhair.base.X, xhair.base.Y) end) end
		uevr.params.functions.log_info("[XHAIR] canvas size restored " .. tostring(hud.BaseCrosshairSize.X))
	end
end
local function xhairEnsure(hud)
	if xhair.comp ~= nil and uevrUtils.getValid(xhair.comp) ~= nil then
		if xhair.mid ~= hud.Crosshairmat then -- HUD rebuilt its material
			xhair.mid = hud.Crosshairmat
			for _, im in ipairs(xhair.imgs) do pcall(function() im:SetBrushFromMaterial(xhair.mid) end) end
		end
		local bold = configui.getValue("crosshair_bold") ~= false
		if bold ~= xhair.bold and xhair.extras ~= nil then -- 0 = Visible, 1 = Collapsed
			xhair.bold = bold
			for _, im in ipairs(xhair.extras) do pcall(function() im:SetVisibility(bold and 0 or 1) end) end
			pcall(function() xhair.slot:SetPadding(bold and xhair.padOn or xhair.padOff) end)
		end
		-- test 19: draw on top of scenery = bDisableDepthTest on the engine's widget base material (shared by all
		-- translucent widget components; the hand HUDs use the masked variant, where it has no effect)
		local top = configui.getValue("crosshair_on_top") ~= false
		if top ~= xhair.top then
			xhair.top = top
			local ok, err = pcall(function()
				local base = uevr.api:find_uobject("Material /Engine/EngineMaterials/Widget3DPassThrough.Widget3DPassThrough")
				base.bDisableDepthTest = top
				xhair.comp:SetVisibility(false, false) -- rebuild the render state
				if xhair.visible then xhair.comp:SetVisibility(true, false) end
				uevr.params.functions.log_info("[XHAIR] on top=" .. tostring(top) .. " now=" .. tostring(base.bDisableDepthTest))
			end)
			if not ok then uevr.params.functions.log_info("[XHAIR] on top error: " .. tostring(err)) end
		end
		return true
	end
	xhair.comp, xhair.visible = nil, false
	if os.clock() < xhair.retryT then return false end
	xhair.retryT = os.clock() + 5.0
	local ok, res = pcall(xhairCreate, hud)
	if not ok then uevr.params.functions.log_info("[XHAIR] create error: " .. tostring(res)) return false end
	return res
end
function xhairCreate(hud)
	local widget, host = nil, "?"
	for _, cls in ipairs(XHAIR_HOSTS) do
		local ok, w = pcall(uevrUtils.createWidget, cls)
		if ok and w ~= nil and w.WidgetTree ~= nil then widget, host = w, cls:match("%.([%w_]+)$") break end
	end
	if widget == nil then uevr.params.functions.log_info("[XHAIR] no host widget class loaded") return false end
	local img = uevrUtils.spawn_object("Class /Script/UMG.Image", widget.WidgetTree)
	if img == nil then uevr.params.functions.log_info("[XHAIR] Image spawn failed") return false end
	xhair.mid = hud.Crosshairmat
	img:SetBrushFromMaterial(xhair.mid)
	xhair.imgs, xhair.extras, xhair.slot, xhair.bold = {img}, nil, nil, nil
	-- test 18: bold mode = Overlay root: dark copy (tinted black, full size) behind, crosshair inset by XHAIR_PAD on top,
	-- drawn twice (stacking raises the half-transparent crosshair's opacity). Falls back to the single Image.
	local root = img
	local okO, errO = pcall(function()
		local ov = uevrUtils.spawn_object("Class /Script/UMG.Overlay", widget.WidgetTree)
		local shadow = uevrUtils.spawn_object("Class /Script/UMG.Image", widget.WidgetTree)
		local img2 = uevrUtils.spawn_object("Class /Script/UMG.Image", widget.WidgetTree)
		if ov == nil or shadow == nil or img2 == nil then error("spawn failed") end
		shadow:SetBrushFromMaterial(xhair.mid)
		shadow:SetColorAndOpacity({R = 0.0, G = 0.0, B = 0.0, A = 0.85})
		img2:SetBrushFromMaterial(xhair.mid)
		local sS = ov:AddChildToOverlay(shadow)
		local s1 = ov:AddChildToOverlay(img)
		local s2 = ov:AddChildToOverlay(img2)
		xhair.padOn = {Left = XHAIR_PAD, Top = XHAIR_PAD, Right = XHAIR_PAD, Bottom = XHAIR_PAD}
		xhair.padOff = {Left = 0, Top = 0, Right = 0, Bottom = 0}
		for _, sl in ipairs({sS, s1, s2}) do sl:SetHorizontalAlignment(0) sl:SetVerticalAlignment(0) end -- Fill
		s1:SetPadding(xhair.padOn)
		s2:SetPadding(xhair.padOn)
		xhair.imgs = {img, shadow, img2}
		xhair.extras = {shadow, img2}
		xhair.slot = s1 -- img2 keeps its padding: only visible in bold mode
		root = ov
	end)
	if not okO then uevr.params.functions.log_info("[XHAIR] bold overlay failed: " .. tostring(errO)) end
	widget.WidgetTree.RootWidget = root -- before the component builds the Slate tree
	local comp = uevrUtils.createWidgetComponent(widget, {removeFromViewport = false, twoSided = true, drawSize = vector_2(XHAIR_PX, XHAIR_PX)})
	if comp == nil then uevr.params.functions.log_info("[XHAIR] WidgetComponent failed") return false end
	-- default Masked blend clips the half-transparent crosshair -> Transparent (2); SetMaterial rebuilds the widget material
	pcall(function() comp.BlendMode = 2 comp:SetMaterial(0, comp.TranslucentMaterial) end)
	pcall(function() comp:SetCastShadow(false) end)
	xhair.comp, xhair.img, xhair.visible = comp, img, true
	uevr.params.functions.log_info(string.format("[XHAIR] created host=%s blend=%s", host, tostring(comp.BlendMode)))
	return true
end
local function xhairPlace(hud, head, dist) -- at aimEnd, facing the head, constant apparent size
	local mult = hud.CurrentPickupSizeMult
	if type(mult) ~= "number" or mult <= 0 then mult = 1.0 end
	local s = math.max(0.0005, dist * XHAIR_RAD * (configui.getValue("crosshair_size") or 1.0) * mult / XHAIR_PX)
	xhairScale.X, xhairScale.Y, xhairScale.Z = s, s, s
	local comp = xhair.comp
	comp:K2_SetWorldLocation(aimEnd, false, reusable_hit_result, true)
	-- test 17: no FindLookAtRotation: UEVR treats its const FVector& args as out params and writes a "result" key into
	-- aimEnd, which then breaks every later call using aimEnd (crosshair froze after the first frame). Facing in plain Lua.
	if head ~= nil then
		local h = head:K2_GetComponentLocation()
		local dx, dy, dz = h.X - aimEnd.X, h.Y - aimEnd.Y, h.Z - aimEnd.Z
		xhairRot.Yaw = math.deg(math.atan(dy, dx))
		xhairRot.Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
		comp:K2_SetWorldRotation(xhairRot, false, reusable_hit_result, true)
	end
	comp:SetWorldScale3D(xhairScale)
	if not xhair.visible then comp:SetVisibility(true, false) xhair.visible = true end
	if not xhair.logged then
		xhair.logged = true
		uevr.params.functions.log_info(string.format("[XHAIR] shown dist=%.0f scale=%.4f pickMult=%.2f", dist, s, mult))
	end
end
function updateAimDot()
	local knife = showLaser
	local hud = xhairWanted() and xhairHud() or nil
	if os.clock() > xhair.hidT then
		xhair.hidT = os.clock() + 1.0
		local h = hud or xhairHud()
		if h ~= nil then
			local ok, err = pcall(xhairCanvas, h, hud ~= nil)
			if not ok and not xhair.canvasErr then xhair.canvasErr = true uevr.params.functions.log_info("[XHAIR] canvas error: " .. tostring(err)) end
		end
	end
	-- knife aim: from the left hand (game crosshair, else the orange dot); otherwise game crosshair where the head looks
	local gaze = hud ~= nil and not knife and regularPlayLast and configui.getValue("game_crosshair_gaze") ~= false
	if not ((knife and (hud ~= nil or aimDotEnabled())) or gaze) then hideAimDot() xhairHide() return end
	local head = controllers.getController(2)
	local c = knife and controllers.getController(0, true) or head
	if c == nil then hideAimDot() xhairHide() return end
	local useX = hud ~= nil and xhairEnsure(hud)
	if not useX and not (knife and aimDotEnabled()) then hideAimDot() xhairHide() return end
	if useX then hideAimDot() else xhairHide() end
	if not useX and (aimDot == nil or uevrUtils.getValid(aimDot) == nil) then
		aimDot = uevrUtils.createStaticMeshComponent("StaticMesh /Engine/BasicShapes/Sphere.Sphere", {visible=true, collisionEnabled=false})
		if aimDot == nil then aimDot = uevrUtils.createStaticMeshComponent("StaticMesh /Engine/BasicShapes/Cube.Cube", {visible=true, collisionEnabled=false}) end
		if aimDot == nil then return end
		pcall(function() aimDot:SetCastShadow(false) end)
		pcall(function() -- bright colour (default sphere is dark grey)
			local mat = uevr.api:find_uobject("Material /Engine/EngineDebugMaterials/DebugMeshMaterial.DebugMeshMaterial")
			local mid = mat ~= nil and aimDot:CreateAndSetMaterialInstanceDynamicFromMaterial(0, mat) or nil
			if mid ~= nil then mid:SetVectorParameterValue("Color", {R=1.0,G=0.15,B=0.05,A=1.0}) end
			uevr.params.functions.log_info("[AIM] colour mat=" .. tostring(mat ~= nil) .. " mid=" .. tostring(mid ~= nil))
		end)
		aimDotVisible = true
	end
	-- test 19: trace from the game camera (where the game's own aim trace starts), not the hand: the hand origin put the
	-- crosshair off target at close range (worse with roomscale off, where the head drifts from the camera)
	local loc = nil
	pcall(function() loc = api:get_player_controller(0).PlayerCameraManager:GetCameraLocation() end)
	if loc == nil then loc = c:K2_GetComponentLocation() end
	local dir = kismet_math_library:GetForwardVector(c:K2_GetComponentRotation())
	aimStart.X, aimStart.Y, aimStart.Z = loc.X, loc.Y, loc.Z
	aimEnd.X, aimEnd.Y, aimEnd.Z = loc.X + dir.X * AIM_MAX, loc.Y + dir.Y * AIM_MAX, loc.Z + dir.Z * AIM_MAX
	aimIgnore[1] = api:get_local_pawn(0)
	local dist = AIM_MAX
	local hit = kismet_system_library:LineTraceSingle(uevrUtils.get_world(), aimStart, aimEnd, 0, false, aimIgnore, 0, reusable_hit_result, true, aimColor, aimColor, 0.0)
	if hit then
		local h = reusable_hit_result.Location
		aimEnd.X, aimEnd.Y, aimEnd.Z = h.X, h.Y, h.Z
		dist = reusable_hit_result.Distance
	end
	-- Visibility misses enemies/props: also trace by object type (static, dynamic, pawn, physics body), keep nearest
	-- test 20: a failure (seen once, transient) no longer disables this for the session: retry after 5 s, give up after 5
	if not aimObjOk and (T20.aimFails or 0) < 5 and os.clock() > (T20.aimRetryT or 0) then aimObjOk = true end
	if aimObjOk then
		local ok, hit2 = pcall(kismet_system_library.LineTraceSingleForObjects, kismet_system_library, uevrUtils.get_world(), aimStart, aimEnd, aimObjTypes, false, aimIgnore, 0, aimHit2, true, aimColor, aimColor, 0.0)
		if ok and T20.aimFails > 0 then T20.aimFails = 0 end
		if not ok then
			aimObjOk, T20.aimFails, T20.aimRetryT = false, (T20.aimFails or 0) + 1, os.clock() + 5.0
			-- verified 2026-11-12: UEVR can't convert the ObjectTypes number array ("Invalid argument type for
			-- ArrayProperty<ObjectProperty>", even with no ignore list) -> no retries
			if string.find(tostring(hit2), "Invalid argument type", 1, true) then T20.aimFails = 99 end
			uevr.params.functions.log_info("[AIM] ForObjects failed (" .. tostring(T20.aimFails) .. "): " .. tostring(hit2))
		elseif hit2 and aimHit2.Distance < dist then
			local h2 = aimHit2.Location
			aimEnd.X, aimEnd.Y, aimEnd.Z = h2.X, h2.Y, h2.Z
			dist = aimHit2.Distance
		end
	end
	-- test 20: a pickup target (pickup_assist) pulls the crosshair onto the item
	if pickupSnap ~= nil then
		aimEnd.X, aimEnd.Y, aimEnd.Z = pickupSnap.X, pickupSnap.Y, pickupSnap.Z
		hit = true
	end
	-- test 13: dot was hidden inside enemy bodies (hit is on the capsule, mesh sticks out) -> pull back up to 40 cm (never past half the distance)
	-- test 19: pull back toward the eyes (head), not the trace start, and size from the eye distance
	local ex, ey, ez = aimStart.X, aimStart.Y, aimStart.Z
	if head ~= nil then local hl = head:K2_GetComponentLocation() ex, ey, ez = hl.X, hl.Y, hl.Z end
	local edx, edy, edz = ex - aimEnd.X, ey - aimEnd.Y, ez - aimEnd.Z
	local eyeDist = math.sqrt(edx * edx + edy * edy + edz * edz)
	dist = eyeDist
	if hit or eyeDist < AIM_MAX * 0.9 then
		local pull = math.min(40.0, eyeDist * 0.5)
		local back = pull / math.max(eyeDist, 1.0)
		dist = eyeDist - pull
		aimEnd.X, aimEnd.Y, aimEnd.Z = aimEnd.X + edx * back, aimEnd.Y + edy * back, aimEnd.Z + edz * back
	end
	if useX then xhairPlace(hud, head, dist) return end
	-- constant apparent size: ~0.5 deg wide at size 1 (sphere mesh is 100 cm across)
	local s = math.max(0.005, dist * 0.000087 * (configui.getValue("aim_dot_size") or 1.0))
	aimScale.X, aimScale.Y, aimScale.Z = s, s, s
	aimDot:K2_SetWorldLocation(aimEnd, false, reusable_hit_result, true)
	aimDot:SetWorldScale3D(aimScale)
	if not aimDotVisible then aimDot:SetVisibility(true) aimDotVisible = true end
	if not aimDotLogged then
		aimDotLogged = true
		uevr.params.functions.log_info(string.format("[AIM] dot shown hit=%s dist=%.0f scale=%.3f", tostring(hit), dist, s))
	end
end

function attachStatusBarOnce()
	if pawn ~= nil and pawn.HUD ~= nil  then
		--attach health bar to left arm
		local healthWidget = pawn.HUD.StatusCluster
		if healthWidget ~= nil then
			if currentStatusBar ~= healthWidget:get_full_name() then				
				print("attach", healthWidget:get_full_name())
				--print("parent was", healthWidget:GetParent():get_full_name())
				healthWidget:RemoveFromParent()
				--myWidgetComponent.CastShadow(false)
				if pawn.Arms ~= nil and pawn.Arms.AttachChildren ~=nil then
					for i,attachChild in pairs(pawn.Arms.AttachChildren) do
						if string.find(attachChild:get_full_name(), "WidgetComponent") and attachChild.Widget ~= nil and string.find(attachChild.Widget:get_full_name(), "StatusCluster") then
							table.remove(pawn.Arms.AttachChildren, i) --remove  item
							attachChild:DetachFromParent()
						end
						
					end				
					--return -- already attached and defined 
				end
				myWidgetComponent = uevrUtils.createWidgetComponent(healthWidget, {manualAttachment=false, removeFromViewport=true, relativeTransform = uevrUtils.get_transform({X=-17.830,Y=-17.280,Z=6.62},{X=0.0, Y=0.0, Z=0.0, W=1.0}, {X=0.1, Y=0.1, Z=0.1}), drawSize=vector_2(1500, 1500)}) 	
				controllers.attachComponentToController(0, myWidgetComponent, "", nil, nil, true) -- test 7: left hand, transform from hp_hud_* sliders
				hpHudComponent = myWidgetComponent
				hpHudLast = nil -- force applyHpHudTransform to set it
				--[[myWidgetComponent:K2_AttachToComponent(pawn.Arms,
					uevrUtils.fname_from_string("UpperArm_R"),
					2, -- SnapToTarget Location
					2, -- SnapToTarget Rotation
					2, -- SnapToTarget Scale  - inherits the weapon's scale
					true
				) ]]
				pcall(applyHpHudTransform)
				-- original right-hand transforms: vertical {X=15.780,Y=-48.670,Z=11.350} {Pitch=181.720,Roll=76.270,Yaw=2}; normal {X=8.630,Y=-3,Z=10.0} {Pitch=181.720,Roll=-203.010,Yaw=2}, scale 0.05
				currentStatusBar = healthWidget:get_full_name()
			end
		end
	end
end

--[[
function attachHealthBarOnce()
	if pawn ~= nil and pawn.HUD ~= nil and pawn.HUD.StatusCluster ~= nil  then
		--attach health bar to left arm
		local healthWidget = pawn.HUD.StatusCluster.PlayerLifeBar
		if healthWidget ~= nil then
			if currentHealthBar ~= healthWidget:get_full_name() then				
				print("attach", healthWidget:get_full_name())
				--print("parent was", healthWidget:GetParent():get_full_name())
				healthWidget:RemoveFromParent()
				--myWidgetComponent.CastShadow(false)
				if pawn.Arms ~= nil and pawn.Arms.AttachChildren ~=nil then
					for i,attachChild in pairs(pawn.Arms.AttachChildren) do
						if string.find(attachChild:get_full_name(), "WidgetComponent") and attachChild.Widget ~= nil and string.find(attachChild.Widget:get_full_name(), "PlayerLifeBar") then
							table.remove(pawn.Arms.AttachChildren, i) --remove  item
							attachChild:DetachFromParent()
						end
						
					end				
					--return -- already attached and defined 
				end
				myWidgetComponent = uevrUtils.createWidgetComponent(healthWidget, {manualAttachment=false, removeFromViewport=true, relativeTransform = uevrUtils.get_transform({X=-17.830,Y=-1.280,Z=6.62},{X=0.0, Y=0.0, Z=0.0, W=1.0}, {X=0.1, Y=0.1, Z=0.1}), drawSize=vector_2(616, 520)}) 	
				--controllers.attachComponentToController(1, myWidgetComponent, "", nil, nil, true)
				myWidgetComponent:K2_AttachToComponent(pawn.Arms,
					uevrUtils.fname_from_string("Hand_R"),
					2, -- SnapToTarget Location
					2, -- SnapToTarget Rotation
					2, -- SnapToTarget Scale  - inherits the weapon's scale
					true
				) 
				uevrUtils.set_component_relative_transform(myWidgetComponent, {X=8.630,Y=-10.680,Z=10.0}, {Pitch=-200,Roll=-189.140,Yaw=2}, {0.05,0.05,0.05}) -- z - forwad , y = right , x - up	
				currentHealthBar = healthWidget:get_full_name()
			end
		end
	end
end

function attachWeaponChargeBarOnce()
	if pawn ~= nil and pawn.HUD ~= nil and pawn.HUD.StatusCluster ~= nil  then
		--attach health bar to left arm
		local healthWidget = pawn.HUD.StatusCluster.WeaponChargeHUD
		if healthWidget ~= nil then
			if currentWeaponChargeBar ~= healthWidget:get_full_name() then				
				print("attach", healthWidget:get_full_name())
				--print("parent was", healthWidget:GetParent():get_full_name())
				healthWidget:RemoveFromParent()
				--myWidgetComponent.CastShadow(false)
				if pawn.Arms ~= nil and pawn.Arms.AttachChildren ~=nil then
					for i,attachChild in pairs(pawn.Arms.AttachChildren) do
						if string.find(attachChild:get_full_name(), "WidgetComponent") and attachChild.Widget ~= nil and string.find(attachChild.Widget:get_full_name(), "WeaponChargeHUD") then
							table.remove(pawn.Arms.AttachChildren, i) --remove  item
							attachChild:DetachFromParent()
						end
						
					end				
					--return -- already attached and defined 
				end
				myWidgetComponent = uevrUtils.createWidgetComponent(healthWidget, {manualAttachment=false, removeFromViewport=true, relativeTransform = uevrUtils.get_transform({X=-17.830,Y=-1.280,Z=6.62},{X=0.0, Y=0.0, Z=0.0, W=1.0}, {X=0.1, Y=0.1, Z=0.1}), drawSize=vector_2(616, 520)}) 	
				--controllers.attachComponentToController(1, myWidgetComponent, "", nil, nil, true)
				myWidgetComponent:K2_AttachToComponent(pawn.Arms,
					uevrUtils.fname_from_string("Hand_R"),
					2, -- SnapToTarget Location
					2, -- SnapToTarget Rotation
					2, -- SnapToTarget Scale  - inherits the weapon's scale
					true
				) 
				uevrUtils.set_component_relative_transform(myWidgetComponent, {X=8.630,Y=-10.680,Z=10.0}, {Pitch=-200,Roll=-189.140,Yaw=2}, {0.05,0.05,0.05}) -- z - forwad , y = right , x - up	
				currentWeaponChargeBar = healthWidget:get_full_name()
			end
		end
	end
end


function attachRootElementOnce()
	if pawn ~= nil and pawn.HUD ~= nil and pawn.HUD.StatusCluster ~= nil  then
		--attach health bar to left arm
		local healthWidget = pawn.HUD.StatusCluster.RootElement
		if healthWidget ~= nil then
			if currentRootElement ~= healthWidget:get_full_name() then				
				print("attach", healthWidget:get_full_name())
				--print("parent was", healthWidget:GetParent():get_full_name())
				healthWidget:RemoveFromParent()
				--myWidgetComponent.CastShadow(false)
				if pawn.Arms ~= nil and pawn.Arms.AttachChildren ~=nil then
					for i,attachChild in pairs(pawn.Arms.AttachChildren) do
						if string.find(attachChild:get_full_name(), "WidgetComponent") and attachChild.Widget ~= nil and string.find(attachChild.Widget:get_full_name(), "RootElement") then
							table.remove(pawn.Arms.AttachChildren, i) --remove  item
							attachChild:DetachFromParent()
						end
						
					end				
					--return -- already attached and defined 
				end
				myWidgetComponent = uevrUtils.createWidgetComponent(healthWidget, {manualAttachment=false, removeFromViewport=true, relativeTransform = uevrUtils.get_transform({X=-17.830,Y=-1.280,Z=6.62},{X=0.0, Y=0.0, Z=0.0, W=1.0}, {X=0.1, Y=0.1, Z=0.1}), drawSize=vector_2(616, 520)}) 	
				--controllers.attachComponentToController(1, myWidgetComponent, "", nil, nil, true)
				myWidgetComponent:K2_AttachToComponent(pawn.Arms,
					uevrUtils.fname_from_string("Hand_R"),
					2, -- SnapToTarget Location
					2, -- SnapToTarget Rotation
					2, -- SnapToTarget Scale  - inherits the weapon's scale
					true
				) 
				uevrUtils.set_component_relative_transform(myWidgetComponent, {X=8.630,Y=-10.680,Z=10.0}, {Pitch=-200,Roll=-189.140, Yaw=2}, {0.05,0.05,0.05}) -- z - forwad , y = right , x - up	
				currentRootElement = healthWidget:get_full_name()
			end
		end
	end
end


function attachAmmoBarOnce()
	if pawn ~= nil and pawn.HUD ~= nil and pawn.HUD.StatusCluster ~= nil  then
		--attach health bar to left arm
		local ammoWidget = pawn.HUD.StatusCluster.DaggerChargeHUD
		if ammoWidget ~= nil then
			if currentAmmoBar ~= ammoWidget:get_full_name() then				
				print("attach", ammoWidget:get_full_name())
				--print("parent was", ammoWidget:GetParent():get_full_name())
				ammoWidget:RemoveFromParent()
				--myWidgetComponent.CastShadow(false)
				if controllers.getController(0) ~= nil and controllers.getController(0).AttachChildren ~=nil then
					for i,attachChild in pairs(controllers.getController(0).AttachChildren) do
						if string.find(attachChild:get_full_name(), "WidgetComponent") and attachChild.Widget ~= nil and string.find(attachChild.Widget:get_full_name(), "DaggerChargeHUD") then
							table.remove(controllers.getController(0).AttachChildren, i) --remove  item
							attachChild:DetachFromParent()
						end
						
					end				
					--return -- already attached and defined 
				end
				myWidgetComponent = uevrUtils.createWidgetComponent(ammoWidget, {manualAttachment=false, removeFromViewport=true, relativeTransform = uevrUtils.get_transform({X=-17.830,Y=-1.280,Z=6.62},{X=0.0, Y=0.0, Z=0.0, W=1.0}, {X=0.1, Y=0.1, Z=0.1}), drawSize=vector_2(616, 520)}) 	
				controllers.attachComponentToController(0, myWidgetComponent, "", nil, nil, true)
				uevrUtils.set_component_relative_transform(myWidgetComponent, {X=-2.7,Y=6.270,Z=20}, {Pitch=-202,Roll=165,Yaw=-4}, {0.05,0.05,0.05}) -- z - forwad , y = right , x - up	
				currentAmmoBar = ammoWidget:get_full_name()
			end
		end
	end
end]]

function attachConsumableBarOnce()
	--print("pawn.HUD.ConsumableHUDX", pawn.HUD.ConsumableHUD:GetDesiredSize().X)
	--print("pawn.HUD.ConsumableHUDY", pawn.HUD.ConsumableHUD:GetDesiredSize().Y)

	if pawn ~= nil and pawn.HUD ~= nil then
		--attach health bar to left arm
		local ammoWidget = pawn.HUD.ConsumableHUD
		if ammoWidget ~= nil then
			if currentConsumableBar ~= ammoWidget:get_full_name() then				
				print("attach", ammoWidget:get_full_name())
				--print("parent was", ammoWidget:GetParent():get_full_name())
				ammoWidget:RemoveFromParent()
				--myWidgetComponent.CastShadow(false)
				if controllers.getController(0) ~= nil and controllers.getController(0).AttachChildren ~=nil then
					for i,attachChild in pairs(controllers.getController(0).AttachChildren) do
						if string.find(attachChild:get_full_name(), "WidgetComponent") and attachChild.Widget ~= nil and string.find(attachChild.Widget:get_full_name(), "ConsumableHUD") then
							table.remove(controllers.getController(0).AttachChildren, i) --remove  item
							attachChild:DetachFromParent()
						end
						
					end				
					--return -- already attached and defined 
				end
				myWidgetComponent = uevrUtils.createWidgetComponent(ammoWidget, {manualAttachment=false, removeFromViewport=true, relativeTransform = uevrUtils.get_transform({X=-17.830,Y=-1.280,Z=6.62},{X=0.0, Y=0.0, Z=0.0, W=1.0}, {X=0.1, Y=0.1, Z=0.1}), drawSize=vector_2(559.39910888672, 306.0)}) 	
				controllers.attachComponentToController(0, myWidgetComponent, "", nil, nil, true)
				--uevrUtils.set_component_relative_transform(myWidgetComponent, {X=3.100,Y=-4.240,Z=7.510}, {Pitch=-202,Roll=165,Yaw=-4}, {0.03,0.03,0.03}) -- original (test 5 and before)
				-- test 6: on the glove like the compass, mirrored to the other side of the wrist (compass transform, pos Y/Z negated, rolled 180 deg about controller X)
				local rot = {Pitch=203.410,Roll=84.8+180,Yaw=-130.340}
				pcall(function()
					local r = kismet_math_library:ComposeRotators(uevrUtils.rotator(203.410, -130.340, 84.8), uevrUtils.rotator(0, 0, 180))
					rot = {Pitch=r.Pitch, Yaw=r.Yaw, Roll=r.Roll}
				end)
				-- test 9: test-6 mirrored transform was invisible -> back to the original start values, now driven by item_hud_* sliders; two-sided so it can't vanish when seen from behind
				itemHudComponent = myWidgetComponent
				itemHudLast = nil
				pcall(function() myWidgetComponent:SetTwoSided(true) end)
				pcall(applyItemHudTransform, 0)
				pcall(function() uevr.params.functions.log_info("[HUD] consumable on left hand (item_hud sliders)") end)
				currentConsumableBar = ammoWidget:get_full_name()
			end
		end
	end
end


function attachCompassOnce()
	if pawn ~= nil and pawn.HUD ~= nil then
		--attach health bar to left arm
		local ammoWidget = pawn.HUD.CompassWidget
		if ammoWidget ~= nil then
			if currentCompass ~= ammoWidget:get_full_name() then				
				print("attach", ammoWidget:get_full_name())
				--print("parent was", ammoWidget:GetParent():get_full_name())
				ammoWidget:RemoveFromParent()
				--myWidgetComponent.CastShadow(false)
				if controllers.getController(0) ~= nil and controllers.getController(0).AttachChildren ~=nil then
					for i,attachChild in pairs(controllers.getController(0).AttachChildren) do
						if string.find(attachChild:get_full_name(), "WidgetComponent") and attachChild.Widget ~= nil and string.find(attachChild.Widget:get_full_name(), "CompassWidget") then
							table.remove(controllers.getController(0).AttachChildren, i) --remove  item
							attachChild:DetachFromParent()
						end
						
					end				
					--return -- already attached and defined 
				end
				myWidgetComponent = uevrUtils.createWidgetComponent(ammoWidget, {manualAttachment=false, removeFromViewport=true, relativeTransform = uevrUtils.get_transform({X=-17.830,Y=-1.280,Z=6.62},{X=0.0, Y=0.0, Z=0.0, W=1.0}, {X=0.1, Y=0.1, Z=0.1}), drawSize=vector_2(616, 520)}) 	
				controllers.attachComponentToController(0, myWidgetComponent, "", nil, nil, true)
				--uevrUtils.set_component_relative_transform(myWidgetComponent, {X=-2.7,Y=6.270,Z=20}, {Pitch=-202,Yaw=-4,Roll=165}, {0.05,0.05,0.05}) -- z - forwad , y = right , x - up	
				--uevrUtils.set_component_relative_transform(myWidgetComponent, {X=7.460,Y=-1.300,Z=0.210}, {Pitch=-14.380,Roll=-103.160,Yaw=57.200}, {0.01,0.01,0.01}) -- z - forwad , y = right , x - up
				uevrUtils.set_component_relative_transform(myWidgetComponent, {X=7.460,Y=-2.280,Z=0.210}, {Pitch=203.410,Roll=84.8,Yaw=-130.340}, {0.01,0.01,0.01}) -- z - forwad , y = right , x - up	
				currentCompass = ammoWidget:get_full_name()
				currentCompassWidgetComponent = myWidgetComponent
			end
		end
	end
end


-- test 15: compass offset sliders (position cm in controller space + extra rotation about the hand's own axes), applied on change
local compassKeys = {"compass_dx", "compass_dy", "compass_dz", "compass_rx", "compass_ry", "compass_rz"}
local compassVals, compassComp = nil, nil
function applyCompassOffset(delta)
	if currentCompassWidgetComponent == nil then return end
	local changed = compassComp ~= currentCompassWidgetComponent or compassVals == nil
	compassVals = compassVals or {0, 0, 0, 0, 0, 0}
	for i = 1, 6 do
		local v = configui.getValue(compassKeys[i]) or 0
		if v ~= compassVals[i] then compassVals[i] = v changed = true end
	end
	if not changed then return end
	compassComp = currentCompassWidgetComponent
	local c = compassVals
	uevrUtils.set_component_relative_transform(currentCompassWidgetComponent,
		{X = 7.460 + c[1], Y = -2.280 + c[2], Z = 0.210 + c[3]},
		hudRotation(203.41, -130.34, 84.8, c[4], c[5], c[6]), {0.01, 0.01, 0.01})
end

-- test 15: base (plain) material on the held weapon mesh: the game's equipment material shifts vertices with the view (sword/spear drifted off the hitbox)
local plainMat = {}
function applyPlainWeaponMaterial()
	local m = activeWeaponMesh
	if m == nil then return end
	pcall(function()
		local key = m:get_full_name()
		local n = m:GetNumMaterials()
		if configui.getValue("plain_weapon_mat") ~= false then
			local first = m:GetMaterial(0)
			if plainMat[key] ~= nil and first ~= nil and string.find(first:get_full_name(), "DefaultMaterial", 1, true) then return end
			local def = uevr.api:find_uobject("Material /Engine/EngineMaterials/DefaultMaterial.DefaultMaterial")
			if def == nil then return end
			if plainMat[key] == nil then
				local orig = {}
				for i = 0, n - 1 do orig[i] = m:GetMaterial(i) end
				plainMat[key] = orig
			end
			for i = 0, n - 1 do m:SetMaterial(i, def) end
		elseif plainMat[key] ~= nil then
			for i, mat in pairs(plainMat[key]) do m:SetMaterial(i, mat) end
			plainMat[key] = nil
		end
	end)
end

-- test 17: weapon sway fix. Equipment materials squash the held weapon toward the camera to fake a 60 deg viewmodel
-- FOV (Game_MPC scalar "FPFOV", rewritten natively every tick; camera FOV is 100, headset per-eye ~110). FPFOV = camera
-- FOV (100) verified to remove it (per-eye 110 did not). Must be written after the game tick, before rendering, so it
-- runs from the viewport-draw and stereo-view callbacks. "[FPFOV]" log: src, game value found, value set.
local fpf = {mpc = nil, kml = nil, world = nil, val = 0, nextT = 0, mtx = nil, calls = 0, fixes = 0, logT = 0, logs = 0}
local FPF_MPC = "MaterialParameterCollection /Game/BaseMaterials/Resources/Game_MPC.Game_MPC"
local function fpfovTarget()
	local set = configui.getValue("weapon_fpfov") or 0
	if set > 0 then return set end
	-- test 17: the headset per-eye FOV (~110, from the projection) did NOT fix it; 100 = the game camera FOV did
	local pc = uevr.api:get_player_controller(0)
	local cm = pc ~= nil and pc.PlayerCameraManager or nil
	local fov = cm ~= nil and cm:GetFOVAngle() or 0
	if type(fov) ~= "number" or fov < 20 or fov > 170 then return 0 end
	return fov
end
local function fpfovApply(src)
	if configui.getValue("weapon_fov_fix") == false then return end
	local now = os.clock()
	if now > fpf.nextT then -- refresh refs + target 1/s
		fpf.nextT = now + 1.0
		fpf.mpc = uevr.api:find_uobject(FPF_MPC)
		if fpf.kml == nil then fpf.kml = uevr.api:find_uobject("Class /Script/Engine.KismetMaterialLibrary"):get_class_default_object() end
		fpf.world = uevrUtils.get_world()
		fpf.val = fpfovTarget()
	end
	if fpf.mpc == nil or fpf.world == nil or fpf.val <= 0 then return end
	local cur = fpf.kml:GetScalarParameterValue(fpf.world, fpf.mpc, "FPFOV")
	fpf.calls = fpf.calls + 1
	if math.abs(cur - fpf.val) > 0.01 then
		fpf.kml:SetScalarParameterValue(fpf.world, fpf.mpc, "FPFOV", fpf.val)
		fpf.fixes = fpf.fixes + 1
	end
	if fpf.logs < 6 and now > fpf.logT then
		fpf.logs, fpf.logT = fpf.logs + 1, now + 10.0
		uevr.params.functions.log_info(string.format("[FPFOV] src=%s game=%.1f set=%.1f calls=%d fixes=%d", src, cur, fpf.val, fpf.calls, fpf.fixes))
	end
end
pcall(function() uevr.sdk.callbacks.on_pre_viewport_client_draw(function() pcall(fpfovApply, "draw") end) end)
pcall(function() uevr.sdk.callbacks.on_early_calculate_stereo_view_offset(function() pcall(fpfovApply, "stereo") end) end)

-- test 16: weapon sway driver discovery. The equipment master material moves vertices with the view and has no
-- instance params for it; MCP can't read collection parameter names, so log them once, 5 s into play:
-- "[MPC] <collection> s<i>/v<i> <name> default=<d> now=<world value>"
local MPC_LIST = {
	"MaterialParameterCollection /Game/BaseMaterials/Resources/Game_MPC.Game_MPC",
	"MaterialParameterCollection /Game/BaseMaterials/Resources/PixelFilter_MPC.PixelFilter_MPC",
	"MaterialParameterCollection /Game/VFX/Post/Environment_MPC.Environment_MPC",
	"MaterialParameterCollection /Game/Blueprints/ENVControl/Retro_PP_Fog_MPC.Retro_PP_Fog_MPC",
}
local mpcDumpT = 0.0
function mpcDump()
	local log = uevr.params.functions.log_info
	local kml = uevrUtils.find_default_instance("Class /Script/Engine.KismetMaterialLibrary")
	local world = uevrUtils.get_world()
	for _, path in ipairs(MPC_LIST) do
		local mpc = uevr.api:find_uobject(path)
		local short = path:match("%.([%w_]+)$")
		if mpc == nil then log("[MPC] " .. short .. " not loaded") else
			local ok, err = pcall(function()
				for i, p in ipairs(mpc.ScalarParameters) do
					local now = "?"
					pcall(function() now = string.format("%.3f", kml:GetScalarParameterValue(world, mpc, p.ParameterName)) end)
					log(string.format("[MPC] %s s%d %s default=%.3f now=%s", short, i, p.ParameterName:to_string(), p.DefaultValue, now))
				end
				for i, p in ipairs(mpc.VectorParameters) do
					local d, now = p.DefaultValue, "?"
					pcall(function() local v = kml:GetVectorParameterValue(world, mpc, p.ParameterName) now = string.format("%.2f,%.2f,%.2f,%.2f", v.R, v.G, v.B, v.A) end)
					log(string.format("[MPC] %s v%d %s default=%.2f,%.2f,%.2f,%.2f now=%s", short, i, p.ParameterName:to_string(), d.R, d.G, d.B, d.A, now))
				end
			end)
			if not ok then log("[MPC] " .. short .. " error " .. tostring(err)) end
		end
	end
end
function mpcDumpTick(delta)
	if mpcDumpT < 0 then return end
	mpcDumpT = mpcDumpT + (delta or 0)
	if mpcDumpT > 5.0 then mpcDumpT = -1 mpcDump() end
end

-- test 16: dev bridge, live discovery without restarts: MCP lua runs uevr.api.dispatch_lua_event("qd_exec", "<lua>");
-- the chunk runs in THIS state (globals + QD); qdlog(...) and the return value go to log.txt as "[EXEC]" lines
QD = {xhair = xhair, swing = swingDetector, plainMat = plainMat}
function qdlog(...)
	local t = table.pack(...)
	for i = 1, t.n do t[i] = tostring(t[i]) end
	uevr.params.functions.log_info("[EXEC] " .. table.concat(t, " ", 1, t.n))
end
pcall(function()
	uevr.sdk.callbacks.on_lua_event(function(name, data)
		if name ~= "qd_exec" then return end
		local fn, err = load(data, "qd_exec")
		if fn == nil then qdlog("load error", err) return end
		local ok, res = pcall(fn)
		qdlog("ok=" .. tostring(ok), res)
	end)
	uevr.params.functions.log_info("[EXEC] bridge ready")
end)
-- test 20: dev helpers for the bridge (self-testing with the fake headset, tools/fakevr). No new top-level locals.
QD.T20 = T20
QD.S6 = T20.S6
QD.dev = {}
function QD.dev.v3(v) if v == nil then return "nil" end return string.format("(%.0f,%.0f,%.0f)", v.X or 0, v.Y or 0, v.Z or 0) end
function QD.dev.r3(r) if r == nil then return "nil" end return string.format("(%.0f,%.0f,%.0f)", r.Pitch or 0, r.Yaw or 0, r.Roll or 0) end
function QD.dev.state()
	local d, out = QD.dev, {}
	local pawn = api:get_local_pawn(0)
	local pc = api:get_player_controller(0)
	out[#out + 1] = "normalPlay=" .. tostring(normalPlay) .. " regular=" .. tostring(regularPlayLast)
	if pawn ~= nil then out[#out + 1] = "pawn=" .. d.v3(pawn:K2_GetActorLocation()) .. d.r3(pawn:K2_GetActorRotation()) end
	if pc ~= nil then pcall(function() out[#out + 1] = "ctrl=" .. d.r3(pc:GetControlRotation()) end) end
	pcall(function() local m = pc.PlayerCameraManager out[#out + 1] = "cam=" .. d.v3(m:GetCameraLocation()) .. d.r3(m:GetCameraRotation()) end)
	for i = 0, 2 do
		local c = controllers.getController(i, true)
		if c ~= nil then out[#out + 1] = "c" .. i .. "=" .. d.v3(c:K2_GetComponentLocation()) .. d.r3(c:K2_GetComponentRotation()) end
	end
	pcall(function() out[#out + 1] = "weapon=" .. (activeWeapon ~= nil and activeWeapon:get_class():get_fname():to_string() or "nil") end)
	pcall(function() out[#out + 1] = "mesh=" .. (activeWeaponMesh ~= nil and activeWeaponMesh:get_fname():to_string() or "nil") end)
	out[#out + 1] = string.format("pickables=%d cands=%d target=%s held=%s laser=%s", #currentLevelPickables, T20.pk and T20.pk.n or -1, tostring(currentAvailablePickable ~= nil), tostring(pickableHeld), tostring(showLaser))
	return table.concat(out, " ")
end
function QD.dev.items(n) -- nearest pickup candidates (refreshed by the pickup tick): distance from the camera + centre
	local out, cs = {}, T20.pk and T20.pk.cands or {}
	local cam = api:get_player_controller(0).PlayerCameraManager:GetCameraLocation()
	local idx = {}
	for i = 1, (T20.pk and T20.pk.n or 0) do idx[#idx + 1] = i end
	local function dist(i) local c = cs[i] return math.sqrt((c.x - cam.X) ^ 2 + (c.y - cam.Y) ^ 2 + (c.z - cam.Z) ^ 2) end
	table.sort(idx, function(a, b) return dist(a) < dist(b) end)
	for k = 1, math.min(n or 5, #idx) do
		local c = cs[idx[k]]
		out[#out + 1] = string.format("#%d d=%.0f (%.0f,%.0f,%.0f) r=%.0f skip=%s", idx[k], dist(idx[k]), c.x, c.y, c.z, c.r or 0, tostring(c.skip))
	end
	return table.concat(out, " | ")
end
function QD.dev.weapons() -- weapon scripts the weapon system knows (index for EquipSpecifiedWeapon)
	local out = {}
	local ws = api:get_local_pawn(0).WeaponSelection
	for i, w in ipairs(ws.AllWeapons) do
		out[#out + 1] = (i - 1) .. "=" .. w:get_class():get_fname():to_string() .. (w == activeWeapon and "*" or "")
	end
	return #out .. " " .. table.concat(out, " ")
end
function QD.dev.face(x, y) -- turn the player (control yaw) towards a world point
	local pc = api:get_player_controller(0)
	local p = api:get_local_pawn(0):K2_GetActorLocation()
	pc:SetControlRotation({Pitch = 0, Yaw = math.deg(math.atan(y - p.Y, x - p.X)), Roll = 0})
	return "yaw=" .. math.deg(math.atan(y - p.Y, x - p.X))
end

-- test 20: after a script reload the previous instance's helper meshes (pickup beam, debug hitbox cubes) stay in the
-- world. Once per load: destroy the plain-Actor owners of engine Cylinder / wireframe Cube components.
function T20.cleanupStale()
	T20.cleaned = true
	local n, seen = 0, 0
	local ok, err = pcall(function()
		local comps = uevrUtils.find_all_of("Class /Script/Engine.StaticMeshComponent", false) or {}
		for _, c in ipairs(comps) do
			seen = seen + 1
			pcall(function()
				local sm = c.StaticMesh
				local nm = sm ~= nil and sm:get_full_name() or ""
				local stale = false
				if (nm == "StaticMesh /Engine/BasicShapes/Cylinder.Cylinder" or nm == "StaticMesh /Engine/BasicShapes/Sphere.Sphere") and c:GetCollisionEnabled() == 0 then -- Sphere: the orange aim dot (s4)
					local m = c:GetMaterial(0) -- our beam: a dynamic instance of the engine debug mesh material
					local parent = m ~= nil and m.Parent or nil
					stale = parent ~= nil and string.find(parent:get_full_name(), "DebugMeshMaterial", 1, true) ~= nil
				elseif nm == "StaticMesh /Engine/BasicShapes/Cube.Cube" then
					local m = c:GetMaterial(0)
					stale = m ~= nil and string.find(m:get_full_name(), "WireframeMaterial", 1, true) ~= nil
				end
				if stale then
					local o = c:GetOwner()
					if o ~= nil and o:get_class():get_fname():to_string() == "Actor" then o:K2_DestroyActor() n = n + 1 end
				end
			end)
		end
	end)
	uevr.params.functions.log_info(string.format("[CLEANUP] stale helper meshes destroyed=%d of %d ok=%s %s", n, seen, tostring(ok), ok and "" or tostring(err)))
end

function applyNormalModeSettings(delta)
	if not T20.cleaned then if T20.reloaded then T20.cleanupStale() else T20.cleaned = true end end
		
	vr.set_mod_value("VR_2DScreenMode", false)
	--vr.set_mod_value("UI_Distance", 2.0)
	--vr.set_mod_value("UI_Distance", 2.8)
	vr.set_mod_value("UI_FollowView", "true")
	pcall(function()
		local uiY = configui.getValue("ui_y_offset")
		if uiY ~= nil then vr.set_mod_value("UI_Y_Offset", string.format("%.3f", uiY)) end
	end)
	if nativeDodgeAimLeft > 0 then
		nativeDodgeAimLeft = nativeDodgeAimLeft - (delta or 0)
		if nativeDodgeAimLeft <= 0 then pcall(restoreDodgeFacing) end
	end
	if nativeDodgeAimLeft > 0 then
		vr.set_mod_value("VR_AimMethod", "1") -- test 9: HMD aim while the native dodge plays
	elseif showLaser then
		vr.set_mod_value("VR_AimMethod", "3")
		if currentCompass ~= nil and not aimDotEnabled() then -- test 7: compass hidden only when the visible laser is on
			currentCompassWidgetComponent:SetVisibility(false, true)
		end
	else
		vr.set_mod_value("VR_AimMethod", "2")
		if currentCompass ~= nil then
			currentCompassWidgetComponent:SetVisibility(true, true)
		end
	end
	vr.set_mod_value("VR_RoomscaleMovement", configui.getValue("roomscale") == false and "0" or "1") -- test 8: A/B toggle
	vr.set_mod_value("VR_MovementOrientation", "1") -- 1 = HMD (0 = follows aim method / hand)
	vr.set_mod_value("VR_DecoupledPitch", "1")
	--vr.set_mod_value("VR_CameraForwardOffset", "0.0000000")
	
	--vr.set_mod_value("VR_CameraRightOffset", "0.000000")
	--vr.set_mod_value("VR_CameraUpOffset", "0.000000")				
	--vr.set_mod_value("VR_LerpCameraYaw", "false")

	
    --vr.set_mod_value("VR_DecoupledPitchUIAdjust", "false")
	UEVR_UObjectHook.set_disabled(false)
	
	normalPlay = isRegularPlay() 
	if configui.getValue("6dof_right") == nil or configui.getValue("6dof_right") == false then
		local pawn = api:get_local_pawn(0)
		if pawn ~= nil and pawn.Arms ~=nil then					
			pawn.Arms:SetRenderInMainPass(true)
			pawn.Arms:SetRenderCustomDepth(true)
			pawn.Arms:HideBoneByName(uevrUtils.fname_from_string("UpperArm_L"), 0)
			pawn.Arms.RelativeScale3D = {X= 1.2, Y = 1.2, Z = 1.2}
			--print("controllers.getController(1)", controllers.getController(1):get_full_name())
			for _,child in ipairs(controllers.getController(1).AttachChildren) do
				if string.find(child:get_full_name(),"Poseable") then
					child.bHiddenInGame = true
				end
			end
			if activeLeftWeaponMesh ~= nil then
				pcall(function() activeLeftWeaponMesh.bHiddenInGame = true end)
			end
		end
	else
		local pawn = api:get_local_pawn(0)
		if pawn ~= nil and pawn.Arms ~=nil then					
			pawn.Arms:SetRenderInMainPass(false)
			pawn.Arms:SetRenderCustomDepth(false)
		end
	end 
	
	pcall(disbaleAttackCooldown)
	pcall(disbaleMeleeFX)
	pcall(speedupAttackComboAnims)

	pcall(attachHitboxesToWeaponTip)
	local meleeOk, meleeErr = pcall(checkMeleeSwing, delta)
	if not meleeOk then meleeReportError(meleeErr) end
	if not needToPupolatePickables and not pickableHeld then
		pcall(handleLeftHandPickables)
	end
	-- test 20: pickup_auto_take: once the grabbed item has flown into the hand (+0.15 s to see it), take it
	if pickableHeld and configui.getValue("pickup_assist") ~= false and configui.getValue("pickup_auto_take") ~= false
		and ((pickupFlyState == nil and os.clock() - T20.heldT > pickupFlyDuration + 0.15) or os.clock() - T20.heldT > 1.5) then
		local okT, errT = pcall(pickupPickable, nil)
		pickableHeld = false
		uevr.params.functions.log_info("[PICKUP] auto take ok=" .. tostring(okT) .. (okT and "" or (" " .. tostring(errT))))
	end
	
	--[[if inPickupDialog then
		checkIfPickablePickedup()
		inPickupDialog = false
	end]]
	local previousLastTouchedSaveArea = lastTouchedSaveArea
	--[[local succes, result = pcall(getLastTouchedSaveArea)
	if succes then 
		lastTouchedSaveArea = result
	else
		lastTouchedSaveArea = nil
	end]]
	lastTouchedSaveArea = getLastTouchedSaveArea()
	
	if needToPupolatePickables or (lastTouchedSaveArea ~= nil and previousLastTouchedSaveArea ~= lastTouchedSaveArea) then
		print("previousLastTouchedSaveArea", previousLastTouchedSaveArea)
		print("lastTouchedSaveArea", lastTouchedSaveArea)
		populateCurrentLevelPickables()
	end
	hands.hideHands(false)
	
	--[[local game_engine_class = api:find_uobject("Class /Script/Engine.GameEngine")
	local game_engine = UEVR_UObjectHook.get_first_object_by_class(game_engine_class)

	local viewport = game_engine.GameViewport
	if viewport == nil then
		--print("Viewport is nil")
		return
	end
	local world = viewport.World
	local level = world.PersistentLevel
	pcall(populateCurrentLevelPickables, level:get_full_name())]]
	if canInteract() then
		-- test 20: no extra buzz when pickup_assist already ticked for its own target
		if not interactBuzzed and (currentAvailablePickable == nil or configui.getValue("pickup_assist") == false) then
			uevrUtils.triggerHapticVibration(Handed.Left, 0, 0.3, 300, 0.6) --quick buzz on first time an item is available to pickup
		end
		interactBuzzed = true
	else
		interactBuzzed = false
	end
	--pcall(attachHealthBarOnce)
	--pcall(attachWeaponChargeBarOnce)
	--pcall(attachRootElementOnce)
	pcall(attachStatusBarOnce)
	pcall(applyHpHudTransform)
	pcall(applyItemHudTransform, delta)
	pcall(applyCompassOffset, delta)
	plainMatT = (plainMatT or 0) + (delta or 0)
	if plainMatT > 1 then plainMatT = 0 applyPlainWeaponMaterial() end
	pcall(hmdFollowDiag, delta)
	pcall(hmdPosDiag, delta)
	pcall(updateKnifeModelVisibility)
	pcall(hudDumpTick, delta)
	pcall(attachConsumableBarOnce)
	pcall(attachCompassOnce)
	if activeLeftWeaponMesh ~= nil then
		pcall(attachAmmoBarOnce)
	end
end


uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	hookFuntionsForRuntimeGeneratedClasses()		
	pcall(updateDebugHitboxes, delta)
	pcall(updateChargeBars)
	pcall(applyLateUpdate, delta)
	local aimOk, aimErr = pcall(updateAimDot) -- hides itself when showLaser is false (menus/cutscenes clear it)
	if not aimOk and aimErr ~= lastAimErr then lastAimErr = aimErr uevr.params.functions.log_info("[XHAIR] updateAimDot error: " .. tostring(aimErr)) end
	regularPlayLast = false
	T20.ikPlay = false
	if isMainMenu() then
		applyMainMenuSettings()
	elseif isInCutScene() then
		applyCinematicSettings()
	elseif isInSaveMenu() or isInShopMenu() or isInInventoryMenu() then
		applyMenuSettings()
	else ---regular play
		regularPlayLast = not uevrUtils.isGamePaused()
		T20.ikPlay = true
		if dodgeCooldownRemaining > 0.0 then
			dodgeCooldownRemaining = dodgeCooldownRemaining - delta
		end
		applyNormalModeSettings(delta)
	end
	-- test 21: consumable belt (libs/qd_belt.lua), regular unpaused play only
	if T20.belt ~= nil then
		local okB, errB = pcall(regularPlayLast and T20.belt.tick or T20.belt.hideAll, delta)
		if not okB and not T20.beltErr then T20.beltErr = true uevr.params.functions.log_info("[BELT] error: " .. tostring(errB)) end
	end
	-- step 3: IK arms: only with the option and motion controls on; hidden outside regular play
	if T20.ik ~= nil then
		local okI, errI = pcall(T20.ik.tick, configui.getValue("ik_arms") == true and configui.getValue("6dof_right") == true, T20.ikPlay == true, delta)
		if not okI and not T20.ikErr then T20.ikErr = true uevr.params.functions.log_info("[IK] error: " .. tostring(errI)) end
	end
end)



function on_xinput_get_state(retval, user_index, state)
	if hands.exists() then
		local isHoldingWeapon = activeWeaponMesh ~= nil
		--print("isHoldingWeapon", isHoldingWeapon)
		local hand = Handed.Right
		hands.handleInput(state, isHoldingWeapon, hand)
		
		-- test 21: second call removed. The offHHand typo (nil -> Handed.Right) made it drive the RIGHT hand as empty-handed,
		-- so releasing grip or the thumbrest opened the fingers around the weapon; fixing the typo would do the same via the
		-- off-hand branch. The call above already animates the left hand (off hand); a held pickup has no left handler.
	end
end

function initHands()
	hands.reset()

	local paramsFile = 'hands_parameters' -- found in the [game profile]/data directory
	local configName = 'Main' -- the name you gave your config
	local animationName = 'Shared' -- the name you gave your animation
	hands.createFromConfig(paramsFile, configName, animationName)
	configuration = json.load_file(paramsFile .. ".json")
	animations = configuration["animations"][animationName]
end

--interaction
function canInteract()
	local playerController = uevr.api:get_player_controller(0)
	if playerController ~= nil and playerController.MyHUD ~= nil then
		return playerController.MyHUD.CanInteract
	end
end


--dodge
local dodge = {
	active = false,
	startPos = nil,
	dirX = 0, dirY = 0,
	speed = DODGE_FORCE,
	targetDist = 0,
}

local function normalizeStickAxis(raw)
	if math.abs(raw) < STICK_DEADZONE then return 0.0 end
	return raw / STICK_MAX
end	

local function beginDodge(state)
	local pawn = api:get_local_pawn(0)
	if pawn == nil then return end

	-- Rule checks: cooldown + not falling
	if dodgeCooldownRemaining > 0.0 then return end
	if pawn.CharacterMovement ~= nil and pawn.CharacterMovement.MovementMode == 3 then return end -- MOVE_Falling

	local playerController = uevr.api:get_player_controller(0)
	if playerController == nil then return end

	local controlRotation = playerController:GetControlRotation()
	local yawOnlyRotation = uevrUtils.get_reuseable_struct_object("ScriptStruct /Script/CoreUObject.Rotator") -- or build one directly if you have a rotator constructor handy
	yawOnlyRotation.Pitch = 0
	local hmdYaw = controlRotation.Yaw
	local okH, headYaw = pcall(function() local h = controllers.getController(2); return h ~= nil and h:K2_GetComponentRotation().Yaw or nil end) -- dodge relative to HMD, not hand
	if okH and headYaw ~= nil then hmdYaw = headYaw end
	yawOnlyRotation.Yaw = hmdYaw
	yawOnlyRotation.Roll = 0

	local forwardVector = kismet_math_library:GetForwardVector(yawOnlyRotation)
	local rightVector = kismet_math_library:GetRightVector(yawOnlyRotation)

	-- CurrentMovementInput.Y = forward/back stick axis, .X = strafe axis (matches C++ naming)
	local inputY = normalizeStickAxis(state.Gamepad.sThumbLY)
	local inputX = normalizeStickAxis(state.Gamepad.sThumbLX)
	

	local dodgeDirX = forwardVector.X * inputY + rightVector.X * inputX
	local dodgeDirY = forwardVector.Y * inputY + rightVector.Y * inputX

	-- If stick is neutral, default to dodging backward
	if math.abs(dodgeDirX) < 0.0001 and math.abs(dodgeDirY) < 0.0001 then
		dodgeDirX = -forwardVector.X
		dodgeDirY = -forwardVector.Y
	else
		local len = math.sqrt(dodgeDirX * dodgeDirX + dodgeDirY * dodgeDirY)
		dodgeDirX = dodgeDirX / len
		dodgeDirY = dodgeDirY / len
	end

	local launchVelocity = uevrUtils.vector(dodgeDirX * DODGE_FORCE, dodgeDirY * DODGE_FORCE, 0.0)
	if pawn.LaunchCharacter ~= nil then
		pawn:LaunchCharacter(launchVelocity, true, false) -- override XY, keep existing Z/gravity
	end

	dodgeCooldownRemaining = DODGE_COOLDOWN
	
	state.Gamepad.sThumbLY = 0 
	state.Gamepad.sThumbLX = 0
	print("try dodge")
	pcall(function() uevr.params.functions.log_info(string.format("[DODGE] hmdYaw=%.0f usedHead=%s ctrlYaw=%.0f dirYaw=%.0f", hmdYaw, tostring(okH and headYaw ~= nil), controlRotation.Yaw, math.deg(math.atan(dodgeDirY, dodgeDirX)))) end)

	dodge.dirX = dodgeDirX
	dodge.dirY = dodgeDirY
	dodge.speed = DODGE_FORCE
	dodge.targetDist = 550	
	dodge.startPos = pawn:K2_GetActorLocation()
	dodge.active = true
end

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
	if not dodge.active then return end
	local pawn = api:get_local_pawn(0)
	if pawn == nil then dodge.active = false return end
	local currPos = pawn:K2_GetActorLocation()
	--[[local sx = currPos.X - dodge.startPos.X
	local sy = currPos.Y - dodge.startPos.Y
	local sz = currPos.Z - dodge.startPos.Z]]
	local travelled = mathLib.vectorDistance(currPos, dodge.startPos)
	if travelled >= dodge.targetDist then
		-- snap to the exact end point of the dodge line
		--[[local f = dodge.targetDist / travelled
		local clamped = uevrUtils.vector(
			dodge.startPos.X + sx * f,
			dodge.startPos.Y + sy * f,
			dodge.startPos.Z + sz * f)
		pawn:K2_SetActorLocation(clamped, false, reusable_hit_result, true)]]
		-- kill the horizontal velocity, keep the vertical so you still fall
		pawn:LaunchCharacter(uevrUtils.vector(0, 0, pawn:GetVelocity().Z), true, false)
		dodge.active = false
		return
	end
	--[[
	-- only act if the slope pushed us past the launch speed:
	-- bXYOverride=true REPLACES the XY velocity, so the slope cannot add to it
	local curVelocity = pawn:GetVelocity()
	local curVelocitySpeed = math.sqrt(curVelocity.X * curVelocity.X + curVelocity.Y * curVelocity.Y)
	if curVelocity > dodge.speed * 1.02 then
		pawn:LaunchCharacter(
			uevrUtils.vector(dodge.dirX * dodge.speed, dodge.dirY * dodge.speed, v.Z),
			true, false)
	end]]
end)

	
local function tryDodge(state)
	local pawn = api:get_local_pawn(0)
	if pawn == nil then return end

	-- Rule checks: cooldown + not falling
	if dodgeCooldownRemaining > 0.0 then return end
	if pawn.CharacterMovement ~= nil and pawn.CharacterMovement.MovementMode == 3 then return end -- MOVE_Falling

	local playerController = uevr.api:get_player_controller(0)
	if playerController == nil then return end

	local controlRotation = playerController:GetControlRotation()
	local yawOnlyRotation = uevrUtils.get_reuseable_struct_object("ScriptStruct /Script/CoreUObject.Rotator") -- or build one directly if you have a rotator constructor handy
	yawOnlyRotation.Pitch = 0
	yawOnlyRotation.Yaw = controlRotation.Yaw
	yawOnlyRotation.Roll = 0

	local forwardVector = kismet_math_library:GetForwardVector(yawOnlyRotation)
	local rightVector = kismet_math_library:GetRightVector(yawOnlyRotation)

	-- CurrentMovementInput.Y = forward/back stick axis, .X = strafe axis (matches C++ naming)
	local inputY = normalizeStickAxis(state.Gamepad.sThumbLY)
	local inputX = normalizeStickAxis(state.Gamepad.sThumbLX)
	

	local dodgeDirX = forwardVector.X * inputY + rightVector.X * inputX
	local dodgeDirY = forwardVector.Y * inputY + rightVector.Y * inputX

	-- If stick is neutral, default to dodging backward
	if math.abs(dodgeDirX) < 0.0001 and math.abs(dodgeDirY) < 0.0001 then
		dodgeDirX = -forwardVector.X
		dodgeDirY = -forwardVector.Y
	else
		local len = math.sqrt(dodgeDirX * dodgeDirX + dodgeDirY * dodgeDirY)
		dodgeDirX = dodgeDirX / len
		dodgeDirY = dodgeDirY / len
	end

	local launchVelocity = uevrUtils.vector(dodgeDirX * DODGE_FORCE, dodgeDirY * DODGE_FORCE, 0.0)
	if pawn.LaunchCharacter ~= nil then
		pawn:LaunchCharacter(launchVelocity, true, false) -- override XY, keep existing Z/gravity
	end

	dodgeCooldownRemaining = DODGE_COOLDOWN
	
	state.Gamepad.sThumbLY = 0 
	state.Gamepad.sThumbLX = 0
	print("try dodge")
end

function toggleInteractionLaser()
	if showLaser == false then
		showLaser = true
	else
		showLaser = false
	end
	interaction.showInteractionLaser(showLaser and not aimDotEnabled())
end

-- Script-side polling of UEVR actions that never arrive in XINPUT (D-pad, system/menu, B). Discovery log: [ACT] on change.
local ACT_MAP = {
	{"DPad_Up", 0x0001}, {"DPad_Down", 0x0002}, {"DPad_Left", 0x0004}, {"DPad_Right", 0x0008},
	-- Select/View -> Back bit -> openInventory. UEVR's get_action_handle returns nil for Teleport/TouchpadClick/Squeeze
	-- (not in its action map), so the SteamVR binding sends left View to AButtonTouchLeft (exposed, otherwise unbound).
	{"AButtonTouchLeft", 0x0020},
	{"SystemButton", 0x0010}, -- BButtonRight removed: it fires on every face button (Test 3 log); real B arrives as 0x2000
}
local actHandles, actLast, actBits = {}, {}, 0
local function pollOneAction(name)
	local vr = uevr.params.vr
	local h = actHandles[name]
	if h == nil then h = vr.get_action_handle("/actions/default/in/" .. name) or false; actHandles[name] = h end
	if h == false then return false end
	return vr.is_action_active(h, vr.get_left_joystick_source()) or vr.is_action_active(h, vr.get_right_joystick_source())
end
local function pollActions()
	local bits = 0
	for i = 1, #ACT_MAP do
		local e = ACT_MAP[i]
		local ok, down = pcall(pollOneAction, e[1])
		down = ok and down == true
		if down ~= actLast[e[1]] then
			actLast[e[1]] = down
			pcall(function() uevr.params.functions.log_info("[ACT] " .. e[1] .. "=" .. tostring(down)) end)
		end
		if down then bits = bits | e[2] end
	end
	return bits
end

-- test 21: consumable belt. Registered before the main xinput callback so a belt grab can swallow its grip button.
pcall(function()
	T20.belt = require("libs/qd_belt")
	T20.belt.init({uevrUtils = uevrUtils, controllers = controllers, configui = configui, hosts = XHAIR_HOSTS, hr = reusable_hit_result,
		log = function(m) uevr.params.functions.log_info(m) end})
	QD.belt = T20.belt
end)
-- step 3: IK arms. require only works while the script loads, so the IK lib (and its side modules) is loaded only when the
-- option is already on: off = nothing new runs and pawn.Arms stays hidden as before.
if configui.getValue("ik_arms") == true then
	T20.ikOk, T20.ikLoadErr = pcall(function()
		T20.ik = require("libs/qd_ik")
		T20.ik.init({ik = require("libs/ik"), uevrUtils = uevrUtils, controllers = controllers, hands = hands, hr = reusable_hit_result,
			log = function(m) uevr.params.functions.log_info(m) end})
		QD.ik = T20.ik
	end)
	if not T20.ikOk then T20.ik = nil uevr.params.functions.log_info("[IK] load error: " .. tostring(T20.ikLoadErr)) end
end
uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
	if inputIndex ~= nil and user_index ~= inputIndex then return end -- skip the 2nd, all-zero call (see main callback)
	if T20.belt ~= nil then pcall(T20.belt.onXInput, state) end
end)

uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
	if (state ~= nil) then
		do -- the callback fires twice per frame; the 2nd call is all-zero and made RT press/release every frame. Lock to the index with data.
			local g = state.Gamepad
			if inputIndex == nil then
				if g.wButtons ~= 0 or g.bRightTrigger > 30 or g.bLeftTrigger > 30 or math.abs(g.sThumbLX) > 8000 or math.abs(g.sThumbLY) > 8000 then
					inputIndex = user_index
					pcall(function() uevr.params.functions.log_info("[INPUT] locked user_index=" .. tostring(user_index)) end)
				end
			elseif user_index ~= inputIndex then
				return
			end
		end
		do -- discovery: log button mask changes (only on change)
			local mask = state.Gamepad.wButtons
			if mask ~= lastLoggedButtons then
				lastLoggedButtons = mask
				pcall(function() uevr.params.functions.log_info(string.format("[INPUT] idx=%s buttons=0x%04X normalPlay=%s", tostring(user_index), mask, tostring(normalPlay))) end)
			end
		end
		if T20.xHeld and normalPlay ~= true then -- test 20: a take may open a popup while X is still down
			if state.Gamepad.wButtons & XINPUT_GAMEPAD_X ~= 0 then state.Gamepad.wButtons = state.Gamepad.wButtons & ~XINPUT_GAMEPAD_X else T20.xHeld = false end
		end
		if normalPlay == true then
			local okA, extra = pcall(pollActions)
			if okA and extra ~= 0 then state.Gamepad.wButtons = state.Gamepad.wButtons | extra end
			-- test 12: fallback for Select (left View, see ACT_MAP) -> R3 = Back/inventory (frame_layout: R3 is otherwise unused). L3+R3 is the UEVR menu: leave it alone.
			if configui.getValue("frame_layout") ~= false and state.Gamepad.wButtons & 0x00C0 == 0x0080 then
				state.Gamepad.wButtons = (state.Gamepad.wButtons & ~0x0080) | 0x0020
			end
			if state.Gamepad.wButtons & 0x0020 ~= 0 then
				if not backHeld then backHeld = true; pcall(openInventory, "Back") end
				state.Gamepad.wButtons = state.Gamepad.wButtons & ~0x0020
			else
				backHeld = false
			end
			if state.Gamepad.wButtons & XINPUT_GAMEPAD_RIGHT_THUMB ~= 0 then
				if not rightThumbHeld and configui.getValue("frame_layout") == false then
					toggleInteractionLaser()
					rightThumbHeld = true				
				end
			else
				rightThumbHeld = false	
			end
			--if configui.getValue("6dof_right") ~= nil and configui.getValue("6dof_right") == true then
				if activeWeapon ~= nil then
					-- hysteresis (press >200, release <100) so an analog trigger hovering near the threshold can't re-fire
					if state.Gamepad.bRightTrigger >200 or (rightTriggerHeld == true and state.Gamepad.bRightTrigger > 100) then
						if rightTriggerHeld == false then --need to only call once, since calling ti again, cancels current call
							activeWeapon:AttackPressed()
							rtPressedAt = meleeClock
							rtSwingReleased = false
							pcall(meleeLog, "RT AttackPressed")
						end
						rightTriggerHeld = true
						rtLowSince = nil
						state.Gamepad.bRightTrigger = 0
					elseif rightTriggerHeld == true and (rtLowSince == nil or meleeClock - rtLowSince < 0.06) then
						-- release debounce: ignore single-frame drops so holding RT can charge
						if rtLowSince == nil then rtLowSince = meleeClock end
						state.Gamepad.bRightTrigger = 0
					elseif rightTriggerHeld == true then
						rtLowSince = nil
						if rtSwingReleased then
							pcall(meleeLog, string.format("RT up held=%.2fs (already released by swing)", meleeClock - rtPressedAt))
						else
							attachHitboxesToWeaponTip()
							local ci = chargeInfo()
							activeWeapon:AttackReleased()
							pcall(meleeLog, string.format("RT AttackReleased held=%.2fs %s", meleeClock - rtPressedAt, ci))
						end
						rtSwingReleased = false
						rightTriggerHeld = false
					end
					if configui.getValue("frame_layout") ~= false and configui.getValue("l2_native_dodge") ~= false then
						-- test 9: native L2 dodge (has the animation), aimed away from the HMD: face head yaw first, aim = HMD while it plays
						-- test 16: with motion melee on, L2 only arms; the stab itself fires (checkMeleeSwing -> l2StabFire)
						local stabMode = configui.getValue("l2_stab_gesture") ~= false and configui.getValue("6dof_right") == true
						if state.Gamepad.bLeftTrigger > 200 or (l2DodgeHeld and state.Gamepad.bLeftTrigger > 100) then
							if not l2DodgeHeld then
								if stabMode then
									l2StabArmed = true
									pcall(meleeLog, "L2 armed: stab to alt attack")
								else
									local okD, errD = pcall(startNativeDodge, 0, "L2")
									if not okD then pcall(meleeLog, "dodge error " .. tostring(errD)) end
								end
							end
							l2StabSeen = meleeClock
							l2DodgeHeld = true
							state.Gamepad.bLeftTrigger = 0
						elseif l2DodgeHeld then
							if l2StabArmed then
								l2StabArmed = false -- a stab's alt attack is released by its own timer
							else
								activeWeapon:AltAttackReleased()
							end
							l2DodgeHeld = false
						end
					elseif configui.getValue("frame_layout") ~= false then
						-- L2 = launched dodge relative to the HMD (no animation)
						if state.Gamepad.bLeftTrigger > 200 or (l2DodgeHeld and state.Gamepad.bLeftTrigger > 100) then
							if not l2DodgeHeld and (configui.getValue("disable_dodge") == nil or configui.getValue("disable_dodge") == false) then
								pcall(beginDodge, state)
							end
							l2DodgeHeld = true
						else
							l2DodgeHeld = false
						end
						state.Gamepad.bLeftTrigger = 0
					elseif state.Gamepad.bLeftTrigger >200 then
						if leftTriggerHeld == false then --need to only call once, since calling ti again, cancels current call
							activeWeapon:AltAttackPressed()
						end
						leftTriggerHeld = true
						state.Gamepad.bLeftTrigger = 0
					elseif leftTriggerHeld == true then
						attachHitboxesToWeaponTip()
						activeWeapon:AltAttackReleased()
						leftTriggerHeld = false
					end
				end
			--end
			local okP, gamePaused = pcall(uevrUtils.isGamePaused)
			if configui.getValue("frame_layout") ~= false and not (okP and gamePaused) then
				-- Steam Frame layout: L2 = dodge (above), B passes through (native). Physical D-pad comes via SteamVR binding -> UEVR DPad_* actions (pollActions).
				-- X only means interact: don't let it jump when nothing to interact with
				-- test 20: ...unless an item is targeted (pickup_assist grabs it with X below)
				if not canInteract() and (currentAvailablePickable == nil or configui.getValue("pickup_assist") == false) then state.Gamepad.wButtons = state.Gamepad.wButtons & ~XINPUT_GAMEPAD_X end
				-- test 18: right stick = the game's own smooth turn (X only, scaled; Y zeroed so the view never pitches)
				if configui.getValue("rstick_turn") ~= false then
					local k = configui.getValue("rstick_turn_speed") or 1.0
					if k ~= 1.0 then
						local rx = math.floor(state.Gamepad.sThumbRX * k)
						if rx > 32767 then rx = 32767 elseif rx < -32768 then rx = -32768 end
						state.Gamepad.sThumbRX = rx
					end
					state.Gamepad.sThumbRY = 0
				-- test 9b: right stick = directional native dodge (relative to HMD); stick otherwise consumed (no turning)
				elseif configui.getValue("rstick_dodge") ~= false then
					local rx, ry = state.Gamepad.sThumbRX, state.Gamepad.sThumbRY
					local mag2 = rx * rx + ry * ry
					if not rsDodgeHeld and mag2 > 22000 * 22000 then
						rsDodgeHeld = true
						if activeWeapon ~= nil and (configui.getValue("disable_dodge") == nil or configui.getValue("disable_dodge") == false) then
							local okD, errD = pcall(startNativeDodge, math.deg(math.atan(rx, ry)), "RS")
							if okD then rsDodgePressed = true else pcall(meleeLog, "dodge error " .. tostring(errD)) end
						end
					elseif rsDodgeHeld and mag2 < 9000 * 9000 then
						rsDodgeHeld = false
						if rsDodgePressed and activeWeapon ~= nil then pcall(function() activeWeapon:AltAttackReleased() end) end
						rsDodgePressed = false
					end
					state.Gamepad.sThumbRX = 0
					state.Gamepad.sThumbRY = 0
				end
				if dodgeStick ~= nil then
					local now = os.clock()
					if now < dodgeStick.untilT then
						state.Gamepad.sThumbLX = dodgeStick.x
						state.Gamepad.sThumbLY = dodgeStick.y
						-- the game picks the dash direction at press time from the stick it saw last frame -> press only after the spoofed stick has been delivered
						if dodgeStick.fireT and now >= dodgeStick.fireT and activeWeapon ~= nil then
							dodgeStick.fireT = nil
							pcall(function() activeWeapon:AltAttackPressed() end)
							pcall(function() uevr.params.functions.log_info("[DODGE] RS press fired with spoofed stick") end)
						elseif dodgeStick.relT and not dodgeStick.fireT and now >= dodgeStick.relT and activeWeapon ~= nil then
							dodgeStick.relT = nil
							pcall(function() activeWeapon:AltAttackReleased() end)
						end
					else
						dodgeStick = nil
					end
				end
			end
			if configui.getValue("disable_dodge") == nil or configui.getValue("disable_dodge") == false then
				if configui.getValue("frame_layout") == false and state.Gamepad.sThumbRY < -15000 and (state.Gamepad.sThumbLX > 15000 or state.Gamepad.sThumbLX < -15000 or state.Gamepad.sThumbLY > 15000 or state.Gamepad.sThumbLY < -15000) and not dodgeWasHeld then
					--local pawn = api:get_local_pawn(0)
					--if pawn ~= nil then
						--if not pawn["BeingBitten?"] then
							--tryDodge(state)
							beginDodge(state)
						--end
					--end
				end
			end			
			if currentAvailablePickable ~= nil then
				--print("picking up")
				-- test 20: with pickup_assist, X (Steam Frame layout) grabs too; auto take happens in the tick
				local xGrab = configui.getValue("pickup_assist") ~= false and configui.getValue("frame_layout") ~= false and state.Gamepad.wButtons & XINPUT_GAMEPAD_X ~= 0
				if state.Gamepad.wButtons & XINPUT_GAMEPAD_A ~= 0 then
					if xGrab then T20.xHeld = true state.Gamepad.wButtons = state.Gamepad.wButtons & ~XINPUT_GAMEPAD_X end -- never jump with A+X
					if pickableHeld then
						pickupPickable(state)
						pickableHeld = false
						state.Gamepad.wButtons = state.Gamepad.wButtons - XINPUT_GAMEPAD_A
						aButtonHeld = true
						--state.Gamepad.wButtons = state.Gamepad.wButtons | XINPUT_GAMEPAD_LEFT_SHOULDER --to release the left hand being stuck in gripping pose
						return 
					end
				else
					if state.Gamepad.wButtons & XINPUT_GAMEPAD_LEFT_SHOULDER ~= 0 or xGrab then
						-- only a fresh press grabs: a button still held from the last grab must not take the next item
						if not pickableHeld and not leftShoulderButtonHeld and not T20.xHeld then
							local okG, errG = pcall(attachPickableToHand)
							if okG then
								pickableHeld = true
								T20.heldT = os.clock()
								pcall(function() uevr.params.functions.log_info("[PICKUP] grab (" .. (xGrab and "X" or "grip") .. ")") end)
							else
								pcall(function() uevr.params.functions.log_info("[PICKUP] grab error: " .. tostring(errG)) end)
							end
						end
						if state.Gamepad.wButtons & XINPUT_GAMEPAD_LEFT_SHOULDER ~= 0 then
							leftShoulderButtonHeld = true
							state.Gamepad.wButtons = state.Gamepad.wButtons - XINPUT_GAMEPAD_LEFT_SHOULDER
						end
						if xGrab then
							T20.xHeld = true
							state.Gamepad.wButtons = state.Gamepad.wButtons & ~XINPUT_GAMEPAD_X
						end
						return
					end
				end
			end
			if T20.xHeld then -- test 20: X that grabbed an item never reaches the game (jump / interact)
				if state.Gamepad.wButtons & XINPUT_GAMEPAD_X ~= 0 then
					state.Gamepad.wButtons = state.Gamepad.wButtons & ~XINPUT_GAMEPAD_X
				else
					T20.xHeld = false
				end
			end
			if canInteract() and configui.getValue("frame_layout") == false then --left grab is X in case of canInteract
				if state.Gamepad.wButtons & XINPUT_GAMEPAD_LEFT_SHOULDER ~= 0 then 
					state.Gamepad.wButtons = state.Gamepad.wButtons - XINPUT_GAMEPAD_LEFT_SHOULDER
					state.Gamepad.wButtons = state.Gamepad.wButtons | XINPUT_GAMEPAD_X
					leftShoulderButtonHeld = true
				end
			end
			--prevent consequent tick with A/left shoulder after pickup
			if aButtonHeld then
				if state.Gamepad.wButtons & XINPUT_GAMEPAD_A ~= 0 then
					state.Gamepad.wButtons = state.Gamepad.wButtons - XINPUT_GAMEPAD_A
				else
					aButtonHeld = false
				end
			end
			if leftShoulderButtonHeld then
				if state.Gamepad.wButtons & XINPUT_GAMEPAD_LEFT_SHOULDER ~= 0 then
					state.Gamepad.wButtons = state.Gamepad.wButtons - XINPUT_GAMEPAD_LEFT_SHOULDER
				else
					leftShoulderButtonHeld = false
				end
			end
		end	
	end
end)

--pickables

--[[
	local PICKUP_LOCATION = {
    [0]  = "GreenRuins",     [1]  = "AquaRuins",
    [2]  = "Library",        [3]  = "Mausoleum",
    [4]  = "AutumnIsland",   [5]  = "Castle",
    [6]  = "SecretZones",    [7]  = "MerchantIsland",
    [8]  = "SZForest",       [9]  = "SZ_Swamp",
    [10] = "SZ_Prison",      [11] = "SZ_Library",
    [12] = "SZ_GRMA",        [13] = "SZ_AquaRuins",
    [14] = "SZ_RecordOfSin", [15] = "StoneGarden",
}
	]]
	
--[[
0       459
1       97
2       145
3       111
4       210
5       94
6       5
7       33
8       134
9       77
10      43
11      9
12      42
13      16
14      67
15      36
]]

--[[
Level /Game/RuinsLevel/Maps/Ruins_Level_00.Ruins_Level_00.PersistentLevel
Level /Game/RuinsLevel/Maps/990_B33sment.990_B33sment.PersistentLevel
Level /Game/RuinsLevel/Maps/000_Shared_Base_Lighting.000_Shared_Base_Lighting.PersistentLevel
Level /Game/RuinsLevel/Maps/100_GR.100_GR.PersistentLevel
Level /Game/RuinsLevel/Maps/310_LIB_exterior.310_LIB_exterior.PersistentLevel
Level /Game/RuinsLevel/Maps/120_GR_goldenroom.120_GR_goldenroom.PersistentLevel
Level /Game/RuinsLevel/Maps/400_MAUS_entrance.400_MAUS_entrance.PersistentLevel
Level /Game/RuinsLevel/Maps/050_Ocean.050_Ocean.PersistentLevel
Level /Game/RuinsLevel/Maps/780_SZ_Depths.780_SZ_Depths.PersistentLevel
Level /Game/RuinsLevel/Maps/700_SZ_GR.700_SZ_GR.PersistentLevel
Level /Game/RuinsLevel/Maps/125_GR_CubeHall.125_GR_CubeHall.PersistentLevel
Level /Game/RuinsLevel/Maps/070_UpperShell.070_UpperShell.PersistentLevel
Level /Game/UI/Menus/OptionsMenu/VideoConfigMap.VideoConfigMap.PersistentLevel
Level /Game/RuinsLevel/Maps/110_GR_dungeon.110_GR_dungeon.PersistentLevel
Level /Game/RuinsLevel/Maps/130_GR_outerisles.130_GR_outerisles.PersistentLevel
Level /Game/RuinsLevel/Maps/200_AQ.200_AQ.PersistentLevel
Level /Game/RuinsLevel/Maps/140_GR_ShopIsleOnly.140_GR_ShopIsleOnly.PersistentLevel
]]


function getCurrentAreaMusic()
	if world ~= nil and world.OwningGameInstance ~= nil and world.OwningGameInstance.ActiveSaveSlot ~= nil then
		print("area_music", world.OwningGameInstance.ActiveSaveSlot.PlayingMusicTrack:get_full_name())
	end
end

function getLastTouchedSaveArea()
	local game_engine_class = api:find_uobject("Class /Script/Engine.GameEngine")
	local game_engine = UEVR_UObjectHook.get_first_object_by_class(game_engine_class)

	local viewport = game_engine.GameViewport
	local world = viewport.World
	if world ~= nil and world.OwningGameInstance ~= nil and world.OwningGameInstance.ActiveSaveSlot ~= nil then
		if world.OwningGameInstance.ActiveSaveSlot.LastTouchedCheckpoint ~= nil then
			return world.OwningGameInstance.ActiveSaveSlot.LastTouchedCheckpoint:get_full_name()
		else
			return nil
		end
	end
	--[[local allAreas = uevrUtils.find_all_instances("BlueprintGeneratedClass /Game/Blueprints/AreaName.AreaName_C", false)
	for _,area in ipairs(allAreas) do
		print(area:get_full_name())
	end]]
	
end


function isPickableFromDefaultLocationMathcesArea(pickupName)
	if lastTouchedSaveArea == nil then --no save return 0 and 7
		return string.find(pickupName, "_GR")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/1GreenRuins/GR_Camp_Save.GR_Camp_Save") then
		return string.find(pickupName, "_GR")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/1GreenRuins/GR_Graveyard_Save.GR_Graveyard_Save") then
		return string.find(pickupName, "_GR")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/1GreenRuins/GR_ShopIsland_Save.GR_ShopIsland_Save") then
		return string.find(pickupName, "_GR")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/1GreenRuins/Shop_TPPad.Shop_TPPad") then
		return string.find(pickupName, "_GR")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/2AquaRuins/AQ_Cave_Save.AQ_Cave_Save") then
		return string.find(pickupName, "_AQ")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/2AquaRuins/AQ_Cistern_Save.AQ_Cistern_Save") then
		return string.find(pickupName, "_AQ")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/2AquaRuins/AQ_Lift_Save.AQ_Lift_Save") then
		return string.find(pickupName, "_AQ")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/2AquaRuins/AQ_Prison_Save.AQ_Prison_Save") then
		return string.find(pickupName, "_AQ")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/2AquaRuins/AQ_RaiderCamp_Save.AQ_RaiderCamp_Save") then
		return string.find(pickupName, "_AQ")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/3Library/Lib_Archives_Save.Lib_Archives_Save") then
		return string.find(pickupName, "_LIB")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/3Library/Lib_Entrance_Save.Lib_Entrance_Save") then
		return string.find(pickupName, "_LIB")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/3Library/Lib_Stairwell_Save.Lib_Stairwell_Save") then
		return string.find(pickupName, "_LIB")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/4Mausoleum/Maus_Lower_Save.Maus_Lower_Save") then
		return string.find(pickupName, "_MAUS")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/4Mausoleum/Maus_Puwema_Save.Maus_Puwema_Save") then
		return string.find(pickupName, "_MAUS")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/4Mausoleum/Maus_Upper_Save.Maus_Upper_Save") then
		return string.find(pickupName, "_MAUS")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/5AutumnIsland/AI_DropTunnel_Save.AI_DropTunnel_Save") then
		return string.find(pickupName, "_AUT")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/5AutumnIsland/AI_Ossi_Save.AI_Ossi_Save") then
		return string.find(pickupName, "_AUT")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/5AutumnIsland/AI_Scrap_Save.AI_Scrap_Save") then
		return string.find(pickupName, "_AUT")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/5AutumnIsland/AI_Start_Save.AI_Start_Save") then
		return string.find(pickupName, "_AUT")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/6Castle/Castle_Junk_Save.Castle_Junk_Save") then
		return string.find(pickupName, "_Castle")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/6Castle/Castle_Lift_Save.Castle_Lift_Save") then
		return string.find(pickupName, "_Castle")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/6Castle/Castle_Start_Save.Castle_Start_Save") then
		return string.find(pickupName, "_Castle")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Forest_1_Save.Forest_1_Save") then
		return string.find(pickupName, "_Depths") or string.find(pickupName, "_Prison") or string.find(pickupName, "Prison_key_1F_BP_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Forest_2_Save.Forest_2_Save") then
		return string.find(pickupName, "_Depths") 		
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/GRSZ_save.GRSZ_save") then
		return string.find(pickupName, "SZ_GR")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Prison_1_Save.Prison_1_Save") then
		return string.find(pickupName, "_Prison") 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Prison_2_Save.Prison_2_Save") then
		--return true
		return string.find(pickupName, "_Prison") 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/SG_FS_MiniTP_Dest.SG_FS_MiniTP_Dest") then
		return false 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/SG_FS_MiniTP_Exit.SG_FS_MiniTP_Exit") then
		return false 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/StoneGarden_1_Save.StoneGarden_1_Save") then
		return string.find(pickupName, "_SG") or string.find(pickupName, "_FinalZone")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Swamp_1_save.Swamp_1_save") then
		return string.find(pickupName, "_Swamp") 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Swamp_2_save.Swamp_2_save") then
		return string.find(pickupName, "_Swamp") 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Swamp_3_save.Swamp_3_save") then
		return string.find(pickupName, "_Swamp") 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/TeleporterSecretDestination.TeleporterSecretDestination") then
		return false
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/Other/BirdTestZone.BirdTestZone") then
		return false
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/Other/BirdTestZone_Castle.BirdTestZone_Castle") then
		return false
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/ROS/ROS_End_Save.ROS_End_Save") then
		return pickupLocation == 14 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/ROS/ROS_Start_Save.ROS_Start_Save") then
		return pickupLocation == 14
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/ROS/ROS_Teleporter.ROS_Teleporter") then
		return pickupLocation == 14
	else 
		return pickupLocation == 0 or pickupLocation == 7
	end
end

function isPickableMathcesArea(pickupLocation, pickupName)
	if pickupLocation == 0 then
		return isPickableFromDefaultLocationMathcesArea(pickupName)
	elseif lastTouchedSaveArea == nil then --no save return 0 and 7
		return pickupLocation == 7
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/1GreenRuins/GR_Camp_Save.GR_Camp_Save") then
		return pickupLocation == 7
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/1GreenRuins/GR_Graveyard_Save.GR_Graveyard_Save") then
		return pickupLocation == 7
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/1GreenRuins/GR_ShopIsland_Save.GR_ShopIsland_Save") then
		return pickupLocation == 7
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/1GreenRuins/Shop_TPPad.Shop_TPPad") then
		return pickupLocation == 7
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/2AquaRuins/AQ_Cave_Save.AQ_Cave_Save") then
		return pickupLocation == 1
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/2AquaRuins/AQ_Cistern_Save.AQ_Cistern_Save") then
		return pickupLocation == 1
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/2AquaRuins/AQ_Lift_Save.AQ_Lift_Save") then
		return pickupLocation == 1
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/2AquaRuins/AQ_Prison_Save.AQ_Prison_Save") then
		return pickupLocation == 1
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/2AquaRuins/AQ_RaiderCamp_Save.AQ_RaiderCamp_Save") then
		return pickupLocation == 1
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/3Library/Lib_Archives_Save.Lib_Archives_Save") then
		return pickupLocation == 2  or pickupLocation == 11 or string.find(pickupName, "BookKey_00_Eldritch_BP_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/3Library/Lib_Entrance_Save.Lib_Entrance_Save") then
		return pickupLocation == 2  or pickupLocation == 11 or string.find(pickupName, "BookKey_00_Eldritch_BP_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/3Library/Lib_Stairwell_Save.Lib_Stairwell_Save") then
		return pickupLocation == 2  or pickupLocation == 11 or string.find(pickupName, "BookKey_00_Eldritch_BP_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/4Mausoleum/Maus_Lower_Save.Maus_Lower_Save") then
		return pickupLocation == 3 or string.find(pickupName, "RottenChalice_2_Pickup1_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/4Mausoleum/Maus_Puwema_Save.Maus_Puwema_Save") then
		return pickupLocation == 3 or string.find(pickupName, "RottenChalice_2_Pickup1_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/4Mausoleum/Maus_Upper_Save.Maus_Upper_Save") then
		return pickupLocation == 3 or string.find(pickupName, "RottenChalice_2_Pickup1_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/5AutumnIsland/AI_DropTunnel_Save.AI_DropTunnel_Save") then
		return pickupLocation == 4 or string.find(pickupName, "BellTreasure_Pickup_C") or string.find(pickupName, "CellPhone_Pickup_C") or string.find(pickupName, "GameConsole_Pickup_C") or string.find(pickupName, "MechArm_Pickup_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/5AutumnIsland/AI_Ossi_Save.AI_Ossi_Save") then
		return pickupLocation == 4 or string.find(pickupName, "BellTreasure_Pickup_C") or string.find(pickupName, "CellPhone_Pickup_C") or string.find(pickupName, "GameConsole_Pickup_C") or string.find(pickupName, "MechArm_Pickup_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/5AutumnIsland/AI_Scrap_Save.AI_Scrap_Save") then
		return pickupLocation == 4 or string.find(pickupName, "BellTreasure_Pickup_C") or string.find(pickupName, "CellPhone_Pickup_C") or string.find(pickupName, "GameConsole_Pickup_C") or string.find(pickupName, "MechArm_Pickup_C") 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/5AutumnIsland/AI_Start_Save.AI_Start_Save") then
		return pickupLocation == 4 or string.find(pickupName, "BellTreasure_Pickup_C") or string.find(pickupName, "CellPhone_Pickup_C") or string.find(pickupName, "GameConsole_Pickup_C") or string.find(pickupName, "MechArm_Pickup_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/6Castle/Castle_Junk_Save.Castle_Junk_Save") then
		return pickupLocation == 5 or string.find(pickupName, "JigekiStatueGold_Pickup_C") or string.find(pickupName, "TimeSpellPocketWatch2__Pickup1_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/6Castle/Castle_Lift_Save.Castle_Lift_Save") then
		return pickupLocation == 5 or string.find(pickupName, "JigekiStatueGold_Pickup_C") or string.find(pickupName, "TimeSpellPocketWatch2__Pickup1_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/6Castle/Castle_Start_Save.Castle_Start_Save") then
		return pickupLocation == 5 or string.find(pickupName, "JigekiStatueGold_Pickup_C") or string.find(pickupName, "TimeSpellPocketWatch2__Pickup1_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Forest_1_Save.Forest_1_Save") then
		return pickupLocation == 6 or pickupLocation == 8 or pickupLocation == 9 or pickupLocation == 10 or 
		string.find(pickupName, "BellTreasure_2_Pickup1_C") or 
		string.find(pickupName, "OnyxSipehaStatue_Pickup_C") or 
		string.find(pickupName, "HolyBone_2_Pickup1_C") or
		string.find(pickupName, "MysticalMirror_2_Pickup1_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Forest_2_Save.Forest_2_Save") then
		return pickupLocation == 6 or pickupLocation == 8 or pickupLocation == 9 or string.find(pickupName, "OnyxSipehaStatue_Pickup_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/GRSZ_save.GRSZ_save") then
		return pickupLocation == 6 or pickupLocation == 8 or pickupLocation == 9 or pickupLocation == 10 or pickupLocation == 11 or pickupLocation == 12 or pickupLocation == 13 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Prison_1_Save.Prison_1_Save") then
		return pickupLocation == 6 or pickupLocation == 10 or pickupLocation == 11 or pickupLocation == 8 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Prison_2_Save.Prison_2_Save") then
		return pickupLocation == 6 or pickupLocation == 10 or pickupLocation == 11 or string.find(pickupName, "OnyxSipehaStatue_Pickup_C")
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/SG_FS_MiniTP_Dest.SG_FS_MiniTP_Dest") then
		return pickupLocation == 6 or pickupLocation == 8 or pickupLocation == 9 or pickupLocation == 10 or pickupLocation == 11 or pickupLocation == 12 or pickupLocation == 13 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/SG_FS_MiniTP_Exit.SG_FS_MiniTP_Exit") then
		return pickupLocation == 6 or pickupLocation == 8 or pickupLocation == 9 or pickupLocation == 10 or pickupLocation == 11 or pickupLocation == 12 or pickupLocation == 13 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/StoneGarden_1_Save.StoneGarden_1_Save") then
		return pickupLocation == 6 or pickupLocation == 15 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Swamp_1_save.Swamp_1_save") then
		return pickupLocation == 6 or pickupLocation == 8 or pickupLocation == 9 or pickupLocation == 10 or pickupLocation == 11 or pickupLocation == 12 or pickupLocation == 13 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Swamp_2_save.Swamp_2_save") then
		return pickupLocation == 6 or pickupLocation == 8 or pickupLocation == 9 or pickupLocation == 10 or pickupLocation == 11 or pickupLocation == 12 or pickupLocation == 13 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/Swamp_3_save.Swamp_3_save") then
		return pickupLocation == 6 or pickupLocation == 8 or pickupLocation == 9 or pickupLocation == 10 or pickupLocation == 11 or pickupLocation == 12 or pickupLocation == 13 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/7SZ/TeleporterSecretDestination.TeleporterSecretDestination") then
		return pickupLocation == 6 or pickupLocation == 8 or pickupLocation == 9 or pickupLocation == 10 or pickupLocation == 11 or pickupLocation == 12 or pickupLocation == 13 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/Other/BirdTestZone.BirdTestZone") then
		return pickupLocation == 0 or pickupLocation == 1
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/Other/BirdTestZone_Castle.BirdTestZone_Castle") then
		return pickupLocation == 5
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/ROS/ROS_End_Save.ROS_End_Save") then
		return pickupLocation == 14 
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/ROS/ROS_Start_Save.ROS_Start_Save") then
		return pickupLocation == 14
	elseif string.find(lastTouchedSaveArea, "AreaName_C /Game/Blueprints/Areas/ROS/ROS_Teleporter.ROS_Teleporter") then
		return pickupLocation == 14
	else 
		return pickupLocation == 0 or pickupLocation == 7
	end
end

function isPickablesMatachesLevelCode(level, pickupLocation)
	if string.find(level, "Ruins_Level_00") or 
		string.find(level, "100_GR") or 
		string.find(level,"110_GR_dungeon") or 
		string.find(level,"130_GR_outerisles") or 
		string.find(level,"125_GR_CubeHall") or 
		string.find(level, "140_GR_ShopIsleOnly") 
		or string.find(level, "120_GR_goldenroom") then
		--return true
		return pickupLocation == 0 or pickupLocation == 7
	elseif string.find(level, "200_AQ") then
		return pickupLocation == 1 or pickupLocation == 0
	elseif string.find(level, "310_LIB_exterior") then
		return pickupLocation == 2 or pickupLocation == 0
	elseif string.find(level, "400_MAUS_entrance") then
		return pickupLocation == 3 or pickupLocation == 0
	elseif string.find(level, "050_Ocean") then
		return pickupLocation == 4 or pickupLocation == 0
	elseif string.find(level, "700_SZ_GR") then
		return pickupLocation == 12 or pickupLocation == 0
	else
		return 0
	end
	
end

function populateCurrentLevelPickablesDebug()
	for _,pickableClassName in ipairs(pickableClassNames) do
		local clazz = api:find_uobject(pickableClassName)
		local currentPicakbales = UEVR_UObjectHook.get_objects_by_class(clazz, false)
		if currentPicakbales ~= nil then
			for _,currentPicakbale in ipairs(currentPicakbales) do
				if currentPicakbale.PickupGraphics ~= nil and 
				not string.find(currentPicakbale:get_full_name(),"GEN_VARIABLE") then					
					--if isPickablesMatachesLevelCode(level, currentPicakbale.PickupLocation) then
					if isPickableMathcesArea(currentPicakbale.PickupLocation, currentPicakbale:get_full_name()) then
						--if currentPicakbale.Acquired then
						print("pickable", currentPicakbale:get_full_name(), currentPicakbale.PickupLocation, currentPicakbale.Acquired)
						--end
						
						local finalGripLocation, finalGripRotation = getPickupGripOffsets(currentPicakbale)
						if not currentPicakbale.Acquired and not string.find(currentPicakbale:get_full_name(), "Coin_Shimmer_BP_C")then
							currentAvailablePickable = currentPicakbale
							currentPicakbale.PickupGraphics:SetRenderInMainPass(true)
							currentPicakbale.PickupGraphics:SetRenderCustomDepth(true)
							currentPicakbale.PickupGraphics:SetVisibility(true)
							local leftHandComponent = hands.getHandComponent(Handed.Left)
							currentPicakbale.PickupGraphics:K2_AttachToComponent(
								leftHandComponent,
								uevrUtils.fname_from_string("Hand_L"),
								1, -- LocationRule - 1 = KeepWorld, the mesh keeps the world transform it spawned with
								1, -- RotationRule - 1 = KeepWorld
								1,           -- ScaleRule: 1 = KeepWorld
								true         -- bWeldSimulatedBodies
							)
							applyPickupFinalGripTransform(currentPicakbale.PickupGraphics, finalGripLocation, finalGripRotation)
							--attachPickableToHand()
							currentPickupMesh = currentPicakbale.PickupGraphics
							break
						end
						
					end
				end
			end
		end
	end
end

--function populateCurrentLevelPickables(level)
function populateCurrentLevelPickables()	
	currentLevelPickables = {}
	for _,pickableClassName in ipairs(pickableClassNames) do
		local clazz = api:find_uobject(pickableClassName)
		local currentPicakbales = UEVR_UObjectHook.get_objects_by_class(clazz, false)
		if currentPicakbales ~= nil then
			for _,currentPicakbale in ipairs(currentPicakbales) do
				if currentPicakbale.PickupGraphics ~= nil and 
				not string.find(currentPicakbale:get_full_name(),"GEN_VARIABLE") then					
					--if isPickablesMatachesLevelCode(level, currentPicakbale.PickupLocation) then
					if isPickableMathcesArea(currentPicakbale.PickupLocation, currentPicakbale:get_full_name()) then
						if currentPicakbale.Acquired then
							print("pickable", currentPicakbale:get_full_name(), currentPicakbale.PickupLocation, currentPicakbale.Acquired)
						end
						table.insert(currentLevelPickables, currentPicakbale)
					end
				end
			end
		end
	end
	needToPupolatePickables = false
	print("populated", #currentLevelPickables, "pickables")
	--[[
	local count = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}
	for _,currentLevelPickable in ipairs(currentLevelPickables) do
		count[currentLevelPickable.PickupLocation+1] = count[currentLevelPickable.PickupLocation+1]+1
	end
	for i,c in ipairs(count) do
		print(i-1,c)
	end]]
end


function vectorSafeNormalize(v)
    if v == nil then return mathLib.vector(0,0,0) end
    local len = mathLib.vectorSize(v)
    if len == nil or len < 0.0001 then
        return mathLib.vector(0,0,0)
    end
    
    -- Multiply individual components manually to bypass the sol arithmetic restriction
    local invLen = 1.0 / len
    local vx = (v.X or v.x or 0) * invLen
    local vy = (v.Y or v.y or 0) * invLen
    local vz = (v.Z or v.z or 0) * invLen
    
    return mathLib.vector(vx, vy, vz)
end


function isPickableValidForPickup(pickable)
	return pickable ~= nil and 
		pickable.K2_GetActorLocation ~= nil and
		not pickable.Acquired and 
		not pickable.DialoguePickup and 
		(pickable.RequireActivation == false or pickable.Activated == true) and
		(pickable.PickupGraphics ~= nil) --and 
	--(pickable.InteractionWidget ~= nil and pickable.InteractionWidget.Widget ~= nil and pickable.InteractionWidget.Widget:IsVisible())
end

-- test 20: easy pickups (pickup_assist). Candidates (valid items, cached centres) refresh every 0.25 s; each tick
-- qd_pickup.select scores them against the left hand's pointing ray from the hand AND from the eyes (= the knife
-- crosshair), plus a proximity grab. Target: beam from the hand, crosshair snaps onto it (pickupSnap, read by
-- updateAimDot), short left-hand tick on change. Occluded targets (eye line trace) are skipped for 0.5 s.
pickupSnap = nil -- {X, Y, Z} of the targeted item or nil
T20.pk = {cands = {}, n = 0, refreshT = 0.0, visT = 0.0, target = nil, blocked = {}, beam = nil, beamOn = false, beamTried = 0.0,
	beamLoc = {X = 0, Y = 0, Z = 0}, beamRot = {Pitch = 0, Yaw = 0, Roll = 0}, beamScale = {X = 0.006, Y = 0.006, Z = 1},
	snap = {X = 0, Y = 0, Z = 0}, opts = {range = 350, near = 30, baseTol = 10, coneDeg = 6, sticky = 0.04},
	boundsMode = nil, bO = {}, bE = {}, bR = {}, tS = {X = 0, Y = 0, Z = 0}, tE = {X = 0, Y = 0, Z = 0}, ignore = {},
	repopT = 0.0, logged = {}}
T20.PK_BEAM_THICK = 0.6 -- cm
function T20.pkItemCentre(p, c)
	-- visible mesh bounds centre (UEVR returns out params as <table>.result), else the mesh pivot, else the actor
	local g = p.PickupGraphics
	if g ~= nil and T20.pk.boundsMode ~= false then
		T20.pk.bO.result, T20.pk.bE.result = nil, nil
		local ok = pcall(function() kismet_system_library:GetComponentBounds(g, T20.pk.bO, T20.pk.bE, T20.pk.bR) end)
		local o, e = T20.pk.bO.result, T20.pk.bE.result
		if ok and o ~= nil and e ~= nil and o.X ~= nil and (o.X ~= 0 or o.Y ~= 0 or o.Z ~= 0) then
			if T20.pk.boundsMode == nil then T20.pk.boundsMode = true uevr.params.functions.log_info("[PICKUP] item centre = mesh bounds") end
			c.x, c.y, c.z = o.X, o.Y, o.Z
			c.r = math.min(20.0, math.max(4.0, e.X or 0, e.Y or 0, e.Z or 0))
			return true
		elseif T20.pk.boundsMode == nil then
			T20.pk.boundsMode = false
			uevr.params.functions.log_info("[PICKUP] mesh bounds unavailable (ok=" .. tostring(ok) .. "), using mesh pivot")
		end
	end
	local l = (g ~= nil and g:K2_GetComponentLocation()) or p:K2_GetActorLocation()
	if l == nil then return false end
	c.x, c.y, c.z, c.r = l.X, l.Y, l.Z, 8.0
	return true
end
function T20.pkRefresh(px, py, pz)
	local n = 0
	local maxD = T20.pk.opts.range + 200.0
	for _, p in ipairs(currentLevelPickables) do
		local ok, valid = pcall(isPickableValidForPickup, p)
		if ok and valid then
			local c = T20.pk.cands[n + 1]
			if c == nil then c = {} T20.pk.cands[n + 1] = c end
			local okC, has = pcall(T20.pkItemCentre, p, c)
			if okC and has then
				local dx, dy, dz = c.x - px, c.y - py, c.z - pz
				if dx * dx + dy * dy + dz * dz <= maxD * maxD then
					n = n + 1
					T20.pk.cands[n] = c
					c.obj = p
					c.skip = (T20.pk.blocked[p] or 0.0) > os.clock()
				end
			end
		end
	end
	T20.pk.n = n
end
function T20.pkBeamHide()
	if T20.pk.beam ~= nil and T20.pk.beamOn then pcall(function() T20.pk.beam:SetVisibility(false) end) end
	T20.pk.beamOn = false
end
function T20.pkBeamEnsure()
	if T20.pk.beam ~= nil and uevrUtils.getValid(T20.pk.beam) ~= nil then return T20.pk.beam end
	T20.pk.beam, T20.pk.beamOn = nil, false
	if os.clock() < T20.pk.beamTried then return nil end
	T20.pk.beamTried = os.clock() + 5.0
	local shape = "Cylinder"
	local b = uevrUtils.createStaticMeshComponent("StaticMesh /Engine/BasicShapes/Cylinder.Cylinder", {visible = false, collisionEnabled = false})
	if b == nil then shape = "Cube" b = uevrUtils.createStaticMeshComponent("StaticMesh /Engine/BasicShapes/Cube.Cube", {visible = false, collisionEnabled = false}) end
	if b == nil then uevr.params.functions.log_info("[PICKUP] beam mesh unavailable") return nil end
	pcall(function() b:SetCastShadow(false) end)
	pcall(function()
		local mat = uevr.api:find_uobject("Material /Engine/EngineDebugMaterials/DebugMeshMaterial.DebugMeshMaterial")
		local mid = mat ~= nil and b:CreateAndSetMaterialInstanceDynamicFromMaterial(0, mat) or nil
		if mid ~= nil then mid:SetVectorParameterValue("Color", {R = 0.25, G = 0.9, B = 1.0, A = 1.0}) end
	end)
	uevr.params.functions.log_info("[PICKUP] beam created (" .. shape .. ")")
	T20.pk.beam = b
	return b
end
function T20.pkBeamPlace(hx, hy, hz, tx, ty, tz)
	local b = T20.pkBeamEnsure()
	if b == nil then return end
	local dx, dy, dz = tx - hx, ty - hy, tz - hz
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	if len < 1.0 then T20.pkBeamHide() return end
	T20.pk.beamLoc.X, T20.pk.beamLoc.Y, T20.pk.beamLoc.Z = hx + dx * 0.5, hy + dy * 0.5, hz + dz * 0.5
	T20.pickup.zAxisRot(dx / len, dy / len, dz / len, T20.pk.beamRot)
	T20.pk.beamScale.X, T20.pk.beamScale.Y, T20.pk.beamScale.Z = T20.PK_BEAM_THICK / 100.0, T20.PK_BEAM_THICK / 100.0, len / 100.0
	b:K2_SetWorldLocationAndRotation(T20.pk.beamLoc, T20.pk.beamRot, false, reusable_hit_result, true)
	b:SetWorldScale3D(T20.pk.beamScale)
	if not T20.pk.beamOn then b:SetVisibility(true) T20.pk.beamOn = true end
end
-- true when the straight line from the eyes to the item is blocked well before the item
function T20.pkOccluded(ex, ey, ez, c)
	T20.pk.tS.X, T20.pk.tS.Y, T20.pk.tS.Z = ex, ey, ez
	T20.pk.tE.X, T20.pk.tE.Y, T20.pk.tE.Z = c.x, c.y, c.z
	T20.pk.ignore[1] = api:get_local_pawn(0)
	T20.pk.ignore[2] = c.obj
	-- test 21: the held weapon belongs to its own visuals actor (not the pawn) and often crosses the eye line in VR
	local okW, wo = pcall(function() return activeWeaponMesh ~= nil and activeWeaponMesh:GetOwner() or nil end)
	T20.pk.ignore[3] = okW and wo or nil
	local ok, hit = pcall(kismet_system_library.LineTraceSingle, kismet_system_library, uevrUtils.get_world(), T20.pk.tS, T20.pk.tE, 0, false, T20.pk.ignore, 0, reusable_hit_result, true, aimColor, aimColor, 0.0)
	if not ok or not hit then return false end
	local dx, dy, dz = c.x - ex, c.y - ey, c.z - ez
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	return reusable_hit_result.Distance < d - math.max(30.0, (c.r or 8.0) * 2.0)
end
function pickupAssistClear()
	T20.pkBeamHide()
	pickupSnap = nil
	T20.pk.target = nil
end
function T20.pkCamLoc()
	local pc = api:get_player_controller(0)
	local m = pc ~= nil and pc.PlayerCameraManager or nil
	return m ~= nil and m:GetCameraLocation() or nil
end
-- items spawned after the level scan (enemy drops etc.) join the list via a ReceiveBeginPlay post-hook (queued,
-- merged in the tick). Hooked once; retried every 5 s until the class is loaded.
T20.pkSpawned, T20.pkHookT, T20.pkHooked = {}, 0.0, false
function T20.pkHookSpawns(now)
	if T20.pkHooked or now < T20.pkHookT then return end
	T20.pkHookT = now + 5.0
	local ok, res = pcall(hook_function, pickableClassNames[1], "ReceiveBeginPlay", false, nil,
		function(fn, obj, locals, result) if obj ~= nil and #T20.pkSpawned < 64 then T20.pkSpawned[#T20.pkSpawned + 1] = obj end end, false)
	if ok and res then T20.pkHooked = true end
	if T20.pkHooked or not T20.pkHookLogged then
		T20.pkHookLogged = true
		uevr.params.functions.log_info("[PICKUP] spawn hook ok=" .. tostring(ok) .. " res=" .. tostring(res))
	end
end
function T20.pkMergeSpawned()
	for k = #T20.pkSpawned, 1, -1 do
		local p = T20.pkSpawned[k]
		T20.pkSpawned[k] = nil
		pcall(function()
			if uevrUtils.getValid(p) == nil or p.PickupGraphics == nil then return end
			for _, q in ipairs(currentLevelPickables) do if q == p then return end end
			if isPickableMathcesArea(p.PickupLocation, p:get_full_name()) then
				table.insert(currentLevelPickables, p)
				uevr.params.functions.log_info("[PICKUP] spawned item added (" .. #currentLevelPickables .. ")")
			end
		end)
	end
end
function pickupAssistTick()
	local now = os.clock()
	T20.pkHookSpawns(now)
	if #T20.pkSpawned > 0 then T20.pkMergeSpawned() end
	-- fallback for item classes whose BeginPlay skips the parent's: full rescan every 10 s (60 s if it is slow)
	if now > (T20.pkRescanT or 0.0) then
		local t0 = os.clock()
		pcall(populateCurrentLevelPickables)
		local dt = os.clock() - t0
		T20.pkRescanT = now + (dt > 0.004 and 60.0 or 10.0)
		if not T20.pkRescanLogged then T20.pkRescanLogged = true uevr.params.functions.log_info(string.format("[PICKUP] rescan %.1f ms, %d items", dt * 1000, #currentLevelPickables)) end
	end
	local hand = controllers.getController(0, true) or controllers.getController(0)
	if hand == nil then pickupAssistClear() currentAvailablePickable = nil return end
	local hp = hand:K2_GetComponentLocation()
	local hd = hand:GetForwardVector()
	local ex, ey, ez = hp.X, hp.Y, hp.Z
	local okL, l = pcall(T20.pkCamLoc)
	if okL and l ~= nil then ex, ey, ez = l.X, l.Y, l.Z end
	if now > T20.pk.refreshT then
		T20.pk.refreshT = now + 0.25
		if next(T20.pk.blocked) ~= nil and now > (T20.pk.blockedGC or 0.0) then T20.pk.blockedGC = now + 10.0 T20.pk.blocked = {} end
		T20.pk.opts.coneDeg = configui.getValue("pickup_cone") or 6.0
		T20.pk.opts.range = (configui.getValue("pickup_range") or 3.5) * 100.0
		T20.pkRefresh(ex, ey, ez)
	end
	local i, score = T20.pickup.select(T20.pk.cands, T20.pk.n, hp.X, hp.Y, hp.Z, hd.X, hd.Y, hd.Z, ex, ey, ez, T20.pk.target, T20.pk.opts)
	local c = i ~= nil and T20.pk.cands[i] or nil
	-- occlusion check on a new target and every 0.3 s for the current one
	if c ~= nil and score >= 0 and (c.obj ~= T20.pk.target or now > T20.pk.visT) then -- hand at the item: no eye test
		T20.pk.visT = now + 0.3
		if T20.pkOccluded(ex, ey, ez, c) then
			T20.pk.blocked[c.obj] = now + 0.5
			c.skip = true
			c = nil
		end
	end
	local obj = c ~= nil and c.obj or nil
	if obj ~= T20.pk.target then
		if obj ~= nil then
			uevrUtils.triggerHapticVibration(Handed.Left, 0, 0.06, 250, 0.45)
			local nm = "?"
			pcall(function() nm = obj:get_fname():to_string() end)
			uevr.params.functions.log_info(string.format("[PICKUP] target %s dist=%.0f", nm, math.sqrt((c.x - ex) ^ 2 + (c.y - ey) ^ 2 + (c.z - ez) ^ 2)))
		end
		T20.pk.target = obj
	end
	currentAvailablePickable = obj
	if c == nil then pickupSnap = nil T20.pkBeamHide() return end
	T20.pk.snap.X, T20.pk.snap.Y, T20.pk.snap.Z = c.x, c.y, c.z
	pickupSnap = T20.pk.snap
	if configui.getValue("pickup_beam") ~= false then
		T20.pkBeamPlace(hp.X + hd.X * 5.0, hp.Y + hd.Y * 5.0, hp.Z + hd.Z * 5.0, c.x, c.y, c.z)
	else
		T20.pkBeamHide()
	end
end

function handleLeftHandPickables()
	if configui.getValue("pickup_assist") ~= false then return pickupAssistTick() end
	if pickupSnap ~= nil or T20.pk.beamOn then pickupAssistClear() end
    local handPos = controllers.getController(0):K2_GetComponentLocation()

    local handForward = controllers.getController(0):GetForwardVector()
	
    local maxDistance =  175 --game's max dist is 175...
    local angleThreshold = 0.85

    local bestTarget = nil
    local highestDot = -1.0

    for _, pickable in ipairs(currentLevelPickables) do
		success, result = pcall(isPickableValidForPickup, pickable)
		--if not success then
		--	print(pickable:get_full_name())
		--end
		if success and result then
			--print("valid", pickable:get_full_name())
			local pickablePos = pickable:K2_GetActorLocation()
			local currentDistance = mathLib.vectorDistance(handPos, pickablePos, false)        
	
			if currentDistance <= maxDistance then
				
				local directionToPickableVector = mathLib.vector(
					pickablePos.X - handPos.X,
					pickablePos.Y - handPos.Y,
					pickablePos.Z - handPos.Z,
					true -- Enabled reusable optimization pool to mitigate frame trash allocation
				) 
						
				local normalizedDirVector = vectorSafeNormalize(directionToPickableVector) 
				
				local dotAlignment = mathLib.vectorDot(handForward, normalizedDirVector, false) 
	
				if dotAlignment > angleThreshold and dotAlignment > highestDot then
					highestDot = dotAlignment
					bestTarget = pickable
				end
			end
		end
    end
	if bestTarget~= nil then
		print("best pickable", bestTarget:get_full_name())
		if bestTarget ~= currentAvailablePickable then
			uevrUtils.triggerHapticVibration(Handed.Left, 0, 0.1, 300, 0.6) --quick buzz on first time an item is available to pickup				
		end
	end
	currentAvailablePickable = bestTarget
end

-- test 21: grip for a pickup without a tuned entry (mesh already attached to Hand_L, KeepWorld scale). Returns
-- location, rotation and {from, to} uniform scale, or nil when the mesh has no static mesh bounds.
function T20.pkAutoHold(mesh)
	local sm = mesh.StaticMesh
	if sm == nil then return nil end
	local b = sm:GetBounds()
	if b == nil or b.BoxExtent == nil then return nil end
	local s0 = mesh.RelativeScale3D.X
	if s0 == nil or s0 <= 0 then s0 = 1.0 end
	local rot, loc, sc, info = T20.grip.pickupHold(b.Origin, b.BoxExtent, {scale = s0})
	uevr.params.functions.log_info(string.format("[PICKUP] auto hold long=%s thin=%s size=%.0f scale %.2f->%.2f", info.axis, info.thin, info.size, s0, sc))
	return loc, rot, {s0, sc}
end

function getPickupGripOffsets(pickup)
	local pickupName = pickup:get_full_name()
	if string.find(pickupName, "BasicSpear_Pickup_C") then
		return {X = 3, Y = -10, Z = -3}, {Yaw = -35, Roll = 1, Pitch = -11}
	elseif string.find(pickupName, "Herb_Item_BP_C") then
		return {X = 19, Y = -13, Z = -1}, {Yaw = 70, Roll = -1, Pitch = 110}
	elseif string.find(pickupName, "HealingPotion_Item_BP_C") then
		return {X = -11, Y = 3, Z = -3}, {Yaw = 48, Roll = -84, Pitch = -30}
	elseif string.find(pickupName, "Coin_Item_BP_C") then
		return {X = 1, Y = -7, Z = -6}, {Yaw = 214, Roll = -8, Pitch = -86}
	elseif string.find(pickupName, "Knifebelt_Pickup_C") then
		return {X = 1, Y = -7, Z = -3}, {Yaw = 207, Roll = 57, Pitch = 3}
	elseif string.find(pickupName, "FinalClaw_Pickup_BP_C") then
		return {X = 1, Y = -7, Z = -2}, {Yaw = 116, Roll = 204, Pitch = 10}
	elseif string.find(pickupName, "Clam_Upgrade_Pickup_C") then
		return {X = 1, Y = -6, Z = -6}, {Yaw = -62, Roll = 73, Pitch = -9}
	elseif string.find(pickupName, "3Coins_Item_Bp_C") then
		return {X = 1, Y = -6, Z = -6}, {Yaw = -62, Roll = 73, Pitch = -9}	
	elseif string.find(pickupName, "CoinBag_ItemBP_C") then
		return {X = -3, Y = 9, Z = -8}, {Yaw = -8, Roll = -99, Pitch = 75}
	elseif string.find(pickupName, "2Coins_Item_BP_C") then
		return {X = 1, Y = -7, Z = -5}, {Yaw = -6, Roll = -38, Pitch = 114}
	elseif string.find(pickupName, "FishMaidenTiara_WRR_BP_C") then
		return {X = -7, Y = -4, Z = -12}, {Yaw = -6, Roll = 272, Pitch = 249}
	elseif string.find(pickupName, "Rusted_Great_MorningStar_Pickup_C") then
		return {X = -3, Y = -7, Z = -2}, {Yaw = -6, Roll = 78, Pitch = 266}
	elseif string.find(pickupName, "WeaponXPPotion_Pickup_Bp_C") then
		return {X = -21, Y = 4, Z = -1}, {Yaw = -6, Roll = -162, Pitch = 84}
	elseif string.find(pickupName, "SkullKeyRelic_BP_C") then
		return {X = -1, Y = -25, Z = -5}, {Yaw = 6, Roll = -45, Pitch = 173}
	elseif string.find(pickupName, "FishWife_Egg_Item_Bp_C") then
		return {X = -1, Y = 2, Z = -22}, {Yaw = 11, Roll = -45, Pitch = 58}
	elseif string.find(pickupName, "mealticket_BP_C") then
		return {X = 4, Y = -7, Z = -13}, {Yaw = -79, Roll = 98, Pitch = 173}
	elseif string.find(pickupName, "Meat_Upgrade_Pickup_C") then
		return {X = 2, Y = -13, Z = 1}, {Yaw = 68, Roll = 215, Pitch = 53}
	elseif string.find(pickupName, "JarHammer_Pickup_C") then
		return {X = 2, Y = -8, Z = -2}, {Yaw = 293, Roll = 215, Pitch = 80}
	elseif string.find(pickupName, "FlyingSwordChargeRelic_BP_C") then
		return {X = 3, Y = 10, Z = -16}, {Yaw = 65, Roll = 101, Pitch = -34}
	elseif string.find(pickupName, "Chicken_Upgrade_Pickup_C") then
		return {X = -2, Y = -7, Z = -4}, {Yaw = -24, Roll = 86, Pitch = -34}
	elseif string.find(pickupName, "Lobster_Upgrade_Pickup_C") then
		return {X = 2, Y = -8, Z = -3}, {Yaw = -101, Roll = -10, Pitch = -26}
	elseif string.find(pickupName, "Fish_UpgradePickup_C") then
		return {X = 2, Y = -8, Z = -3}, {Yaw = -101, Roll = -10, Pitch = -26}
	elseif string.find(pickupName, "WoodClub_Pickup_C") then
		return {X = 2, Y = -8, Z = -1}, {Yaw = -101, Roll = 171, Pitch = -30}
	elseif string.find(pickupName, "HPIncreaseNecklace_Pickup_C") then
		return {X = 2, Y = 1, Z = -25}, {Yaw = -26, Roll = 73, Pitch = -20}
	elseif string.find(pickupName, "COL_1Ruin_Torch_Blueprint_C") then
		return {X = 0, Y = -7, Z = -1}, {Yaw = -16, Roll = 71, Pitch = -98}
	elseif string.find(pickupName, "CrystalFragment_Pickup_BP_C") then
		return {X = 13, Y = -14, Z = 1}, {Yaw = -180, Roll = 27, Pitch = 71}
	elseif string.find(pickupName, "BookKey_00_RattyBugs_BP_C") then
		return {X = 13, Y = -26, Z = 1}, {Yaw = -89, Roll = 27, Pitch = 82}
	elseif string.find(pickupName, "HeavyCure_Pickup_Bp_C") then
		return {X = 10, Y = -17, Z = 1}, {Yaw = -89, Roll = 53, Pitch = 82}
	elseif string.find(pickupName, "IronFruit_Pickup_Bp_C") then
		return {X = -11, Y = -10, Z = -6}, {Yaw = -89, Roll = 113, Pitch = 100}
	elseif string.find(pickupName, "DefaultDagger_Pickup_C") then
		return {X = 0, Y = -9, Z = -3}, {Yaw = 78, Roll = -6, Pitch = 237}
	elseif string.find(pickupName, "Chakram_Pickup_C") then
		return {X = 0, Y = 2, Z = -17}, {Yaw = -109, Roll = 26, Pitch = 69}
	elseif string.find(pickupName, "Panacea_Pickup_Bp_C") then
		return {X = -16, Y = 7, Z = 2}, {Yaw = -109, Roll = 113, Pitch = 69}
	elseif string.find(pickupName, "RadiantFruit_Pickup_BP_C") then
		return {X = -10, Y = -4, Z = -2}, {Yaw = -113, Roll = 87, Pitch = 131}
	elseif string.find(pickupName, "AquaDoorKey_BP_C") then
		return {X = -14, Y = -6, Z = -15}, {Yaw = 6, Roll = 9, Pitch = 86}
	elseif string.find(pickupName, "TridentKeyTrident_Pickup_C") then
		return {X = -14, Y = -4, Z = -2}, {Yaw = 2, Roll = -71, Pitch = 91}
	elseif string.find(pickupName, "DiseaseCure_Pickup_Bp_C") then
		return {X = -1, Y = -5, Z = -2}, {Yaw = 77, Roll = -71, Pitch = 91}
	elseif string.find(pickupName, "StickyCure_Pickup_Bp_C") then
		return {X = 4, Y = -13, Z = -12}, {Yaw = 4, Roll = 117, Pitch = 88}
	elseif string.find(pickupName, "TridentKey_00_BP_C") then
		return {X = -3, Y = -7, Z = -22}, {Yaw = 65, Roll = 24, Pitch = 85}
	elseif string.find(pickupName, "PoisonResistTiara_Pickup_C") then
		return {X = 1, Y = -9, Z = -7}, {Yaw = 26, Roll = 7, Pitch = 255}
	elseif string.find(pickupName, "Needle_Pickup1_C") then
		return {X = 8, Y = -14, Z = 2}, {Yaw = 65, Roll = 24, Pitch = 85}
	elseif string.find(pickupName, "ChickenBossNecklace_Pickup_2") then
		return {X = -2, Y = -9, Z = -16}, {Yaw = 41, Roll = 7, Pitch = 267}
	elseif string.find(pickupName, "Hammer_Pickup_C") then
		return {X = 1, Y = -9, Z = -2}, {Yaw = 26, Roll = 46, Pitch = 250}
	elseif string.find(pickupName, "HealingPotion_Item_02_BP_C") then
		return {X = -13, Y = -2, Z = -1}, {Yaw = 26, Roll = -48, Pitch = 250}
	elseif string.find(pickupName, "IronPotion_Pickup_BP_C") then
		return {X = -24, Y = 4, Z = 2}, {Yaw = 26, Roll = -48, Pitch = 250}
	elseif string.find(pickupName, "BindingCure_Pickup_Bp_C") then
		return {X = 4, Y = -9, Z = -2}, {Yaw = 26, Roll = -48, Pitch = 298}
	elseif string.find(pickupName, "DiseaseResistCharm_Pickup_C") then
		return {X = -8, Y = -6, Z = -11}, {Yaw = 146, Roll = -48, Pitch = 298}
	elseif string.find(pickupName, "HomingDagger_Pickup_BP_C") then
		return {X = -11, Y = -1, Z = -2}, {Yaw = 154, Roll = 154, Pitch = 360}
	elseif string.find(pickupName, "BookKey_00_WarHistory_BP_C") then
		return {X = 4, Y = 3, Z = -10}, {Yaw = 124, Roll = 66, Pitch = 178}	
	elseif string.find(pickupName, "BookKey_00_QueerRomance_BP_C") then
		return {X = 5, Y = -6, Z = -8}, {Yaw = 124, Roll = 66, Pitch = 203}
	elseif string.find(pickupName, "BookKey_00_Wodaso_BP_C") then
		return {X = 5, Y = -6, Z = -8}, {Yaw = 124, Roll = 66, Pitch = 203}	
	elseif string.find(pickupName, "BookKey_00_BoneMachines_BP_C") then
		return {X = 5, Y = -6, Z = -8}, {Yaw = 124, Roll = 66, Pitch = 203}			
	elseif string.find(pickupName, "GenieLamp_Pickup_C") then
		return {X = 5, Y = -6, Z = -8}, {Yaw = 124, Roll = 66, Pitch = 203}		 
	elseif string.find(pickupName, ".Spear_Pickup_C") then
		return {X = 1, Y = -8, Z = -2}, {Yaw = 161, Roll = 88, Pitch = 173}
	elseif string.find(pickupName, "Herb_Item_01_BP_C") then
		return {X = 20, Y = -8, Z = 4}, {Yaw = 173, Roll = 88, Pitch = 73}
	elseif string.find(pickupName, "BerserkFruit_Pickup_Bp_C") then
		return {X = 29, Y = -13, Z = -2}, {Yaw = 78, Roll = 88, Pitch = 83}
	elseif string.find(pickupName, "JewelledGoldRattyBug_Pickup_C") then
		return {X = -12, Y = -3, Z = -4}, {Yaw = 78, Roll = -23, Pitch = 242}
	elseif string.find(pickupName, "HealingPotion_Item_03_BP_C") then
		return {X = -15, Y = 12, Z = -5}, {Yaw = 217, Roll = 92, Pitch = 212}
	elseif string.find(pickupName, "Rapier_Pickup_C") then
		return {X = 1, Y = -8, Z = -2}, {Yaw = 223, Roll = 152, Pitch = 77}
	elseif string.find(pickupName, "ThrowingAxe_Pickup_C") then
		return {X = -3, Y = -7, Z = 0}, {Yaw = 9, Roll = -156, Pitch = 78}
	elseif string.find(pickupName, "StickyResistCharm_Pickup_C") then
		return {X = -3, Y = -8, Z = -14}, {Yaw = 4, Roll = -77, Pitch = 88}
	elseif string.find(pickupName, "WeakenCure_Pickup_Bp_C") then
		return {X = 16, Y = -11, Z = -3}, {Yaw = 4, Roll = -77, Pitch = 88}
	elseif string.find(pickupName, "Scythe_Pickup_C") then
		return {X = 1, Y = -7, Z = -3}, {Yaw = -6, Roll = -38, Pitch = 88}
	elseif string.find(pickupName, "PoisonCure_Pickup_Bp_C") then
		return {X = 10, Y = -22, Z = -3}, {Yaw = -6, Roll = -38, Pitch = 88}
	elseif string.find(pickupName, "PoisonPiercer_Pickup_C") then
		return {X = 1, Y = -6, Z = -3}, {Yaw = -6, Roll = -38, Pitch = 88}
	elseif string.find(pickupName, "RottenChalice_2_Pickup1_C") then
		return {X = 1, Y = -6, Z = -3}, {Yaw = -6, Roll = -122, Pitch = 88}
	elseif string.find(pickupName, "Vampire_Dagger_Pickup_C") then
		return {X = 1, Y = -6, Z = -3}, {Yaw = -6, Roll = -38, Pitch = 88}
	elseif string.find(pickupName, "PoisonDagger_Pickup_C") then
		return {X = 1, Y = -6, Z = -3}, {Yaw = -6, Roll = -38, Pitch = 88}
	elseif string.find(pickupName, "BookKey_00_BoneMachines_BP_C") then	
		return {X = 1, Y = -6, Z = -3}, {Yaw = -6, Roll = -38, Pitch = 88}
	elseif string.find(pickupName, "BookKey_00_CookBook_BP_C") then	
		return {X = 1, Y = -6, Z = -3}, {Yaw = -6, Roll = -38, Pitch = 88}
		
	elseif string.find(pickupName, "RuneVisionCharm_Pickup_C") then
		return {X = -2, Y = -4, Z = -16}, {Yaw = 124, Roll = 176, Pitch = 290}
	elseif string.find(pickupName, "KnightsKey_BP_C") then
		return {X = 2, Y = -7, Z = -4}, {Yaw = 118, Roll = 91, Pitch = 15}
	elseif string.find(pickupName, "WodasoCross_Pickup_C") then
		return {X = 13, Y = -20, Z = -3}, {Yaw = 221, Roll = 91, Pitch = 15}
	elseif string.find(pickupName, "KingsDagger_Pickup_C") then
		return {X = 1, Y = -6, Z = -3}, {Yaw = -6, Roll = -38, Pitch = 88}
	elseif string.find(pickupName, "Dagger_Pickup_C") then
		return {X = 1, Y = -6, Z = -3}, {Yaw = -6, Roll = -38, Pitch = 88}
	elseif string.find(pickupName, "KingSword_Remnant_BP_C") then
		return {X = 2, Y = -5, Z = -12}, {Yaw = -6, Roll = -38, Pitch = 88}
	elseif string.find(pickupName, "Slashgun_Pickup_C") then
		return {X = -6, Y = 2, Z = -9}, {Yaw = 24, Roll = 4, Pitch = -28}
	elseif string.find(pickupName, "EnergyCell_Pickup_BP_C") then
		return {X = -6, Y = 2, Z = -9}, {Yaw = 24, Roll = 4, Pitch = -28}
	elseif string.find(pickupName, "Herb_Item_02_BP_C") then
		return {X = 1, Y = -29, Z = -2}, {Yaw = -85, Roll = 85, Pitch = -82}
	elseif string.find(pickupName, "HeavyResistCharm_Pickup_C") then
		return {X = 0, Y = 5, Z = -17}, {Yaw = -85, Roll = 92, Pitch = -82}	
	elseif string.find(pickupName, "EnergyCell_Half_Pickup_BP_C") then
		return {X = -1, Y = -12, Z = -4}, {Yaw = -85, Roll = 92, Pitch = -82}
	elseif string.find(pickupName, "ElecGun_Pickup_C") then
		return {X = 1, Y = -7, Z = -2}, {Yaw = -91, Roll = 92, Pitch = 69}
	elseif string.find(pickupName, "WeaponXPAmulet_Pickup_C") then
		return {X = -2, Y = -15, Z = 0}, {Yaw = -15, Roll = 216, Pitch = 155}
	elseif string.find(pickupName, "TowerDoor_Key_BP_C") then
		return {X = -2, Y = -19, Z = -11}, {Yaw = -94, Roll = 133, Pitch = 139}
	elseif string.find(pickupName, "Shotgun_Pickup_C") then
		return {X = -2, Y = -10, Z = -2}, {Yaw = -94, Roll = 71, Pitch = 83}
	elseif string.find(pickupName, "TeleporterFragment_Pickup_BP_C") then
		return {X = -3, Y = 3, Z = -2}, {Yaw = -92, Roll = 28, Pitch = -12}
	elseif string.find(pickupName, "RejuvenatingPotion_Pickup_Bp_C") then
		return {X = -12, Y = 16, Z = -7}, {Yaw = -92, Roll = 30, Pitch = -85}
	elseif string.find(pickupName, "Dagger_Explode_Pickup_C") then
		return {X = -12, Y = -8, Z = -3}, {Yaw = 279, Roll = 66, Pitch = 203}
	elseif string.find(pickupName, "BerserkPotion_Item_BP_C") then
		return {X = -19, Y = -6, Z = 2}, {Yaw = 279, Roll = 66, Pitch = 203}
	elseif string.find(pickupName, "BellTreasure_Pickup_C") then
		return {X = -22, Y = -7, Z = -4}, {Yaw = 284, Roll = 164, Pitch = 284}
	elseif string.find(pickupName, "BellTreasure_2_Pickup1_C") then
		return {X = -22, Y = -7, Z = -4}, {Yaw = 284, Roll = 164, Pitch = 284}
	elseif string.find(pickupName, "CyberSword_Pickup_C") then
		return {X = 4, Y = -8, Z = -2}, {Yaw = 284, Roll = 164, Pitch = 284}
	elseif string.find(pickupName, "RocketLauncher_Pickup_C") then
		return {X = 4, Y = -6, Z = -18}, {Yaw = 281, Roll = 158, Pitch = 168}
	elseif string.find(pickupName, "Castle_Key_Cup_BP_C") then
		return {X = 4, Y = -7, Z = -18}, {Yaw = 273, Roll = 168, Pitch = 74}
	elseif string.find(pickupName, "Castle_Key_") then
		return {X = 4, Y = -7, Z = -18}, {Yaw = 273, Roll = 168, Pitch = 74}
	elseif string.find(pickupName, "MPCure_Pickup_Bp_C") then
		return {X = -5, Y = -11, Z = -7}, {Yaw = 276, Roll = 166, Pitch = -102}
	elseif string.find(pickupName, "MagicPoisonResistCharm_Pickup_C") then
		return {X = -5, Y = -5, Z = -14}, {Yaw = 276, Roll = 166, Pitch = -102}
	elseif string.find(pickupName, "Prison_key_1F_BP_C") then
		return {X = 1, Y = -5, Z = -6}, {Yaw = 276, Roll = 166, Pitch = -102}
	elseif string.find(pickupName, "HolyBone_2_Pickup1_C") then
		return {X = 6, Y = -9, Z = -11}, {Yaw = 276, Roll = 165, Pitch = -2}
	elseif string.find(pickupName, "WeaponUpgradeUnlock") then
		return {X = 6, Y = -5, Z = -14}, {Yaw = 296, Roll = 186, Pitch = -106}
	elseif string.find(pickupName, "DropChanceAmulet_Pickup_C") then
		return {X = 6, Y = -5, Z = -14}, {Yaw = 296, Roll = 97, Pitch = -106}
	elseif string.find(pickupName, "Skullrod_Pickup_C") then
		return {X = 1, Y = -8, Z = -2}, {Yaw = 161, Roll = 88, Pitch = 173}
	elseif string.find(pickupName, "CellPhone_Pickup_C") then
		return {X = 1, Y = -10, Z = -5}, {Yaw = 128, Roll = -32, Pitch = 139}
	elseif string.find(pickupName, "GameConsole_Pickup_C") then
		return {X = -8, Y = -14, Z = -19}, {Yaw = 27, Roll = -68, Pitch = -36}
	elseif string.find(pickupName, "MechArm_Pickup_C") then
		return {X = -1, Y = 0, Z = -1}, {Yaw = 116, Roll = -172, Pitch = -10}
	elseif string.find(pickupName, "PandoraBlade_Pickup_C") then
		return {X = -3, Y = -8, Z = -2}, {Yaw = -97, Roll = -179, Pitch = -10}		
	else		
		return {X = configui.getValue("loc_x"),Y = configui.getValue("loc_y"), Z = configui.getValue("loc_z")},{Yaw = configui.getValue("rot_yaw"), Roll = configui.getValue("rot_roll"), Pitch = configui.getValue("rot_pitch")}, true -- test 21: true = no tuned grip
	end
	
end

function tryApplyPickupFinalGripRotation(mesh, gripRotation)
	mesh:K2_SetRelativeRotation(gripRotation, true, empty_hitresult, true)
end

function applyPickupFinalGripTransform(mesh, gripLocation, gripRotation)
	mesh:K2_SetRelativeLocation(gripLocation, true, empty_hitresult, true)
	local success, result = pcall(tryApplyPickupFinalGripRotation, mesh, gripRotation)
	if not success then
		mesh:K2_SetRelativeRotation({Yaw = gripRotation.Yaw, Roll = gripRotation.Roll, Pitch = gripRotation.Pitch}, true, empty_hitresult, true)
	end
end

function cancelCurrentPickupFlyIn()
	uevrUtils.cancelLerp(pickupFlyLerpID)
	pickupFlyState = nil
end

local function trySetRelativeRotationLerp(state, alpha)
	state.mesh:K2_SetRelativeRotation(kismet_math_library:RLerp(state.fromRotation, state.toRotation, alpha, true), true, empty_hitresult, true)
end

-- progress == math.min(self.progress / self.duration - 1 means it's done
local function pickupFlyInCallback(alpha, progress, state)
	if state == nil or state ~= pickupFlyState then return end

	if state.mesh == nil then --the pickup got destroyed while we were flying
		pickupFlyState = nil
		return
	end

	local from = state.fromLocation
	local to = state.toLocation
	state.mesh:K2_SetRelativeLocation(uevrUtils.vector(
		from.X + (to.X - from.X) * alpha,
		from.Y + (to.Y - from.Y) * alpha,
		from.Z + (to.Z - from.Z) * alpha), true, empty_hitresult, true)
	--UKismetMathLibrary::RLerp(FRotator A, FRotator B, float Alpha, bool bShortestPath);
	--[[Instead of an object instantly snapping from one orientation to another, RLerp calculates a smooth, intermediate rotation between a starting orientation (A) and an ending orientation
	An Alpha of 0.0 outputs 100% of rotation A.
	An Alpha of 1.0 outputs 100% of rotation B.
	An Alpha of 0.5 outputs an orientation exactly halfway between them.
	]]
	if kismet_math_library ~= nil and kismet_math_library.RLerp ~= nil then
		--stupid pitch vs Pitch sometimes fails (e.g. Pliers, ChirstBook)
		success, result = pcall(trySetRelativeRotationLerp, state, alpha)
		if not success then
			state.mesh:K2_SetRelativeRotation(kismet_math_library:RLerp({Yaw = state.fromRotation.Yaw, Roll = state.fromRotation.Roll, Pitch = state.fromRotation.Pitch}, {Yaw = state.toRotation.Yaw, Roll = state.toRotation.Roll, Pitch = state.toRotation.Pitch}, alpha, true), true, empty_hitresult, true)
		end
	end
	
	if state.toScale ~= nil then -- test 21: auto hold shrinks big items while they fly in
		local k = (progress >= 1.0) and 1.0 or alpha
		local s = state.fromScale + (state.toScale - state.fromScale) * k
		state.sv.X, state.sv.Y, state.sv.Z = s, s, s
		pcall(function() state.mesh:SetRelativeScale3D(state.sv) end)
	end
	-- this game has pitch and not Pitch, change for final grip
	if progress >= 1.0 then
		applyPickupFinalGripTransform(state.mesh, state.toLocation, state.toRotation)

		pickupFlyState = nil
	end
end

function startPickupLerpMovement(mesh, gripLocation, gripRotation)
	cancelCurrentPickupFlyIn()

	pickupFlyState = {
		mesh = mesh,
		fromLocation = {X = mesh.RelativeLocation.X, Y = mesh.RelativeLocation.Y, Z = mesh.RelativeLocation.Z},
		toLocation = gripLocation,
		fromRotation = mesh.RelativeRotation,
		toRotation = gripRotation
	}
	--uevrUtils.lerp(lerpID, startAlpha, endAlpha, duration, userdata, callback(alpha, progress, userData = pickupFlyState))
	uevrUtils.lerp(pickupFlyLerpID, 0.0, 1.0, pickupFlyDuration, pickupFlyState, pickupFlyInCallback)

end


function attachPickableToHand()
	local pickup = currentAvailablePickable
	if pickupAssistClear ~= nil then pcall(pickupAssistClear) end -- test 20: hide the beam while the item is held

	
	local mesh = nil
	if pickup.PickupGraphics ~= nil then
		mesh = pickup.PickupGraphics
	else 
		return
	end
	
	--Coin_Item_BP_C /Game/RuinsLevel/Maps/100_GR.100_GR.PersistentLevel.Coin_Item_BP61_8
	
	mesh:SetMobility(2) --EComponentMobility.Movable
	mesh:SetCollisionEnabled(0)
	mesh:SetSimulatePhysics(false)
	mesh:SetCollisionResponseToAllChannels(0)
	mesh.BodyInstance.bSimulatePhysics = true
	mesh.BodyInstance.bEnableGravity = false
	mesh:SetEnableGravity(false)
	mesh:WakeAllRigidBodies()
	mesh:SetSimulatePhysics(false)
	--[[
	pickup.Box:SetMobility(2) --EComponentMobility.Movable
	pickup.Box:SetCollisionEnabled(0)
	pickup.Box:SetSimulatePhysics(false)
	pickup.Box:SetCollisionResponseToAllChannels(0)
	pickup.Box.BodyInstance.bSimulatePhysics = true
	pickup.Box.BodyInstance.bEnableGravity = false
	pickup.Box:SetEnableGravity(false)
	pickup.Box:WakeAllRigidBodies()
	pickup.Box:SetSimulatePhysics(false)
	]]
	-- test 20: remember where the mesh lives so the take can put it back for the game's own acquire animation
	pcall(function()
		local rl, rr, rs = mesh.RelativeLocation, mesh.RelativeRotation, mesh.RelativeScale3D
		T20.pkOrig = {mesh = mesh, parent = mesh.AttachParent, loc = {X = rl.X, Y = rl.Y, Z = rl.Z},
			rot = {Pitch = rr.Pitch, Yaw = rr.Yaw, Roll = rr.Roll}, scale = {X = rs.X, Y = rs.Y, Z = rs.Z}}
	end)
	pickup:SetActorEnableCollision(false)
	pickup:SetReplicateMovement(false)
	pickup.RootComponent:SetShouldUpdatePhysicsVolume(false)
	
	local leftHandComponent = hands.getHandComponent(Handed.Left)
	--attachments.attachToMesh(mesh, leftHandComponent, "hand_l", Handed.Left, defaultAttachOptions)
	--[[
	When you use K2_AttachToComponent (or AttachComponentToComponent in Blueprints) with a LocationRule of KeepWorld, 
	the relative location is automatically calculated by Unreal Engine so that the component does not move in the world.
	Mathematically, the new relative location is the component's absolute world location minus the target parent's absolute world location, adjusted for the parent's world rotation and scale.
	]]
	mesh:K2_AttachToComponent(
			leftHandComponent,
			uevrUtils.fname_from_string("Hand_L"),
			1, -- LocationRule - 1 = KeepWorld, the mesh keeps the world transform it spawned with
			1, -- RotationRule - 1 = KeepWorld
			1,           -- ScaleRule: 1 = KeepWorld
			true         -- bWeldSimulatedBodies
		)
	local finalGripLocation, finalGripRotation, gripFallback = getPickupGripOffsets(pickup)
	if string.find(pickup:get_full_name(),"FishMaidenTiara_WRR_BP_C") then
		mesh.RelativeScale3D = {X = 0.688, Y =0.688, Z= 0.688}
	elseif string.find(pickup:get_full_name(), "AquaDoorKey_BP_C") or 
		string.find(pickup:get_full_name(), "PoisonResistTiara_Pickup_C") or
		string.find(pickup:get_full_name(), "TridentKeyTrident_Pickup_C") --or
		--string.find(pickup:get_full_name(), "TridentKey_00_BP_C") or
		--string.find(pickup:get_full_name(), "StickyCure_Pickup_Bp_C") or
		--string.find(pickup:get_full_name(), "DiseaseCure_Pickup_Bp_C") 
	then
	elseif string.find(pickup:get_full_name(), "BookKey_00_WarHistory_BP_C") or
		string.find(pickup:get_full_name(), "BookKey_00_QueerRomance_BP_C") or
		string.find(pickup:get_full_name(), "BookKey_00_Wodaso_BP_C") or
		string.find(pickup:get_full_name(), "BookKey_00_BoneMachines_BP_C") or
		string.find(pickup:get_full_name(), "BookKey_00_CookBook_BP_C")	then
		mesh.RelativeScale3D = {X = 0.250, Y =0.250, Z= 0.250}	
	elseif string.find(pickup:get_full_name(), "Slashgun_Pickup_C") or string.find(pickup:get_full_name(), "ElecGun_Pickup_C") then
		mesh.RelativeScale3D = {X = 0.500, Y =0.500, Z= 0.500}	
	elseif string.find(pickup:get_full_name(), "EnergyCell_Pickup_BP_C") or string.find(pickup:get_full_name(), "EnergyCell_Half_Pickup_BP_C") then
		mesh.RelativeScale3D = {X = 0.750, Y =0.750, Z= 0.750}			
	end
	
	-- test 21: no tuned grip -> computed from the mesh bounds (qd_grip.pickupHold); the scale is lerped during the fly-in
	local holdScale = nil
	if (gripFallback or T20.forceAutoHold) and configui.getValue("pickup_auto_hold") ~= false then -- forceAutoHold: dev bridge
		local okH, hl, hr, hs = pcall(T20.pkAutoHold, mesh)
		if okH and hl ~= nil then finalGripLocation, finalGripRotation, holdScale = hl, hr, hs
		elseif not okH then uevr.params.functions.log_info("[PICKUP] auto hold failed: " .. tostring(hl)) end
	end
	startPickupLerpMovement(mesh, finalGripLocation, finalGripRotation)
	if holdScale ~= nil and pickupFlyState ~= nil then
		pickupFlyState.fromScale, pickupFlyState.toScale, pickupFlyState.sv = holdScale[1], holdScale[2], {X = 1.0, Y = 1.0, Z = 1.0}
	end

	handsAnimation.destroyAnimationHandler(leftHandComponent)
	uevrUtils.executeUEVRCallbacks("on_accessory_animation", Handed.Left, "") -- grip_left_weapon_pistol
	mesh:SetRenderInMainPass(true)
	mesh:SetRenderCustomDepth(true)
	--mesh:SetRenderInDepthPass(true)
	--mesh:SetVisibility(true, true)
	
	--no need to show sedcondary meshes...
	--[[if pickup.PickupGraphics1 ~= nil then
		pickup.PickupGraphics1:SetRenderInMainPass(false)
		pickup.PickupGraphics1:SetRenderCustomDepth(false)
	end
	if pickup.PickupGraphics2 ~= nil then
		pickup.PickupGraphics2:SetRenderInMainPass(false)
		pickup.PickupGraphics2:SetRenderCustomDepth(false)

	end]]
	--hide left hand weapon so that the pickable will replace it
	if activeLeftWeaponMesh ~= nil then
		activeLeftWeaponMesh:SetRenderInMainPass(false)
		activeLeftWeaponMesh:SetRenderCustomDepth(false)
	end
	print("attached pickable to hand", currentAvailablePickable:get_full_name())
	currentPickup = pickup
	currentPickupMesh = mesh
end

function checkIfPickablePickedup()
	if currentAvailablePickable ~= nil then
		print("checking if picked up", currentAvailablePickable:get_full_name())
		--[[if not currentAvailablePickable.DialoguePickup then -- pickable not picked up. revert its mesh visibility
			local mesh = nil			
			if currentAvailablePickable.PickupGraphics ~= nil then
				mesh = currentAvailablePickable.PickupGraphics
			else
				return
			end
			--mesh:SetVisibility(true, true)
			mesh:SetRenderInMainPass(false)
			mesh:SetRenderCustomDepth(false)
			--mesh:SetRenderInDepthPass(false)
		end]]
		
		currentPickupMesh:K2_DetachFromComponent(
			uevrUtils.fname_from_string(""),
			0, -- LocationRule - 1 = KeepWorld, the mesh keeps the world transform it spawned with
			0, -- RotationRule - 1 = KeepWorld
			1,           -- ScaleRule: 1 = KeepWorld
			true         -- bCallModify
		)
		-- test 20: KeepRelative detach left the mesh visible near the world origin. Put it back on its original parent
		-- with its original transform; the game's acquire logic then animates/hides it as in flat mode.
		local o = T20.pkOrig
		if o ~= nil and o.mesh == currentPickupMesh and o.parent ~= nil then
			local okR, errR = pcall(function()
				currentPickupMesh:K2_AttachToComponent(o.parent, uevrUtils.fname_from_string(""), 0, 0, 0, false)
				currentPickupMesh:K2_SetRelativeLocationAndRotation(o.loc, o.rot, false, empty_hitresult, true)
				currentPickupMesh:SetRelativeScale3D(o.scale)
			end)
			uevr.params.functions.log_info("[PICKUP] mesh restored to its parent ok=" .. tostring(okR) .. (okR and "" or (" " .. tostring(errR))))
		end
		T20.pkOrig = nil
		
		--show left hand weapon again
		if activeLeftWeaponMesh ~= nil then
			activeLeftWeaponMesh:SetRenderInMainPass(true)
			activeLeftWeaponMesh:SetRenderCustomDepth(true)
		end
	
		currentPickupMesh = nil
		currentAvailablePickable = nil

	end
end

function pickupPickable(state)
	physicalPickablePickup = true
	cancelCurrentPickupFlyIn()
	local pawn = api:get_local_pawn(0)
	if pawn~= nil then 
		pcall(function() currentAvailablePickable:Interact(pawn)  end)
	end
	--pcall(function() currentAvailablePickable:Pickup(false) currentAvailablePickable.Acquired = true end) -- simulate player is near pickable

	--pcall(function() currentAvailablePickable:Pickup(true) currentAvailablePickable.Acquired = true currentAvailablePickable:Pickup(false) end) -- simulate player is near pickable
	--pcall(function() currentAvailablePickable:Pickup(false) end)
	print("picked up pickable", currentAvailablePickable:get_full_name())
	checkIfPickablePickedup()	
	currentPickup = nil
	--inPickupDialog = true	
end



--[[
uevrUtils.createDeferral("populateCurrentLevelPickables", 2000, function()
	populateCurrentLevelPickables()
end)]]

function on_level_change(level)
	controllers.createController(0)
	controllers.createController(1)
	initHands()
	--needToPupolatePickables = true
	--uevrUtils.updateDeferral("populateCurrentLevelPickables")
    --currentAreaMusic = getCurrentAreaMusic()
	lastTouchedSaveArea = nil
	if T20.belt ~= nil then pcall(T20.belt.reset) end -- test 21: belt cards die with the level
	if T20.ik ~= nil then pcall(T20.ik.reset) end -- step 3: the IK copy dies with the pawn
	-- test 20: no pickup state may survive into the new level (actors are gone)
	currentAvailablePickable, pickableHeld = nil, false
	T20.pk.n, T20.pk.target, T20.pkSpawned, T20.pk.blocked = 0, nil, {}, {}
	if pickupAssistClear ~= nil then pcall(pickupAssistClear) end
	--pcall(getLastTouchedSaveArea)
	--populateCurrentLevelPickables(level:get_full_name())
	--populateCurrentLevelPickables()
	needToPupolatePickables = true
	--populateCurrentLevelPickablesDebug(level:get_full_name())
	currentStatusBar = nil
	currentHealthBar = nil
	currentAmmoBar = nil
	currentWeaponChargeBar = nil
	currentRootElement = nil
	currentConsumableBar = nil
	currentCompass = nil
	currentCompassWidgetComponent = nil

	--[[local game_engine_class = api:find_uobject("Class /Script/Engine.GameEngine")
	local game_engine = UEVR_UObjectHook.get_first_object_by_class(game_engine_class)

	local viewport = game_engine.GameViewport
	if viewport == nil then
		--print("Viewport is nil")
		return
	end
	local world = viewport.World
	local levels = world.Levels
	for _,level in ipairs(levels) do
		print(level:get_full_name())
	end]]
end


--[[
uevrUtils.registerMontageChangeCallback(function(montage, montageName)  
	if montageName ~= nil then
        print("montageName", montageName)
    end
end)
]]

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
	if normalPlay == true then	
		pcall(attachHitboxesToWeaponTip)

		local pawn = api:get_local_pawn(0)
		if pawn ~= nil and pawn.Arms ~= nil then
			if pawn.Arms ~= nil and pawn.Arms.AnimScriptInstance ~= nil then
				local playingMontage = pawn.Arms.AnimScriptInstance:GetCurrentActiveMontage()
				local montageName = playingMontage and uevrUtils.getShortName(playingMontage) or nil
				if playingMontage ~= lastWeaponMontage then
					lastWeaponMontage = playingMontage
					-- step 5 (charge/rush discovery): montage changes to the log, with dash + charge state
					pcall(function() meleeLog(string.format("[MONT] arms=%s dashing=%s charge=%s altHeld=%s", tostring(montageName), tostring(pawn.Dashing), tostring(pawn.CurrentAttackCharge_), tostring(pawn.AltAttackPressed))) end)
				end
				--[[
				if montageName ~= nil and (string.find(montageName,"Player_Slash_LeftDown_Montage") or 
				string.find(montageName,"Player_Slash_RightDown_Montage") or 
				string.find(montageName,"Player_FPArms_LeftHand_MeleeResponse_Montage") or
				string.find(montageName,"Player_FPArms_Std_Charge_Attack_Montage") or
				string.find(montageName,"Player_Stab_Charge_Montage") or
				string.find(montageName,"Player_PolearmStab_1_Montage") or
				string.find(montageName,"Player_PolearmStab_2_Montage") or
				string.find(montageName,"Player_PolearmStab_3_Montage")-- or
				--string.find(montageName,"BasicSpearDash")
				--string.find(montageName,"RustySwordDash")
				
				) then			
					--pawn.Arms.AnimScriptInstance:Montage_SetPlayRate(playingMontage, 1.0)					
					--pawn.Arms.AnimScriptInstance:Montage_Stop(0.1, playingMontage)
				end  
				]]
			end
		end
	end
end)