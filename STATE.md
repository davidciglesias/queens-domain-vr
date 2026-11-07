# STATE (<=40 lines). Read with CLAUDE.md, CODEMAP.md. Reference notes: REFERENCES.md (don't re-fetch repos).
Paths: game F:\Steam\steamapps\common\QueensDomain; UEVR F:\Mods\UEVR\uevrAug302026; live profile %APPDATA%\UnrealVRMod\QueensDomain-Win64-Shipping. Tests: python tools/run_tests.py. Logs: sh tools/logsum.sh.

## Roadmap
P1 Detector + debug hotkey + logging  <- CURRENT: code done, waiting for first in-game test
P2 Tuning from playtest logs (Sonnet)
P3 Investigate hitbox overlap -> damage, notify gating, speed-based damage; plan only, no code until approved (Opus: /model opusplan)
P4 Implement approved plan (Sonnet)
P5 Polish: blocking, two-handed grip, stamina feel, tuning (Sonnet)

Base: Megido 071126 (merged 2026-11-07, clean 3-way merge; re-enabled the hidden "6dof_right" menu checkbox that our code gates on). Pre-merge live script: backups/queens_domain_vr.lua.pre-071126.

## Verified
- From code, not run in game: weapon from pawn.CurrentInHandWeapon; notify hooks re-parent NormalHitbox/DefaultHitbox to the weapon mesh; right trigger AttackPressed/Released, left AltAttack*; cooldown, FX and combo-speed changes apply only with the option on.
- Unit tests: 28 pass on Lua 5.4 (tools/pydeps/lupa); both scripts pass the syntax check.
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
- Existing bugs seen, not touched: left-trigger block clears bRightTrigger; `offHHand` typo in on_xinput_get_state.
- Reference licences: project is AGPL-3.0; bldbrne-vr (AGPL) and BotW-BetterVR (MIT) code reusable with notices kept.

## Next step
User runs the first test (see HANDOFF). Then read logs with tools/logsum.sh and start P2.
