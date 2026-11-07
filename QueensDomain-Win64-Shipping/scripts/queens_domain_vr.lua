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
				id = "verical_status_bar",
				label = "Verical Status Bar",
				initialValue = false
			},
			
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
		swingNotifyHook = true
	end
end

attachments.registerOnGripUpdateCallback(function()	
	if isInCutScene() or isInSaveMenu() or isInShopMenu() or isInInventoryMenu() or normalPlay == false then return nil end

    local weaponMesh = getWeaponMesh()
	
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
				if activeLeftWeaponMesh ~= nil and previousActiveLeftWeaponMesh == nil then
					showLaser = true
					interaction.showInteractionLaser(true)
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
end

function isRegularPlay() 
	return true
end

function disbaleAttackCooldown()
	if configui.getValue("6dof_right") ~= nil and configui.getValue("6dof_right") == true then
		if configui.getValue("constant_attack") == nil or configui.getValue("constant_attack") == true then 
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
function attachHitboxesToWeaponTip()
	if configui.getValue("6dof_right") ~= nil and configui.getValue("6dof_right") == true then
		local pawn = api:get_local_pawn(0)
		if pawn ~= nil and pawn.Arms ~= nil and 
			activeWeaponMesh~= nil and activeWeaponMesh.StaticMesh ~= nil and 
			activeWeaponMesh.StaticMesh.ExtendedBounds ~= nil and 
			activeWeaponMesh.StaticMesh.ExtendedBounds.BoxExtent ~= nil and
			activeWeaponMesh.StaticMesh.ExtendedBounds.Origin ~= nil then
			local activeWeaponMeshBounds = activeWeaponMesh.StaticMesh.ExtendedBounds.BoxExtent
			--local activeLeftWeaponMeshCenter = {X = activeWeaponMeshBounds.X/2, Y = activeWeaponMeshBounds.Y/2, Z = activeWeaponMeshBounds.Z/2}
			local activeLeftWeaponMeshCenter = activeWeaponMesh.StaticMesh.ExtendedBounds.Origin
	
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

-- Motion melee: swing -> AttackPressed/AttackReleased. Detector: libs/motion_melee.lua
local MELEE_RELEASE_DELAY = 0.05 -- s between AttackPressed and AttackReleased
local MELEE_SYNTHETIC_SPEED = 4.0 -- m/s
local MELEE_SYNTHETIC_TIME = 0.25 -- s
local swingDetector = motionMelee.new()
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

local function meleeFire(speed, source)
	if activeWeapon == nil then
		meleeLog(source .. " swing ignored: no weapon speed=" .. string.format("%.2f", speed))
		return
	end
	if rightTriggerHeld or meleeReleaseIn > 0.0 then
		meleeLog(source .. " swing ignored: attack button busy")
		return
	end
	attachHitboxesToWeaponTip()
	meleePressedWeapon = activeWeapon
	meleeReleaseIn = MELEE_RELEASE_DELAY
	meleeSwingCount = meleeSwingCount + 1
	activeWeapon:AttackPressed()
	meleeLog(string.format("swing #%d %s speed=%.2f threshold=%.2f %s", meleeSwingCount, source, speed, swingDetector.fireSpeed, meleeHitboxState()))
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
		end
	end
end

function checkMeleeSwing(delta)
	meleeClock = meleeClock + delta
	meleeRelease(delta)
	if configui.getValue("6dof_right") ~= true then return end

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

	if swingDetector.missPeak > 0.0 then
		meleeLog(string.format("no swing: peak=%.2f reason=%s", swingDetector.missPeak, tostring(swingDetector.missReason)))
		swingDetector.missPeak = 0.0
	end
	if fired then meleeFire(speed, source) end
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
				controllers.attachComponentToController(1, myWidgetComponent, "", nil, nil, true)
				--[[myWidgetComponent:K2_AttachToComponent(pawn.Arms,
					uevrUtils.fname_from_string("UpperArm_R"),
					2, -- SnapToTarget Location
					2, -- SnapToTarget Rotation
					2, -- SnapToTarget Scale  - inherits the weapon's scale
					true
				) ]]
				if configui.getValue("verical_status_bar") ~= nil and configui.getValue("verical_status_bar") == true then
					uevrUtils.set_component_relative_transform(myWidgetComponent, {X=15.780,Y=-48.670,Z=11.350}, {Pitch=181.720,Roll=76.270,Yaw=2}, {0.05,0.05,0.05}) -- z - forwad , y = right , x - up
				else
					uevrUtils.set_component_relative_transform(myWidgetComponent, {X=8.630,Y=-3,Z=10.0}, {Pitch=181.720,Roll=-203.010,Yaw=2}, {0.05,0.05,0.05}) -- z - forwad , y = right , x - up	
				end
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
				--uevrUtils.set_component_relative_transform(myWidgetComponent, {X=-2.7,Y=6.270,Z=20}, {Pitch=-202,Roll=165,Yaw=-4}, {0.03,0.03,0.03}) -- z - forwad , y = right , x - up	
				uevrUtils.set_component_relative_transform(myWidgetComponent, {X=3.100,Y=-4.240,Z=7.510}, {Pitch=-202,Roll=165,Yaw=-4}, {0.03,0.03,0.03}) -- z - forwad , y = right , x - up	
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


function applyNormalModeSettings(delta) 
		
	vr.set_mod_value("VR_2DScreenMode", false)
	--vr.set_mod_value("UI_Distance", 2.0)
	--vr.set_mod_value("UI_Distance", 2.8)
	vr.set_mod_value("UI_FollowView", "true")
	if showLaser then
		vr.set_mod_value("VR_AimMethod", "3")
		if currentCompass ~= nil then
			currentCompassWidgetComponent:SetVisibility(false, true)
		end
	else
		vr.set_mod_value("VR_AimMethod", "2")
		if currentCompass ~= nil then
			currentCompassWidgetComponent:SetVisibility(true, true)
		end
	end
	vr.set_mod_value("VR_RoomscaleMovement", "1")
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
		if not interactBuzzed then
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
	pcall(attachConsumableBarOnce)
	pcall(attachCompassOnce)
	if activeLeftWeaponMesh ~= nil then
		pcall(attachAmmoBarOnce)
	end
end


uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	hookFuntionsForRuntimeGeneratedClasses()		
	if isMainMenu() then
		applyMainMenuSettings()
	elseif isInCutScene() then
		applyCinematicSettings()
	elseif isInSaveMenu() or isInShopMenu() or isInInventoryMenu() then
		applyMenuSettings()
	else ---regular play
		if dodgeCooldownRemaining > 0.0 then
			dodgeCooldownRemaining = dodgeCooldownRemaining - delta
		end
		applyNormalModeSettings(delta)	
	end
end)



