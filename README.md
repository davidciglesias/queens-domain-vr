# Queen's Domain VR

An unofficial VR mod for Queen's Domain, running through [UEVR](https://github.com/praydog/UEVR).
Version 0.1.

## Features

- Motion-based melee: swing the controller to attack, hold to charge, release to strike.
- Cross-shoulder weapon switching on the right hand, and a left-hand throwable switch.
- A belt at the waist holding consumables, with the weakest owned healer pinned for quick use.
- Throwables and finger knives: open the left hand to carry knives.
- Arm-mounted HUD panels that follow the hand, and IK arms that track the controllers.
- Left-hand aim, a higher-contrast crosshair, and an optional black background behind menus.
- A grouped options panel for toggling the above.

## Requirements

- Queen's Domain (Steam) and a working VR setup in SteamVR.
- UEVR, installed separately.
No native plugins are needed: the release is pure Lua.

## Install

The release zip, `QueensDomain-Win64-Shipping.zip`, is a UEVR profile: the mod scripts, the bundled Lua libraries and their data.

1. Open UEVR's injector and click **Import Config**. Select `QueensDomain-Win64-Shipping.zip`. Leave it as a zip; do not extract it.
2. Start SteamVR, launch the game, and inject with UEVR.

Import adds files to the existing profile rather than replacing it. When upgrading, delete the old `scripts` folder first.
Your saved panel values (`user_configuration.json`) are not in the zip, so they are kept.

Building from source: the repository holds only the mod's own scripts; the libraries come from the zip.

## Dev tools

These are for development and are not needed to play.

- **Tests:** install Python with `pip install lupa`, then run `python tools/run_tests.py` from the repository root.
  The suite runs the Lua unit tests and syntax-checks the scripts.
- **Self-test launcher** (`tools/selftest_launch.ps1`): starts SteamVR, the game and UEVR injection in one step.
  Set these environment variables first:
  - `QD_UEVR_DIR`: the folder containing `UEVRInjector.exe` (required unless you pass `-NoInject`).
  - `QD_STEAM`: the Steam root. Defaults to the registry's Steam path.
  - `QD_STEAMVR`: the SteamVR folder. Defaults to `<Steam>\steamapps\common\SteamVR`.
- **Fake headset** (`tools/fakevr/`): a scripted test headset for SteamVR. See [tools/fakevr/README.md](tools/fakevr/README.md).
  Its scripts honour the same `QD_STEAM` and `QD_STEAMVR` variables.
- **Screenshots** (`tools/screenshot.ps1`): captures the game window as a downscaled JPEG.
- **Release build** (`python tools/build_release.py`): writes `dist/QueensDomain-Win64-Shipping.zip` with the developer bridge stripped.

## Known limitations

- Aim assist uses visibility traces only. The object-type trace fails on the UEVR build tested, so it is switched off for the session.
- Tested on a fake headset with the title, file select and in-world views, plus the inventory and ranged fire. Full melee and belt testing is still on the test sheet.

## Legal

This is an unofficial fan mod. It is not affiliated with or endorsed by the game's developers or publisher,
and it contains no game assets.

The mod is licensed under the GNU Affero General Public License v3.0; see [LICENSE](LICENSE).
Third-party credits are in [ATTRIBUTIONS.md](ATTRIBUTIONS.md).
