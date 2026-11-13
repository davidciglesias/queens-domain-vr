# Plan: charge attacks + rush (dash) attack in VR (planning only, no code yet)
Fits roadmap between P2 and P3. Mechanics only, no spoilers.

## Known
- RT = AttackPressed on press, AttackReleased on release; holding RT = charge, release = charged attack (game side). Montage names seen in a disabled block near line 2400: charge-attack montage, stab-charge montage, and a sword "Dash" montage (rush attack candidate, name unconfirmed).
- Current swing code presses then releases 0.05 s later (a tap), so it can never charge.
- Detector (libs/motion_melee.lua) rejected fast swings as "short" (peaks 2.1-2.7 and one 14.8 m/s): minTime 0.05 s, minTravel 0.15 m, rearm 1.2 m/s, cooldown 0.4 s.

## Discovery (needs one play session, log only)
1. Add [MELEE] logging of the current arms montage name on change (reuse lastWeaponMontage block, ~2392) and of AttackPressed/Released held duration.
2. Playtest script: (a) tap RT, (b) hold RT ~1 s and release, (c) hold RT while moving, release, (d) try rush: find its trigger (hold+direction? double-tap? separate button?).
3. From logs: charge time to full, montage names per case, which weapon functions fire (use WeaponScriptBase_C notify hooks at ~223-236).

## D2 findings (2026-11-13, fake headset, starter sword + basic spear; bridge sampler, nothing kept in code but the [MONT] log)
- Charge = hold RT. Press starts the arms "charge attack" wind-up montage at once; the release always plays the same alternating slash, whatever the hold time. Charge is damage only: CalculateChargeMultiplier_Impure(out) -> out.result goes 1.0 -> ~0.4 s delay -> linear ~0.11/s -> cap 1.333 at ~3.5 s (sword). Resets to 1.0 on release.
- Field names: real property is `CurrentAttackCharge` (no trailing _; Dumper7 strips BP suffixes) but it reads nil -> use CalculateChargeMultiplier_Impure. Calculate_Charge_Multiplier and weapon GetCurrentChargeCount/GetMaxCharges return nothing on a melee weapon (those "charges" are a separate meter, not hold-charge). Out params land in the table under key `result`. chargeInfo() fields charge/calc/wCount are therefore always nil: fix in I2.
- Rush/dash = the weapon's ALT attack (AltAttackPressed): weapon-specific dash montage, pawn.Dashing true. Sword ~0.85 s, spear ~0.4 s (CustomDashIsActive). Hold length makes no difference. No hitbox during the dash itself (Normal/DefaultHitbox collision 0 throughout).
- Rush attack = AttackPressed LATE in the sword dash (~0.6 s in): hitbox notify opens ~0.4 s later with NO arm montage. Pressed early (0.2 s in) it is ignored; pressed right after the dash it is a normal slash.
- Left stick forward + RT: normal attack, no dash. With motion melee on, L2 only arms the stab (the stab fires the alt attack), so L2 never dashes by itself.

## D3 APPROVED by user 2026-11-13
- Charge: keep RT hold + swing releases (charge_on_swing). Add haptic pulses as the multiplier rises + strong pulse at cap; fix chargeInfo (use CalculateChargeMultiplier_Impure out.result).
- Rush: dash as now; a swing detected while pawn.Dashing is buffered and AttackPressed/Released fired at the earliest accepted point (~0.55-0.6 s into the dash, sword; check the shorter spear dash). Next: I1 (motion_melee.lua + tests), I2 wiring, I3 fake-headset check.

## Design options (pre-discovery notes)
- Charge: hold trigger (existing path) OR physical: hold-still wind-up (hand slow + pulled back, press when wind-up starts, release on forward swing). Prefer: trigger held = charging, swing releases it (swing speed ends charge).
- Rush: forward thrust gesture (hand moves forward fast along aim, high minTravel, low lateral) OR left stick forward + swing. Should not conflict with normal swing; add separate classifier in detector (direction gate already exists for inward/upward).
- Settings: motion_charge_mode (off / trigger-hold / wind-up), motion_rush_mode, thresholds as sliders.
- Keep motion off-path unchanged when 6dof_right off.

## Steps
D1 logging + playtest (user) -> D2 read logs, write findings here -> D3 pick design, get approval -> I1 implement in motion_melee.lua with unit tests (tools/test_motion_melee.lua) -> I2 wire in queens_domain_vr.lua -> I3 playtest, tune.
Also fix in same pass: "short" rejections (maybe lower minTravel/minTime) and nil weapon mesh (CurrentVisuals.Mesh).
