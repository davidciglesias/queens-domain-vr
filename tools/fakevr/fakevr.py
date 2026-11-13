#!/usr/bin/env python3
"""fakevr - script the qdfake SteamVR driver (fake HMD + Quest-2-style Touch controllers).

Talks UDP to 127.0.0.1:27115 (driver polls it every vrserver frame, ~90-100 Hz).
Space: SteamVR tracking space, meters, +X right, +Y up, -Z forward. Quaternions (w, x, y, z).
Angles in this module are degrees: yaw + = turn left, pitch + = aim up, roll about local Z.
"head-relative" = HMD position + HMD yaw only (head pitch/roll ignored).

    from fakevr import FakeVR, quat_from_ypr
    vr = FakeVR()
    vr.pose('right', (0.2, 1.2, -0.4), quat_from_ypr(0, 20, 0))
    vr.tap('right', 'trigger')
    vr.point('right', offset=(0.25, -0.3, -0.45), yaw=-10, frame='tip')
    vr.swing(direction='left', speed=3.0, length=0.8)
    print(vr.haptics())

CLI: python fakevr.py -h   (stdlib only)
"""
import argparse
import json
import math
import socket
import sys
import time

HOST, PORT, RATE = "127.0.0.1", 27115, 90.0
HANDS = ("left", "right")

# Render-model components (what SteamVR uses for /pose/tip and /pose/grip), relative to the raw
# pose: (position m, quaternion w,x,y,z). COMPONENTS = Steam Frame controller (driver default,
# {frame_controller}frame_controller_*: tip rotate_xyz (-40,0,0), grip (2.8091,0,0)); measured equal
# by verify.py 2026-11-13. COMPONENTS_TOUCH = oculus_quest2_controller_* (driver setting controller=touch).
def _qx(deg):
    h = math.radians(deg) / 2
    return (math.cos(h), math.sin(h), 0.0, 0.0)


COMPONENTS = {
    "tip": {"left": ((0.012694, -0.02522, 0.020687), _qx(-40.0)),
            "right": ((-0.012694, -0.02522, 0.020687), _qx(-40.0))},
    "grip": {"left": ((-0.003117, -0.004277, 0.099501), _qx(2.8091)),
             "right": ((0.003117, -0.004277, 0.099501), _qx(2.8091))},
}

COMPONENTS_TOUCH = {
    "tip": {"left": ((0.016694, -0.02522, 0.024687), _qx(-37.4)),
            "right": ((-0.016694, -0.02522, 0.024687), _qx(-37.4))},
    "grip": {"left": ((0.0, 0.003, 0.097), _qx(5.037)),
             "right": ((0.0, 0.003, 0.097), _qx(5.037))},
}

# ------------------------------------------------------------------ math
def qmul(a, b):
    w1, x1, y1, z1 = a
    w2, x2, y2, z2 = b
    return (w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2, w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
            w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2, w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2)


def qconj(q):
    return (q[0], -q[1], -q[2], -q[3])


def qrot(q, v):
    return qmul(qmul(q, (0.0, *v)), qconj(q))[1:]


def qaxis(axis, deg):
    n = math.sqrt(sum(c * c for c in axis))
    s = math.sin(math.radians(deg) / 2) / n
    return (math.cos(math.radians(deg) / 2), axis[0] * s, axis[1] * s, axis[2] * s)


def quat_from_ypr(yaw=0.0, pitch=0.0, roll=0.0):
    """Yaw about +Y, then pitch about local +X, then roll about local +Z (degrees)."""
    return qmul(qmul(qaxis((0, 1, 0), yaw), qaxis((1, 0, 0), pitch)), qaxis((0, 0, 1), roll))


def forward(q):
    return qrot(q, (0.0, 0.0, -1.0))


def heading_deg(q):
    f = forward(q)
    return math.degrees(math.atan2(-f[0], -f[2]))


def ypr_from_quat(q):
    f = forward(q)
    yaw = math.degrees(math.atan2(-f[0], -f[2]))
    pitch = math.degrees(math.asin(max(-1.0, min(1.0, f[1]))))
    rest = qmul(qconj(qmul(qaxis((0, 1, 0), yaw), qaxis((1, 0, 0), pitch))), q)
    roll = math.degrees(2 * math.atan2(rest[3], rest[0]))
    return yaw, pitch, roll


