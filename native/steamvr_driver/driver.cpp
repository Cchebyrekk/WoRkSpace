// The WoRkPlace SteamVR driver (slice q1): PC VR games in the Quest over the own
// link instead of Quest Link. SteamVR loads it into vrserver.exe; it adds one
// headset whose poses come from the game host (src/game_host.gd, which holds the
// headset's control channel) through the GameLink mapping (game_link.h). Direct
// mode: SteamVR renders into textures of this driver and submits each frame as
// layers with the head pose they were drawn with; FrameCompositor draws them
// into one foveated picture (both eyes side by side), which goes to the headset
// through the eyes' stream of branch pc-render (video_stream.cpp: HEVC, each
// frame tagged with the id of the pose it was drawn with; the headset's
// player.gd turns the picture to where the head is by then). The first try used
// a virtual display, which gives no pose with a frame: tagged by a guess, the
// picture shook in the headset (04.11.2026). No Godot here.

#include "frame_compositor.h"
#include "game_link.h"
#include "win_backend.h"

#include <windows.h>

#include <openvr_driver.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

namespace {

// The picture sent per eye: the Quest 3S's own eye size, foveated as branch
// pc-render sends it (FOVEATION is Foveation.STRENGTH: the middle gets 1.8 times
// the pixels of an even picture). The game draws larger, RENDER_SCALE (SteamVR
// scales that again by its own resolution setting): the first try drew the sent
// size, evenly, and looked soft (04.11.2026).
constexpr uint32_t EYE_WIDTH = 1832;
constexpr uint32_t EYE_HEIGHT = 1920;
constexpr float FOVEATION = 0.55f;
constexpr float RENDER_SCALE = 1.4f;
constexpr float REFRESH_HZ = 72.0f;
// LinkProtocol.REMOTE_EYES_PORT: the headset's player takes the eyes from here.
constexpr int EYES_PORT = 47903;
// 60 Mbit/s at first, as branch pc-render: soft in motion. At 120 the headset's
// decoder fell behind (44 pictures a second shown of 72, 04.11.2026).
constexpr int EYES_KBPS = 90000;
// Until the headset tells its own: about the Quest 3S's field of view.
constexpr float DEFAULT_TAN = 1.0f;
constexpr float DEFAULT_IPD = 0.063f;

// %LOCALAPPDATA%\WoRkPlace\steamvr_driver.log, written through at once, and
// SteamVR's own log (vrserver.txt).
void log(const char *format, ...) {
	static std::mutex mutex;
	static FILE *file = nullptr;
	char text[1024];
	va_list args;
	va_start(args, format);
	std::vsnprintf(text, sizeof(text), format, args);
	va_end(args);
	std::lock_guard<std::mutex> lock(mutex);
	if (vr::VRDriverLog()) {
		vr::VRDriverLog()->Log(text);
	}
	if (!file) {
		char path[MAX_PATH];
		DWORD length = GetEnvironmentVariableA("LOCALAPPDATA", path, MAX_PATH);
		if (length == 0 || length >= MAX_PATH) {
			return;
		}
		std::string name = std::string(path) + "\\WoRkPlace\\steamvr_driver.log";
		file = std::fopen(name.c_str(), "a");
		if (!file) {
			return;
		}
	}
	SYSTEMTIME now;
	GetLocalTime(&now);
	std::fprintf(file, "%02d.%02d %02d:%02d:%02d.%03d %s\n", now.wDay, now.wMonth, now.wHour, now.wMinute, now.wSecond,
			now.wMilliseconds, text);
	std::fflush(file);
}

// A consistent copy of the host's half of the link (its seqlock).
bool read_link(workplace::GameLink *link, workplace::GameLink &out) {
	for (int attempt = 0; attempt < 8; attempt++) {
		uint32_t before = link->sequence.load(std::memory_order_acquire);
		if (before & 1) {
			std::this_thread::yield();
			continue;
		}
		out.headset = link->headset;
		out.pose_id = link->pose_id;
		out.head_ok = link->head_ok;
		out.written_us = link->written_us;
		out.head = link->head;
		std::memcpy(out.eyes, link->eyes, sizeof(out.eyes));
		std::memcpy(out.fov, link->fov, sizeof(out.fov));
		std::memcpy(out.controllers, link->controllers, sizeof(out.controllers));
		std::memcpy(out.hand_ok,link->hand_ok,sizeof(out.hand_ok));
		std::memcpy(out.wrist,link->wrist,sizeof(out.wrist));
		std::memcpy(out.bones,link->bones,sizeof(out.bones));
		std::atomic_thread_fence(std::memory_order_acquire);
		if (link->sequence.load(std::memory_order_relaxed) == before) {
			return true;
		}
	}
	return false;
}

vr::HmdQuaternion_t quaternion(const float q[4]) {
	return { q[3], q[0], q[1], q[2] };
}

vr::HmdMatrix34_t matrix(const workplace::GameTransform &t) {
	float x = t.rotation[0], y = t.rotation[1], z = t.rotation[2], w = t.rotation[3];
	vr::HmdMatrix34_t m{};
	m.m[0][0] = 1 - 2 * (y * y + z * z);
	m.m[0][1] = 2 * (x * y - z * w);
	m.m[0][2] = 2 * (x * z + y * w);
	m.m[1][0] = 2 * (x * y + z * w);
	m.m[1][1] = 1 - 2 * (x * x + z * z);
	m.m[1][2] = 2 * (y * z - x * w);
	m.m[2][0] = 2 * (x * z - y * w);
	m.m[2][1] = 2 * (y * z + x * w);
	m.m[2][2] = 1 - 2 * (x * x + y * y);
	m.m[0][3] = t.position[0];
	m.m[1][3] = t.position[1];
	m.m[2][3] = t.position[2];
	return m;
}

class Headset : public vr::ITrackedDeviceServerDriver,
				public vr::IVRDisplayComponent,
				public vr::IVRDriverDirectModeComponent {
	workplace::GameLink *link = nullptr;
	uint32_t id = vr::k_unTrackedDeviceIndexInvalid;
	std::atomic<bool> running{ false };
	std::thread pose_thread;
	std::thread vsync_thread;
	HANDLE pose_event = nullptr;

	std::mutex view_mutex; // the projection and the eyes, set from the pose thread
	float tangents[2][4] = { { -DEFAULT_TAN, DEFAULT_TAN, -DEFAULT_TAN, DEFAULT_TAN },
		{ -DEFAULT_TAN, DEFAULT_TAN, -DEFAULT_TAN, DEFAULT_TAN } };
	workplace::GameTransform eyes[2] = { { { 0, 0, 0, 1 }, { -DEFAULT_IPD / 2, 0, 0 } },
		{ { 0, 0, 0, 1 }, { DEFAULT_IPD / 2, 0, 0 } } };

	// Poses given to SteamVR, newest last: a frame's layers carry the head pose
	// it was drawn with, looked up here for the headset's pose id.
	struct Given {
		uint32_t id;
		vr::HmdMatrix34_t head;
		uint64_t written_us; // when the host wrote it (clock_us)
	};
	std::mutex given_mutex;
	std::deque<Given> given;
	uint64_t matched = 0;
	uint64_t unmatched = 0;
	float worst_error = 0.0f;
	std::chrono::steady_clock::time_point next_match_log = std::chrono::steady_clock::now();

	FrameCompositor compositor;
	bool compositor_ok = false;

	std::mutex stream_mutex;
	workplace::StreamBackend *stream = nullptr;
	std::thread stream_starter;
	std::atomic<bool> stream_starting{ false };
	std::atomic<bool> stream_up{ false };
	uint32_t presented = 0;
	// The frame's projection (its first layer's) and the time from the host
	// writing a pose to the frame drawn with it presented, for report().
	vr::HmdMatrix44_t frame_projection[2]{};
	double pose_to_present_ms = 0.0;
	uint64_t pose_to_present_count = 0;
	// The stream's counters at the last report (every 10 s, the driver's log).
	workplace::StreamStats reported;
	uint32_t reported_presented = 0;
	std::chrono::steady_clock::time_point next_report = std::chrono::steady_clock::now();

public:
	explicit Headset(workplace::GameLink *p_link) : link(p_link) { load_fov(); }

	vr::EVRInitError Activate(uint32_t p_id) override {
		id = p_id;
		vr::PropertyContainerHandle_t props = vr::VRProperties()->TrackedDeviceToPropertyContainer(id);
		vr::VRProperties()->SetStringProperty(props, vr::Prop_ModelNumber_String, "WoRkPlace Quest");
		vr::VRProperties()->SetStringProperty(props, vr::Prop_ManufacturerName_String, "WoRkPlace");
		vr::VRProperties()->SetStringProperty(props, vr::Prop_TrackingSystemName_String, "workplace");
		vr::VRProperties()->SetFloatProperty(props, vr::Prop_UserIpdMeters_Float, DEFAULT_IPD);
		vr::VRProperties()->SetFloatProperty(props, vr::Prop_UserHeadToEyeDepthMeters_Float, 0.0f);
		vr::VRProperties()->SetFloatProperty(props, vr::Prop_DisplayFrequency_Float, REFRESH_HZ);
		vr::VRProperties()->SetFloatProperty(props, vr::Prop_SecondsFromVsyncToPhotons_Float, 0.0f);
		vr::VRProperties()->SetBoolProperty(props, vr::Prop_IsOnDesktop_Bool, false);
		vr::VRProperties()->SetBoolProperty(props, vr::Prop_HasDisplayComponent_Bool, true);
		vr::VRProperties()->SetBoolProperty(props, vr::Prop_HasVirtualDisplayComponent_Bool, false);
		vr::VRProperties()->SetBoolProperty(props, vr::Prop_HasDriverDirectModeComponent_Bool, true);
		vr::VRProperties()->SetBoolProperty(props, vr::Prop_DriverDirectModeSendsVsyncEvents_Bool, true);
		vr::VRProperties()->SetBoolProperty(props, vr::Prop_HasCameraComponent_Bool, false);
		std::string error;
		compositor_ok = compositor.open(EYE_WIDTH, EYE_HEIGHT, FOVEATION, error);
		if (compositor_ok) {
			vr::VRProperties()->SetUint64Property(props, vr::Prop_GraphicsAdapterLuid_Uint64, compositor.adapter_luid());
		} else {
			log("compositing did not start: %s", error.c_str());
		}
		pose_event = CreateEventW(nullptr, FALSE, FALSE, workplace::GAME_LINK_EVENT);
		running = true;
		pose_thread = std::thread([this] { follow_poses(); });
		vsync_thread = std::thread([this] { send_vsyncs(); });
		log("headset activated as device %u (direct mode)", id);
		return vr::VRInitError_None;
	}

	void Deactivate() override {
		running = false;
		if (pose_thread.joinable()) {
			pose_thread.join();
		}
		if (vsync_thread.joinable()) {
			vsync_thread.join();
		}
		if (stream_starter.joinable()) {
			stream_starter.join();
		}
		std::lock_guard<std::mutex> lock(stream_mutex);
		if (stream) {
			stream->stop();
			delete stream;
			stream = nullptr;
		}
		stream_up = false;
		link->eyes_port = 0;
		if (pose_event) {
			CloseHandle(pose_event);
			pose_event = nullptr;
		}
		id = vr::k_unTrackedDeviceIndexInvalid;
		log("headset deactivated");
	}

	void EnterStandby() override {}

	void *GetComponent(const char *name) override {
		if (std::strcmp(name, vr::IVRDisplayComponent_Version) == 0) {
			return static_cast<vr::IVRDisplayComponent *>(this);
		}
		if (std::strcmp(name, vr::IVRDriverDirectModeComponent_Version) == 0) {
			return static_cast<vr::IVRDriverDirectModeComponent *>(this);
		}
		return nullptr;
	}

	void DebugRequest(const char *, char *response, uint32_t size) override {
		if (size > 0) {
			response[0] = 0;
		}
	}

	vr::DriverPose_t GetPose() override { return pose_from(nullptr); }

	// IVRDisplayComponent: no lens distortion (the headset's runtime does its own).
	void GetWindowBounds(int32_t *x, int32_t *y, uint32_t *width, uint32_t *height) override {
		*x = 0;
		*y = 0;
		*width = EYE_WIDTH * 2;
		*height = EYE_HEIGHT;
	}

	bool IsDisplayOnDesktop() override { return false; }
	bool IsDisplayRealDisplay() override { return false; }

	void GetRecommendedRenderTargetSize(uint32_t *width, uint32_t *height) override {
		*width = static_cast<uint32_t>(EYE_WIDTH * RENDER_SCALE);
		*height = static_cast<uint32_t>(EYE_HEIGHT * RENDER_SCALE);
	}

	void GetEyeOutputViewport(vr::EVREye eye, uint32_t *x, uint32_t *y, uint32_t *width, uint32_t *height) override {
		*x = eye == vr::Eye_Left ? 0 : EYE_WIDTH;
		*y = 0;
		*width = EYE_WIDTH;
		*height = EYE_HEIGHT;
	}

	// OpenVR's top is up negative: its y runs down.
	void GetProjectionRaw(vr::EVREye eye, float *left, float *right, float *top, float *bottom) override {
		std::lock_guard<std::mutex> lock(view_mutex);
		const float *t = tangents[eye == vr::Eye_Left ? 0 : 1];
		*left = t[0];
		*right = t[1];
		*top = -t[3];
		*bottom = -t[2];
	}

	vr::DistortionCoordinates_t ComputeDistortion(vr::EVREye, float u, float v) override {
		vr::DistortionCoordinates_t result{};
		result.rfRed[0] = result.rfGreen[0] = result.rfBlue[0] = u;
		result.rfRed[1] = result.rfGreen[1] = result.rfBlue[1] = v;
		return result;
	}

	bool ComputeInverseDistortion(vr::HmdVector2_t *result, vr::EVREye, uint32_t, float u, float v) override {
		result->v[0] = u;
		result->v[1] = v;
		return true;
	}

	// IVRDriverDirectModeComponent: SteamVR renders into textures made here and
	// submits the frame as layers; Present draws them into the sent picture.
	void CreateSwapTextureSet(uint32_t pid, const SwapTextureSetDesc_t *desc, SwapTextureSet_t *out) override {
		compositor.create_set(pid, *desc, *out);
		log("swap textures for process %u: %ux%u, format %u", pid, desc->nWidth, desc->nHeight, desc->nFormat);
	}

	void DestroySwapTextureSet(vr::SharedTextureHandle_t handle) override { compositor.destroy_set(handle); }
	void DestroyAllSwapTextureSets(uint32_t pid) override { compositor.destroy_all(pid); }

	void GetNextSwapTextureSetIndex(vr::SharedTextureHandle_t handles[2], uint32_t (*indices)[2]) override {
		compositor.next_indices(handles, indices);
	}

	void SubmitLayer(const SubmitLayerPerEye_t (&layer)[2]) override { compositor.add_layer(layer); }

	void Present(vr::SharedTextureHandle_t sync) override {
		// The field of view the headset turns the picture by (its own, per eye).
		float target[2][4];
		{
			std::lock_guard<std::mutex> lock(view_mutex);
			for (int e = 0; e < 2; e++) {
				target[e][0] = tangents[e][0];
				target[e][1] = tangents[e][1];
				target[e][2] = -tangents[e][3];
				target[e][3] = -tangents[e][2];
			}
		}
		vr::HmdMatrix34_t head{};
		if (!compositor_ok || !compositor.compose(sync, target, head, frame_projection)) {
			return;
		}
		if (!stream_up) {
			start_stream();
			return;
		}
		uint64_t written_us = 0;
		uint32_t pose_id = pose_of(head, written_us);
		if (written_us != 0) {
			pose_to_present_ms += (workplace::StreamBackend::clock_us() - written_us) / 1000.0;
			pose_to_present_count++;
		}
		std::lock_guard<std::mutex> lock(stream_mutex);
		if (stream) {
			stream->shared_submit(compositor.output_handle(), pose_id);
			link->frames_presented = ++presented;
			report();
		}
	}

	void PostPresent(const Throttling_t *) override {}

	void GetFrameTiming(vr::DriverDirectMode_FrameTiming *timing) override { timing->m_nReprojectionFlags = 0; }

	// Where frames go missing: drawn by SteamVR, taken by the stream, encoded, sent.
	void report() {
		auto now = std::chrono::steady_clock::now();
		if (now < next_report) {
			return;
		}
		next_report = now + std::chrono::seconds(10);
		workplace::StreamStats stats = stream->stats();
		uint64_t encoded = stats.frames_encoded - reported.frames_encoded;
		log("10 s: presented %u, taken %llu, encoded %llu, sent %llu, %.1f Mbit/s, encoding %.1f ms on average%s%s",
				presented - reported_presented, stats.frames_captured - reported.frames_captured, encoded,
				stats.frames_sent - reported.frames_sent, (stats.bytes_sent - reported.bytes_sent) * 8.0 / 10e6,
				encoded > 0 ? (stats.encode_ms_sum - reported.encode_ms_sum) / encoded : 0.0,
				stats.client.empty() ? ", no headset" : "", stats.error.empty() ? "" : (", error: " + stats.error).c_str());
		reported = stats;
		reported_presented = presented;
		// Tangents left, right, top, bottom from the projection (OpenVR's, y down)
		// against those given to SteamVR: if they differ, the headset turns the
		// picture by a wrong field of view.
		float given_fov[2][4];
		{
			std::lock_guard<std::mutex> lock(view_mutex);
			std::memcpy(given_fov, tangents, sizeof(given_fov));
		}
		for (int e = 0; e < 2; e++) {
			const auto &m = frame_projection[e].m;
			log("  eye %d drawn with: l %.3f r %.3f t %.3f b %.3f (m00 %.3f m02 %.3f m11 %.3f m12 %.3f); given l %.3f r %.3f t %.3f b %.3f",
					e, (m[0][2] - 1) / m[0][0], (m[0][2] + 1) / m[0][0], (m[1][2] - 1) / m[1][1], (m[1][2] + 1) / m[1][1],
					m[0][0], m[0][2], m[1][1], m[1][2], given_fov[e][0], given_fov[e][1], -given_fov[e][3], -given_fov[e][2]);
		}
		log("  pose written to frame presented: %.1f ms on average", pose_to_present_count ? pose_to_present_ms / pose_to_present_count : 0.0);
		pose_to_present_ms = 0.0;
		pose_to_present_count = 0;
	}

	void run_frame() {
		link->driver_beat_us = workplace::StreamBackend::clock_us();
	}

private:
	vr::DriverPose_t pose_from(const workplace::GameLink *state) {
		vr::DriverPose_t pose{};
		pose.qWorldFromDriverRotation = { 1, 0, 0, 0 };
		pose.qDriverFromHeadRotation = { 1, 0, 0, 0 };
		pose.qRotation = { 1, 0, 0, 0 };
		pose.deviceIsConnected = true;
		pose.result = vr::TrackingResult_Running_OutOfRange;
		if (state && state->headset && state->head_ok) {
			pose.qRotation = quaternion(state->head.rotation);
			for (int i = 0; i < 3; i++) {
				pose.vecPosition[i] = state->head.position[i];
			}
			pose.poseIsValid = true;
			pose.result = vr::TrackingResult_Running_OK;
		}
		return pose;
	}

	// The host's poses into SteamVR, as they come.
	void follow_poses() {
		uint32_t last_sequence = 0;
		bool had_headset = false;
		while (running) {
			WaitForSingleObject(pose_event, 5);
			uint32_t sequence = link->sequence.load();
			if (sequence == last_sequence) {
				continue;
			}
			workplace::GameLink state{};
			if (!read_link(link, state)) {
				continue;
			}
			last_sequence = sequence;
			if ((state.headset != 0) != had_headset) {
				had_headset = state.headset != 0;
				log(had_headset ? "the headset came" : "the headset left");
			}
			if (state.headset) {
				update_view(state);
			}
			vr::DriverPose_t pose = pose_from(&state);
			{
				std::lock_guard<std::mutex> lock(given_mutex);
				given.push_back({ state.pose_id, matrix(state.head), state.written_us });
				if (given.size() > 256) {
					given.pop_front();
				}
			}
			vr::VRServerDriverHost()->TrackedDevicePoseUpdated(id, pose, sizeof(pose));
		}
	}

	// A steady display at REFRESH_HZ: SteamVR paces its frames by these.
	void send_vsyncs() {
		auto period = std::chrono::duration_cast<std::chrono::steady_clock::duration>(
				std::chrono::duration<double>(1.0 / REFRESH_HZ));
		auto next = std::chrono::steady_clock::now();
		while (running) {
			next += period;
			std::this_thread::sleep_until(next);
			vr::VRServerDriverHost()->VsyncEvent(0.0);
		}
	}

	// The headset's id of the pose a frame was drawn with: the given pose nearest
	// the frame's (SteamVR passes ours on as it is: the velocities are zero, so
	// its prediction adds nothing).
	uint32_t pose_of(const vr::HmdMatrix34_t &head, uint64_t &written_us) {
		std::lock_guard<std::mutex> lock(given_mutex);
		float best = 1e9f;
		uint32_t found = 0;
		for (auto it = given.rbegin(); it != given.rend(); ++it) {
			float error = 0.0f;
			for (int r = 0; r < 3; r++) {
				for (int c = 0; c < 4; c++) {
					error += std::fabs(it->head.m[r][c] - head.m[r][c]);
				}
			}
			if (error < best) {
				best = error;
				found = it->id;
				written_us = it->written_us;
			}
		}
		if (best < 0.001f) {
			matched++;
		} else {
			unmatched++;
			worst_error = std::max(worst_error, best);
		}
		auto now = std::chrono::steady_clock::now();
		if (now >= next_match_log) {
			next_match_log = now + std::chrono::seconds(10);
			log("frames matched to poses: %llu exactly, %llu not (worst error %.4f)", matched, unmatched, worst_error);
			matched = unmatched = 0;
			worst_error = 0.0f;
		}
		return found;
	}

	// The headset's own eyes and field of view, when they change.
	void update_view(const workplace::GameLink &state) {
		bool fov_changed = false;
		bool eyes_changed = false;
		{
			std::lock_guard<std::mutex> lock(view_mutex);
			for (int e = 0; e < 2; e++) {
				for (int i = 0; i < 4; i++) {
					if (std::fabs(state.fov[e][i] - tangents[e][i]) > 0.001f) {
						fov_changed = true;
					}
				}
			}
			// Only the distance between the eyes: their poses relative to the head jitter
			// a little frame to frame (the head and the views are read at different
			// moments), and SteamVR redid its eyes every frame (04.11.2026).
			float ipd = state.eyes[1].position[0] - state.eyes[0].position[0];
			eyes_changed = ipd > 0.04f && ipd < 0.09f && std::fabs(ipd - (eyes[1].position[0] - eyes[0].position[0])) > 0.001f;
			if (fov_changed) {
				std::memcpy(tangents, state.fov, sizeof(tangents));
			}
			if (eyes_changed) {
				eyes[0] = { { 0, 0, 0, 1 }, { -ipd / 2, 0, 0 } };
				eyes[1] = { { 0, 0, 0, 1 }, { ipd / 2, 0, 0 } };
			}
		}
		if (fov_changed) {
			vr::HmdRect2_t rect[2];
			for (int e = 0; e < 2; e++) {
				rect[e].vTopLeft = { { state.fov[e][0], -state.fov[e][3] } };
				rect[e].vBottomRight = { { state.fov[e][1], -state.fov[e][2] } };
			}
			vr::VRServerDriverHost()->SetDisplayProjectionRaw(id, rect[0], rect[1]);
			save_fov(state.fov);
			log("field of view: left eye %.3f %.3f %.3f %.3f, right %.3f %.3f %.3f %.3f", state.fov[0][0], state.fov[0][1],
					state.fov[0][2], state.fov[0][3], state.fov[1][0], state.fov[1][1], state.fov[1][2], state.fov[1][3]);
		}
		if (eyes_changed) {
			workplace::GameTransform left, right;
			{
				std::lock_guard<std::mutex> lock(view_mutex);
				left = eyes[0];
				right = eyes[1];
			}
			vr::VRServerDriverHost()->SetDisplayEyeToHead(id, matrix(left), matrix(right));
			float ipd = right.position[0] - left.position[0];
			vr::VRProperties()->SetFloatProperty(vr::VRProperties()->TrackedDeviceToPropertyContainer(id),
					vr::Prop_UserIpdMeters_Float, ipd);
			log("eyes: ipd %.1f mm", ipd * 1000.0f);
		}
	}

	// The headset's last field of view, kept between runs: SteamVR draws with
	// what GetProjectionRaw says at the start and did not follow a change later.
	static std::string fov_path() {
		char path[MAX_PATH];
		DWORD length = GetEnvironmentVariableA("LOCALAPPDATA", path, MAX_PATH);
		return length == 0 || length >= MAX_PATH ? std::string() : std::string(path) + "\\WoRkPlace\\steamvr_fov.txt";
	}

	void load_fov() {
		std::string path = fov_path();
		FILE *file = path.empty() ? nullptr : std::fopen(path.c_str(), "r");
		if (!file) {
			return;
		}
		float read[2][4];
		bool ok = true;
		for (int e = 0; e < 2; e++) {
			for (int i = 0; i < 4; i++) {
				ok = ok && std::fscanf(file, "%f", &read[e][i]) == 1 && std::fabs(read[e][i]) < 5.0f;
			}
		}
		std::fclose(file);
		if (ok) {
			std::memcpy(tangents, read, sizeof(tangents));
			log("field of view of the last run: left eye %.3f %.3f %.3f %.3f", read[0][0], read[0][1], read[0][2], read[0][3]);
		}
	}

	static void save_fov(const float (&fov)[2][4]) {
		std::string path = fov_path();
		FILE *file = path.empty() ? nullptr : std::fopen(path.c_str(), "w");
		if (!file) {
			return;
		}
		for (int e = 0; e < 2; e++) {
			std::fprintf(file, "%.4f %.4f %.4f %.4f\n", fov[e][0], fov[e][1], fov[e][2], fov[e][3]);
		}
		std::fclose(file);
	}

	// The stream starts with the first composed frame, on its own thread: Present
	// must not wait.
	void start_stream() {
		if (stream_starting.exchange(true)) {
			return;
		}
		stream_starter = std::thread([this] {
			workplace::StreamBackend *created = workplace::StreamBackend::create();
			std::string error;
			if (!created->start_shared(compositor.adapter_luid(), compositor.output_handle(), EYES_PORT, EYES_KBPS,
						static_cast<int32_t>(REFRESH_HZ), error)) {
				log("eyes' stream did not start: %s", error.c_str());
				delete created;
				return; // stays "starting": no retry every frame
			}
			workplace::StreamStats stats = created->stats();
			{
				std::lock_guard<std::mutex> lock(stream_mutex);
				stream = created;
			}
			link->eyes_width = static_cast<uint32_t>(stats.width);
			link->eyes_height = static_cast<uint32_t>(stats.height);
			link->eyes_port = EYES_PORT;
			stream_up = true;
			log("eyes' stream: %dx%d HEVC %d kbit/s on port %d, foveation %.2f", stats.width, stats.height, EYES_KBPS,
					EYES_PORT, FOVEATION);
		});
	}
};

// q2a: physical controller poses first; buttons and haptics follow separately.
class Controller : public vr::ITrackedDeviceServerDriver {
	int hand;
	uint32_t id = vr::k_unTrackedDeviceIndexInvalid;
	vr::DriverPose_t pose{};
	vr::VRInputComponentHandle_t clicks[7]{}, touches[7]{}, scalars[4]{}, haptic=0;
	vr::VRInputComponentHandle_t skeleton=0;
public:
	explicit Controller(int p_hand) : hand(p_hand) {}
	vr::EVRInitError Activate(uint32_t object) override {
		id = object;
		auto properties = vr::VRProperties()->TrackedDeviceToPropertyContainer(id);
		vr::VRProperties()->SetStringProperty(properties, vr::Prop_TrackingSystemName_String, "workplace");
		vr::VRProperties()->SetStringProperty(properties, vr::Prop_ModelNumber_String, "WoRkPlace Touch");
		vr::VRProperties()->SetStringProperty(properties, vr::Prop_RenderModelName_String, "{workplace}controller_box");
		vr::VRProperties()->SetStringProperty(properties, vr::Prop_ControllerType_String, "oculus_touch");
		vr::VRProperties()->SetStringProperty(properties, vr::Prop_InputProfilePath_String, "{oculus}/input/touch_profile.json");
		const char *names[] = {hand == 0 ? "x" : "a", hand == 0 ? "y" : "b", "system", "joystick", "trigger", "grip", "thumbrest"};
		for(int i=0;i<7;i++) {
			std::string base=std::string("/input/")+names[i];
			if(i<6) vr::VRDriverInput()->CreateBooleanComponent(properties,(base+"/click").c_str(),&clicks[i]);
			if(i!=2 && i!=5) vr::VRDriverInput()->CreateBooleanComponent(properties,(base+"/touch").c_str(),&touches[i]);
		}
		const char *paths[]={"/input/trigger/value","/input/grip/value","/input/joystick/x","/input/joystick/y"};
		for(int i=0;i<4;i++) vr::VRDriverInput()->CreateScalarComponent(properties,paths[i],&scalars[i],vr::VRScalarType_Absolute,
				i<2 ? vr::VRScalarUnits_NormalizedOneSided : vr::VRScalarUnits_NormalizedTwoSided);
		vr::VRDriverInput()->CreateHapticComponent(properties,"/output/haptic",&haptic);
		auto result=vr::VRDriverInput()->CreateSkeletonComponent(properties,hand==0?"/input/skeleton/left":"/input/skeleton/right",
				hand==0?"/skeleton/hand/left":"/skeleton/hand/right","/pose/raw",vr::VRSkeletalTracking_Full,nullptr,0,&skeleton);
		log("hand skeleton %d: creation result %d",hand,int(result));
		vr::VRProperties()->SetInt32Property(properties, vr::Prop_ControllerRoleHint_Int32,
				hand == 0 ? vr::TrackedControllerRole_LeftHand : vr::TrackedControllerRole_RightHand);
		log("controller %s activated as %u (pose only)", hand == 0 ? "left" : "right", id);
		return vr::VRInitError_None;
	}
	void Deactivate() override { id = vr::k_unTrackedDeviceIndexInvalid; }
	void EnterStandby() override {}
	void *GetComponent(const char *) override { return nullptr; }
	void DebugRequest(const char *, char *response, uint32_t size) override { if(size) response[0] = 0; }
	vr::DriverPose_t GetPose() override { return pose; }
	void update(const workplace::GameLink &state) {
		if (id == vr::k_unTrackedDeviceIndexInvalid) return;
		auto controller = state.controllers[hand];
		bool optical=state.hand_ok[hand] && !controller.ok;
		if(optical) {controller.ok=1;controller.grip=state.wrist[hand];}
		pose = {};
		pose.qWorldFromDriverRotation = {1,0,0,0};
		pose.qDriverFromHeadRotation = {1,0,0,0};
		pose.qRotation = {1,0,0,0};
		pose.deviceIsConnected = state.headset != 0;
		pose.poseIsValid = state.headset && controller.ok &&
				workplace::StreamBackend::clock_us() - state.written_us < 500000;
		pose.result = pose.poseIsValid ? vr::TrackingResult_Running_OK : vr::TrackingResult_Running_OutOfRange;
		if (pose.poseIsValid) {
			pose.qRotation = quaternion(controller.grip.rotation);
			for(int i=0;i<3;i++) pose.vecPosition[i] = controller.grip.position[i];
		}
		vr::VRServerDriverHost()->TrackedDevicePoseUpdated(id, pose, sizeof(pose));
		if(optical && pose.poseIsValid && skeleton) {
			vr::VRBoneTransform_t bones[31]{};
			for(int i=0;i<31;i++) {
				const auto &b=state.bones[hand][i];
				bones[i].orientation={b.rotation[3],b.rotation[0],b.rotation[1],b.rotation[2]};
				for(int axis=0;axis<3;axis++)bones[i].position.v[axis]=b.position[axis];
				bones[i].position.v[3]=1;
			}
			vr::VRDriverInput()->UpdateSkeletonComponent(skeleton,vr::VRSkeletalMotionRange_WithoutController,bones,31);
			vr::VRDriverInput()->UpdateSkeletonComponent(skeleton,vr::VRSkeletalMotionRange_WithController,bones,31);
		}
		for(int i=0;i<7;i++) {
			bool click=(controller.buttons & (1u<<i)) != 0;
			if(i==4) click = click || controller.trigger>0.75f;
			if(i==5) click = click || controller.grip_value>0.75f;
			if(clicks[i]) vr::VRDriverInput()->UpdateBooleanComponent(clicks[i],pose.poseIsValid && click,0);
			if(touches[i]) vr::VRDriverInput()->UpdateBooleanComponent(touches[i],pose.poseIsValid && (controller.touches & (1u<<i)),0);
		}
		float values[]={controller.trigger,controller.grip_value,controller.stick[0],controller.stick[1]};
		for(int i=0;i<4;i++) if(scalars[i]) vr::VRDriverInput()->UpdateScalarComponent(scalars[i],pose.poseIsValid ? values[i] : 0,0);
	}
	void pulse(const vr::VREvent_t &event, workplace::GameLink *link) {
		if(event.eventType!=vr::VREvent_Input_HapticVibration || event.data.hapticVibration.componentHandle!=haptic) return;
		const auto &p=event.data.hapticVibration;
		uint64_t ms=std::clamp(int(p.fDurationSeconds*1000),1,5000);
		uint64_t amplitude=std::clamp(int(p.fAmplitude*1000),0,1000);
		uint64_t frequency=std::clamp(int(p.fFrequency),0,1000);
		link->haptics[hand].store(ms | (amplitude<<16) | (frequency<<26));
	}
};

class Provider : public vr::IServerTrackedDeviceProvider {
	workplace::GameLink *link = nullptr;
	Headset *headset = nullptr;
	Controller *controllers[2]{};

public:
	vr::EVRInitError Init(vr::IVRDriverContext *context) override {
		VR_INIT_SERVER_DRIVER_CONTEXT(context);
		std::string error;
		link = workplace::game_link_open(error);
		if (!link) {
			log("no game link: %s", error.c_str());
			return vr::VRInitError_Driver_Failed;
		}
		link->driver_beat_us = workplace::StreamBackend::clock_us();
		headset = new Headset(link);
		if (!vr::VRServerDriverHost()->TrackedDeviceAdded("WRKP-QUEST", vr::TrackedDeviceClass_HMD, headset)) {
			log("SteamVR did not take the headset");
			return vr::VRInitError_Driver_Failed;
		}
		for (int hand=0;hand<2;hand++) {
			controllers[hand] = new Controller(hand);
			vr::VRServerDriverHost()->TrackedDeviceAdded(hand == 0 ? "WRKP-TOUCH-L" : "WRKP-TOUCH-R",
					vr::TrackedDeviceClass_Controller, controllers[hand]);
		}
		log("driver started");
		return vr::VRInitError_None;
	}

