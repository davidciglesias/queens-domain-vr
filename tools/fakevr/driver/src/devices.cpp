// qdfake devices: HMD (desktop-window display) + Steam Frame (default) or Quest Touch controllers.
#include "qdfake.h"

#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>

namespace qd {

const char *const kDevName[DEV_COUNT] = { "hmd", "left", "right" };

static const vr::VRInputComponentHandle_t kNoHandle = vr::k_ulInvalidInputComponentHandle;

void Log(const char *fmt, ...)
{
	char buf[1024];
	va_list args;
	va_start(args, fmt);
	vsnprintf(buf, sizeof(buf), fmt, args);
	va_end(args);
	vr::VRDriverLog()->Log(buf);
}

double EpochSec()
{
	using namespace std::chrono;
	return duration_cast<duration<double>>(system_clock::now().time_since_epoch()).count();
}

vr::DriverPose_t MakeDriverPose(const PoseState &s)
{
	vr::DriverPose_t p = {};
	if (s.t > 0.0) { // age of a time-stamped sample; SteamVR extrapolates with vel from then
		const double off = s.t - EpochSec();
		p.poseTimeOffset = off > 0.0 ? 0.0 : (off < -0.25 ? -0.25 : off);
	}
	p.qWorldFromDriverRotation.w = 1.0;
	p.qDriverFromHeadRotation.w = 1.0;
	for (int i = 0; i < 3; ++i) {
		p.vecPosition[i] = s.pos[i];
		p.vecVelocity[i] = s.vel[i];
		p.vecAngularVelocity[i] = s.avel[i];
	}
	p.qRotation.w = s.rot[0];
	p.qRotation.x = s.rot[1];
	p.qRotation.y = s.rot[2];
	p.qRotation.z = s.rot[3];
	p.deviceIsConnected = s.connected;
	p.poseIsValid = s.connected && s.valid;
	p.result = !s.connected ? vr::TrackingResult_Uninitialized
		: (s.valid ? vr::TrackingResult_Running_OK : vr::TrackingResult_Running_OutOfRange);
	p.willDriftInYaw = false;
	p.shouldApplyHeadModel = false; // pose is exactly what the script sent
	return p;
}

static int32_t SettingI(const char *key, int32_t def, bool positive)
{
	vr::EVRSettingsError err = vr::VRSettingsError_None;
	const int32_t v = vr::VRSettings()->GetInt32(kSettings, key, &err);
	if (err != vr::VRSettingsError_None || (positive && v <= 0))
		return def;
	return v;
}

static float SettingF(const char *key, float def)
{
	vr::EVRSettingsError err = vr::VRSettingsError_None;
	const float v = vr::VRSettings()->GetFloat(kSettings, key, &err);
	return (err == vr::VRSettingsError_None && v > 0.f) ? v : def;
}

// ---------------------------------------------------------------- display
void HmdDisplay::GetWindowBounds(int32_t *x, int32_t *y, uint32_t *w, uint32_t *h)
{
	*x = cfg.window_x;
	*y = cfg.window_y;
	*w = cfg.window_w;
	*h = cfg.window_h;
}

void HmdDisplay::GetRecommendedRenderTargetSize(uint32_t *w, uint32_t *h)
{
	*w = cfg.render_w;
	*h = cfg.render_h;
}

void HmdDisplay::GetEyeOutputViewport(vr::EVREye eye, uint32_t *x, uint32_t *y, uint32_t *w, uint32_t *h)
{
	*y = 0;
	*w = cfg.window_w / 2;
	*h = cfg.window_h;
	*x = (eye == vr::Eye_Left) ? 0 : cfg.window_w / 2;
}

void HmdDisplay::GetProjectionRaw(vr::EVREye, float *l, float *r, float *t, float *b)
{
	const float th = tanf(cfg.fov_deg * 0.5f * 3.14159265f / 180.f);
	const float tv = th * (float)cfg.render_h / (float)cfg.render_w;
	*l = -th;
	*r = th;
	*t = -tv; // OpenVR: top is negative
	*b = tv;
}

vr::DistortionCoordinates_t HmdDisplay::ComputeDistortion(vr::EVREye, float u, float v)
{
	vr::DistortionCoordinates_t c{};
	c.rfRed[0] = c.rfGreen[0] = c.rfBlue[0] = u;
	c.rfRed[1] = c.rfGreen[1] = c.rfBlue[1] = v;
	return c;
}

bool HmdDisplay::ComputeInverseDistortion(vr::HmdVector2_t *res, vr::EVREye, uint32_t, float u, float v)
{
	res->v[0] = u; // identity distortion
	res->v[1] = v;
	return true;
}

// ---------------------------------------------------------------- HMD
HmdDevice::HmdDevice(SharedPoses *poses) : poses_(poses)
{
	DisplayConfig &c = display_.cfg;
	c.window_x = SettingI("window_x", 0, false);
	c.window_y = SettingI("window_y", 0, false);
	c.window_w = (uint32_t)SettingI("window_width", 1920, true);
	c.window_h = (uint32_t)SettingI("window_height", 1080, true);
	c.render_w = (uint32_t)SettingI("render_width", 1440, true);
	c.render_h = (uint32_t)SettingI("render_height", 1600, true);
	c.fov_deg = SettingF("fov_deg", 100.f);
	c.freq = SettingF("display_frequency", 90.f);
}

vr::EVRInitError HmdDevice::Activate(uint32_t id)
{
	auto *p = vr::VRProperties();
	const vr::PropertyContainerHandle_t c = p->TrackedDeviceToPropertyContainer(id);
	p->SetStringProperty(c, vr::Prop_ModelNumber_String, "QDFake HMD");
	p->SetStringProperty(c, vr::Prop_ManufacturerName_String, "QDFake");
	p->SetStringProperty(c, vr::Prop_TrackingSystemName_String, "qdfake");
	p->SetStringProperty(c, vr::Prop_DriverVersion_String, "qdfake-1");
	float ipd = vr::VRSettings()->GetFloat(vr::k_pch_SteamVR_Section, vr::k_pch_SteamVR_IPD_Float);
	if (!(ipd > 0.04f && ipd < 0.09f))
		ipd = 0.063f;
	p->SetFloatProperty(c, vr::Prop_UserIpdMeters_Float, ipd);
	p->SetFloatProperty(c, vr::Prop_DisplayFrequency_Float, display_.cfg.freq);
	p->SetFloatProperty(c, vr::Prop_UserHeadToEyeDepthMeters_Float, 0.f);
	p->SetFloatProperty(c, vr::Prop_SecondsFromVsyncToPhotons_Float, 0.011f);
	p->SetBoolProperty(c, vr::Prop_IsOnDesktop_Bool, false); // avoid vrmonitor "not fullscreen" warnings
	p->SetBoolProperty(c, vr::Prop_DisplayDebugMode_Bool, true);
	p->SetBoolProperty(c, vr::Prop_ContainsProximitySensor_Bool, true);
	p->SetStringProperty(c, vr::Prop_InputProfilePath_String, "{qdfake}/input/qdfake_hmd_profile.json");
	vr::VRDriverInput()->CreateBooleanComponent(c, "/input/system/click", &sys_);
	vr::VRDriverInput()->CreateBooleanComponent(c, "/proximity", &prox_);
	SetProximity(true);
	const DisplayConfig &d = display_.cfg;
	Log("HMD activated idx=%u window=%d,%d %ux%u render=%ux%u fov=%.0f hz=%.0f ipd=%.3f", id, d.window_x,
		d.window_y, d.window_w, d.window_h, d.render_w, d.render_h, d.fov_deg, d.freq, ipd);
	index = id;
	return vr::VRInitError_None;
}

void HmdDevice::Deactivate()
{
	index = vr::k_unTrackedDeviceIndexInvalid;
}

void *HmdDevice::GetComponent(const char *name)
{
	if (strcmp(name, vr::IVRDisplayComponent_Version) == 0)
		return static_cast<vr::IVRDisplayComponent *>(&display_);
	return nullptr;
}

vr::DriverPose_t HmdDevice::GetPose()
{
	std::lock_guard<std::mutex> lk(poses_->mtx);
	return MakeDriverPose(poses_->dev[DEV_HMD]);
}

void HmdDevice::SetProximity(bool on)
{
	if (prox_ != kNoHandle)
		vr::VRDriverInput()->UpdateBooleanComponent(prox_, on, 0.0);
}

void HmdDevice::SetSystem(bool on)
{
	if (sys_ != kNoHandle)
		vr::VRDriverInput()->UpdateBooleanComponent(sys_, on, 0.0);
}

// ---------------------------------------------------------------- controllers
ControllerDevice::ControllerDevice(bool is_left, SharedPoses *poses)
	: left(is_left), poses_(poses)
{
	serial_ = left ? "QDFAKE_Controller_Left" : "QDFAKE_Controller_Right";
	for (auto &h : hb_)
		h = kNoHandle;
	for (auto &h : hf_)
		h = kNoHandle;
}

vr::EVRInitError ControllerDevice::Activate(uint32_t id)
{
	auto *p = vr::VRProperties();
	auto *in = vr::VRDriverInput();
	const vr::PropertyContainerHandle_t c = p->TrackedDeviceToPropertyContainer(id);
	{
		char mode[32] = {};
		vr::EVRSettingsError err = vr::VRSettingsError_None;
		vr::VRSettings()->GetString(kSettings, "controller", mode, sizeof(mode), &err);
		frame = !(err == vr::VRSettingsError_None && strcmp(mode, "touch") == 0);
	}
	if (frame)
		return ActivateFrame(id, c);
	// Look like a Quest 2 Touch controller so SteamVR picks oculus_touch bindings.
	p->SetStringProperty(c, vr::Prop_TrackingSystemName_String, "oculus");
	p->SetStringProperty(c, vr::Prop_ManufacturerName_String, "Oculus");
	p->SetStringProperty(c, vr::Prop_ModelNumber_String,
		left ? "Oculus Quest2 (Left Controller)" : "Oculus Quest2 (Right Controller)");
	p->SetStringProperty(c, vr::Prop_RenderModelName_String,
		left ? "oculus_quest2_controller_left" : "oculus_quest2_controller_right");
	p->SetStringProperty(c, vr::Prop_RegisteredDeviceType_String,
		left ? "oculus/QDFAKE_Controller_Left" : "oculus/QDFAKE_Controller_Right");
	p->SetStringProperty(c, vr::Prop_ControllerType_String, "oculus_touch");
	p->SetStringProperty(c, vr::Prop_InputProfilePath_String, "{oculus}/input/touch_profile.json");
	p->SetInt32Property(c, vr::Prop_ControllerRoleHint_Int32,
		left ? vr::TrackedControllerRole_LeftHand : vr::TrackedControllerRole_RightHand);
	p->SetStringProperty(c, vr::Prop_DriverVersion_String, "qdfake-1");
	p->SetBoolProperty(c, vr::Prop_DeviceIsWireless_Bool, true);
	p->SetBoolProperty(c, vr::Prop_DeviceProvidesBatteryStatus_Bool, true);
	p->SetFloatProperty(c, vr::Prop_DeviceBatteryPercentage_Float, 1.f);
	p->SetBoolProperty(c, vr::Prop_DeviceIsCharging_Bool, false);
	// Legacy (IVRSystem::GetControllerState) layout, same as touch_profile simulation_settings.
	const uint64_t buttons = vr::ButtonMaskFromId(vr::k_EButton_System) |
		vr::ButtonMaskFromId(vr::k_EButton_ApplicationMenu) | vr::ButtonMaskFromId(vr::k_EButton_Grip) |
		vr::ButtonMaskFromId(vr::k_EButton_A) | vr::ButtonMaskFromId(vr::k_EButton_Axis0) |
		vr::ButtonMaskFromId(vr::k_EButton_Axis1) | vr::ButtonMaskFromId(vr::k_EButton_Axis2);
	p->SetUint64Property(c, vr::Prop_SupportedButtons_Uint64, buttons);
	p->SetInt32Property(c, vr::Prop_Axis0Type_Int32, vr::k_eControllerAxis_Joystick);
	p->SetInt32Property(c, vr::Prop_Axis1Type_Int32, vr::k_eControllerAxis_Trigger);
	p->SetInt32Property(c, vr::Prop_Axis2Type_Int32, vr::k_eControllerAxis_Trigger);

	// Components = everything {oculus}/input/touch_profile.json declares (minus skeleton).
	const auto one = vr::VRScalarUnits_NormalizedOneSided, two = vr::VRScalarUnits_NormalizedTwoSided;
	in->CreateScalarComponent(c, "/input/trigger/value", &hf_[FI_TRIGGER], vr::VRScalarType_Absolute, one);
	in->CreateBooleanComponent(c, "/input/trigger/touch", &hb_[BI_TRIG_TOUCH]);
	in->CreateScalarComponent(c, "/input/grip/value", &hf_[FI_GRIP], vr::VRScalarType_Absolute, one);
	in->CreateBooleanComponent(c, "/input/grip/touch", &hb_[BI_GRIP_TOUCH]);
	in->CreateScalarComponent(c, "/input/joystick/x", &hf_[FI_JOY_X], vr::VRScalarType_Absolute, two);
	in->CreateScalarComponent(c, "/input/joystick/y", &hf_[FI_JOY_Y], vr::VRScalarType_Absolute, two);
	in->CreateBooleanComponent(c, "/input/joystick/click", &hb_[BI_JOY_CLICK]);
	in->CreateBooleanComponent(c, "/input/joystick/touch", &hb_[BI_JOY_TOUCH]);
	in->CreateBooleanComponent(c, left ? "/input/x/click" : "/input/a/click", &hb_[BI_F1_CLICK]);
	in->CreateBooleanComponent(c, left ? "/input/x/touch" : "/input/a/touch", &hb_[BI_F1_TOUCH]);
	in->CreateBooleanComponent(c, left ? "/input/y/click" : "/input/b/click", &hb_[BI_F2_CLICK]);
	in->CreateBooleanComponent(c, left ? "/input/y/touch" : "/input/b/touch", &hb_[BI_F2_TOUCH]);
	if (left) { // touch_profile: /input/system is left-hand only (menu button)
		in->CreateBooleanComponent(c, "/input/system/click", &hb_[BI_SYS_CLICK]);
		in->CreateBooleanComponent(c, "/input/system/touch", &hb_[BI_SYS_TOUCH]);
	}
	in->CreateBooleanComponent(c, "/input/thumbrest/touch", &hb_[BI_THUMBREST_TOUCH]);
	in->CreateHapticComponent(c, "/output/haptic", &haptic_);
	sent_valid_ = false;
	Log("%s controller activated (touch) idx=%u serial=%s", left ? "left" : "right", id, serial_.c_str());
	index = id;
	return vr::VRInitError_None;
}

// Steam Frame controller: same properties/profile the real one gets through vrlink (vrlink log 2026-11-11),
// components = everything {frame_controller}/input/frame_controller_profile.json declares (minus skeleton).
// SteamVR then remaps apps without a frame_controller binding (UEVR) from oculus_touch, like the real device.
vr::EVRInitError ControllerDevice::ActivateFrame(uint32_t id, vr::PropertyContainerHandle_t c)
{
	auto *p = vr::VRProperties();
	auto *in = vr::VRDriverInput();
	p->SetStringProperty(c, vr::Prop_TrackingSystemName_String, "frame_controller");
	p->SetStringProperty(c, vr::Prop_ManufacturerName_String, "Valve");
	p->SetStringProperty(c, vr::Prop_ModelNumber_String,
		left ? "QDFake Frame Controller (Left)" : "QDFake Frame Controller (Right)");
	p->SetStringProperty(c, vr::Prop_RenderModelName_String,
		left ? "{frame_controller}frame_controller_left" : "{frame_controller}frame_controller_right");
	p->SetStringProperty(c, vr::Prop_ResourceRoot_String, "frame_controller");
	p->SetStringProperty(c, vr::Prop_RegisteredDeviceType_String,
		left ? "frame_controller/QDFAKE_Controller_Left" : "frame_controller/QDFAKE_Controller_Right");
	p->SetStringProperty(c, vr::Prop_ControllerType_String, "frame_controller");
	p->SetStringProperty(c, vr::Prop_InputProfilePath_String, "{frame_controller}/input/frame_controller_profile.json");
	p->SetInt32Property(c, vr::Prop_ControllerRoleHint_Int32,
		left ? vr::TrackedControllerRole_LeftHand : vr::TrackedControllerRole_RightHand);
	p->SetStringProperty(c, vr::Prop_DriverVersion_String, "qdfake-1");
	p->SetBoolProperty(c, vr::Prop_DeviceIsWireless_Bool, true);
	p->SetBoolProperty(c, vr::Prop_DeviceProvidesBatteryStatus_Bool, true);
	p->SetFloatProperty(c, vr::Prop_DeviceBatteryPercentage_Float, 1.f);
	p->SetBoolProperty(c, vr::Prop_DeviceIsCharging_Bool, false);

	const auto one = vr::VRScalarUnits_NormalizedOneSided, two = vr::VRScalarUnits_NormalizedTwoSided;
	in->CreateScalarComponent(c, "/input/trigger/value", &hf_[FI_TRIGGER], vr::VRScalarType_Absolute, one);
	in->CreateBooleanComponent(c, "/input/trigger/click", &hb_[BI_TRIG_CLICK]);
	in->CreateBooleanComponent(c, "/input/trigger/touch", &hb_[BI_TRIG_TOUCH]);
	in->CreateScalarComponent(c, "/input/grip/value", &hf_[FI_GRIP], vr::VRScalarType_Absolute, one);
	in->CreateBooleanComponent(c, "/input/grip/click", &hb_[BI_GRIP_CLICK]);
	in->CreateBooleanComponent(c, "/input/grip/touch", &hb_[BI_GRIP_TOUCH]);
	in->CreateScalarComponent(c, "/input/thumbstick/x", &hf_[FI_JOY_X], vr::VRScalarType_Absolute, two);
	in->CreateScalarComponent(c, "/input/thumbstick/y", &hf_[FI_JOY_Y], vr::VRScalarType_Absolute, two);
	in->CreateBooleanComponent(c, "/input/thumbstick/click", &hb_[BI_JOY_CLICK]);
	in->CreateBooleanComponent(c, "/input/thumbstick/touch", &hb_[BI_JOY_TOUCH]);
	in->CreateBooleanComponent(c, "/input/bumper/click", &hb_[BI_BUMPER_CLICK]);
	in->CreateBooleanComponent(c, "/input/bumper/touch", &hb_[BI_BUMPER_TOUCH]);
	in->CreateBooleanComponent(c, "/input/system/click", &hb_[BI_SYS_CLICK]);
	in->CreateBooleanComponent(c, "/input/system/touch", &hb_[BI_SYS_TOUCH]);
	in->CreateBooleanComponent(c, "/input/thumbrest/touch", &hb_[BI_THUMBREST_TOUCH]);
	static const char *const kFaceR[4] = { "/input/a", "/input/b", "/input/x", "/input/y" };
	static const char *const kFaceL[4] = { "/input/dpad_down", "/input/dpad_right", "/input/dpad_left", "/input/dpad_up" };
	static const BoolIn kFaceBi[4][2] = { { BI_F1_CLICK, BI_F1_TOUCH }, { BI_F2_CLICK, BI_F2_TOUCH },
		{ BI_F3_CLICK, BI_F3_TOUCH }, { BI_F4_CLICK, BI_F4_TOUCH } };
	char path[64];
	for (int i = 0; i < 4; ++i) {
		const char *base = left ? kFaceL[i] : kFaceR[i];
		snprintf(path, sizeof(path), "%s/click", base);
		in->CreateBooleanComponent(c, path, &hb_[kFaceBi[i][0]]);
		snprintf(path, sizeof(path), "%s/touch", base);
		in->CreateBooleanComponent(c, path, &hb_[kFaceBi[i][1]]);
	}
	in->CreateBooleanComponent(c, left ? "/input/view/click" : "/input/menu/click", &hb_[BI_MENU_CLICK]);
	in->CreateBooleanComponent(c, left ? "/input/view/touch" : "/input/menu/touch", &hb_[BI_MENU_TOUCH]);
	in->CreateHapticComponent(c, "/output/haptic", &haptic_);
	sent_valid_ = false;
	Log("%s controller activated (frame) idx=%u serial=%s", left ? "left" : "right", id, serial_.c_str());
	index = id;
	return vr::VRInitError_None;
}

void ControllerDevice::Deactivate()
{
	index = vr::k_unTrackedDeviceIndexInvalid;
}

vr::DriverPose_t ControllerDevice::GetPose()
{
	std::lock_guard<std::mutex> lk(poses_->mtx);
	return MakeDriverPose(poses_->dev[left ? DEV_LEFT : DEV_RIGHT]);
}

bool ControllerDevice::OwnsHaptic(vr::VRInputComponentHandle_t h) const
{
	return haptic_ != kNoHandle && h == haptic_;
}

void ControllerDevice::PushInput(const HandInput &in, bool force)
{
	if (index == vr::k_unTrackedDeviceIndexInvalid)
		return;
	force = force || !sent_valid_;
	// Analog click (Frame trigger/grip): on at >= 0.9, off below 0.8 (guess; the real click point is unknown).
	HandInput s = in;
	const bool tc = sent_valid_ && sent_.b[BI_TRIG_CLICK], gc = sent_valid_ && sent_.b[BI_GRIP_CLICK];
	s.b[BI_TRIG_CLICK] = in.f[FI_TRIGGER] >= (tc ? 0.8f : 0.9f);
	s.b[BI_GRIP_CLICK] = in.f[FI_GRIP] >= (gc ? 0.8f : 0.9f);
	auto *di = vr::VRDriverInput();
	for (int i = 0; i < BI_COUNT; ++i)
		if (hb_[i] != kNoHandle && (force || s.b[i] != sent_.b[i]))
			di->UpdateBooleanComponent(hb_[i], s.b[i], 0.0);
	for (int i = 0; i < FI_COUNT; ++i)
		if (hf_[i] != kNoHandle && (force || s.f[i] != sent_.f[i]))
			di->UpdateScalarComponent(hf_[i], s.f[i], 0.0);
	sent_ = s;
	sent_valid_ = true;
}

} // namespace qd
