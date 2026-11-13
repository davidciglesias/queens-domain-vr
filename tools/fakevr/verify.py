"""verify.py - end-to-end check of the qdfake driver through a real OpenVR client (pyopenvr).

SteamVR must be running with fake mode on (fakevr.ps1 on). Use the venv interpreter:
  tools\\fakevr\\venv\\Scripts\\python.exe tools\\fakevr\\verify.py [all|base|actions]
base    : devices + roles, pose round-trip (standing + raw universes), velocity, conn/valid,
          legacy IVRSystem::GetControllerState buttons/axes
actions : SteamVR Input with verify_input/actions.json (same oculus_touch paths as the game's
          binding): trigger/grip/a/b/x/y/joystick/system, /pose/raw|tip|grip offsets, haptics
all     : base, then actions in a fresh process (one process can't mix legacy input + manifest)
Exit code 0 = all checks passed.
"""
import ctypes
import math
import os
import random
import subprocess
import sys
import threading
import time
from ctypes import HRESULT, POINTER, WINFUNCTYPE, Structure, byref, c_uint, c_void_p

import openvr

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fakevr import COMPONENTS, FakeVR, qconj, qmul, qrot, quat_from_ypr  # noqa: E402

STANDING, RAW = openvr.TrackingUniverseStanding, openvr.TrackingUniverseRawAndUncalibrated
NDEV = openvr.k_unMaxTrackedDeviceCount


class Report:
    def __init__(self):
        self.fails = 0

    def check(self, ok, msg):
        print(("PASS " if ok else "FAIL ") + msg)
        self.fails += 0 if ok else 1
        return ok


def pos_quat(m):
    """HmdMatrix34_t -> (pos, quat wxyz)."""
    r = [[m[i][j] for j in range(3)] for i in range(3)]
    tr = r[0][0] + r[1][1] + r[2][2]
    if tr > 0:
        s = math.sqrt(tr + 1.0) * 2
        q = (0.25 * s, (r[2][1] - r[1][2]) / s, (r[0][2] - r[2][0]) / s, (r[1][0] - r[0][1]) / s)
    elif r[0][0] > r[1][1] and r[0][0] > r[2][2]:
        s = math.sqrt(1.0 + r[0][0] - r[1][1] - r[2][2]) * 2
        q = ((r[2][1] - r[1][2]) / s, 0.25 * s, (r[0][1] + r[1][0]) / s, (r[0][2] + r[2][0]) / s)
    elif r[1][1] > r[2][2]:
        s = math.sqrt(1.0 + r[1][1] - r[0][0] - r[2][2]) * 2
        q = ((r[0][2] - r[2][0]) / s, (r[0][1] + r[1][0]) / s, 0.25 * s, (r[1][2] + r[2][1]) / s)
    else:
        s = math.sqrt(1.0 + r[2][2] - r[0][0] - r[1][1]) * 2
        q = ((r[1][0] - r[0][1]) / s, (r[0][2] + r[2][0]) / s, (r[1][2] + r[2][1]) / s, 0.25 * s)
    return (m[0][3], m[1][3], m[2][3]), q


def ang(a, b):
    return math.degrees(2 * math.acos(min(1.0, abs(sum(x * y for x, y in zip(a, b))))))