	void Cleanup() override {
		log("driver stopping");
		// SteamVR deactivates the headset before this.
		delete headset;
		for (auto &controller : controllers) { delete controller; controller = nullptr; }
		headset = nullptr;
		if (link) {
			link->driver_beat_us = 0;
			link->eyes_port = 0;
		}
		workplace::game_link_close();
		link = nullptr;
		VR_CLEANUP_SERVER_DRIVER_CONTEXT();
	}

	const char *const *GetInterfaceVersions() override { return vr::k_InterfaceVersions; }

	void RunFrame() override {
		workplace::GameLink state{};
		if (link && read_link(link, state)) {
			for(auto *controller : controllers) if(controller) controller->update(state);
		}
		if (headset) {
			headset->run_frame();
		}
		vr::VREvent_t event;
		while (vr::VRServerDriverHost()->PollNextEvent(&event, sizeof(event))) {
			for(auto *controller:controllers) if(controller) controller->pulse(event,link);
		}
	}

	bool ShouldBlockStandbyMode() override { return false; }
	void EnterStandby() override {}
	void LeaveStandby() override {}
};

Provider provider;

} // namespace

extern "C" __declspec(dllexport) void *HmdDriverFactory(const char *interface_name, int *return_code) {
	if (std::strcmp(interface_name, vr::IServerTrackedDeviceProvider_Version) == 0) {
		return &provider;
	}
	if (return_code) {
		*return_code = vr::VRInitError_Init_InterfaceNotFound;
	}
	return nullptr;
}