def qslerp(a, b, u):
    d = _dot(a, b)
    if d < 0:
        b, d = _scale(b, -1.0), -d
    if d > 0.9995:
        return _norm(_add(a, _scale(_sub(b, a), u)))
    th = math.acos(d)
    return _add(_scale(a, math.sin((1 - u) * th) / math.sin(th)), _scale(b, math.sin(u * th) / math.sin(th)))


def _minjerk(u):
    """Minimum-jerk position fraction and its derivative d/du for u in [0, 1]."""
    return 10 * u ** 3 - 15 * u ** 4 + 6 * u ** 5, 30 * u ** 2 - 60 * u ** 3 + 30 * u ** 4


def _add(a, b):
    return tuple(x + y for x, y in zip(a, b))


def _sub(a, b):
    return tuple(x - y for x, y in zip(a, b))


def _scale(a, s):
    return tuple(x * s for x in a)


def _dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def _norm(a):
    n = math.sqrt(_dot(a, a))
    return _scale(a, 1.0 / n) if n > 1e-12 else a


def raw_from_frame(hand, frame, pos, quat):
    """Raw device pose that puts SteamVR's /pose/<frame> (tip|grip|raw) at pos/quat."""
    if frame in (None, "raw"):
        return tuple(pos), tuple(quat)
    pc, qc = COMPONENTS[frame][hand]
    q_raw = qmul(quat, qconj(qc))
    return _sub(pos, qrot(q_raw, pc)), q_raw


def frame_from_raw(hand, frame, pos, quat):
    if frame in (None, "raw"):
        return tuple(pos), tuple(quat)
    pc, qc = COMPONENTS[frame][hand]
    return _add(pos, qrot(quat, pc)), qmul(quat, qc)


_DIRS = {"left": (-1, 0, 0), "right": (1, 0, 0), "up": (0, 1, 0), "down": (0, -1, 0),
         "forward": (0, 0, -1), "fwd": (0, 0, -1), "thrust": (0, 0, -1), "back": (0, 0, 1)}


def direction_vec(direction):
    """'left', 'down-left', 'downleft', an angle in the frontal plane in degrees
    (0 right, 90 up, 180 left, 270 down) or an (x, y, z) vector; head-yaw frame."""
    if isinstance(direction, (tuple, list)):
        return _norm(tuple(float(c) for c in direction))
    s = str(direction).strip().lower()
    try:
        a = math.radians(float(s))
        return (math.cos(a), math.sin(a), 0.0)
    except ValueError:
        pass
    v, rest = (0.0, 0.0, 0.0), s.replace("-", "").replace("_", "")
    while rest:
        for name in sorted(_DIRS, key=len, reverse=True):
            if rest.startswith(name):
                v, rest = _add(v, _DIRS[name]), rest[len(name):]
                break
        else:
            raise ValueError(f"bad direction {direction!r}")
    return _norm(v)


# ------------------------------------------------------------------ client
class FakeVRError(RuntimeError):
    pass


