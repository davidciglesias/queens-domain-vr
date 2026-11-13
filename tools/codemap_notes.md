# CODEMAP (rebuild: sh tools/gen_codemap.sh; edit notes in tools/codemap_notes.md)
Live profile (what the game loads): %APPDATA%\UnrealVRMod\QueensDomain-Win64-Shipping
Game script: scripts/queens_domain_vr.lua (LF, ~4000 lines). Mine: scripts/libs/motion_melee.lua, qd_grip.lua (auto-grip math), qd_pickup.lua (pickup target scoring), qd_belt.lua (consumable belt), qd_ik.lua (IK arms); tests tools/test_*.lua.
LIMIT: the main chunk has 199 top-level locals (Lua max 200). New state/functions go in the T20 table (or other tables/globals), never new top-level locals. Tests (python tools/run_tests.py) load the LIVE profile copy: sync first.
Framework: scripts/libs/* (third party: don't edit or read whole, keep credits).
Framework = jbusfield/uevrlib, identical copy: docs in refs/uevrlib/docs/*.md. Game SDK (Dumper7): refs/Dumper7SDK/.../CppSDK/SDK/*_classes.hpp, grep before adding discovery logging (spoiler-prone file names). See REFERENCES.md.
Log: log.txt in the profile. Lua `print` does not reach it; use uevr.params.functions.log_info.
Settings: data/user_configuration.json (saved menu values).
Pristine copies (ignored by git): backups/queens_domain_vr.lua.orig-071126 (current base, Megido 071126), backups/queens_domain_vr.lua.orig (previous base).

## Melee flow
- Weapon: getWeaponMesh sets activeWeapon (pawn.CurrentInHandWeapon) and activeWeaponMesh.
- Tick: on_pre_engine_tick -> applyNormalModeSettings -> attachHitboxesToWeaponTip, checkMeleeSwing.
- checkMeleeSwing: raw head/right-hand poses -> detector -> meleeFire (AttackPressed), meleeRelease (AttackReleased ~0.05 s later).
- Charge/rush (step 6, T20.S6): T20.S6.tick (from checkMeleeSwing) pulses the right hand while RT charges (charge_haptics; motion_melee ChargeHaptics on pawn:CalculateChargeMultiplier_Impure out.result via T20.S6.mult) and runs the RushBuffer on pawn.Dashing: a swing in a dash waits until rush_earliest s (default 0.6) or dash end (rush_buffer option); step 9: only when the weapon has DashHitboxBonusRange (rush.enabled, set on weapon change; spear-type dashes fire at once).
- F8 (register_key_bind, needs game window focus): fake hand path through the same detector.
- Notify hooks (hookFuntionsForRuntimeGeneratedClasses, WeaponScriptBase_C) re-attach hitboxes and log.
- Trigger: on_xinput_get_state callback: right = AttackPressed/Released, left = AltAttack*. Works whether motion is on or off.
- L2 (frame_layout + l2_native_dodge): with l2_stab_gesture + 6dof_right, L2 only arms (l2StabArmed, l2StabSeen); checkMeleeSwing sends a fired stroke to l2StabFire instead of meleeFire: needs (stab_outward 0 = off) and signed stabAxisAlign (|cos| stroke dir vs weapon long axis hbCache.axis, world) >= stab_axis, then startNativeDodge(0,"L2stab") (AltAttackPressed), l2StabRelease ~0.1 s later. Else L2 press = startNativeDodge directly.
- Hit window (motion_hit_window, step 10): hitWinOpen/hitWinClose/hitWinTick/hitWinPollHits call pawn:ActivateHitbox/DeactivateHitbox (never hook those: tick deadlock); hookHitWindow pre-hooks PlayerHitboxState_C Received_NotifyBegin/End to skip the game's late window. Detector .speed = latest hand speed; hitWinOpen skips when it is below rearmSpeed (buffered rush/post-dash -> game window). attachHitboxesToWeaponTip: bounds from StaticMesh or SkeletalMesh (skeletal weapons via visuals SocketComp).
- Detector lastOutward = share of the committed run's travel away from the head (thrust ~0.6+, sideways swing ~0.2, chop < 0); in play swipes still gave 0.4-0.8. lastDirX/Y/Z = unit net run direction (tracking), lastStraight = net/path.

## Crosshair / aim (updateAimDot, every pre-tick)
- Game crosshair = HUD canvas draw (MyHUD.Crosshairmat, UI-domain MID) -> left eye only. game_crosshair: xhairEnsure/xhairCreate host a UMG Image (brush = that MID) as WidgetTree.RootWidget of a game UserWidget on a world WidgetComponent; xhairPlace at the trace point facing the head (rotation computed in Lua: FindLookAtRotation writes a "result" key into Lua-table args -> breaks reused tables; avoid it with tables). xhairCanvas sets BaseCrosshairSize 0 (restored when off). crosshair_bold: root = Overlay (black-tinted copy full size + 2 copies padded XHAIR_PAD), toggled live in xhairEnsure. crosshair_on_top: bDisableDepthTest on /Engine Widget3DPassThrough base (xhairEnsure).
- Trace origin = PlayerCameraManager camera location; direction: knife aim (showLaser) = left controller; else head gaze (game_crosshair_gaze, regular play only). Orange sphere only when the crosshair is unavailable/off.

## Right stick (on_xinput_get_state, frame_layout)
- rstick_turn (default): RS X x rstick_turn_speed to the game (smooth turn), RS Y zeroed. Off: rstick_dodge = directional native dodge, stick consumed.

## Dev bridge
- MCP: uevr_lua_exec `uevr.api.dispatch_lua_event("qd_exec", "<lua>")` runs the chunk in the game script's state (globals, QD table); qdlog(...) / return value -> log.txt "[EXEC]" (read with uevr_uevr_log filter "[EXEC]"). Only after the script was (re)loaded.
- mpcDump: broken (TArray<struct> reads nil), no longer called. MPC names were read from memory (FName index -> write into a spare FName prop, read back). Game_MPC: FPFOV=60 (weapon viewmodel FOV, native rewrite each tick), FS_Time*, PhotoMode, HideFPEffects; PixelFilter_MPC: EnableDither, DitherStrength=64.
- Lua in game state: no `debug` lib; locals (configui, controllers, uevrUtils) via package.loaded["libs/..."]; UFunction:hook_ptr available (obj:as_function()).

## Weapon FOV fix (weapon_fov_fix, weapon_fpfov)
- fpfovApply from on_pre_viewport_client_draw + on_early_calculate_stereo_view_offset: sets Game_MPC FPFOV to weapon_fpfov or auto = camera FOV (PlayerCameraManager:GetFOVAngle, 100; verified fix; per-eye 110 was wrong). "[FPFOV]" log. Neither callback fires with the HMD inactive.

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

## Pickups (pickup_assist, test 20)
- applyNormalModeSettings -> handleLeftHandPickables -> pickupAssistTick (old cone code kept when option off). Candidates = currentLevelPickables (level scan) + items spawned later (ReceiveBeginPlay post-hook on ItemPickup_Base_C, T20.pkHookSpawns/pkMergeSpawned), refreshed every 0.25 s (T20.pkRefresh: valid, within reach, centre from GetComponentBounds out param `.result`, else mesh pivot).
- qd_pickup.select: proximity grab (hand within 30 cm) or hand ray / eye ray (camera loc + left controller forward = knife crosshair) within max(r,10 cm) + dist*tan(pickup_cone); sticky current target. Occlusion: eye line trace (T20.pkOccluded) -> skip 0.5 s.
- Feedback: haptic tick on target change, beam (engine Cylinder, DebugMeshMaterial, T20.pkBeam*), crosshair snaps to pickupSnap in updateAimDot. Grab: left grip or X (frame_layout) -> attachPickableToHand (fly-in) -> pickup_auto_take: pickupPickable after fly-in (tick), else A. xinput: T20.xHeld swallows X until released; X no longer stripped when an item is targeted.
- Held look (test 21, pickup_auto_hold): getPickupGripOffsets returns a 3rd value true when the item has no tuned entry (105 tuned of ~350 classes) -> T20.pkAutoHold(mesh) -> qd_grip.pickupHold(StaticMesh bounds): long axis through the fist, thin axis out of the palm, bounds centre on the palm, max 35 cm; scale lerped in pickupFlyInCallback (pickupFlyState.fromScale/toScale). Hand_L socket frame: +X thumb, -Y fingers, -Z out of the palm. T20.forceAutoHold (bridge) forces it on tuned items.

## Auto grip (auto_grip, test 20)
- Grip callback -> autoGripEnsure(mesh, weapon): no attachments entry for the id -> qd_grip.autoGrip(StaticMesh:GetBounds()) oriented like the sword entry (T20.agRef, id RustySword_...), guns (class chain has GunBase_WeaponScript_C, T20.agIsRanged) barrel-straight -> attachments.addAttachmentToConfig + setAttachmentOffset (saved to data/attachments_parameters.json). Saved entries never touched. "[GRIP] auto" log.
- checkMeleeSwing: swings never attack with a ranged weapon ("swing ignored: ranged weapon").

## Self-test harness (test 20)
- tools/fakevr: SteamVR driver qdfake (fake HMD + Touch controllers, UDP 127.0.0.1:27115), fakevr.ps1 on/off/status, fakevr.py (poses, buttons, swings, haptics). See tools/fakevr/README.md.
- tools/screenshot.ps1: game window -> downscaled JPEG (Read it as an image).
- Bridge helpers: QD.dev.state() (pawn/camera/controllers/weapon/pickup state), QD.dev.items(n), QD.dev.weapons(), QD.dev.face(x, y); QD.T20 = T20.
- Game saves: %LOCALAPPDATA%/QueensDomain/Saved/SaveGames (Steam Cloud). Back up before cheat tests, restore after (backups/saves_*).
- T20.cleanupStale: first regular tick after a script load destroys the previous instance's beam/aim-dot sphere/debug cubes (plain Actor owners).

## Consumable belt (belt, belt_drop, test 21)
- libs/qd_belt.lua (tests tools/test_qd_belt.lua). Init + an on_xinput_get_state callback registered just before the main xinput callback (so a belt grab swallows its grip before the pickup code / game); tick at the end of the on_pre_engine_tick callback (regular play, else hideAll). QD.belt = module (bridge).
- Items: pawn.ConsumableRotationOrder (all consumable types) filtered by GameInstance:ReadInventoryItemCount > 0, max 5, every 0.5 s. Cards = world WidgetComponents (XHAIR_HOSTS host widget, Overlay: tinted Image + item icon (ItemIcon via SetBrushFromTexture) + count TextBlock), arc at the waist (head yaw smoothed, belt_drop cm below the eyes), facing the head, shown when looking down / hand near / holding.
- Grab: grip rising edge with a controller within 14 cm of a card; card follows the hand; within 17 cm of the mouth -> select it as the game's consumable (GameInstance.ActiveSaveSlot.SelectedConsumable = item, which the use event reads; HUD SetSelectedItem for display only; old SelectNextConsumable cycle kept as fallback) + pawn:InpActEvt_UseItem_K2Node_InputActionEvent_21(key); "[BELT] use result: count a -> b" 1.5 s later. ScriptUseItem is NOT used (never lowered the count in test 21).
- Right hand pose: global on_xinput_get_state makes ONE hands.handleInput(state, isHoldingWeapon, Right) call (test 21 removed the buggy 2nd call that reopened the weapon hand).

## IK arms (ik_arms, plan step 3, test 25)
- libs/qd_ik.lua (tests tools/test_qd_ik.lua) wraps uevrlib libs/ik.lua; config data/ik_parameters.json (profile "default": mesh Pawn.Arms, parent_type 2, solvers left_arm/right_arm with explicit start_bone/joint_bone/end_bone; the lib's own ancestor guess picks Clavicle/UpperArm = wrong).
- Load: main script, right after the belt init: only if ik_arms is true at script load (require fails later, also from the bridge) -> T20.ik, QD.ik. Off at load = lib never loaded. Tick: pre-engine tick after the belt: T20.ik.tick(ik_arms and 6dof_right, T20.ikPlay, delta); T20.ikPlay = regular-play branch (paused included). on_level_change -> T20.ik.reset.
- qd_ik pure: followYaw (dead zone + rate + drift), decide (create/destroy/show/hide/place), meshOrigin, toWorld, reachShift, clampLen. Runtime: create (ik.new, SetAbsolute, scale 1.2, HideBoneByName Hand_L/R, measures shoulders + arm length), place (world transform from the HMD every tick, reused vector/rotator), calibrate (wrist offset = hands-lib Hand bone in controller space, once a second), destroy (ik.destroyAll).
- Tunables on the module table (live via QD.ik.X): DROP, BACK, SCALE, DEAD, RATE, DRIFT, REACH, MAX_PULL. State QD.ik.st (rig, mesh, bodyYaw, hidden). Log tag "[IK]".
