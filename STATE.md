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
## Test 29 (belt bug fix, item/gun/throwable coverage): archived in STATE_archive.md.
## Test 30 (2026-11-13, plan step 8, fake headset; backups/*.pre-s8, saves md5-equal, vrsettings byte-equal, user config equal; synced to live)
- Quick slots: SaveSlot.QuickSlotItems is a TSet (Lua reads nil; header via read_dword 0x470 Num / 0x49C NumFree; elements unreachable, reads are bounds-checked). No cap (all 30 accepted); new items auto-join. pawn:SelectNextConsumable visits only owned quick-slot items in ConsumableRotationOrder. Belt now = first belt_slots (option 1-5, default 5) of those, found by walking that cycle and restoring SelectedConsumable; re-walked on ownership/header change and each time the belt appears. VERIFIED: {3,7,20} -> 3 cards; all quick -> 5; swap shows after re-show; belt_slots 2 -> 2; selection kept. Real NextItem input event (InpActEvt_NextItem_..._29 on this pawn class; number differs from the SDK dump) with 30 owned: cycles all 30 and wraps (goes backwards through the rotation order); HUD follows. No 5-item cap in the game. 8b: belt = belt_slots window over the owned quick list centred on SelectedConsumable (circular; fits -> stable order); re-centres within ~0.1 s of the game's next/previous item while shown. VERIFIED live (head pitched down, 5 cards, one press shifted the window).
## Test 31 (2026-11-13, step 9, fake headset; backups/*.pre-s9, saves md5-equal, vrsettings byte-equal, user config equal; synced to live)
- Spear has NO rush: AttackPressed anywhere in its ~0.33 s dash (0-0.42 s tested) or after it gives one hitbox notify ~0.2 s later. Only weapons with DashHitboxBonusRange (2 scripts, sword family; 11 other dash weapons lack it) have the late rush window. Fix: RushBuffer.enabled = weapon has DashHitboxBonusRange (checked on weapon change). VERIFIED: spear swing in dash fires at once; sword swing at 0.21 s -> RUSH at 0.60 s, notify 0.25 s later. Dash ends early against obstacles (sword 0.33 s vs 0.82 s). One game crash (access violation via UEVR hook) during the bridge sweep, not reproduced at same timings.
## Test 32 (2026-11-13, step 10 P3 hit window, fake headset + inactive enemy spawned via cheat; backups/*.pre-s10, saves md5-equal, vrsettings byte-equal, user config equal; synced to live)
- Old motion_hit_window never worked: hit window is on the PAWN (ActivateHitbox(primary, dash)/DeactivateHitbox; trace at call time + every frame, 1 hit per enemy per activation), opened by the PlayerHitboxState anim notify; the weapon "Activate Hitbox"/HandleHit never run. UEVR RULE: a UFunction the script hooks (or anything it runs synchronously) cannot be called from our tick: "resource deadlock would occur", call skipped, error unwinds through game code. Hooks only on PE-called events (notify Begin/End).
- Rewrite: open = pawn:ActivateHitbox after our AttackReleased / charged release / L2 stab (alt: primary=false); close slow/max; notify Begin within 1.5 s skipped (dash notifies pass), End skipped while ours open; hit feedback polls #pawn.EnemiesHitThisSwipe. VERIFIED: swing hits at release (t=0, hand moving), game window skipped, same damage; RT-only attack still hits via the game window; L2 stab hits. Option stays opt-in (off). Open: headset feel, charged swing, rush/dash interplay, wall bonk.
