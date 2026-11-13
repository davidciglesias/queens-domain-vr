# STATE (<=40 lines). Read with CLAUDE.md, CODEMAP.md. Reference notes: REFERENCES.md (don't re-fetch repos).
Paths: game F:\Steam\steamapps\common\QueensDomain; UEVR F:\Mods\UEVR\uevrAug302026; live profile %APPDATA%\UnrealVRMod\QueensDomain-Win64-Shipping. Tests: python tools/run_tests.py. Logs: sh tools/logsum.sh.

Roadmap: P1-P2 done; P3 hitbox damage (test 19) and later plan steps live in PLAN_next.md.

Base: Megido 071126 (merged 2026-11-07, clean 3-way merge; re-enabled the hidden "6dof_right" menu checkbox that our code gates on). Pre-merge live script: backups/queens_domain_vr.lua.pre-071126.

## Verified
- From code, not run in game: weapon from pawn.CurrentInHandWeapon; notify hooks re-parent NormalHitbox/DefaultHitbox to the weapon mesh; right trigger AttackPressed/Released, left AltAttack*; cooldown, FX and combo-speed changes apply only with the option on.
- Unit tests: 125 pass on Lua 5.4 (tools/pydeps/lupa); both scripts pass the syntax check.
- The shipped log.txt is from another PC and has no Lua print lines, so print is assumed not to reach the log.

## Not yet verified in game
- [MELEE] lines reach log.txt; look for "motion melee loaded" first.
- vr.get_pose fields and meters; +Y as up (used only by the "raising" filter).
- F8 works with the headset on (needs game window focus).
- AttackPressed with AttackReleased 0.05 s later plays one attack.
- Default threshold 2.0 m/s feels right.

## Open questions
- Does a swing fire guns or other non-melee weapons? Only melee is intended; find how to tell them apart from logs.
- Trigger still attacks with motion on; keep or disable?
- Reference licences: project is AGPL-3.0; bldbrne-vr (AGPL) and BotW-BetterVR (MIT) code reusable with notices kept.

## Reference material (2026-11-08): refs/ (gitignored) = game SDK dump, uevrlib docs, uevr-mcp. Notes in REFERENCES.md.
SDK facts (generic names): weapon = pawn.CurrentInHandWeapon (WeaponScriptBase_C : ActorComponent) with AttackPressed/Released, AltAttackPressed/Released, PreChargeAltPressed, GetChargedNormalAttackMultiplier, GetCurrentChargeCount; CurrentVisuals = WeaponVisuals_C (base has NO Mesh prop: SocketComp + GetMeshes(out array); .Mesh only on subclasses). Player FS_PlayerChar_C : FS_PlayerCharacter : Character: bools AttackPressed/AltAttackPressed, CurrentAttackCharge_, Calculate_Charge_Multiplier(out mult, out alpha); dodge = dash system: Dashing, LastDashMoveDir, DashDistanceTravelled, DashSpeedMult, GetDashTurnRateMult, CancelDash; OpenPauseMenu(bool QuickJournal) (candidate for Select/inventory). Crosshair is drawn by the HUD (FS_HUD_C Crosshairmat material, UpdateCrosshairMaterial), not a UMG widget -> explains HUDDUMP miss.
Ideas APPROVED by user 2026-11-08 (do all, items 1-4 before 9b test): (1) [DODGE] end log reads pawn.Dashing/LastDashMoveDir; (2) charge discovery logs CurrentAttackCharge_ instead of inferring from hold time; (3) Select -> pawn:OpenPauseMenu(true?); (4) mesh fallback via SocketComp/GetMeshes; (5) spear grip via uevrlib "Attachments Config Dev" tab ({Pitch,Yaw,Roll}); (6) install uevr-mcp (plugin DLL + MCP server) for live inspection instead of log round trips.

