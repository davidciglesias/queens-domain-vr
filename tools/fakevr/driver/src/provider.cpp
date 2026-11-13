// qdfake provider: device setup, pose thread, UDP control channel, haptics.
#include "qdfake.h"

#include <mstcpip.h>
#include <ws2tcpip.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif

namespace qd {

// nullptr = not reported by "get" (trigger/grip click are derived from the value inside PushInput).
static const char *const kBoolNameL[BI_COUNT] = { "trigger_touch", "grip_touch", "joy_click", "joy_touch",
	"x_click", "x_touch", "y_click", "y_touch", "system_click", "system_touch", "thumbrest_touch", nullptr, nullptr,
	"bumper_click", "bumper_touch", "menu_click", "menu_touch", "dpad_left_click", "dpad_left_touch",
	"dpad_up_click", "dpad_up_touch" };
static const char *const kBoolNameR[BI_COUNT] = { "trigger_touch", "grip_touch", "joy_click", "joy_touch",
	"a_click", "a_touch", "b_click", "b_touch", "system_click", "system_touch", "thumbrest_touch", nullptr, nullptr,
	"bumper_click", "bumper_touch", "menu_click", "menu_touch", "x_click", "x_touch", "y_click", "y_touch" };
static const char *const kFloatName[FI_COUNT] = { "trigger", "grip", "joy_x", "joy_y" };

static const size_t kMaxHaptics = 400;
static const uint32_t kNoIdx = vr::k_unTrackedDeviceIndexInvalid;
static const char *kHelp =
	"cmds (';' or newline separated): [at <unix time>] pose <dev> x y z [qw qx qy qz] | vel <dev> vx vy vz | "
	"avel <dev> wx wy wz | conn <dev> 0|1 | valid <dev> 0|1 | btn <hand> trigger|grip|a|b|x|y|joyclick|"
	"system|thumbrest|bumper|menu|view|dpad_up|down|left|right 0|1 | touch <hand> <name> 0|1 | axis <hand> trigger|grip 0..1 | joy <hand> x y | "
	"btn hmd system 0|1 | prox 0|1 | reset | wake | keepalive <s> | get (state + haptics, consumed) | "
	"state | ping | help. dev=hmd|left|right";

static double SteadySec()
{
	using namespace std::chrono;
	return duration_cast<duration<double>>(steady_clock::now().time_since_epoch()).count();
}

static bool Is(const char *a, const char *b) { return _stricmp(a, b) == 0; }

static bool Fail(std::string &out, const char *msg)
{
	out = msg;
	return false;
}

static bool Num(const char *s, double &v)
{
	char *end = nullptr;
	v = strtod(s, &end);
	return end != s && *end == 0 && std::isfinite(v);
}

static float Clamp(double v, double lo, double hi) { return (float)(v < lo ? lo : (v > hi ? hi : v)); }

static int DevOf(const char *s)
{
	if (Is(s, "hmd") || Is(s, "head") || Is(s, "h"))
		return DEV_HMD;
	if (Is(s, "left") || Is(s, "l"))
		return DEV_LEFT;
	if (Is(s, "right") || Is(s, "r"))
		return DEV_RIGHT;
	return -1;
}

void Provider::ResetState()
{
	{
		std::lock_guard<std::mutex> lk(poses_.mtx);
		for (auto &d : poses_.dev) {
			d = PoseState{};
			d.rot[0] = 1.0;
			d.connected = true;
			d.valid = true;
		}
		// Standing 1.7 m looking -Z; hands at waist height, 35 cm in front, 20 cm apart from center.
		poses_.dev[DEV_HMD].pos[1] = 1.7;
		poses_.dev[DEV_LEFT].pos[0] = -0.2;
		poses_.dev[DEV_LEFT].pos[1] = 1.0;
		poses_.dev[DEV_LEFT].pos[2] = -0.35;
		poses_.dev[DEV_RIGHT].pos[0] = 0.2;
		poses_.dev[DEV_RIGHT].pos[1] = 1.0;
		poses_.dev[DEV_RIGHT].pos[2] = -0.35;
	}
	input_[0] = HandInput{};
	input_[1] = HandInput{};
	prox_ = true;
	hmd_sys_ = false;
}

vr::EVRInitError Provider::Init(vr::IVRDriverContext *ctx)
{
	VR_INIT_SERVER_DRIVER_CONTEXT(ctx);
	Log("qdfake init (build %s %s)", __DATE__, __TIME__);
	ResetState();
	rxbuf_.resize(65536);

	vr::EVRSettingsError se = vr::VRSettingsError_None;
	const int32_t port = vr::VRSettings()->GetInt32(kSettings, "port", &se);
	if (se == vr::VRSettingsError_None && port > 0 && port < 65536)
		port_ = port;
	const float ka = vr::VRSettings()->GetFloat(kSettings, "keepalive_s", &se);
	if (se == vr::VRSettingsError_None && ka >= 0.f)
		keepalive_s_ = ka;
	WSADATA wsa;
	if (WSAStartup(MAKEWORD(2, 2), &wsa) == 0) {
		wsa_ok_ = true;
		sock_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
		if (sock_ != INVALID_SOCKET) {
			u_long nonblocking = 1;
			ioctlsocket(sock_, FIONBIO, &nonblocking);
			BOOL report_reset = FALSE; // ignore ICMP port-unreachable from vanished clients
			DWORD bytes = 0;
			WSAIoctl(sock_, SIO_UDP_CONNRESET, &report_reset, sizeof(report_reset), nullptr, 0, &bytes, nullptr, nullptr);
			sockaddr_in a{};
			a.sin_family = AF_INET;
			a.sin_port = htons((u_short)port_);
			inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
			if (bind(sock_, reinterpret_cast<sockaddr *>(&a), sizeof(a)) != 0) {
				Log("UDP bind 127.0.0.1:%d failed (WSA %d): control channel disabled", port_, WSAGetLastError());
				closesocket(sock_);
				sock_ = INVALID_SOCKET;
			} else {
				Log("UDP control listening on 127.0.0.1:%d", port_);
			}
		}
	}

	hmd_ = std::make_unique<HmdDevice>(&poses_);
	ctl_[0] = std::make_unique<ControllerDevice>(true, &poses_);
	ctl_[1] = std::make_unique<ControllerDevice>(false, &poses_);
	auto *host = vr::VRServerDriverHost();
	if (!host->TrackedDeviceAdded(hmd_->Serial(), vr::TrackedDeviceClass_HMD, hmd_.get())) {
		Log("failed to add HMD");
		return vr::VRInitError_Driver_Unknown;
	}
	for (auto &c : ctl_)
		if (!host->TrackedDeviceAdded(c->Serial().c_str(), vr::TrackedDeviceClass_Controller, c.get()))
			Log("failed to add controller %s", c->Serial().c_str());

	rf_t0_ = SteadySec();
	running_ = true;
	pose_thread_ = std::thread(&Provider::PoseThread, this);
	return vr::VRInitError_None;
}

void Provider::Cleanup()
{
	running_ = false;
	WakePoseThread();
	if (pose_thread_.joinable())
		pose_thread_.join();
	if (sock_ != INVALID_SOCKET) {
		closesocket(sock_);
		sock_ = INVALID_SOCKET;
	}
	if (wsa_ok_) {
		WSACleanup();
		wsa_ok_ = false;
	}
	hmd_.reset();
	ctl_[0].reset();
	ctl_[1].reset();
	VR_CLEANUP_SERVER_DRIVER_CONTEXT();
}

void Provider::WakePoseThread()
{
	{
		std::lock_guard<std::mutex> lk(wake_mtx_);
		wake_ = true;
	}
	wake_cv_.notify_one();
}

// Pushes all poses at ~250 Hz, and immediately when a UDP command changed one.
void Provider::PoseThread()
{
	PoseState snap[DEV_COUNT];
	while (running_) {
		{
			std::unique_lock<std::mutex> lk(wake_mtx_);
			wake_cv_.wait_for(lk, std::chrono::milliseconds(4), [this] { return wake_ || !running_; });
			wake_ = false;
		}
		if (!running_)
			break;
		{
			std::lock_guard<std::mutex> lk(poses_.mtx);
			for (int d = 0; d < DEV_COUNT; ++d)
				snap[d] = poses_.dev[d];
		}
		auto *host = vr::VRServerDriverHost();
		uint32_t idx = hmd_->index;
		if (idx != kNoIdx)
			host->TrackedDevicePoseUpdated(idx, MakeDriverPose(snap[DEV_HMD]), sizeof(vr::DriverPose_t));
		for (int h = 0; h < 2; ++h) {
			idx = ctl_[h]->index;
			if (idx != kNoIdx)
				host->TrackedDevicePoseUpdated(idx, MakeDriverPose(snap[DEV_LEFT + h]), sizeof(vr::DriverPose_t));
		}
	}
}

void Provider::RunFrame()
{
	++rf_count_;
	const double now = SteadySec();
	if (now - rf_t0_ >= 1.0) {
		rf_hz_ = rf_count_ / (now - rf_t0_);
		rf_count_ = 0;
		rf_t0_ = now;
	}
	const bool keepalive = keepalive_s_ > 0 && now - last_keepalive_ >= keepalive_s_;
	if (keepalive)
		last_keepalive_ = now;
	for (int h = 0; h < 2; ++h) { // first call after Activate sends everything
		const bool woke = ctl_[h]->standby_hint.exchange(false);
		if (woke) {
			++standby_wakes_;
			Log("%s controller put in standby by SteamVR -> re-sending inputs (wake #%llu)", h ? "right" : "left",
				(unsigned long long)standby_wakes_);
		}
		ctl_[h]->PushInput(input_[h], keepalive || woke);
	}
	PollUdp();
	vr::VREvent_t ev{};
	while (vr::VRServerDriverHost()->PollNextEvent(&ev, sizeof(ev))) {
		if (ev.eventType != vr::VREvent_Input_HapticVibration)
			continue;
		for (int h = 0; h < 2; ++h)
			if (ctl_[h]->OwnsHaptic(ev.data.hapticVibration.componentHandle))
				OnHaptic(h, ev.data.hapticVibration);
	}
}

void Provider::OnHaptic(int hand, const vr::VREvent_HapticVibration_t &e)
{
	++haptics_total_;
	if (haptics_.size() >= kMaxHaptics) {
		haptics_.pop_front();
		++haptics_dropped_;
	}
	haptics_.push_back(HapticEvent{ EpochSec(), hand, e.fDurationSeconds, e.fFrequency, e.fAmplitude });
	if (haptics_total_ <= 20 || haptics_total_ % 500 == 0)
		Log("haptic #%llu %s dur=%.4f freq=%.1f amp=%.3f", (unsigned long long)haptics_total_,
			hand ? "right" : "left", e.fDurationSeconds, e.fFrequency, e.fAmplitude);
}

void Provider::PollUdp()
{
	if (sock_ == INVALID_SOCKET)
		return;
	for (int i = 0; i < 512; ++i) {
		sockaddr_in from{};
		int fromlen = sizeof(from);
		const int n = recvfrom(sock_, rxbuf_.data(), (int)rxbuf_.size() - 1, 0, reinterpret_cast<sockaddr *>(&from), &fromlen);
		if (n == SOCKET_ERROR) {
			const int e = WSAGetLastError();
			if (e == WSAEWOULDBLOCK)
				break;
			if (e == WSAECONNRESET || e == WSAEMSGSIZE)
				continue;
			if (log_budget_ > 0) {
				--log_budget_;
				Log("recvfrom failed (WSA %d)", e);
			}
			break;
		}
		rxbuf_[n] = 0;
		HandleDatagram(rxbuf_.data(), n, from);
	}
}

void Provider::HandleDatagram(char *data, int, const sockaddr_in &from)
{
	std::string reply, err, r;
	int ok = 0;
	bool pose_dirty = false;
	double stamp = 0.0; // set by "at <epoch>", applies to later pose/vel lines of this datagram
	char *ctx = nullptr;
	for (char *line = strtok_s(data, "\n;", &ctx); line; line = strtok_s(nullptr, "\n;", &ctx)) {
		r.clear();
		if (Exec(line, r, pose_dirty, stamp)) {
			++ok;
			if (!r.empty())
				reply.swap(r);
		} else {
			++errs_;
			if (err.empty())
				err = r;
		}
	}
	if (pose_dirty)
		WakePoseThread();
	const std::string out = !err.empty() ? "err " + err : (!reply.empty() ? reply : "ok " + std::to_string(ok));
	sendto(sock_, out.data(), (int)out.size(), 0, reinterpret_cast<const sockaddr *>(&from), sizeof(from));
}

bool Provider::Exec(char *line, std::string &out, bool &pose_dirty, double &stamp)
{
	char *tok[12];
	int nt = 0;
	char *ctx = nullptr;
	for (char *t = strtok_s(line, " \t\r,", &ctx); t && nt < 12; t = strtok_s(nullptr, " \t\r,", &ctx))
		tok[nt++] = t;
	if (nt == 0 || tok[0][0] == '#')
		return true;
	++cmds_;
	const char *c = tok[0];
	const bool quiet = Is(c, "pose") || Is(c, "vel") || Is(c, "avel") || Is(c, "get") || Is(c, "state") ||
		Is(c, "ping") || Is(c, "at");
	if (!quiet && cmd_log_budget_ > 0) {
		--cmd_log_budget_;
		std::string s;
		for (int i = 0; i < nt; ++i)
			(s += ' ') += tok[i];
		Log("cmd:%s", s.c_str());
	}
	double v[7] = {};
	const int d = nt > 1 ? DevOf(tok[1]) : -1;

	if (Is(c, "at")) {
		if (nt != 2 || !Num(tok[1], v[0]) || v[0] < 0)
			return Fail(out, "usage: at <unix time of the following pose samples>");
		stamp = v[0];
		return true;
	}
	if (Is(c, "pose")) {
		if ((nt != 5 && nt != 9) || d < 0)
			return Fail(out, "usage: pose <hmd|left|right> x y z [qw qx qy qz]");
		for (int i = 0; i < nt - 2; ++i)
			if (!Num(tok[i + 2], v[i]))
				return Fail(out, "bad number");
		if (nt == 9) {
			const double n = sqrt(v[3] * v[3] + v[4] * v[4] + v[5] * v[5] + v[6] * v[6]);
			if (n < 1e-9)
				return Fail(out, "zero quaternion");
			for (int i = 3; i < 7; ++i)
				v[i] /= n;
		}
		std::lock_guard<std::mutex> lk(poses_.mtx);
		PoseState &s = poses_.dev[d];
		s.t = stamp;
		for (int i = 0; i < 3; ++i)
			s.pos[i] = v[i];
		if (nt == 9)
			for (int i = 0; i < 4; ++i)
				s.rot[i] = v[3 + i];
		pose_dirty = true;
		return true;
	}
	if (Is(c, "vel") || Is(c, "avel")) {
		if (nt != 5 || d < 0)
			return Fail(out, "usage: vel|avel <hmd|left|right> x y z");
		for (int i = 0; i < 3; ++i)
			if (!Num(tok[i + 2], v[i]))
				return Fail(out, "bad number");
		std::lock_guard<std::mutex> lk(poses_.mtx);
		double *dst = Is(c, "vel") ? poses_.dev[d].vel : poses_.dev[d].avel;
		poses_.dev[d].t = stamp;
		for (int i = 0; i < 3; ++i)
			dst[i] = v[i];
		pose_dirty = true;
		return true;
	}
	if (Is(c, "conn") || Is(c, "valid")) {
		if (nt != 3 || d < 0 || !Num(tok[2], v[0]))
			return Fail(out, "usage: conn|valid <hmd|left|right> 0|1");
		std::lock_guard<std::mutex> lk(poses_.mtx);
		(Is(c, "conn") ? poses_.dev[d].connected : poses_.dev[d].valid) = v[0] != 0.0;
		pose_dirty = true;
		return true;
	}
	if (Is(c, "btn") || Is(c, "touch")) {
		if (nt != 4 || d < 0 || !Num(tok[3], v[0]))
			return Fail(out, "usage: btn|touch <hand> <name> 0|1");
		const bool on = v[0] != 0.0, tonly = Is(c, "touch");
		const char *n = tok[2];
		if (d == DEV_HMD) {
			if (tonly || !(Is(n, "system") || Is(n, "menu")))
				return Fail(out, "hmd only has: btn hmd system 0|1");
			hmd_sys_ = on;
			hmd_->SetSystem(on);
			return true;
		}
		const int h = d - 1;
		HandInput &in = input_[h];
		// Frame: right x/y are their own buttons (F3/F4); left a|x = dpad_down, b|y = dpad_right (what
		// SteamVR's oculus_touch remap reads as X/Y), dpad_left/dpad_up = F3/F4; menu = right menu / left view.
		const bool fr = ctl_[h]->frame && ctl_[h]->HasComponent(BI_F3_CLICK);
		int face = 0; // 1..4 = F1..F4
		if (Is(n, "a") || (Is(n, "x") && !(fr && h == 1)) || Is(n, "dpad_down"))
			face = 1;
		else if (Is(n, "b") || (Is(n, "y") && !(fr && h == 1)) || Is(n, "dpad_right"))
			face = 2;
		else if (fr && (Is(n, "x") || Is(n, "dpad_left")))
			face = 3;
		else if (fr && (Is(n, "y") || Is(n, "dpad_up")))
			face = 4;
		if (face) {
			static const BoolIn kC[4] = { BI_F1_CLICK, BI_F2_CLICK, BI_F3_CLICK, BI_F4_CLICK };
			static const BoolIn kT[4] = { BI_F1_TOUCH, BI_F2_TOUCH, BI_F3_TOUCH, BI_F4_TOUCH };
			if (!tonly)
				in.b[kC[face - 1]] = on;
			in.b[kT[face - 1]] = on;
		} else if (Is(n, "bumper")) {
			if (!ctl_[h]->HasComponent(BI_BUMPER_CLICK))
				return Fail(out, "no bumper (touch mode)");
			if (!tonly)
				in.b[BI_BUMPER_CLICK] = on;
			in.b[BI_BUMPER_TOUCH] = on;
		} else if ((Is(n, "menu") || Is(n, "view")) && ctl_[h]->HasComponent(BI_MENU_CLICK)) {
			if (!tonly)
				in.b[BI_MENU_CLICK] = on;
			in.b[BI_MENU_TOUCH] = on;
		} else if (Is(n, "trigger")) {
			if (!tonly)
				in.f[FI_TRIGGER] = on ? 1.f : 0.f;
			in.b[BI_TRIG_TOUCH] = on;
		} else if (Is(n, "grip")) {
			if (!tonly)
				in.f[FI_GRIP] = on ? 1.f : 0.f;
			in.b[BI_GRIP_TOUCH] = on;
		} else if (Is(n, "joyclick") || Is(n, "joystick") || Is(n, "joy") || Is(n, "stick")) {
			if (!tonly)
				in.b[BI_JOY_CLICK] = on;
			in.b[BI_JOY_TOUCH] = on || in.f[FI_JOY_X] != 0.f || in.f[FI_JOY_Y] != 0.f;
		} else if (Is(n, "system") || Is(n, "menu")) {
			if (!ctl_[h]->HasComponent(BI_SYS_CLICK))
				return Fail(out, "no system button on right hand (touch_profile: left only)");
			if (!tonly)
				in.b[BI_SYS_CLICK] = on;
			in.b[BI_SYS_TOUCH] = on;
		} else if (Is(n, "thumbrest")) {
			in.b[BI_THUMBREST_TOUCH] = on;
		} else {
			return Fail(out, "unknown button (trigger grip a b x y joyclick system thumbrest; frame: bumper menu view dpad_*)");
		}
		ctl_[h]->PushInput(in, false);
		return true;
	}
	if (Is(c, "axis")) {
		if (nt != 4 || d < DEV_LEFT || !Num(tok[3], v[0]))
			return Fail(out, "usage: axis <left|right> trigger|grip 0..1");
		HandInput &in = input_[d - 1];
		const float f = Clamp(v[0], 0.0, 1.0);
		if (Is(tok[2], "trigger")) {
			in.f[FI_TRIGGER] = f;
			in.b[BI_TRIG_TOUCH] = f > 0.f;
		} else if (Is(tok[2], "grip")) {
			in.f[FI_GRIP] = f;
			in.b[BI_GRIP_TOUCH] = f > 0.f;
		} else {
			return Fail(out, "axis name must be trigger|grip");
		}
		ctl_[d - 1]->PushInput(in, false);
		return true;
	}
	if (Is(c, "joy")) {
		if (nt != 4 || d < DEV_LEFT || !Num(tok[2], v[0]) || !Num(tok[3], v[1]))
			return Fail(out, "usage: joy <left|right> x y");
		HandInput &in = input_[d - 1];
		in.f[FI_JOY_X] = Clamp(v[0], -1.0, 1.0);
		in.f[FI_JOY_Y] = Clamp(v[1], -1.0, 1.0);
		in.b[BI_JOY_TOUCH] = in.b[BI_JOY_CLICK] || in.f[FI_JOY_X] != 0.f || in.f[FI_JOY_Y] != 0.f;
		ctl_[d - 1]->PushInput(in, false);
		return true;
	}
	if (Is(c, "prox")) {
		if (nt != 2 || !Num(tok[1], v[0]))
			return Fail(out, "usage: prox 0|1");
		prox_ = v[0] != 0.0;
		hmd_->SetProximity(prox_);
		return true;
	}
	if (Is(c, "wake")) { // re-send all controller inputs (unchanged values)
		for (int h = 0; h < 2; ++h)
			ctl_[h]->PushInput(input_[h], true);
		return true;
	}
	if (Is(c, "keepalive")) {
		if (nt != 2 || !Num(tok[1], v[0]) || v[0] < 0)
			return Fail(out, "usage: keepalive <seconds, 0=off>");
		keepalive_s_ = v[0];
		return true;
	}
	if (Is(c, "reset")) {
		ResetState();
		for (int h = 0; h < 2; ++h)
			ctl_[h]->PushInput(input_[h], true);
		hmd_->SetProximity(true);
		hmd_->SetSystem(false);
		pose_dirty = true;
		return true;
	}
	if (Is(c, "get") || Is(c, "state")) { // state = get without consuming haptic events
		out = BuildJson(Is(c, "get"));
		return true;
	}
	if (Is(c, "ping")) {
		out = "pong";
		return true;
	}
	if (Is(c, "help")) {
		out = kHelp;
		return true;
	}
	return Fail(out, "unknown command (try: help)");
}

std::string Provider::BuildJson(bool consume_haptics)
{
	PoseState s[DEV_COUNT];
	{
		std::lock_guard<std::mutex> lk(poses_.mtx);
		for (int d = 0; d < DEV_COUNT; ++d)
			s[d] = poses_.dev[d];
	}
	std::string j;
	j.reserve(4096 + haptics_.size() * 100);
	char b[640];
	snprintf(b, sizeof(b),
		"{\"ok\":true,\"t\":%.4f,\"port\":%d,\"rf_hz\":%.1f,\"cmds\":%llu,\"errs\":%llu,\"prox\":%d,\"hmd_system\":%d,"
		"\"keepalive_s\":%.1f,\"standby_wakes\":%llu,\"dev\":{",
		EpochSec(), port_, rf_hz_, (unsigned long long)cmds_, (unsigned long long)errs_, prox_ ? 1 : 0, hmd_sys_ ? 1 : 0,
		keepalive_s_, (unsigned long long)standby_wakes_);
	j += b;
	for (int d = 0; d < DEV_COUNT; ++d) {
		const uint32_t idx = d == DEV_HMD ? hmd_->index.load() : ctl_[d - 1]->index.load();
		const PoseState &p = s[d];
		snprintf(b, sizeof(b),
			"%s\"%s\":{\"idx\":%d,\"pos\":[%.5f,%.5f,%.5f],\"rot\":[%.6f,%.6f,%.6f,%.6f],\"vel\":[%.4f,%.4f,%.4f],"
			"\"avel\":[%.4f,%.4f,%.4f],\"conn\":%d,\"valid\":%d",
			d ? "," : "", kDevName[d], idx == kNoIdx ? -1 : (int)idx, p.pos[0], p.pos[1], p.pos[2], p.rot[0], p.rot[1],
			p.rot[2], p.rot[3], p.vel[0], p.vel[1], p.vel[2], p.avel[0], p.avel[1], p.avel[2], p.connected ? 1 : 0,
			p.valid ? 1 : 0);
		j += b;
		if (d != DEV_HMD) {
			const HandInput &in = input_[d - 1];
			const char *const *names = d == DEV_LEFT ? kBoolNameL : kBoolNameR;
			j += ",\"in\":{";
			for (int i = 0; i < FI_COUNT; ++i) {
				snprintf(b, sizeof(b), "%s\"%s\":%.4f", i ? "," : "", kFloatName[i], in.f[i]);
				j += b;
			}
			for (int i = 0; i < BI_COUNT; ++i) {
				if (!names[i] || !ctl_[d - 1]->HasComponent((BoolIn)i))
					continue;
				snprintf(b, sizeof(b), ",\"%s\":%d", names[i], in.b[i] ? 1 : 0);
				j += b;
			}
			j += "}";
		}
		j += "}";
	}
	j += "},\"haptics\":[";
	bool first = true;
	for (const HapticEvent &e : haptics_) {
		snprintf(b, sizeof(b), "%s{\"t\":%.4f,\"hand\":\"%s\",\"dur\":%.5f,\"freq\":%.2f,\"amp\":%.4f}", first ? "" : ",",
			e.t, e.hand ? "right" : "left", e.dur, e.freq, e.amp);
		j += b;
		first = false;
	}
	snprintf(b, sizeof(b), "],\"haptics_total\":%llu,\"haptics_dropped\":%llu}", (unsigned long long)haptics_total_,
		(unsigned long long)haptics_dropped_);
	j += b;
	if (consume_haptics) {
		haptics_.clear();
		haptics_dropped_ = 0;
	}
	return j;
}

} // namespace qd

static qd::Provider g_provider;

extern "C" __declspec(dllexport) void *HmdDriverFactory(const char *iface, int *ret)
{
	if (strcmp(vr::IServerTrackedDeviceProvider_Version, iface) == 0)
		return &g_provider;
	if (ret)
		*ret = vr::VRInitError_Init_InterfaceNotFound;
	return nullptr;
}