class FakeVR:
    def __init__(self, host=HOST, port=PORT, timeout=1.0):
        self.addr, self.timeout = (host, port), timeout
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(timeout)

    def close(self):
        self.sock.close()

    def _drain(self):
        self.sock.setblocking(False)
        try:
            while True:
                self.sock.recv(65536)
        except OSError:
            pass
        finally:
            self.sock.settimeout(self.timeout)

    def send(self, *lines, wait=True):
        """Send protocol lines in one datagram (applied atomically in one driver frame).
        Returns the reply ('ok N', JSON, 'pong'); raises FakeVRError on 'err ...' or timeout."""
        if wait:
            self._drain()
        self.sock.sendto("\n".join(lines).encode(), self.addr)
        if not wait:
            return None
        try:
            reply = self.sock.recv(65536).decode()
        except (socket.timeout, ConnectionResetError):
            raise FakeVRError(f"no reply from qdfake at {self.addr[0]}:{self.addr[1]} "
                              "(SteamVR running with fakevr.ps1 on?)") from None
        if reply.startswith("err"):
            raise FakeVRError(reply)
        return reply

    # -- raw protocol wrappers
    def ping(self):
        return self.send("ping") == "pong"

    def get(self):
        """Full state + haptic events since the previous get (clears them)."""
        return json.loads(self.send("get"))

    def reset(self):
        return self.send("reset")

    def pose(self, dev, pos, quat=None, vel=None, wait=True, stamp=None):
        """stamp: wall-clock time (time.time()) the sample belongs to; the driver passes the age
        to SteamVR (poseTimeOffset) so velocity extrapolation is not skewed by UDP/frame latency."""
        cmd = "pose %s %.6f %.6f %.6f" % (dev, *pos)
        if quat is not None:
            cmd += " %.7f %.7f %.7f %.7f" % tuple(quat)
        lines = ([f"at {stamp:.6f}"] if stamp else []) + [cmd]
        lines += ["vel %s %.6f %.6f %.6f" % (dev, *vel)] if vel is not None else []
        return self.send(*lines, wait=wait)

    def vel(self, dev, v, wait=True):
        return self.send("vel %s %.6f %.6f %.6f" % (dev, *v), wait=wait)

    def avel(self, dev, w, wait=True):
        return self.send("avel %s %.6f %.6f %.6f" % (dev, *w), wait=wait)

    def btn(self, hand, name, down=True):
        return self.send(f"btn {hand} {name} {int(bool(down))}")

    def touch(self, hand, name, on=True):
        return self.send(f"touch {hand} {name} {int(bool(on))}")

    def axis(self, hand, name, value):
        return self.send(f"axis {hand} {name} {float(value):.4f}")

    def joy(self, hand, x, y):
        return self.send(f"joy {hand} {float(x):.4f} {float(y):.4f}")

    def conn(self, dev, on=True):
        return self.send(f"conn {dev} {int(bool(on))}")

    def valid(self, dev, on=True):
        return self.send(f"valid {dev} {int(bool(on))}")

    def prox(self, on=True):
        return self.send(f"prox {int(bool(on))}")

    # -- helpers
    def tap(self, hand, name, dur=0.1):
        """Press and release (default 100 ms = ~9 game frames; shorter taps can be missed)."""
        self.btn(hand, name, True)
        time.sleep(dur)
        return self.btn(hand, name, False)

    def hold(self, hand, name, secs):
        return self.tap(hand, name, secs)

    def haptics(self):
        """Haptic events since the previous get()/haptics() (consumes them)."""
        return self.get()["haptics"]

    def state(self):
        """Like get() but leaves the haptic queue untouched."""
        return json.loads(self.send("state"))

    def head(self):
        h = self.state()["dev"]["hmd"]
        return tuple(h["pos"]), tuple(h["rot"])

    def dismiss_dashboard(self, hand="left"):
        """Hide the SteamVR dashboard (shown at startup and 10 s after the last scene app; it owns
        input focus, so the game gets no actions while it is up): aim `hand` (the dashboard's laser
        hand, normally left) at the floor, click its trigger, restore the pose. Do it while the game
        is running - with no scene app SteamVR brings the dashboard back after 10 s."""
        d = self.state()["dev"][hand]
        self.pose(hand, d["pos"], quat_from_ypr(0, -85, 0), vel=(0, 0, 0))
        time.sleep(0.15)
        self.tap(hand, "trigger", 0.1)
        time.sleep(0.2)
        return self.pose(hand, d["pos"], d["rot"])

    def move_to(self, dev, pos, quat, speed=0.5, rate=RATE):
        """Glide `dev` from its current pose to pos/quat (minimum-jerk, average `speed` m/s,
        >= 90 deg/s turn) streaming pose+velocity at `rate` Hz. Teleports would look like a
        40+ m/s swing to anything that differentiates positions. speed<=0 teleports."""
        d = self.state()["dev"][dev]
        p0, q0 = tuple(d["pos"]), tuple(d["rot"])
        dist = math.sqrt(_dot(_sub(pos, p0), _sub(pos, p0)))
        if _dot(q0, quat) < 0:
            quat = _scale(quat, -1.0)
        ang = math.degrees(2 * math.acos(min(1.0, abs(_dot(q0, quat)))))
        T = 0.0 if speed <= 0 else max(dist / speed, ang / 90.0)
        n = int(T * rate)
        t0 = time.perf_counter()
        for k in range(1, n + 1):
            u = k / n
            s, ds = _minjerk(u)
            p = _add(p0, _scale(_sub(pos, p0), s))
            v = _scale(_sub(pos, p0), ds / T)
            self.pose(dev, p, qslerp(q0, quat, s), vel=v, wait=False, stamp=time.time())
            delay = t0 + k / rate - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
        return self.pose(dev, pos, quat, vel=(0.0, 0.0, 0.0))

    def point(self, hand="right", offset=(0.2, -0.3, -0.4), yaw=0.0, pitch=0.0, roll=0.0,
              frame="raw", head=None, speed=0.5):
        """Place `hand` at a head-relative offset (x right, y up, -z forward, meters) aiming
        yaw/pitch/roll (degrees, head-yaw relative). frame='tip'|'grip' compensates the
        render-model offset so that SteamVR's /pose/tip or /pose/grip lands exactly there.
        Glides there at `speed` m/s (0 = teleport)."""
        hp, hq = head or self.head()
        qy = qaxis((0, 1, 0), heading_deg(hq))
        pos = _add(hp, qrot(qy, offset))
        quat = qmul(qy, quat_from_ypr(yaw, pitch, roll))
        p_raw, q_raw = raw_from_frame(hand, frame, pos, quat)
        self.move_to(hand, p_raw, q_raw, speed)
        return p_raw, q_raw

    def swing(self, hand="right", direction="left", speed=3.0, length=0.8, arc=70.0,
              mid=(0.15, -0.35, -0.45), profile="const", settle=0.15, rate=RATE,
              yaw=0.0, pitch=0.0, roll=0.0, frame="raw", head=None, on_frame=None,
              approach_speed=0.5):
        """Stream a smooth swing for `hand` at `rate` Hz (pose + matching velocity each frame).
        Path: circular arc of arc length `length` (m) through head-relative point `mid`,
        travelling along `direction` at mid-swing and bulging forward (arc degrees; 0 = line).
        profile 'const': |v| = speed throughout; 'smooth': minimum-jerk, peak |v| = speed.
        Orientation is fixed (yaw/pitch/roll head-relative, of /pose/<frame>). First glides to
        the start pose at `approach_speed` m/s (move_to; 0 = teleport), holds it `settle` s, then
        swings; ends with vel 0 at the end point. Returns a summary dict."""
        hp, hq = head or self.head()
        qy = qaxis((0, 1, 0), heading_deg(hq))
        d = direction_vec(direction)
        fwd = (0.0, 0.0, -1.0)
        n = _sub(fwd, _scale(d, _dot(fwd, d)))  # bulge axis: forward, orthogonal to d
        theta = math.radians(arc)
        if math.sqrt(_dot(n, n)) < 1e-3:  # thrust along forward: straight line
            n, theta = (0.0, 1.0, 0.0), 0.0
        n = _norm(n)
        L = float(length)
        R = L / theta if theta > 1e-6 else None
        center = _sub(mid, _scale(n, R)) if R else None

        def path(s):  # position and unit tangent at arc length s (head-yaw frame)
            if R is None:
                return _add(mid, _scale(d, s - L / 2)), d
            phi = (s - L / 2) / R
            c, si = math.cos(phi), math.sin(phi)
            return (_add(center, _add(_scale(n, R * c), _scale(d, R * si))),
                    _add(_scale(n, -si), _scale(d, c)))

        if profile == "const":
            T = L / speed
            prof = lambda t: (speed * t, speed)
        elif profile == "smooth":
            T = 1.875 * L / speed
            prof = lambda t: (L * (10 * (t / T) ** 3 - 15 * (t / T) ** 4 + 6 * (t / T) ** 5),
                              L / T * (30 * (t / T) ** 2 - 60 * (t / T) ** 3 + 30 * (t / T) ** 4))
        else:
            raise ValueError("profile must be const|smooth")
        q_target = qmul(qy, quat_from_ypr(yaw, pitch, roll))
        q_raw = raw_from_frame(hand, frame, (0, 0, 0), q_target)[1]
        start = raw_from_frame(hand, frame, _add(hp, qrot(qy, path(0.0)[0])), q_target)[0]
        self.move_to(hand, start, q_raw, approach_speed, rate)
        dt, k, t0, frames = 1.0 / rate, 0, time.perf_counter(), []
        try:
            while True:
                t = k * dt - settle
                last = t >= T
                s, v = (0.0, 0.0) if t < 0 else ((L, 0.0) if last else prof(t))
                p_local, tan = path(s)
                pos = _add(hp, qrot(qy, p_local))
                vel = qrot(qy, _scale(tan, v))
                p_raw = raw_from_frame(hand, frame, pos, q_target)[0]
                self.pose(hand, p_raw, q_raw, vel=vel, wait=False, stamp=time.time())
                frames.append((round(t, 4), p_raw, vel))
                if on_frame:
                    on_frame(k, t, p_raw, vel)
                k += 1
                if last:
                    break
                delay = t0 + k * dt - time.perf_counter()
                if delay > 0:
                    time.sleep(delay)
        finally:
            self.send("vel %s 0 0 0" % hand, wait=False)
            time.sleep(0.02)
            self._drain()
        return {"hand": hand, "duration": T, "frames": k, "arc_length": L, "speed": speed,
                "profile": profile, "start": frames[0][1], "end": frames[-1][1],
                "wall_time": time.perf_counter() - t0, "q_raw": q_raw}


