# fakevr: scripted fake headset for SteamVR (driver `qdfake`)
HMD = 1920x1080 desktop window, 1440x1600/eye, 100 deg FOV, 90 Hz. Controllers = Steam Frame (default; `{frame_controller}` profile/render model, like the real one via vrlink;
SteamVR remaps UEVR from oculus_touch, same as the real device). Driver setting `controller: "touch"` = old Quest 2 Touch
(fakevr.COMPONENTS_TOUCH). Frame extras: `btn <hand> bumper|menu|view|dpad_*`; right x/y are own buttons; left x|a = dpad_down,
y|b = dpad_right; trigger/grip click derived (>=0.9 on, <0.8 off). Bumper also fires the trigger action (SteamVR remap). Control: UDP 127.0.0.1:27115.
- Build (SteamVR closed, DLL locked while it runs): `driver\build.cmd` -> `driver\qdfake\bin\win64\driver_qdfake.dll` (OpenVR v2.5.1 headers in `third_party\`).
- `powershell -ExecutionPolicy Bypass -File tools\fakevr\fakevr.ps1 on|off|status`. Refuses while SteamVR runs. `on` = one-time
  backup to `backup\steamvr.vrsettings.orig` + vrpathreg adddriver + steamvr.forcedDriver=qdfake, activateMultipleDrivers=true.
  `off` restores both keys + removedriver. SteamVR also writes LastKnown/GpuSpeed, so copy the backup back for a byte-exact restore.
- Start SteamVR **non-elevated**: `explorer.exe "<SteamVR>\bin\win64\vrstartup.exe"` (`<SteamVR>` = `QD_STEAMVR`, default `<Steam>\steamapps\common\SteamVR`; `QD_STEAM` overrides the Steam root). Claude Code shells are
  elevated. Elevated SteamVR loses vrwebhelper and its IPC namespace, and clients fail with InitError_IPC_NamespaceUnavailable.
  Stop: Stop-Process vrmonitor,vrserver,vrcompositor,vrdashboard,vrwebhelper.
- Verify: `venv\Scripts\python.exe verify.py all` (pyopenvr in `venv\`).

Protocol (lines split by newline or `;`, one datagram = one frame; reply `ok N`, `err ...` or JSON). Space: m, +X right, +Y up, -Z fwd, quat w x y z.
`pose <hmd|left|right> x y z [qw qx qy qz]`, `vel|avel <dev> x y z`, `at <unix time>` (stamps the following pose/vel lines),
`btn <hand> trigger|grip|a|b|x|y|joyclick|system|thumbrest 0|1` (a=x, b=y), `touch ...`, `axis <hand> trigger|grip v`, `joy <hand> x y`,
`conn|valid <dev> 0|1`, `prox 0|1`, `reset`, `wake`, `keepalive <s>`, `get` (state + haptic events, consumed), `state`, `ping`, `help`.
Defaults: HMD (0,1.7,0). Hands (+/-0.2, 1.0, -0.35), identity rotation.
Python (stdlib only): `from fakevr import FakeVR, quat_from_ypr; vr = FakeVR(); vr.tap('right','trigger')`,
`vr.point('right', offset=(0.25,-0.3,-0.45), yaw=-10, frame='tip')`, `vr.swing(direction='down-left', speed=3, length=0.8)`,
`vr.haptics()`, `vr.dismiss_dashboard()`, `vr.move_to(...)`. CLI: `python fakevr.py -h` (pose/ypr/btn/tap/hold/axis/joy/point/swing/haptics/get/dismiss/raw).

Verified 2026-11-12 (verify.py): 3 devices with roles, oculus_touch type, no profile or render-model errors. Pose round-trip error is
0.001 mm / 0.016 deg (standing = raw). Velocity, valid and conn work. Legacy GetControllerState bits/axes work. SteamVR Input actions work
(trigger, grip, a, b, x, y, joystick, analog values) and haptics reach `get`. /pose/tip = raw + (-/+16.7, -25.2, +24.7) mm, pitched
37.4 deg down. /pose/grip = raw + (0, 3, 97) mm, pitched 5.04 deg up. `frame=` compensates.
Not verified: `at` stamping and its verify check (built, never run), swing smoothing after the stamp change, keepalive vs standby, any real game.
Gotchas: the dashboard is up at start and 10 s after a scene app exits. It owns input focus, so run `fakevr.py dismiss` once the game
renders. Left `system` toggles the dashboard and the app never gets it. Holding it plus the left trigger takes a SteamVR screenshot.
Idle controllers go to standby after 5 min and lose their role, so the driver re-sends inputs every 30 s. A teleport looks like a 40 m/s swing
to code that differentiates positions, so `point` and `swing` glide in at 0.5 m/s. Velocity is extrapolated, so positions lead by v*dt.
- NEVER run verify.py while the game runs: it starts as a scene app and SteamVR closes the game. Game input needs the dashboard
  closed (dismiss after the game is the scene app). The HMD profile ships a default binding for steam.app.1799840 (UEVR
  HeadsetOnHead); without it SteamVR logs "(qdfake_hmd) has no configured binding".
Frame verified 2026-11-13: verify.py all pass (frame_controller type, simulated oculus_touch, tip/grip offsets); in game RT -> "RT AttackPressed",
held one press/one release, LT -> L2. pawn.AttackPressed stays false (mod calls weapon:AttackPressed directly).
