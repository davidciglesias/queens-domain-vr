# STATE archive (tests 1-18). Historical; current state in STATE.md.

## Test 1 result (2026-11-07)
- Detector works: [MELEE] lines reach log, swings 2.7-10 m/s fire, F8 works. Every swing logs no-pawn-or-mesh (activeWeaponMesh nil; activeWeapon set) -> check CurrentVisuals.Mesh in P2.
- UI: dialogue text rendered far too low. Added ui_y_offset slider (default 0.3, applied as UI_Y_Offset in applyNormalModeSettings). Untested; backup backups/queens_domain_vr.lua.pre-uiy.
- Inputs: this UEVR build (Aug302026) suggests no valve/frame_controller bindings (only simple/go/touch/index...), so mapping is UEVR/SteamVR-level. Script remaps (grip->X on interact, R-thumb laser, R-stick dodge) not yet changed; dpad unused by script.

- Remap done (untested): checkbox frame_layout (default on): B = dodge via beginDodge (edge-triggered, B consumed), stick-gesture dodge and LB->X interact remap disabled when on; fixed LT block clearing bRightTrigger. D-pad, X/Y, RB, L3, A pass through. LB still grabs pickables, R3 still toggles laser.

## Test 2 feedback (2026-11-07) + fixes (untested; backup backups/queens_domain_vr.lua.pre-menufix)
- UI Y offset fine now (manual). B dead in menus: pause menu not detected as menu, B was eaten by dodge remap -> now skipped when uevrUtils.isGamePaused().
- Movement followed hand: VR_MovementOrientation was 0 -> script now sets 1 (HMD) in applyNormalModeSettings.
- Options/Start don't open menu: added [INPUT] buttons=0x.. log on mask change; check which bits arrive (likely SteamVR binding, not script).
- OPEN: weapon model vs hitbox/debug lines mismatch. Hitbox uses mesh-local ExtendedBounds.Origin with SnapToTarget scale; suspect visible weapon is another component (hand attachment) than activeWeaponMesh. Need which "debug lines" (UEVR hitbox vis? game?) and a log of both world positions.

## Native controls (user, flat play, Steam Controller, 2026-11-07)
D-pad right = cycle weapons; Start = menu; Select/Options = inventory; L3 = sprint; L2 = backwards dodge; R2 = attack (hold = charge for extra power); A = jump / OK; X = interact; B = cancel in menus; Y, L1, R1 unknown yet.
Spear: points forward, can be extended for damage (charge?) -> VR idea: poke gesture = extend/attack, swing = normal attack, R2 still charges. Spear model looked badly aligned in VR (see OPEN above).
Conflicts to resolve: our script uses B=dodge (native dodge is L2) and L2 = AltAttack; with native Start/Select not reaching the game in VR, check [INPUT] log.

- 2026-11-07: L2/AltAttack left as original. R2 "spam" in VR: added hysteresis (press>200, release<100) + [MELEE] "RT AttackPressed/Released held=Xs" log (backup backups/queens_domain_vr.lua.pre-rt). Hypothesis if still spam: we zero bRightTrigger so game never sees the hold; real fix may be passing the trigger through. Flat play does not write the log (no UEVR).

- 2026-11-07 (backup .pre-dbg): original profile zeroed NormalAttackBlockDurationBase (probable R2 spam cause) -> now untouched, value logged "[MELEE] weapon NormalAttackBlockDurationBase=". Added checkbox debug_hitboxes (default on): wireframe cubes on pawn.NormalHitbox / DefaultHitbox + small cube at weapon mesh pivot; "[DBG]" log with world positions on weapon change and each swing. Spear grip offset in data/attachments_parameters.json (BasicSpear entry rot 0,-90,-270 from original author) suspected misaligned; not edited yet. Untested.

## Charge/rush plan
See PLAN_charge_rush.md (discovery first: log montages + hold durations, no code until approved).

- 2026-11-07: reinstalled: repo script copied to live profile (live was stale). Backup of old live: backups/queens_domain_vr.lua.live-before-reinstall. Config/user_configuration left untouched. Use the same copy after each edit.

## Test 3 feedback + fixes (2026-11-07, untested; backups .pre-t3 in backups/)
- Log showed only A(0x1000) X(0x4000) Y(0x8000) RB L3 R3 ever arrive in XINPUT; B, Start/Back, D-pad never do -> SteamVR binding gap. Script now polls UEVR actions (DPad_*, SystemButton, BButtonRight) and ORs them into wButtons (Start/dpad/B); logs "[ACT] name=bool" on change so we see which really fire. Inventory (Back) has no source yet.
- X suppressed unless canInteract() (it was jumping). Dodge now uses HMD world yaw (controllers.getController(2)), backward when stick neutral.
- Status HUD was attached to controller 1 (right); now controller 0 (left) with consumable-like wrist transform (guess; tune).
- Spear pointed 90deg left of hand: BasicSpear yaw -90 -> 0 in data/attachments_parameters.json (guess, flip to -180 if wrong). Copied to live.