## Tests 16-25: archived in STATE_archive.md. Still relevant: fake-headset self-test works end to end (Frame controllers; RT/LT, grip, View -> status screen); pickups, auto grip, belt use verified in game; View needs the patched SteamVR binding (workshop copy may be re-synced by Steam: rebind left View -> "A Button Touch Left"); pawn.AttackPressed stays false while RT is held (mod calls the weapon directly).

## Test 28 (2026-11-13, step 6): ChargeHaptics + RushBuffer, options charge_haptics/rush_buffer/rush_earliest. VERIFIED sword: 6 step pulses + strong at full (1.333 @3.7 s); swing 0.21 s into dash buffered, fires 0.6 s = rush. Open: headset feel.
## Tests 29-31: archived in STATE_archive.md (31: spear has no rush window; buffer only for DashHitboxBonusRange weapons).
## Test 32 (2026-11-13, step 10 P3 hit window, fake headset + inactive enemy spawned via cheat; backups/*.pre-s10, saves md5-equal, vrsettings byte-equal, user config equal; synced to live)
- Old motion_hit_window never worked: hit window is on the PAWN (ActivateHitbox(primary, dash)/DeactivateHitbox; trace at call time + every frame, 1 hit per enemy per activation), opened by the PlayerHitboxState anim notify; the weapon "Activate Hitbox"/HandleHit never run. UEVR RULE: a UFunction the script hooks (or anything it runs synchronously) cannot be called from our tick: "resource deadlock would occur", call skipped, error unwinds through game code. Hooks only on PE-called events (notify Begin/End).
- Rewrite: open = pawn:ActivateHitbox after our AttackReleased / charged release / L2 stab (alt: primary=false); close slow/max; notify Begin within 1.5 s skipped (dash notifies pass), End skipped while ours open; hit feedback polls #pawn.EnemiesHitThisSwipe. VERIFIED: swing hits at release (t=0, hand moving), game window skipped, same damage; RT-only attack still hits via the game window; L2 stab hits. Option stays opt-in (off). Open: headset feel, charged swing, rush/dash interplay, wall bonk.

## Test 33 (2026-11-13, step 11, fake headset; backups/*.pre-s11 + backups/s11, saves md5-equal, vrsettings byte-equal, user config equal; synced to live)
- Hitbox attach only handled StaticMesh: 28 of 106 weapons render via a SkeletalMeshComponent (visuals SocketComp) and never got the hitbox. Fix: bounds from StaticMesh or SkeletalMesh (GetBounds, ImportedBounds fallback). VERIFIED: hitbox parents to the skeletal mesh, swing damages. Charged swing with window: damage = plain x charge mult (17.9 -> 22.6 @1.27). BUG FIXED: buffered rush fired with the hand stopped -> our window closed at 0.2 s and skipped the game rush window (rush never landed); now hitWinOpen skips when hand speed < rearmSpeed. VERIFIED rush lands via game window. Wall swing: one window, no repeat hits/bonk. Open: EnemiesHitThisSwipe also counts obstacles/props (hit haptic on walls); dash-start notify reports dash=false (a swing <1.5 s before a dash would skip it); still-hand RT-only attack did not hit here.## Test 34 (2026-11-13, step 13, fake headset; backups/*.pre-s13 + backups/s13; saves md5-equal, user config restored; synced to live)
- Hit haptic only for FS_EnemyCharacterBase actors (EnemiesHitThisSwipe lists walls/props too). VERIFIED: prop hit skipped, enemy hit -> enemies=1. BUG FIXED: a direct swing detected at its end (hand already slow at AttackReleased) skipped our window and the game window missed -> slow-hand skip now only for rush/post-dash buffered swings (hitWin.src); fix NOT yet run in game (relaunch stuck at Steam "Synchronizing cloud" after save restore). Still-hand RT attack: no damage = by design (hitbox rides the still blade; enemy must touch it). Notify Begin now logs pawn.Dashing (dash-start dash=false question still open). Fake swing reach ~95 cm (sword box centre ~50 cm ahead).