def dist(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def axis_angle(q):
    w = max(-1.0, min(1.0, q[0]))
    a = 2 * math.acos(abs(w))
    s = math.sqrt(max(0.0, 1 - w * w)) or 1.0
    sign = 1 if w >= 0 else -1
    return math.degrees(a), tuple(round(sign * c / s, 3) for c in q[1:])


class _Sample(Structure):
    _fields_ = [("Count", c_uint), ("Quality", c_uint)]


class _Tex2D(Structure):
    _fields_ = [("Width", c_uint), ("Height", c_uint), ("MipLevels", c_uint), ("ArraySize", c_uint),
                ("Format", c_uint), ("SampleDesc", _Sample), ("Usage", c_uint), ("BindFlags", c_uint),
                ("CPUAccessFlags", c_uint), ("MiscFlags", c_uint)]


class FramePump:
    """Submits a blank D3D11 texture every frame so SteamVR treats this process as a Running
    scene app; without that (and with the dashboard up) actions stay inactive."""

    def __init__(self):
        dev, ctx, fl = c_void_p(), c_void_p(), c_uint()
        hr = ctypes.windll.d3d11.D3D11CreateDevice(None, 1, None, 0, None, 0, 7, byref(dev), byref(fl), byref(ctx))
        if hr:
            raise RuntimeError("D3D11CreateDevice failed 0x%x" % (hr & 0xFFFFFFFF))
        vt = ctypes.cast(dev, POINTER(POINTER(c_void_p)))[0]
        create = WINFUNCTYPE(HRESULT, c_void_p, POINTER(_Tex2D), c_void_p, POINTER(c_void_p))(vt[5])
        self.dev, self.tex = dev, c_void_p()
        create(dev, byref(_Tex2D(64, 64, 1, 1, 28, _Sample(1, 0), 0, 0x28, 0, 0)), None, byref(self.tex))
        self.t = openvr.Texture_t()
        self.t.handle, self.t.eType, self.t.eColorSpace = self.tex.value, openvr.TextureType_DirectX, openvr.ColorSpace_Gamma
        self.stop, self.errors = False, []
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        comp = openvr.VRCompositor()
        while not self.stop:
            try:
                comp.waitGetPoses(None, None)
                comp.submit(openvr.Eye_Left, self.t)
                comp.submit(openvr.Eye_Right, self.t)
            except Exception as e:  # keep pumping; report later
                self.errors.append(repr(e))
                time.sleep(0.011)

    def close(self):
        self.stop = True
        self.thread.join(1.0)


def prop(vrsys, i, p):
    try:
        return vrsys.getStringTrackedDeviceProperty(i, p)
    except openvr.error_code.TrackedPropertyError:
        return ""


def base():
    rep, fv = Report(), FakeVR()
    fv.reset()
    time.sleep(0.1)
    vrsys, pump = openvr.init(openvr.VRApplication_Scene), None
    try:
        for i in range(NDEV):
            cls = vrsys.getTrackedDeviceClass(i)
            if cls != openvr.TrackedDeviceClass_Invalid:
                print(f"  dev {i}: class={cls} serial={prop(vrsys, i, openvr.Prop_SerialNumber_String)} "
                      f"role={vrsys.getControllerRoleForTrackedDeviceIndex(i)} "
                      f"type={prop(vrsys, i, openvr.Prop_ControllerType_String)} "
                      f"model={prop(vrsys, i, openvr.Prop_RenderModelName_String)}")
        L = vrsys.getTrackedDeviceIndexForControllerRole(openvr.TrackedControllerRole_LeftHand)
        R = vrsys.getTrackedDeviceIndexForControllerRole(openvr.TrackedControllerRole_RightHand)
        devs = {"hmd": openvr.k_unTrackedDeviceIndex_Hmd, "left": L, "right": R}
        rep.check(prop(vrsys, 0, openvr.Prop_SerialNumber_String) == "QDFAKE-HMD-0001", "HMD is qdfake")
        rep.check(prop(vrsys, L, openvr.Prop_SerialNumber_String) == "QDFAKE_Controller_Left" and
                  prop(vrsys, R, openvr.Prop_SerialNumber_String) == "QDFAKE_Controller_Right",
                  f"controller roles: left idx {L}, right idx {R}")
        ctype = prop(vrsys, L, openvr.Prop_ControllerType_String)
        rep.check(ctype in ("frame_controller", "oculus_touch") and prop(vrsys, R, openvr.Prop_ControllerType_String) == ctype,
                  f"controller type {ctype}")
        w, h = vrsys.getRecommendedRenderTargetSize()
        print(f"  recommended render target {w}x{h} (SteamVR applies its supersample scale)")

        # ---- pose round trip
        rng, worst = random.Random(7), {STANDING: [0, 0], RAW: [0, 0]}
        ok_all = True
        for _ in range(6):
            tgt = {n: ((rng.uniform(-1, 1), rng.uniform(0.3, 2.0), rng.uniform(-1, 1)),
                       quat_from_ypr(rng.uniform(-180, 180), rng.uniform(-80, 80), rng.uniform(-90, 90)))
                   for n in devs}
            for n, (p, q) in tgt.items():
                fv.pose(n, p, q, vel=(0, 0, 0))
            time.sleep(0.08)
            for origin in (STANDING, RAW):
                poses = vrsys.getDeviceToAbsoluteTrackingPose(origin, 0, NDEV)
                for n, i in devs.items():
                    p, q = pos_quat(poses[i].mDeviceToAbsoluteTracking)
                    dp, da = dist(p, tgt[n][0]), ang(q, tgt[n][1])
                    worst[origin] = [max(worst[origin][0], dp), max(worst[origin][1], da)]
                    ok_all &= bool(poses[i].bPoseIsValid and poses[i].bDeviceIsConnected and dp < 1e-3 and da < 0.1)
        rep.check(ok_all, "pose round-trip x6 random poses, 3 devices: worst standing %.3f mm %.3f deg, raw %.3f mm %.3f deg"
                  % (worst[STANDING][0] * 1e3, worst[STANDING][1], worst[RAW][0] * 1e3, worst[RAW][1]))

        # ---- velocity + prediction
        p0, v0 = (0.2, 1.2, -0.4), (1.0, 0.5, -2.0)
        fv.pose("right", p0, (1, 0, 0, 0), vel=v0)
        time.sleep(0.08)
        tp = vrsys.getDeviceToAbsoluteTrackingPose(STANDING, 0, NDEV)[R]
        v = tuple(tp.vVelocity[k] for k in range(3))
        pp = pos_quat(vrsys.getDeviceToAbsoluteTrackingPose(STANDING, 0.05, NDEV)[R].mDeviceToAbsoluteTracking)[0]
        p_now = pos_quat(tp.mDeviceToAbsoluteTracking)[0]
        rep.check(dist(v, v0) < 0.01, f"velocity reported {tuple(round(c, 3) for c in v)}")
        print("  note: with vel set, pose(t+0.05) - pose(t) = %s (SteamVR extrapolates v*dt; t=0 pose offset %.1f mm)"
              % (tuple(round(a - b, 3) for a, b in zip(pp, p_now)), dist(p_now, p0) * 1e3))
        fv.vel("right", (0, 0, 0))
        # time-stamped sample ("at"): a pose 50 ms old moving at 1 m/s +X must read p + v*age
        stamp = time.time() - 0.05
        fv.pose("right", p0, (1, 0, 0, 0), vel=(1.0, 0, 0), stamp=stamp)
        time.sleep(0.03)
        tq = time.time()
        x = pos_quat(vrsys.getDeviceToAbsoluteTrackingPose(STANDING, 0, NDEV)[R].mDeviceToAbsoluteTracking)[0][0]
        rep.check(abs(x - (p0[0] + (tq - stamp))) < 0.006,
                  f"'at' stamp honoured: x {x:.4f} vs expected {p0[0] + (tq - stamp):.4f}")
        fv.pose("right", p0, (1, 0, 0, 0), vel=(0, 0, 0))

        # ---- connection / tracking validity
        fv.valid("right", False)
        time.sleep(0.1)
        tp = vrsys.getDeviceToAbsoluteTrackingPose(STANDING, 0, NDEV)[R]
        rep.check(not tp.bPoseIsValid and tp.bDeviceIsConnected and
                  tp.eTrackingResult == openvr.TrackingResult_Running_OutOfRange, "valid right 0 -> pose invalid")
        fv.valid("right", True)
        fv.conn("left", False)
        time.sleep(0.3)
        tp = vrsys.getDeviceToAbsoluteTrackingPose(STANDING, 0, NDEV)[L]
        rep.check(not tp.bDeviceIsConnected, "conn left 0 -> disconnected")
        fv.conn("left", True)
        time.sleep(0.5)
        L2 = vrsys.getTrackedDeviceIndexForControllerRole(openvr.TrackedControllerRole_LeftHand)
        tp = vrsys.getDeviceToAbsoluteTrackingPose(STANDING, 0, NDEV)[L]
        rep.check(tp.bDeviceIsConnected and tp.bPoseIsValid and L2 == L, f"conn left 1 -> reconnected (idx {L2})")

        # ---- legacy GetControllerState (needs input focus: render frames + no dashboard)
        fv.reset()
        pump = FramePump()
        focus(rep, vrsys, fv)
        ev = openvr.VREvent_t()
        while vrsys.pollNextEvent(ev):
            pass
        print(f"  input available to this app: {vrsys.isInputAvailable()} "
              f"(activity hmd/left/right: {[vrsys.getTrackedDeviceActivityLevel(i) for i in (0, L, R)]})")
        t_end = time.time() + 5  # legacy bindings load a moment after init
        while time.time() < t_end:
            fv.btn("right", "a", 1)
            time.sleep(0.1)
            warm = vrsys.getControllerState(R)[1].ulButtonPressed >> 7 & 1
            fv.btn("right", "a", 0)
            time.sleep(0.1)
            if warm:
                break
        # left system is not in {oculus}/input/legacy_bindings_touch.json (and toggles the dashboard)
        cases = [("right", "trigger", 33, 1), ("right", "grip", 2, 2), ("right", "a", 7, None),
                 ("right", "b", 1, None), ("right", "joyclick", 32, None), ("left", "trigger", 33, 1),
                 ("left", "grip", 2, 2), ("left", "x", 7, None), ("left", "y", 1, None),
                 ("left", "joyclick", 32, None)]
        for hand, btn, bit, axis in cases:
            i = devs[hand]
            fv.btn(hand, btn, 1)
            time.sleep(0.12)
            st = vrsys.getControllerState(i)[1]
            down, ax = st.ulButtonPressed, (st.rAxis[axis].x if axis is not None else None)
            fv.btn(hand, btn, 0)
            time.sleep(0.12)
            up = vrsys.getControllerState(i)[1].ulButtonPressed
            rep.check(bool(down >> bit & 1) and not (up >> bit & 1) and (ax is None or ax > 0.99),
                      f"legacy {hand} {btn}: bit {bit} pressed=0x{down:x} released=0x{up:x}"
                      + (f" axis{axis}={ax:.2f}" if ax is not None else ""))
        fv.joy("right", 0.5, -0.25)
        fv.axis("left", "trigger", 0.4)
        time.sleep(0.12)
        jr, tl = vrsys.getControllerState(R)[1].rAxis[0], vrsys.getControllerState(L)[1].rAxis[1]
        rep.check(abs(jr.x - 0.5) < 0.01 and abs(jr.y + 0.25) < 0.01 and abs(tl.x - 0.4) < 0.01,
                  f"legacy axes: right joy ({jr.x:.3f},{jr.y:.3f}), left trigger {tl.x:.3f}")
        fv.reset()
    finally:
        if pump:
            pump.close()
        openvr.shutdown()
    return rep.fails


def focus(rep, vrsys, fv):
    """Wait until this scene app is Running, then hide the dashboard if it is up."""
    apps, ov = openvr.VRApplications(), openvr.VROverlay()
    t_end = time.time() + 10
    while time.time() < t_end and apps.getSceneApplicationState() != openvr.EVRSceneApplicationState_Running:
        time.sleep(0.1)
    rep.check(apps.getSceneApplicationState() == openvr.EVRSceneApplicationState_Running, "scene app Running")
    if ov.isDashboardVisible():
        prim = ov.getPrimaryDashboardDevice()
        hand = "right" if prim == vrsys.getTrackedDeviceIndexForControllerRole(
            openvr.TrackedControllerRole_RightHand) else "left"
        fv.dismiss_dashboard(hand)
        time.sleep(0.3)
        rep.check(not ov.isDashboardVisible(), f"dashboard dismissed via fakevr.dismiss_dashboard('{hand}')")
    return ov


def actions():
    rep, fv = Report(), FakeVR()
    fv.reset()
    fv.get()  # drop old haptic events
    vrsys = openvr.init(openvr.VRApplication_Scene)
    pump = FramePump()
    try:
        ov = focus(rep, vrsys, fv)
        vin = openvr.VRInput()
        vin.setActionManifestPath(os.path.join(HERE, "verify_input", "actions.json"))
        names = ["trigger_click", "trigger_value", "grip_click", "grip_value", "a", "b", "x", "y", "joy",
                 "joy_click", "system", "pose_raw", "pose_tip", "pose_grip"]
        A = {n: vin.getActionHandle(f"/actions/main/in/{n}") for n in names}
        hap = vin.getActionHandle("/actions/main/out/haptic")
        src = {h: vin.getInputSourceHandle(f"/user/hand/{h}") for h in ("left", "right")}
        sets = (openvr.VRActiveActionSet_t * 1)()
        sets[0].ulActionSet = vin.getActionSetHandle("/actions/main")
        sets[0].ulRestrictedToDevice = openvr.k_ulInvalidInputValueHandle

        def pose(name, hand):
            vin.updateActionState(sets)
            return vin.getPoseActionDataRelativeToNow(A[name], STANDING, 0, src[hand])

        t_end = time.time() + 15
        while time.time() < t_end and not pose("pose_raw", "right").bActive:
            time.sleep(0.2)
        rep.check(pose("pose_raw", "right").bActive,
                  f"binding active (verify_input/bindings_oculus_touch.json), input focus {vrsys.isInputAvailable()}")

        def digital(name, hand):
            vin.updateActionState(sets)
            return vin.getDigitalActionData(A[name], src[hand])

        def analog(name, hand):
            vin.updateActionState(sets)
            return vin.getAnalogActionData(A[name], src[hand])

        for hand, btn, act in [("right", "trigger", "trigger_click"), ("right", "grip", "grip_click"),
                               ("right", "a", "a"), ("right", "b", "b"), ("right", "joyclick", "joy_click"),
                               ("left", "trigger", "trigger_click"), ("left", "grip", "grip_click"),
                               ("left", "x", "x"), ("left", "y", "y"), ("left", "joyclick", "joy_click")]:
            before = digital(act, hand)
            fv.btn(hand, btn, 1)
            time.sleep(0.12)
            on = digital(act, hand)
            fv.btn(hand, btn, 0)
            time.sleep(0.12)
            off = digital(act, hand)
            rep.check(on.bActive and on.bState and not before.bState and not off.bState,
                      f"action {act} <- {hand} {btn} (active={on.bActive} {int(before.bState)}{int(on.bState)}{int(off.bState)})")
        fv.axis("right", "trigger", 0.6)
        fv.axis("left", "grip", 0.35)
        fv.joy("left", 0.3, -0.7)
        time.sleep(0.12)
        tv, gv, jv = analog("trigger_value", "right"), analog("grip_value", "left"), analog("joy", "left")
        rep.check(abs(tv.x - 0.6) < 0.01 and abs(gv.x - 0.35) < 0.01 and abs(jv.x - 0.3) < 0.01 and abs(jv.y + 0.7) < 0.01,
                  f"analog: right trigger {tv.x:.3f}, left grip {gv.x:.3f}, left joy ({jv.x:.3f},{jv.y:.3f})")
        fv.reset()

        for hand, p in (("left", (-0.25, 1.1, -0.3)), ("right", (0.3, 1.2, -0.35))):
            q = quat_from_ypr(30, 10, -20)
            fv.pose(hand, p, q, vel=(0, 0, 0))
            time.sleep(0.12)
            rp, rq = pos_quat(pose("pose_raw", hand).pose.mDeviceToAbsoluteTracking)
            rep.check(dist(rp, p) < 1e-3 and ang(rq, q) < 0.1, f"{hand} /pose/raw == sent pose")
            for name in ("tip", "grip"):
                d = pose(f"pose_{name}", hand)
                cp, cq = pos_quat(d.pose.mDeviceToAbsoluteTracking)
                rel_p, rel_q = qrot(qconj(rq), tuple(a - b for a, b in zip(cp, rp))), qmul(qconj(rq), cq)
                exp_p, exp_q = COMPONENTS[name][hand]
                deg, axis = axis_angle(rel_q)
                rep.check(d.bActive and d.pose.bPoseIsValid and dist(rel_p, exp_p) < 1e-3 and ang(rel_q, exp_q) < 0.2,
                          f"{hand} /pose/{name} in raw frame: pos {tuple(round(c * 1000, 1) for c in rel_p)} mm, "
                          f"rot {deg:.2f} deg about {axis} (fakevr.COMPONENTS match)")
        fv.reset()

        fv.get()
        vin.triggerHapticVibrationAction(hap, 0, 0.05, 160, 0.7, src["right"])
        vin.triggerHapticVibrationAction(hap, 0, 0.1, 80, 0.3, src["left"])
        time.sleep(0.3)
        ev = fv.get()["haptics"]
        r = [e for e in ev if e["hand"] == "right"]
        l_ = [e for e in ev if e["hand"] == "left"]
        rep.check(bool(r) and bool(l_) and abs(r[0]["amp"] - 0.7) < 0.01 and abs(l_[0]["amp"] - 0.3) < 0.01,
                  f"haptics round-trip: {ev}")

        # last: left system (= Touch menu button). SteamVR's compositor binding uses it to toggle
        # the dashboard, so report what the app sees instead of failing on it.
        fv.btn("left", "system", 1)
        seen = False
        for _ in range(6):
            time.sleep(0.05)
            seen |= bool(digital("system", "left").bState)
        fv.btn("left", "system", 0)
        time.sleep(0.6)
        print(f"INFO left system click: app action seen={seen}, dashboard visible after={ov.isDashboardVisible()}")
        if ov.isDashboardVisible():
            fv.dismiss_dashboard("left")
    finally:
        pump.close()
        openvr.shutdown()
    return rep.fails


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    if mode == "all":
        rc = 0
        for m in ("base", "actions"):
            print(f"== {m}")
            rc |= subprocess.call([sys.executable, os.path.abspath(__file__), m])
        print("ALL PASSED" if rc == 0 else "SOME CHECKS FAILED")
        sys.exit(rc)
    sys.exit(1 if (base() if mode == "base" else actions()) else 0)
