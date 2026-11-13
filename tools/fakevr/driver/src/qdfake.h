// qdfake: fake HMD + two Oculus-Touch-style controllers for SteamVR whose
// poses and inputs are scripted over UDP (127.0.0.1:27115). Test harness only.
// Based on the OpenVR v2.5.1 samples (simplehmd + simplecontroller).
#pragma once
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <openvr_driver.h>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace qd {

void Log(const char *fmt, ...);
double EpochSec();

inline constexpr const char *kSettings = "driver_qdfake";

enum Dev { DEV_HMD = 0, DEV_LEFT = 1, DEV_RIGHT = 2, DEV_COUNT = 3 };
extern const char *const kDevName[DEV_COUNT];

struct PoseState {
	double pos[3];
	double rot[4]; // w x y z
	double vel[3];
	double avel[3];
	double t; // wall-clock time the sample belongs to (0 = "now"); sets poseTimeOffset
	bool connected;
	bool valid;
};

// Controller inputs. F1 = a (right) / x (left), F2 = b (right) / y (left).
// Frame mode only: F3/F4 = right x/y, left dpad_left/dpad_up (left F1/F2 = dpad_down/dpad_right);
// MENU = right menu / left view; trigger/grip click are derived from the value in PushInput.
enum BoolIn {
	BI_TRIG_TOUCH, BI_GRIP_TOUCH, BI_JOY_CLICK, BI_JOY_TOUCH, BI_F1_CLICK, BI_F1_TOUCH,
	BI_F2_CLICK, BI_F2_TOUCH, BI_SYS_CLICK, BI_SYS_TOUCH, BI_THUMBREST_TOUCH,
	BI_TRIG_CLICK, BI_GRIP_CLICK, BI_BUMPER_CLICK, BI_BUMPER_TOUCH, BI_MENU_CLICK, BI_MENU_TOUCH,
	BI_F3_CLICK, BI_F3_TOUCH, BI_F4_CLICK, BI_F4_TOUCH, BI_COUNT
};
enum FloatIn { FI_TRIGGER, FI_GRIP, FI_JOY_X, FI_JOY_Y, FI_COUNT };

struct HandInput {
	bool b[BI_COUNT];
	float f[FI_COUNT];
};

struct HapticEvent {
	double t;
	int hand; // 0 left, 1 right
	float dur, freq, amp;
};

// Pose state shared between the RunFrame thread (writer) and the pose thread (reader).
struct SharedPoses {
	std::mutex mtx;
	PoseState dev[DEV_COUNT];
};

vr::DriverPose_t MakeDriverPose(const PoseState &s);

struct DisplayConfig {
	int32_t window_x, window_y;
	uint32_t window_w, window_h, render_w, render_h;
	float fov_deg, freq;
};

class HmdDisplay : public vr::IVRDisplayComponent {
public:
	DisplayConfig cfg{};
	void GetWindowBounds(int32_t *x, int32_t *y, uint32_t *w, uint32_t *h) override;
	bool IsDisplayOnDesktop() override { return true; }
	bool IsDisplayRealDisplay() override { return false; }
	void GetRecommendedRenderTargetSize(uint32_t *w, uint32_t *h) override;
	void GetEyeOutputViewport(vr::EVREye eye, uint32_t *x, uint32_t *y, uint32_t *w, uint32_t *h) override;
	void GetProjectionRaw(vr::EVREye eye, float *l, float *r, float *t, float *b) override;
	vr::DistortionCoordinates_t ComputeDistortion(vr::EVREye eye, float u, float v) override;
	bool ComputeInverseDistortion(vr::HmdVector2_t *res, vr::EVREye eye, uint32_t ch, float u, float v) override;
};

class HmdDevice : public vr::ITrackedDeviceServerDriver {
public:
	explicit HmdDevice(SharedPoses *poses);
	vr::EVRInitError Activate(uint32_t id) override;
	void Deactivate() override;
	void EnterStandby() override {}
	void *GetComponent(const char *name) override;
	void DebugRequest(const char *, char *buf, uint32_t n) override { if (n) buf[0] = 0; }
	vr::DriverPose_t GetPose() override;
	void SetProximity(bool on);
	void SetSystem(bool on);
	const char *Serial() const { return "QDFAKE-HMD-0001"; }
	std::atomic<uint32_t> index{ vr::k_unTrackedDeviceIndexInvalid };

private:
	SharedPoses *poses_;
	HmdDisplay display_;
	vr::VRInputComponentHandle_t sys_ = vr::k_ulInvalidInputComponentHandle;
	vr::VRInputComponentHandle_t prox_ = vr::k_ulInvalidInputComponentHandle;
};

class ControllerDevice : public vr::ITrackedDeviceServerDriver {
public:
	ControllerDevice(bool left, SharedPoses *poses);
	vr::EVRInitError Activate(uint32_t id) override;
	void Deactivate() override;
	void EnterStandby() override { standby_hint = true; } // provider re-sends inputs = activity
	std::atomic<bool> standby_hint{ false };
	void *GetComponent(const char *) override { return nullptr; }
	void DebugRequest(const char *, char *buf, uint32_t n) override { if (n) buf[0] = 0; }
	vr::DriverPose_t GetPose() override;
	// Sends components whose value differs from what was last sent (or all if force).
	void PushInput(const HandInput &in, bool force);
	bool OwnsHaptic(vr::VRInputComponentHandle_t h) const;
	bool HasComponent(BoolIn b) const { return hb_[b] != vr::k_ulInvalidInputComponentHandle; }
	const std::string &Serial() const { return serial_; }
	std::atomic<uint32_t> index{ vr::k_unTrackedDeviceIndexInvalid };
	const bool left;
	bool frame = true; // Steam Frame controller (setting "controller" = "frame", default) or Quest Touch ("touch")

private:
	vr::EVRInitError ActivateFrame(uint32_t id, vr::PropertyContainerHandle_t c);
	SharedPoses *poses_;
	std::string serial_;
	vr::VRInputComponentHandle_t hb_[BI_COUNT];
	vr::VRInputComponentHandle_t hf_[FI_COUNT];
	vr::VRInputComponentHandle_t haptic_ = vr::k_ulInvalidInputComponentHandle;
	HandInput sent_{};
	bool sent_valid_ = false;
};

class Provider : public vr::IServerTrackedDeviceProvider {
public:
	vr::EVRInitError Init(vr::IVRDriverContext *ctx) override;
	void Cleanup() override;
	const char *const *GetInterfaceVersions() override { return vr::k_InterfaceVersions; }
	void RunFrame() override;
	bool ShouldBlockStandbyMode() override { return false; }
	void EnterStandby() override {}
	void LeaveStandby() override {}

private:
	void PoseThread();
	void WakePoseThread();
	void ResetState();
	void PollUdp();
	void HandleDatagram(char *data, int len, const sockaddr_in &from);
	bool Exec(char *line, std::string &reply, bool &pose_dirty, double &stamp);
	std::string BuildJson(bool consume_haptics);
	void OnHaptic(int hand, const vr::VREvent_HapticVibration_t &h);

	SharedPoses poses_;
	HandInput input_[2]{};
	bool prox_ = true, hmd_sys_ = false;
	std::unique_ptr<HmdDevice> hmd_;
	std::unique_ptr<ControllerDevice> ctl_[2];

	SOCKET sock_ = INVALID_SOCKET;
	bool wsa_ok_ = false;
	int port_ = 27115;
	std::vector<char> rxbuf_;

	std::thread pose_thread_;
	std::atomic<bool> running_{ false };
	std::mutex wake_mtx_;
	std::condition_variable wake_cv_;
	bool wake_ = false;

	std::deque<HapticEvent> haptics_;
	uint64_t haptics_total_ = 0, haptics_dropped_ = 0;

	uint64_t cmds_ = 0, errs_ = 0, rf_count_ = 0, standby_wakes_ = 0;
	double rf_t0_ = 0, rf_hz_ = 0;
	// Idle controllers enter standby after SteamVR's power timeout (5 min) and lose their
	// hand role; re-sending the (unchanged) inputs every keepalive_s_ counts as activity.
	double keepalive_s_ = 30.0, last_keepalive_ = 0;
	int log_budget_ = 40;
	int cmd_log_budget_ = 300; // non-pose commands echoed to vrserver.txt
};

} // namespace qd
