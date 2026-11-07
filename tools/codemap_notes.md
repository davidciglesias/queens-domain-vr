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
