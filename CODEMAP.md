# CODEMAP (rebuild: sh tools/gen_codemap.sh; edit notes in tools/codemap_notes.md)
Live profile (what the game loads): %APPDATA%\UnrealVRMod\QueensDomain-Win64-Shipping
Game script: scripts/queens_domain_vr.lua (CRLF, ~2240 lines). Mine: scripts/libs/motion_melee.lua.
Framework: scripts/libs/* (third party: don't edit or read whole, keep credits).
Log: log.txt in the profile. Lua `print` does not reach it; use uevr.params.functions.log_info.
Settings: data/user_configuration.json (saved menu values).
Pristine copies (ignored by git): backups/queens_domain_vr.lua.orig-071126 (current base, Megido 071126), backups/queens_domain_vr.lua.orig (previous base).

## Melee flow
- Weapon: getWeaponMesh sets activeWeapon (pawn.CurrentInHandWeapon) and activeWeaponMesh.
- Tick: on_pre_engine_tick -> applyNormalModeSettings -> attachHitboxesToWeaponTip, checkMeleeSwing.
- checkMeleeSwing: raw head/right-hand poses -> detector -> meleeFire (AttackPressed), meleeRelease (AttackReleased ~0.05 s later).
- F8 (register_key_bind, needs game window focus): fake hand path through the same detector.
- Notify hooks (hookFuntionsForRuntimeGeneratedClasses, WeaponScriptBase_C) re-attach hitboxes and log.
- Trigger: on_xinput_get_state callback: right = AttackPressed/Released, left = AltAttack*. Works whether motion is on or off.

## 6dof_right branches ("motion controls melee" option)
- Config definition: checkbox, off by default; sliders motion_swing_speed, motion_swing_cooldown follow it.
- Grip update callback: when off, takes a separate path (read before changing).
- disbaleAttackCooldown, disbaleMeleeFX, speedupAttackComboAnims: only when on.
- attachHitboxesToWeaponTip: only when on.
- applyNormalModeSettings: off = show arms, hide poseables and left weapon; on = hide arms.
- checkMeleeSwing and F8: only when on.
- Trigger block has its check commented out, so it always runs.

## Framework helpers
controllers.getController(0 left, 1 right, 2 head); vr.get_pose(index, Vector3f, Quaternionf) gives meters in tracking space, read with .X .Y .Z; register_key_bind(name, fn) polled by uevr_utils.

## Key lines (generated)
6dof_right checks: 161 264 445 460 473 551 679 714 1012 1327 
Attack calls: 658 670 1331 1337 1342 1348 
Notify hooks: 223 225 234 236 

## Functions in queens_domain_vr.lua (generated: line range, name)
221-247 hookFuntionsForRuntimeGeneratedClasses
249-271 attachments.registerOnGripUpdateCallback
275-293 getLeftHandWeaponMesh
295-312 getWeaponMesh
315-318 isMainMenu
320-326 isInCutScene
328-334 isInSaveMenu
336-342 isInShopMenu
345-351 isInInventoryMenu
354-376 applyMainMenuSettings
378-408 applyMenuSettings
409-438 applyCinematicSettings
440-442 isRegularPlay
444-456 disbaleAttackCooldown
459-470 disbaleMeleeFX
472-484 speedupAttackComboAnims
550-611 attachHitboxesToWeaponTip
629-631 meleeLog
633-639 meleeHitboxState
641-643 meleeLogNotify
645-660 meleeFire
662-674 meleeRelease
676-710 checkMeleeSwing
712-724 register_key_bind
727-731 meleeReportError
735-773 attachStatusBarOnce
776-810 attachHealthBarOnce
812-846 attachWeaponChargeBarOnce
849-883 attachRootElementOnce
886-913 attachAmmoBarOnce
915-946 attachConsumableBarOnce
949-979 attachCompassOnce
982-1096 applyNormalModeSettings
1099-1113 callback on_pre_engine_tick
1117-1129 on_xinput_get_state
1131-1140 initHands
1143-1148 canInteract
1160-1163 normalizeStickAxis
1165-1220 beginDodge
1222-1254 callback on_post_engine_tick
1257-1305 tryDodge
1307-1314 toggleInteractionLaser
1316-1411 callback on_xinput_get_state
1468-1472 getCurrentAreaMusic
1474-1492 getLastTouchedSaveArea
1495-1580 isPickableFromDefaultLocationMathcesArea
1582-1672 isPickableMathcesArea
1674-1698 isPickablesMatachesLevelCode
1700-1740 populateCurrentLevelPickablesDebug
1743-1773 populateCurrentLevelPickables
1776-1790 vectorSafeNormalize
1793-1801 isPickableValidForPickup
1803-1851 handleLeftHandPickables
1853-2070 getPickupGripOffsets
2072-2074 tryApplyPickupFinalGripRotation
2076-2082 applyPickupFinalGripTransform
2084-2087 cancelCurrentPickupFlyIn
2089-2091 trySetRelativeRotationLerp
2094-2128 pickupFlyInCallback
2130-2143 startPickupLerpMovement
2146-2247 attachPickableToHand
2249-2283 checkIfPickablePickedup
2285-2300 pickupPickable
2309-2344 on_level_change
2348-2352 uevrUtils.registerMontageChangeCallback
2355-2388 callback on_post_engine_tick
