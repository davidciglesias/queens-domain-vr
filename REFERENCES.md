# Motion-melee references (don't re-fetch; read this instead)
This project is AGPL-3.0. bldbrne-vr (AGPL-3.0) and BotW-BetterVR (MIT) code may be adapted: keep their copyright notices and list them in ATTRIBUTIONS.md.

## bldbrne-vr/bldbrne-vr (AGPL) - source/src/core/vr/
- swing_detector.h: pure, unit-tested classifier. `SwingDetector` ~L325-400 commit gate; `Stroke`/Classifier consts L101-170.
- melee_window.h, melee_moves.h, combat_channel.*: mapping swings to game attacks / damage windows (relevant to P3, unread).
- bloodborne_melee.cpp (210 KB, don't read whole); solid_weapon.h, weapon_weight.h, two_hand_motion.h (P5).
Concepts:
- Hand speed measured relative to the head, so body turns/headset moves don't count.
- Commit = fast for a minimum time AND minimum travel, so single-frame spikes don't count.
- Must slow below a lower "rearm" speed before the next swing (hysteresis; stops waggle spam); plus min interval.
- Ignores wind-ups, raising, pulling back. A wind-up can flow straight into the strike.
- Tracking dropout: freeze briefly, then reset; short recovery before judging again.
- Their tuning (m/s, s): fire 2.0, rearm 1.4, min time 0.04, travel 0.15 m, interval 0.35, stab 3.0.
- Light vs heavy: wound-up start + large blade arc = heavy; heavy needs trigger held or a big wind-up (P5).
- Stamina: light swing 80%, strong 100%; low stamina downgrades strong to light (P5).

## Crementif/BotW-BetterVR (MIT) - src/hooking/
- weapon.h: `WeaponProfile` thresholds L36-61; `ForSensitivity` presets L111+ (unread values). weapon.cpp 628 lines: analyser.
- resources/BreathOfTheWild_BetterVR/patch_CTRL_WeaponAttacks.asm: damage hook.
Concepts:
- Separate slash (blade angular velocity, rad/s, axis must stay steady) and stab (forward travel + accel, low rotation) detection; "good sample" time must accumulate before locking.
- Damage only during a recognised motion, so resting a hitbox on an enemy can't stagger it: this is the model for P3/P4.
- Thresholds scale by calibrated arm length; sensitivity presets (idea for P5).
- Button attack stays available; motion is optional.

## Local reference material (refs/, gitignored; added 2026-11-08)
Recreate: `unzip Dumper7SDK.zip -d refs/`; `git clone --depth 1` jbusfield/uevrlib and elliotttate/uevr-mcp into refs/.

### uevrlib (refs/uevrlib, d69c5bd) = our scripts/libs/* byte-for-byte; docs/*.md apply directly
- Rotation convention: attachments JSON "rotation" and uevrUtils.rotator({a,b,c}) = {Pitch, Yaw, Roll} deg; "location" {X,Y,Z} cm, relative to the parent (grip mesh/MotionController, or raw controller when callback returns nil mesh).
- Raw-controller attach has a +90 yaw offset vs MotionControllerComponent attach (attachments.md ~L113-127); global base offset via attachments.init(nil,nil,loc,rot); per-weapon tuning live in the "Attachments Config Dev" UI tab (Location/Rotation/Scale, melee/scoped/two-handed, melee_rotation_offset), saved to data/attachments_parameters.json. Use this tab instead of guessing spear yaw edits.
- registerOnGripUpdateCallback returns rightAttachment, rightMesh, rightSocketName, leftAttachment, leftMesh, leftSocketName, detachFromParent, allowReattach.
- reticule.md: reticule.init/setActiveReticule; targeting = camera (default) or controller ("Advanced"); props Hide/Distance/Scale -> candidate replacement for our hand-made aim dot.
- remap.md: remap.init() + "Remap Config Dev" tab (unpress original, while pressed/toggled) -> candidate for button remaps instead of xinput code.
- gestures.md: gestures.detectGestureWithState / swipe callbacks (no swing classifier; keep motion_melee).
- montage.md: uevrUtils.registerMontageChangeCallback(fn, priority) (montageData fields undocumented; log them).
- Docs say nothing about xinput double-fire, roomscale offset or head-translation drift.

### uevr-mcp (refs/uevr-mcp, 8cf1053): live game access for the agent
- plugin uevr_mcp.dll -> %APPDATA%\UnrealVRMod\QueensDomain-Win64-Shipping\plugins\ (HTTP localhost:8899 + pipe \.\pipe\UEVR_MCP); MCP server = .NET (dotnet 10 SDK present) `dotnet run --project <abs>\mcp-server`, env UEVR_MCP_API_URL=http://localhost:8899; release zip ships UevrMcpServer.exe + install.ps1.
- Tools: uevr_get_player/objects_by_class/search_classes, uevr_read_field/inspect_object/chain, uevr_invoke_method, uevr_lua_exec (persistent state), uevr_lua_reload, uevr_get_log/clear_log, uevr_vr_poses/vr_input, uevr_screenshot, uevr_vr_settings/set_vr_setting, uevr_watch_add, uevr_process_event_* (ProcessEvent listener = find which functions fire).
- Cautions: needs game running + plugin; uevr_setup_game can crash some games (don't use; UEVR already set up); write_cdo/save_config/write_stability_config persist -> avoid; MCP-only Lua needs `if mcp == nil` guard. DLL is file-locked while game runs.
