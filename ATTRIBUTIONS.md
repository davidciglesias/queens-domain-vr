# Attributions

## Base UEVR profile: Megido (Flat2VR Discord)
`QueensDomain-Win64-Shipping/scripts/queens_domain_vr.lua`
is the initial Queen's Domain UEVR profile script (version `QueensDomain-Win64-Shipping-071126`) created by **Megido** and
shared on the Flat2VR Discord. This repository adds motion-based melee on top
of it. The script is modified from the original, and the unmodified original is
not redistributed here.

Megido's original work is included, and modified here, with their permission.
Copyright in the original script remains with Megido. As modified, it is
distributed as part of this project under the GNU AGPL-3.0 (see `LICENSE`);
modifications were made starting 2026-11 (motion-based melee and related
changes).

## UEVR
Built for [UEVR](https://github.com/praydog/UEVR) by praydog (MIT; a separate program, not part of this work). UEVR itself
is not included.

## UEVR Lua libraries (`scripts/libs`)
The profile depends on the community UEVR Lua utility libraries
(`uevr_utils`, `hands`, `attachments`, `interaction`, etc.), whose headers credit
contributions from markmon, Pande4360, Rusty Gere and lobotomy. They are not
included in this repository (they ship with the profile); they remain the
property of their authors under their own terms.

## Reference projects
- [Crementif/BotW-BetterVR](https://github.com/Crementif/BotW-BetterVR) (MIT): slash/stab detection approach; code may be reused (MIT is AGPL-compatible). Any copied or ported code keeps its copyright notice (see below).
- [bldbrne-vr](https://github.com/bldbrne-vr/bldbrne-vr) (AGPL-3.0): swing-detection concepts. This project is AGPL-3.0, so its code may be adapted, with its copyright notices kept.

## Test tooling
`tools/run_tests.py` uses [lupa](https://github.com/scoder/lupa) (MIT) to run
Lua tests. It is installed locally and not redistributed here.

## Game
Queen's Domain is the property of its developers and publisher. This project is
an unofficial fan mod and is not affiliated with or endorsed by them. No game
assets are included.