function on_xinput_get_state(retval, user_index, state)
	if hands.exists() then
		local isHoldingWeapon = activeWeaponMesh ~= nil
		--print("isHoldingWeapon", isHoldingWeapon)
		local hand = Handed.Right
		hands.handleInput(state, isHoldingWeapon, hand)
		
		local isHoldingLeftWeapon = activeLeftWeaponMesh ~= nil or currentAvailablePickable ~= nil
		--print("isHoldingWeapon", isHoldingWeapon)
		local offHand = Handed.Left
		hands.handleInput(state, isHoldingLeftWeapon, offHHand)
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
	interaction.showInteractionLaser(showLaser)
end

uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
	if (state ~= nil) then
		if normalPlay == true then
			if state.Gamepad.wButtons & XINPUT_GAMEPAD_RIGHT_THUMB ~= 0 then
				if not rightThumbHeld then
					toggleInteractionLaser()
					rightThumbHeld = true				
				end
			else
				rightThumbHeld = false	
			end
			--if configui.getValue("6dof_right") ~= nil and configui.getValue("6dof_right") == true then
				if activeWeapon ~= nil then
					if state.Gamepad.bRightTrigger >200 then
						if rightTriggerHeld == false then --need to only call once, since calling ti again, cancels current call
							activeWeapon:AttackPressed()
						end
						rightTriggerHeld = true
						state.Gamepad.bRightTrigger = 0
					elseif rightTriggerHeld == true then
						attachHitboxesToWeaponTip()
						activeWeapon:AttackReleased()
						rightTriggerHeld = false
					end
					if state.Gamepad.bLeftTrigger >200 then
						if leftTriggerHeld == false then --need to only call once, since calling ti again, cancels current call
							activeWeapon:AltAttackPressed()
						end
						leftTriggerHeld = true
						state.Gamepad.bRightTrigger = 0
					elseif leftTriggerHeld == true then
						attachHitboxesToWeaponTip()
						activeWeapon:AltAttackReleased()
						leftTriggerHeld = false
					end
				end
			--end
			if configui.getValue("disable_dodge") == nil or configui.getValue("disable_dodge") == false then 
				if state.Gamepad.sThumbRY < -15000 and (state.Gamepad.sThumbLX > 15000 or state.Gamepad.sThumbLX < -15000 or state.Gamepad.sThumbLY > 15000 or state.Gamepad.sThumbLY < -15000) and not dodgeWasHeld then
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
				if state.Gamepad.wButtons & XINPUT_GAMEPAD_A ~= 0 then
					if pickableHeld then
						pickupPickable(state)
						pickableHeld = false
						state.Gamepad.wButtons = state.Gamepad.wButtons - XINPUT_GAMEPAD_A
						aButtonHeld = true
						--state.Gamepad.wButtons = state.Gamepad.wButtons | XINPUT_GAMEPAD_LEFT_SHOULDER --to release the left hand being stuck in gripping pose
						return 
					end
				else
					if state.Gamepad.wButtons & XINPUT_GAMEPAD_LEFT_SHOULDER ~= 0 then					
						if not pickableHeld then 
							attachPickableToHand()
							pickableHeld = true
						end
						leftShoulderButtonHeld = true
						state.Gamepad.wButtons = state.Gamepad.wButtons - XINPUT_GAMEPAD_LEFT_SHOULDER	
						return
					end	
				end
			end
			if canInteract() then --left grab is X in case of canInteract
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

function handleLeftHandPickables()
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
		return {X = configui.getValue("loc_x"),Y = configui.getValue("loc_y"), Z = configui.getValue("loc_z")},{Yaw = configui.getValue("rot_yaw"), Roll = configui.getValue("rot_roll"), Pitch = configui.getValue("rot_pitch")}	
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
	local finalGripLocation, finalGripRotation = getPickupGripOffsets(pickup)
	if string.find(pickup:get_full_name(), "FishMaidenTiara_WRR_BP_C") then
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
	
	startPickupLerpMovement(mesh, finalGripLocation, finalGripRotation)

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
					print("arms montageName", montageName)				            
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