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