# ------------------------------------------------------------------ CLI
def _main(argv=None):
    ap = argparse.ArgumentParser(description="Control the qdfake SteamVR driver.")
    ap.add_argument("--port", type=int, default=PORT)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ping")
    sub.add_parser("get", help="print state JSON (+ haptics since last get, consumed)")
    sub.add_parser("state", help="print state JSON without consuming haptics")
    sub.add_parser("reset", help="default poses, all inputs released")
    p = sub.add_parser("dismiss", help="hide the SteamVR dashboard (laser-click at the floor)")
    p.add_argument("hand", choices=HANDS, nargs="?", default="left")
    p = sub.add_parser("raw", help="send protocol lines verbatim")
    p.add_argument("lines", nargs="+")
    p = sub.add_parser("pose")
    p.add_argument("dev", choices=("hmd", "left", "right"))
    p.add_argument("vals", type=float, nargs="+", help="x y z [qw qx qy qz]")
    p = sub.add_parser("ypr", help="pose with yaw/pitch/roll degrees: dev x y z yaw pitch roll")
    p.add_argument("dev", choices=("hmd", "left", "right"))
    p.add_argument("vals", type=float, nargs=6)
    p = sub.add_parser("vel")
    p.add_argument("dev", choices=("hmd", "left", "right"))
    p.add_argument("vals", type=float, nargs=3)
    for name in ("btn", "touch"):
        p = sub.add_parser(name)
        p.add_argument("hand", choices=("hmd",) + HANDS)
        p.add_argument("name")
        p.add_argument("state", type=int, choices=(0, 1))
    p = sub.add_parser("axis")
    p.add_argument("hand", choices=HANDS)
    p.add_argument("name", choices=("trigger", "grip"))
    p.add_argument("value", type=float)
    p = sub.add_parser("joy")
    p.add_argument("hand", choices=HANDS)
    p.add_argument("x", type=float)
    p.add_argument("y", type=float)
    p = sub.add_parser("conn")
    p.add_argument("dev", choices=("hmd", "left", "right"))
    p.add_argument("state", type=int, choices=(0, 1))
    for name, dflt in (("tap", 0.1), ("hold", 1.0)):
        p = sub.add_parser(name)
        p.add_argument("hand", choices=HANDS)
        p.add_argument("name")
        p.add_argument("secs", type=float, nargs="?", default=dflt)
    p = sub.add_parser("haptics", help="print haptic events since last get")
    p.add_argument("--watch", type=float, default=0.0, help="keep polling for N seconds")
    p = sub.add_parser("point", help="place a hand head-relative and aim it")
    p.add_argument("hand", choices=HANDS)
    p.add_argument("--off", type=float, nargs=3, default=(0.2, -0.3, -0.4), metavar=("X", "Y", "Z"))
    p.add_argument("--yaw", type=float, default=0.0)
    p.add_argument("--pitch", type=float, default=0.0)
    p.add_argument("--roll", type=float, default=0.0)
    p.add_argument("--frame", choices=("raw", "tip", "grip"), default="raw")
    p.add_argument("--speed", type=float, default=0.5, help="glide speed m/s (0 = teleport)")
    p = sub.add_parser("swing", help="stream a swing arc at 90 Hz")
    p.add_argument("--hand", choices=HANDS, default="right")
    p.add_argument("--dir", default="left", help="left|right|up|down|forward|down-left|<deg>")
    p.add_argument("--speed", type=float, default=3.0, help="m/s (peak for --profile smooth)")
    p.add_argument("--length", type=float, default=0.8, help="arc length, m")
    p.add_argument("--arc", type=float, default=70.0, help="arc angle, deg (0 = straight)")
    p.add_argument("--mid", type=float, nargs=3, default=(0.15, -0.35, -0.45), metavar=("X", "Y", "Z"))
    p.add_argument("--profile", choices=("const", "smooth"), default="const")
    p.add_argument("--settle", type=float, default=0.15)
    p.add_argument("--rate", type=float, default=RATE)
    p.add_argument("--yaw", type=float, default=0.0)
    p.add_argument("--pitch", type=float, default=0.0)
    p.add_argument("--roll", type=float, default=0.0)
    p.add_argument("--frame", choices=("raw", "tip", "grip"), default="raw")
    p.add_argument("--approach", type=float, default=0.5, help="glide-to-start speed m/s (0 = teleport)")
    a = ap.parse_args(argv)
    vr = FakeVR(port=a.port)
    c = a.cmd
    if c == "ping":
        print("pong" if vr.ping() else "?")
    elif c in ("get", "state"):
        print(json.dumps(getattr(vr, c)(), indent=1))
    elif c == "reset":
        print(vr.reset())
    elif c == "dismiss":
        print(vr.dismiss_dashboard(a.hand))
    elif c == "raw":
        print(vr.send(*a.lines))
    elif c == "pose":
        if len(a.vals) not in (3, 7):
            sys.exit("pose needs x y z [qw qx qy qz]")
        print(vr.pose(a.dev, a.vals[:3], a.vals[3:] or None))
    elif c == "ypr":
        print(vr.pose(a.dev, a.vals[:3], quat_from_ypr(*a.vals[3:])))
    elif c == "vel":
        print(vr.vel(a.dev, a.vals))
    elif c in ("btn", "touch"):
        print(getattr(vr, c)(a.hand, a.name, a.state))
    elif c == "axis":
        print(vr.axis(a.hand, a.name, a.value))
    elif c == "joy":
        print(vr.joy(a.hand, a.x, a.y))
    elif c == "conn":
        print(vr.conn(a.dev, a.state))
    elif c in ("tap", "hold"):
        print(vr.tap(a.hand, a.name, a.secs))
    elif c == "haptics":
        end = time.time() + a.watch
        while True:
            for e in vr.haptics():
                print(json.dumps(e))
            if time.time() >= end:
                break
            time.sleep(0.1)
    elif c == "point":
        p_raw, q_raw = vr.point(a.hand, a.off, a.yaw, a.pitch, a.roll, a.frame, speed=a.speed)
        print("raw pos %.4f %.4f %.4f quat %.5f %.5f %.5f %.5f" % (*p_raw, *q_raw))
    elif c == "swing":
        r = vr.swing(a.hand, a.dir, a.speed, a.length, a.arc, tuple(a.mid), a.profile, a.settle,
                     a.rate, a.yaw, a.pitch, a.roll, a.frame, approach_speed=a.approach)
        print("swing %s: %d frames, %.3f s motion (%.3f s wall), start %s end %s" % (
            r["hand"], r["frames"], r["duration"], r["wall_time"],
            tuple(round(x, 3) for x in r["start"]), tuple(round(x, 3) for x in r["end"])))


if __name__ == "__main__":
    try:
        _main()
    except FakeVRError as e:
        sys.exit(str(e))