## Test 4 feedback + fixes (2026-11-07, untested; backup backups/queens_domain_vr.lua.pre-t4)
- Root cause of R2 spam/no charge: xinput callback fires twice per frame, the 2nd call all-zero. Now: lock to the first user_index with data ("[INPUT] locked user_index=") + 60 ms RT release debounce.
- UEVR action BButtonRight fired on every face button -> removed from pollActions (real B arrives as 0x2000). D-pad/System actions never fire; UEVR D-pad shifting gives nothing.
- frame_layout: L2 = beginDodge (HMD-relative, backward if stick neutral), AltAttack off; B passes through native. Y-chord D-pad removed (user has a real D-pad).
- Status HUD: left controller, compass transform mirrored (pos Y/Z negated, rolled 180 about X), scale 0.006; "[HUD]" log. Guess; tune.
- OPEN hitbox vs model: hitbox follows activeWeaponMesh (=grip mesh), center 48 cm along mesh X, extent 60x4x1.8; debug cube matches hitbox by construction. User: wireframe too far forward. Now uses StaticMesh:GetBounds() (render) instead of ExtendedBounds, cached per mesh, + slider hitbox_forward_offset (cm along mesh X). Log "[DBG] hitbox bounds src=" compares both.
Next: user restarts game, tests, says done; read [INPUT]/[HUD]/[MELEE] RT held= lines.
## Test 5 feedback + fixes (2026-11-08, untested; backup backups/queens_domain_vr.lua.pre-t5)
- SteamVR binding gave D-pad + Start (SystemButton fires). Select->touchpad click poor. Face buttons bound via oculus a/b left/right.
- Log: spear mesh long axis = +X (origin 48.3, ext 60.4); other blade = -Y (origin -25.8, ext 36.5) with mesh scale ~3 (pivot->hitbox 78 cm). Old forward-offset slider always moved along X -> wrong axis for Y-long blades.
- Hitbox now: auto long axis + tip sign from bounds; new slider hitbox_reach (cm, grows tip end only, for spear thrust which VR can't do); relative rotation reset to 0 every tick (game may rotate hitbox during attacks). [DBG] now logs a 2nd "rot" line: mesh/hitbox/head world rotations, hitbox rel rot + scale, axis.
- Charge: checkbox charge_on_swing (default on): RT held = charging, a detected swing sends AttackReleased ("charged swing release held="), RT up then sends nothing. RT up without swing = old behaviour.
- To check next: "rotates with HMD" claim via rot line (hbRel nonzero? normalHB rot != mesh rot?); does charged swing release give a charged attack; reach value that feels right for spear (maybe per-weapon later).

## Test 6 fixes (2026-11-08, untested; backup backups/queens_domain_vr.lua.pre-t6)
- Test 5 log: hitbox rot == mesh rot, hbRel 0 -> alignment OK. User had saved hitbox_forward_offset=-60 (global) -> sword box ended ~behind the hand.
- Hitbox sliders now per class (X-long mesh = spear): spear = hitbox_forward_offset (default -60) + spear_reach (30); blade = blade_offset (-40) + blade_reach (10). Old hitbox_reach removed. Tune live in the menu.
- HUD: user meant ConsumableHUD (near left hand), not StatusCluster. StatusCluster restored to original (controller 1, original transform); ConsumableHUD now gets mirrored-compass transform on controller 0, scale 0.012, "[HUD] consumable" log.
- Inventory (Select) binding still unsolved; minor.

## Test 7 fixes (2026-11-08, untested; backups .pre-t7 for script + user_configuration.json)
- Test 6 log: saved frame_layout was FALSE -> L2 ran native AltAttack dodge (aim-relative). Flipped to true in live user_configuration.json. Added "[DODGE] hmdYaw= usedHead= ctrlYaw= dirYaw=" log.
- Knife cursor = left-hand interaction laser + VR_AimMethod 3; log showed R3 pressed 14x (incl. 0x00C0 with L3) toggling it off -> aim fell to right hand. With frame_layout: R3 no longer toggles laser, laser forced on while Daggervisuals present ("[LASER] on").
- User dislikes the laser: checkbox aim_dot (default on) + slider aim_dot_size. updateAimDot (every pre-tick) = Sphere mesh at left-controller forward trace hit (LineTraceSingle, Visibility, ignores pawn, max 50 m), constant angular size; laser hidden while aim stays on the left hand; compass no longer hidden by knife aim. "[AIM] dot shown" logged once. Game's own aim marker missing: original profile never hid it (likely a screen-centre 2D widget); not chased.
- HP HUD (StatusCluster) moved to left controller; live sliders hp_hud_x/y/z/pitch/yaw/roll/scale (applyHpHudTransform, re-applied on change, "[HUD] hp on left" log). Start values = right-hand original mirrored (Y, yaw, roll negated). verical_status_bar now unused.
- Blade hitbox: sliders blade_side / blade_flat (mesh-local units along the two short axes).
- Weapon attach confirmed (subagent): attachments.lua K2_AttachTo the right MotionController, no HMD code. "Weapon follows HMD" diag: "[DIAG] head= rCtrl= mesh= meshRel= parent= pawnYaw= ctrlYaw=" when head yaw moves >15 deg (80 lines max). Test: hold right hand still, turn head.

- D-pad/face-button fix = SteamVR binding: UEVR (OpenVR) ships bindings only for knuckles/touch/vive/rift; the Frame controller uses an emulated one (D-pad unbound, BButtonRight fires on every face button). User to bind D-pad -> DPad_*, Menu -> SystemButton, B -> BButtonRight in SteamVR for the game; pollActions already ORs DPad_*/SystemButton into wButtons. Then check SteamVR's saved binding file.

## Test 8 (2026-11-08, untested; backup backups/queens_domain_vr.lua.pre-t8)
- Test 7 result: weapons drift opposite to head translation (head right -> weapons left, up -> down). [DIAG] rotations fine (mesh follows rCtrl, not head) -> positional. Added "[POS]" log (head, cam-head, rCtrl-pawn, mesh-rCtrl, head-pawn; on >8 cm head move, 60 max) + checkbox roomscale (default on) to A/B VR_RoomscaleMovement.
- Aim dot hard to see; user wants the game's own aim marker (seen near left hand, away from compass) placed where the left hand points. Discovery: "[HUDDUMP]" dumps HUD widget props + trees of ConsumableHUD/CompassWidget/StatusCluster (vis, parent, size, opacity) 3 s after knife aim on; F9 re-dumps.
- ConsumableHUD ("usable item") not visible in VR though flat shows it -> check its HUDDUMP vis/opacity.
- Checkbox hide_knife_model (default on): knife mesh RenderInMainPass off (updateKnifeModelVisibility).
- [HUD] hp on left logs on every slider change (3600 lines while dragging); harmless.

## Test 9 (2026-11-08, untested; backup backups/queens_domain_vr.lua.pre-t9)
- Test 8 log: [POS] with roomscale on: pawn follows head horizontally (head-pawn XY const), rCtrl world stays put, camera base follows head -> suspect view gets head offset twice (near weapons drift, far world barely). roomscale default now OFF (user never toggled it). B (0x2000) reaches game natively; effect unknown.
- Item HUD (ConsumableHUD): test-6 mirrored transform invisible; now original start transform + live sliders item_hud_* (applyItemHudTransform), SetTwoSided(true), "[HUD] item icon vis=" logged on change. At load ItemIcon/Name/Count were Collapsed (frame visible).
- hide_knife_model default -> false (user missed the knife).
- L2: checkbox l2_native_dodge (default on): faceHmdForNativeDodge (pawn + control rotation to HMD yaw, VR_AimMethod=1 for 0.8 s) then native AltAttackPressed/Released (animation). "[DODGE] native hmdYaw= pawnYawBefore=". Off = old LaunchCharacter dodge (no anim, variable distance from friction/stop at 550).
- User idea (not done): right stick = directional dodge, other right-stick actions disabled. Ask after native dodge test.
- 9b: right stick = directional native dodge (checkbox rstick_dodge, default on; right stick zeroed -> no game turning; UEVR snap turn already off). startNativeDodge(offsetDeg, src): pawn faces HMD yaw+offset+180, bUseControllerRotationYaw/bOrientRotationToMovement off for 0.8 s then restored (restoreDodgeFacing), native AltAttackPressed; released when stick < 9000. Logs "[DODGE] native src= ... useCtrlYaw= orient=" and "[DODGE] end moved= moveYaw= wantYaw=" -> if moveYaw != wantYaw the game dodges along control rotation, not actor rotation. Removed SetControlRotation (could have jumped the view).

## Test 10 (2026-11-08, untested; backup backups/queens_domain_vr.lua.pre-t10; copied to live)
- Ideas 1-4 done: (1) "[DODGE] dash Dashing= dir= dist= speedMult=" after dodge end; (2) chargeInfo() appends "charge=<CurrentAttackCharge_>" to swing-release and RT-release logs; (3) openInventory(): pawn:OpenPauseMenu(true), triggers F7 or XInput Back bit 0x0020 (log "[INV]"); (4) getWeaponMesh falls back to CurrentVisuals.SocketComp / GetMeshes (log "[MELEE] mesh via SocketComp/GetMeshes fallback").
- (5) spear grip = manual in-game via uevrlib "Attachments Config Dev" tab (user). (6) uevr-mcp NOT installed: no prebuilt uevr_mcp.dll locally (release/ has only install.ps1); needs GitHub release download or cmake build. Awaiting user go on source.
- 2026-11-08: (6) uevr-mcp installed from release v1.0.0 (C:\Tools\UevrMcp, plugin DLL in live plugins\, user-scope MCP 'uevr'). Restart Claude Code, then launch the game with UEVR.
- Select/Options: pollActions now maps action Teleport -> Back bit 0x0020 -> openInventory. User binds Select -> Teleport in SteamVR. F7 only a test hook.

## Test 11 (2026-11-08, untested; backup backups/queens_domain_vr.lua.pre-t11; copied to live)
- Test 10 log: Teleport action never fired (only DPad_*/SystemButton) -> SteamVR Select binding not applied. Chord L3+R3 worked ([INV] ok) but is the UEVR menu -> replaced in test 12 by R3 alone.
- RS dodge always backward: [DODGE] moveYaw ~= pawnYawBefore+180 regardless of facing -> game dashes toward LEFT-stick input, backward when neutral. startNativeDodge(RS) now spoofs sThumbLX/LY (dodgeStick, 0.5 s) in the HMD-relative direction; pawn-facing hack kept.
- Charge: CurrentAttackCharge_ reads nil (also via MCP lua: FS_PlayerChar_C fields nil on FS_Full_PlayerChar_C there). chargeInfo now logs pawnAtk/ultra/visCharge/calc/wCount/montage for discovery.
- Left-hand square = likely empty ConsumableHUD frame: component now hidden while ItemIcon is Collapsed/Hidden.
- Left-hand dagger = StaticMeshComponent (Default_Dagger_Low) on left MotionController, visible; hide_knife_model default false (user wanted it back in test 9) -> check box in menu; ask user which they want.

## Test 12 (2026-11-08, untested; backup .pre-t11 is pre-test-11; copied to live)
- Select: R3 alone (frame_layout) -> Back -> openInventory; L3+R3 chord removed (UEVR menu). openInventory confirmed ok in log.
- RS dodge: log showed dash always goes backward from HMD yaw (spoofed stick had no effect: game reads stick at press time, our spoof came after). Now AltAttackPressed is fired 0.12 s AFTER the stick spoof starts (dodgeStick.fireT), released at +0.3 s; log "[DODGE] RS press fired with spoofed stick".
- Item HUD: icon slot was anchored bottom-centre vs frame top-left -> re-slotted onto the frame centre (log "[HUD] item icon re-slotted"), sliders item_icon_dx/dy nudge.
- HUD rotation: new sliders hp_hud_rx/ry/rz and item_hud_rx/ry/rz = extra rotation about the hand's own X/Y/Z axes applied on top of the old Euler sliders (hudRotation, quaternion, gimbal-free, unit-checked in lupa). Old pitch/yaw/roll sliders unchanged.
- Charge debug: two wireframe bars on the weapon mesh (debug_hitboxes on): LIVE grows 10 cm/s of RT hold (max 4 s), LAST keeps the previous release length. Game charge value still unread: CurrentAttackCharge_ nil, calc nil, ultra=0.0 works; chargeInfo now also logs startT (pawn.AttackChargeStartTime) and GetGameTimeSinceCreation. Bars use hold time, not game value.
- Weapon follows HMD: hypothesis = MotionController late update (bDisableLowLatencyUpdate was false on both). Checkbox no_late_update (default on, re-applied every 2 s); also set live via MCP. Not verified: needs headset on + MCP vr_poses/component positions while moving head with hands still.
- Aim dot v2 (untested): colour via DebugMeshMaterial MID "Color" (log "[AIM] colour mat=.. mid=.."), extra LineTraceSingleForObjects {0..4} keeps nearest hit (log "[AIM] ForObjects failed" if API rejects), 3 cm pull-back from surface. Backup tools/queens_domain_vr.lua.bak_aimdot.
- Open: low-res look at 100% res (needs 500%). Not yet investigated; game was not running. Next: with game up, uevr_list_cvars/get_cvar for r.ScreenPercentage, r.TemporalAA*, r.TSR*, r.PostProcessAAQuality, DLSS/FSR; test set_cvar live.
- 2026-11-08: aim dot v2 was NOT live (live stale); synced repo->live. ALWAYS copy repo script to live after edits (backups/queens_domain_vr.lua.live-before-aimdot2).

## Test 13 (2026-11-08, untested; backup backups/queens_domain_vr.lua.pre-t13; synced to live)
- Dodge: logs show spear dashes away from pawn facing, sword toward it -> facing = wantYaw + 180 (spear) / + 0 (sword); weaponIsSpear set in hitbox code (axis X).
- R3 opened quick journal (bestiary): openInventory now OpenPauseMenu(false).
- Resolution: r.ScreenPercentage was 37.5; set_cvar did NOT stick, uevr_exec_command "r.ScreenPercentage 100" did. Not persisted (game/UEVR may reset). Dithering cause not yet isolated.
- Damage test: MCP hook id 1 (log) on Actor.ReceiveAnyDamage; read with uevr_hook_log after user hits monsters (params not captured, only calls). Bars still hold-time based.
- TODO: live wireframe tuning with sword; weapon-follows-head via MCP vr_poses (hmd_active was false).

## Test 13b findings (2026-11-09)
- Weapon "swims" with head rotation: ALL game-side transforms (hand, mesh, hitbox) are world-correct and static (verified via MCP). Swapping the sword Mesh material (MID <- RustedSword_MI <- Equipment_Evo_MIB) to Engine DefaultMaterial made it align with the wireframe -> the equipment master material moves vertices (WPO) with the view. No exposed scalar/vector param for it (static switch / hidden). Restored original material.
- Hitbox offset cause: saved hitbox_forward_offset -60, spear_reach 59, blade_offset -40, blade_reach 10 -> zeroed in live user_configuration.json + script defaults.
- Dodge: per-weapon learning added (dodgeFlip); user suspects sword dodge is natively forward.
- screen_pct slider (default 100) forces r.ScreenPercentage via ExecuteConsoleCommand every 2 s (game resets to 37.5). Works.
- F10 = [MESHDUMP]. MPCs of interest for dithering/look: /Game/BaseMaterials/Resources/PixelFilter_MPC, Game_MPC (param names hidden by MCP read).
- Aim dot pulled back up to 40 cm from hit.

## Test 14 (2026-11-09; backup backups/queens_domain_vr.lua.pre-t14; synced to live)
- Flat game: sword alt attack stabs forward, spear stabs then backs off -> native animation correct. Removed dodgeFlip learning + 180 facing hack; L2 = native alt attack toward HMD yaw (offset 0); RS same with stick direction.
- Plugin uevr_utils.dll (original profile plugin) disabled: live plugins\uevr_utils.dll.disabled, original in backups/plugins_orig/. Restore = rename back. Testing sword material sway without it after restart.
- Render scale: 100% (script slider screen_pct) + SteamVR res ~2500x2500 (user sets). FXAA set live only (r.DefaultFeature.AntiAliasing 1), not persisted.
- TODO: thrust gesture for stab (PLAN_charge_rush.md); sword material sway fix options (plain material w/ checkbox).

## Test 15 (2026-11-09; backup backups/queens_domain_vr.lua.pre-t15; synced to live, untested)
- After plugin removal: picture clearer, L2 stab fine (but weapon must be moved by hand to look like an attack); sword/spear still off the hitbox -> checkbox plain_weapon_mat (default on): held weapon mesh gets Engine DefaultMaterial (originals stored, restored when off; re-applied every 1 s).
- Item HUD now always visible (even 0 units). Compass offset sliders compass_dx/dy/dz (cm) + compass_rx/ry/rz (extra rot about hand axes), base transform unchanged. R3 now opens the normal pause menu (OpenPauseMenu(false)).
- 2026-11-09 end: R3 still wrong (opens plain pause menu). User turned off the game's "retro resolution" setting. Next steps in PLAN_next.md.

## Test 16 (2026-11-10; backups backups/*.pre-t16; synced to live; untested in game: needs a script reload)
- Crosshair: game crosshair = HUD canvas (left eye only); material is UI-domain (MaterialDomain 5, translucent) -> can't go on a mesh. New game_crosshair (default on): UMG Image with the HUD's own MID, hosted as RootWidget of a game UserWidget on a world WidgetComponent (Transparent blend), at the knife aim point (left hand) or head gaze otherwise (game_crosshair_gaze), facing the head, constant angular size (crosshair_size). Canvas copy hidden by BaseCrosshairSize -> 0 (was 37x39). Logs "[XHAIR] created/shown/canvas". Orange dot = fallback only.
- L2 + stab: l2_stab_gesture (default on, needs Motion Controls Melee): L2 only arms; a detected stroke with outward share >= stab_outward (0.4) fires the native alt attack (startNativeDodge "L2stab", released 0.1 s later); non-stab strokes while L2 held do nothing. Logs "[MELEE] L2 armed / L2 stab -> / L2 stab rejected out=". Normal swing log now has out=. Detector: lastOutward (+4 tests, 32 pass).
- Rusty-weapon sway: confirmed live: weapon MI <- Equipment_Evo_MIB (MIC) <- Equipment_MA (opaque master); instance has only colour/tiling scalars, no textures (look = master), so no texture-preserving swap. WPO driver unknown: Game_MPC has 16 scalars (one = 60.0, FOV-like) + PixelFilter_MPC 6, but MCP can't read FName params and name guesses (FOV, WeaponFOV, ViewmodelFOV, FirstPersonFOV, CameraFOV) return 0. Added "[MPC]" dump 5 s into play + dev bridge (qd_exec lua event, see CODEMAP "Dev bridge"). plain_weapon_mat stays the working fallback.
- Next: user reloads scripts (restart game or UEVR Reset scripts). Read [XHAIR], [MELEE] L2 stab out=, [MPC], "[EXEC] bridge ready". Then via bridge/MCP invoke KismetMaterialLibrary.SetScalarParameterValue on the FOV-like Game_MPC param (try = camera FOV / neutral) with plain_weapon_mat off; if the rusty sword lands on the wireframe, bake it in and default plain_weapon_mat off.

## Test 17 (2026-11-10; backups backups/*.pre-t17; synced to live; needs script reload + headset)
- Test 16 result: crosshair + orange dot invisible; L2 stab fired on horizontal swipes (out 0.42-0.78 on everything).
- Crosshair root cause (verified live): FindLookAtRotation(aimEnd, ...) writes a "result" key into the aimEnd Lua table (UEVR treats const FVector& as out) -> every later call with aimEnd threw "Struct property 'result' not found in Vector" -> crosshair froze after frame 1 (found 120 m away), silently (pcall). Facing now computed in Lua; updateAimDot errors now logged "[XHAIR] updateAimDot error:".
- Weapon sway: Game_MPC FPFOV = 60 = first-person weapon FOV squash (camera FOV 100, headset per-eye ~110 from projection P00=0.696). Game rewrites it natively every tick (not via the BP SetScalarParameterValue). New weapon_fov_fix (default on) + weapon_fpfov (0 = auto per-eye FOV) set it from the viewport-draw/stereo callbacks (only fire in VR). Unverified whether this lands before rendering; check "[FPFOV] src= game= set= fixes=" and, with plain_weapon_mat OFF, whether the rusty weapon sits on the wireframe without swimming. If not: try weapon_fpfov 100 (camera FOV).
- L2 stab: new stab_axis (default 0.6): |cos| between the stroke's net direction and the weapon's long axis (world, via tracking->world yaw from HMD). Log adds axis= tip= straight=. Verified live: game MotionControllers follow the AIM pose, vr.get_pose gives GRIP pose; tracking->UE = (-z, x, y) + yaw (~175 deg here).

## Test 18 (2026-11-10; backups *.pre-t17 cover t17+t18; synced to live; needs script reload)
- Test 17 result: crosshair fixed but too faint; weapon_fpfov 100 (= camera FOV) fixes sway + hitbox alignment (auto 110 = per-eye did NOT); compass tuned by user. L2 log: pokes axis 0.82-0.98, swipe 0.26 -> axis gate works; outward 0.4 still rejects some pokes (out 0.33-0.50).
- Done: weapon_fpfov auto (0) = PlayerCameraManager:GetFOVAngle(); plain_weapon_mat default off; debug_hitboxes default off (also set live); stab_outward 0.4 / stab_axis 0.6 restored live (user asked); screen_pct slider + forcing removed; compass_* defaults = user's values; rstick_turn (default on, + rstick_turn_speed): RS X passes to the game's smooth turn, Y zeroed, RS dodge only when off.
- Crosshair: XHAIR_RAD 0.028 -> 0.06; crosshair_bold (default on): Overlay root = black-tinted full-size copy behind + 2 stacked copies inset 6 px. Unknown if the material honours the tint ("[XHAIR] bold overlay failed:" logged on error).

## Test 19 (2026-11-11; backups *.pre-t17 (scripts), attachments_parameters.json.pre-t19; synced to live; needs script reload)
- Test 18 result: weapon visuals fixed (FPFOV 100); crosshair still occluded + offset at close range; L2 sometimes failed; swing hits only land where the swing ends; club can't hit, looks horizontal.
- Found: game hit window opens 0.25 s (sword) / 0.6 s (club) after swing commit (notify -> "Activate Hitbox"; real UFunction names have spaces, SDK shows "_"). Activate Hitbox outside an attack leaves NormalHitbox/DefaultHitbox collision 0. L2 rejections: 35/42 by outward (real pokes out ~0, axis 0.97+), 2 were pull-backs (tip -0.94).
- motion_hit_window (opt-in, user approved plan A): hitWinOpen after our AttackReleased / charged release / L2 stab -> weapon["Activate Hitbox"]; close when detector.speed < rearm after 0.2 s (max 0.8); game Activate within 1.5 s of ours and game Deactivate while ours open skipped (pre-hook returns false: unverified). Logs "[MELEE] HIT window open/close/game Activate skipped/HandleHit sinceOpen= damaged=" + "HIT hooks activate= ...".
- L2: user wants no direction gating -> stab_axis + stab_outward default 0 (= off, set live): any detected stroke with L2 held = alt attack. Signed tip check kept for stab_axis > 0; axis still logged.
- Crosshair: trace starts at PlayerCameraManager camera location (game's aim origin) along hand/head dir; pull-back + size from the eye; crosshair_on_top (default on) sets bDisableDepthTest on /Engine Widget3DPassThrough (shared base; "[XHAIR] on top=" log).
- Club grip: attachments entry rotation [180,0,0] -> sword's [0,87.1,12.4] (both meshes long along -Y). Repo data/attachments_parameters.json was stale vs live -> replaced by live copy.
- Check next (still untested): HIT lines, club hits, crosshair on top, L2 failures.

# Archived 2026-11-13 (plan step 3): tests 20-24, moved verbatim from STATE.md

## Test 20 (2026-11-12; backups backups/*.pre-t20(b) + saves backups/saves_20261112 (restored after testing); synced to live)
Verified IN GAME with the fake headset (tools/fakevr, no user):
- Pickups: pointing the left hand selects the item, beam + crosshair snap shown, eye-line occlusion drops items behind rocks, grip grabs, auto take -> item acquired. Spawn hook + 10 s rescan (15 ms, 199 items) OK.
- Auto grip: all 107 weapon items equipped via the cheat manager (FS_Cheats_C.GiveAllWeapons + pawn:EquipItem(item, 0)); 103 new entries in data/attachments_parameters.json (77 sword-like -Y, 12 +X, 9 guns, 5 odd). Spot checks (long weapon, rifle) held at the handle, head/barrel forward.
- R3 -> items/equipment screen (OpenStatus) works. Swings: 5/5 fake swings fire attacks + game notifies; gun swing -> "swing ignored: ranged weapon". Hit-window hooks resolve ("Activate Hitbox" with a space is valid).
- [AIM] object trace can never work through UEVR (ObjectTypes number array rejected): now fails once and stops.
Not verified in game: mesh put back on its parent after a take (old KeepRelative detach left it near the world origin; fixed), late-fire swings (new detector rule, unit-tested), hit haptics on real hits, HIT window open/close (no enemy nearby).
- Fable review (20 findings) applied: stuck pickup states, held-button re-grabs, level-change reset, X leaking into popups, one-shot hit block, haptics only for the player's weapon.
- Check next with the headset: "[PICKUP]" lines + how pickups feel, "[GRIP] auto" weapons feel, "LATE" swings, "[PICKUP] mesh restored", hit haptics.

## Test 21 (2026-11-12 evening, user away; backups backups/*.pre-t21, saves backups/saves_20261112b; synced to live)
- Pickups: ~350 pickup classes, 105 hand-tuned grips (getPickupGripOffsets); the rest used one fixed fallback pose at full size. New pickup_auto_hold (default on): qd_grip.pickupHold from mesh bounds (long axis through the fist, thin axis out of the palm, bounds centre on the palm (4,-9,-5) in Hand_L space, max 35 cm; scale lerped during the fly-in). Hand_L socket: +X thumb side, -Y fingers, -Z out of the palm (measured). VERIFIED in game via the real flow (grip grab, "[PICKUP] auto hold" log, screenshots, scale lerp 0.83->0.59).
- Right hand "floating": on_xinput_get_state called hands.handleInput twice; the 2nd call (offHHand typo -> nil -> RIGHT hand) drove the weapon hand as empty, so any grip/thumbrest release opened the fingers around the weapon. Removed the 2nd call. VERIFIED live (monkeypatch equivalent): fingers stay closed after grip release (before: open).
- Consumable belt (libs/qd_belt.lua, options belt / belt_drop): owned consumables (ConsumableRotationOrder + GameInstance:ReadInventoryItemCount) as icon cards on an arc at the waist, shown when looking down; grip near a card grabs it, at the mouth -> select it as the game's consumable + fire the game's UseItem input event. VERIFIED: cards render, grab + mouth trigger + selection. NOT verified: an item actually consumed (count stayed 4 at the test spot with the event, ScriptUseItem (dropped: possible free use) and 1.5 s holds of 10 gamepad buttons; the use button may be something else or use is blocked there). Fable review applied (stale cards after level change, user_index filter, input reset in menus, arm on fresh press only, select loop stop).
- Pickup eye-line check now also ignores the held weapon's visuals actor (separate from the pawn). Untested in game.
- Weapon placement sweep (all 104 weapons, bridge): fist centre within 4 cm of the handle axis for all, median 22 % up from the pommel. Fake-headset gotcha: attachments write Relative* fields directly, so a perfectly still fake controller shows stale weapon transforms (nudge the mesh/controller before measuring).
- Check next with the headset: belt cards readable/size/height (belt_drop); grab a card, bring it to the mouth: "[BELT] use result: count a -> b" (if b == a, tell me which button uses items in flat play); right hand stays closed on the weapon; pickups without a tuned grip held upright ("[PICKUP] auto hold").
- NEXT (user hints 2026-11-12): use the Bloodborne mod (bldbrne-vr, see REFERENCES.md) as reference for the belt "use" path and IK arms; have an agent find why the "teleport" button isn't detected (wanted for the item menu). Keep comments short.

## Test 22 (2026-11-12 night, fake headset; saves backups/saves_20261112c restored; belt synced to live)
- Belt use path VERIFIED: hud:SetSelectedItem(item) + pawn:InpActEvt_UseItem_K2Node_InputActionEvent_21(key) consumed the item (count 4 -> 3, healed). Test 21's "count stayed 4" = item had no effect at full health (heal item; health was above max), not a broken path. SelectNextConsumable never changed hud.CurrentItem (stays nil): qd_belt.selectItem now tries SetSelectedItem first.
- Not re-tested through the grab-to-mouth flow with the new select (bridge calls only).
- Full flow VERIFIED (fake headset, health field set to 50 via bridge): grab card with left hand, glide to the mouth, "[BELT] use ok=true", "use result: count 4 -> 3". Belt use is done. Saves backups/saves_20261112d restored.
- ACCEPTED by user: belt use does nothing when the item doesn't apply (heal item at full health: count unchanged, log still "use ok=true"); no message added.
- Self-test 2026-11-12 (fake headset): pickup assist VERIFIED in game: left-hand target -> left grip "[PICKUP] grab (grip)" -> "mesh restored" -> "auto take ok=true". Belt card at the default height steals L1 when the left hand is ~60 cm below the eyes, 25-30 cm forward (by design: the hand is on a card). Auto hold (auto_take off) NOT verified: setup problem (moved item kept following the hand / snapping back), not a mod finding.

## Test 23 (2026-11-13, fake headset; saves backups/saves_20261113 restored; driver backups backups/fakevr_pre_frame)
- Fake driver now emulates Steam Frame controllers (default; setting controller=touch for the old Quest mode). Game log shows "simulated controller type: oculus_touch", same as the real Frame session of 11-09. VERIFIED in game: fake RT -> "RT AttackPressed", held 2-9 s = one press + one release; LT -> "L2 armed"; right bumper also acts as RT (SteamVR's Frame remap maps trigger -> trigger+bumper; true on the real device too).
- pawn.AttackPressed (character bool) stays false while RT is held: the mod calls weapon:AttackPressed() directly and zeroes RT, so the game's input event never sets it. Relevant for charge discovery (plan step 5).

## Test 24 (2026-11-13, fake headset; saves backups/saves_20261113b restored; script synced to live)
- Select/Teleport cause: UEVR's vr.get_action_handle returns nil for Teleport (also TouchpadClick, Squeeze, HeadsetOnHead, ThumbRestTouch*): not in UEVR's action map, so no binding can reach Lua. Fix: SteamVR Frame binding sends left View to AButtonTouchLeft (exposed, unbound) and ACT_MAP polls it; missing handles cached as false. R3 fallback kept.
- Active binding = Workshop copy F:\Steam\steamapps\workshop\content\250820\3835707217\*_legacy.bin (NOT userdata\...\250820\remote\binding_config.json); both patched, originals backups/workshop_legacy.bin.pre-s2 + binding_config.json.pre-s2. Steam may re-sync the workshop copy: if View stops working, rebind left View -> "A Button Touch Left" in SteamVRs binding UI.
emoteinding_config.json); both patched, originals backups/workshop_legacy.bin.pre-s2 + binding_config.json.pre-s2. Steam may re-sync the workshop copy: if View stops working, rebind left View -> "A Button Touch Left" in SteamVR's binding UI.
- VERIFIED in game: fake left View -> "[ACT] AButtonTouchLeft=true" -> "[INV] OpenStatus src=Back ok=true", status screen shown.
- Seen: right Menu also arrives as XInput Back (0x0020) besides SystemButton -> opens the status screen too (fake device; check on the real Frame).

## Test 25 (2026-11-13, plan step 3, fake headset; backups backups/*.pre-s3, saves backups/saves_20261113c restored; synced to live)
- IK arms: option ik_arms (default OFF, needs 6dof_right). libs/qd_ik.lua wraps uevrlib libs/ik.lua (data/ik_parameters.json: poseable copy of pawn.Arms, two-bone solvers UpperArm/LowerArm/Hand per side). Hand bones of the copy are hidden: the hands lib meshes on the controllers stay as they are (weapons, pickups, fingers untouched); wrist target = that hand mesh's Hand bone. Shoulders 21 cm below / 9 cm behind the eyes, yaw trails the head (30 deg dead zone, 20 deg/s re-centring), out-of-reach hands pull the shoulders up to 12 cm; mesh scale 1.2. Hidden outside regular play, destroyed on level change / option off.
- require() only works while the script loads (not from the bridge, not later): libs/ik.lua is loaded only if ik_arms is on at load, so turning it ON needs a game restart (off and on-again are live). Lib default bone guess was wrong (took Clavicle/UpperArm): start_bone/joint_bone set in the json.
- VERIFIED in game (screenshots + bridge numbers): off = no arms, pawn.Arms hidden as before, no [IK] lines; on = both arms reach the hands (wrist error 0.0 cm in reach), weapon stays in the hand, RT attack fires, swing detector runs (ranged weapon held: "swing ignored" as before), status screen hides the arms and they return, live off/on. NOT verified: real headset feel (shoulder height/width, elbow direction), forearm twist (no twist bones set), cutscenes/level change, melee-weapon swing, pickup grab and belt with arms on (their code is untouched). Seen (also with IK off): right controller yawed ~40 deg against the head made the view spin with the fake pose; not investigated.
## Test 26 (2026-11-13, plan step 4 leftovers, fake headset; backups backups/*.pre-s4, saves restored md5-equal; synced to live)
- LT/bRightTrigger: already gone. No left-trigger path in on_xinput_get_state touches bRightTrigger (the old bug was in the pre-rewrite code); RT is zeroed only by the RT handler itself, because the mod calls the weapon directly. The `offHHand` typo is fixed too (test 21).
- Debug cubes: no leak. The 3 hitbox cubes + 2 charge bars are cached, created only when invalid, hidden (not recreated) when debug_hitboxes is off; counted live: 5 mod cubes constant over 5 off/on toggles. Only reload leak found: aim-dot Sphere not covered by T20.cleanupStale -> added Sphere (debug-material instance, no collision). Unverified live (aim dot is off while the game crosshair is used).
- Pickup eye-line ignore of the weapon visuals actor: VERIFIED in game that weapon mesh owner = visuals actor (not the pawn) and pkOccluded runs with it as ignore[3] without error; the weapon mesh has no collision, so it was probably never blocking anyway.
- Auto hold with pickup_auto_take OFF: VERIFIED. Grab holds the item rigidly on the hand (distance constant while the hand moves, no snap back), A takes it (mesh restored, game acquires). Earlier failure was test setup. Auto-hold grip logged for an untuned item (13.8 cm from the controller).

## Test 27 (2026-11-13, plan step 5 D1-D2, fake headset; backups/*.pre-s5, saves restored md5-equal, vrsettings byte-exact; synced to live)
- Added [MONT] montage-change log line (arms montage + Dashing). Charge = damage-only multiplier on RT hold (cap ~3.5 s), rush = late RT inside the alt-attack dash. Details + chargeInfo nil-field bug: PLAN_charge_rush.md D2. D3 approved: RT hold + swing with charge haptics; swing during dash = buffered rush. Next: I1-I3.

# Archived 2026-11-13 (plan step 10): test 29, moved verbatim from STATE.md
## Test 29 (2026-11-13, plan step 7 coverage, fake headset; backups/*.pre-s7, saves md5-equal, vrsettings byte-equal, user config equal; synced to live)
- Guns (9 types, class chain GunBase): RT reaches all, swings ignored on all, aim = right hand (ctrl rot == hand), muzzle ~21 cm from hand. They fire only with resources: energy (pawn.EnergyChargeLogic.CurrentPowerCharge, 0 on this save) or own weapon charges (AddToCharge). Beam type plays its fire montage but never sets LastFireTime.
- Throwables (26 types): left grip throws all, aim = left hand. Switch type in tests with pawn:EquipItem(item, 0); items = FS_ItemData_C with pawn:GetDaggerChargeCompFromItem ~= nil.
- BELT BUG FIXED (qd_belt selectItem): the use event consumes GameInstance.ActiveSaveSlot.SelectedConsumable, not HUD CurrentItem; HUD-only select used the slot's item (game auto-picks a heal item when health drops). VERIFIED with fake-hand grabs while hurt: cards 5 and 3 consumed their own items.
- Consumables (30 types): with correct select, 15 consume; 3 open a confirm dialog; 12 no-op here (probably need a specific place or situation). Open: belt shows only the first 5 owned types (MAX_SLOTS), others unreachable.
