#pragma once
// Windows-side implementation behind the Godot classes. This header is free of
// both Godot and Windows headers so the two never meet in one translation unit.

#include <cstdint>
#include <string>
#include <vector>

namespace workplace {

struct MonitorInfo {
	void *handle = nullptr; // HMONITOR
	std::string device_name; // \\.\DISPLAYnn, changes when the display driver restarts
	std::string device_path; // \\?\DISPLAY#MTT1337#..., the monitor itself: stays the same
	int32_t x = 0;
	int32_t y = 0;
	int32_t width = 0;
	int32_t height = 0;
	bool primary = false;
};

std::vector<MonitorInfo> enumerate_monitors();

// Captures one monitor with Windows.Graphics.Capture. Frames stay on the GPU:
// they are copied into a D3D11 texture that is shared with the caller's D3D12 device.
class CaptureBackend {
public:
	static CaptureBackend *create();
	virtual ~CaptureBackend() = default;

	// `d3d12_device` is an ID3D12Device*. On failure returns false and fills `error`.
	virtual bool start(void *monitor_handle, void *d3d12_device, std::string &error) = 0;
	virtual void stop() = 0;

	// ID3D12Resource* of the shared texture; owned by the backend, valid until stop().
	virtual void *d3d12_resource() const = 0;
	virtual int32_t width() const = 0;
	virtual int32_t height() const = 0;
	virtual uint64_t frame_count() const = 0;
};

// What a running stream has done so far (StreamBackend::stats).
struct StreamStats {
	uint64_t frames_captured = 0;
	uint64_t frames_encoded = 0;
	uint64_t frames_sent = 0;
	uint64_t bytes_sent = 0;
	double encode_ms = 0.0; // the last frame, from input to output of the encoder
	double encode_ms_sum = 0.0; // all frames so far (an average over a time: its change / frames_encoded's)
	int32_t width = 0;
	int32_t height = 0;
	std::string encoder; // the hardware encoder's name
	std::string client; // "ip:port" of the connected headset, empty if none
	std::string error; // what stopped the stream thread, empty while it runs
};

// Streams one monitor to the headset (slice o3): Windows.Graphics.Capture frames
// are turned into NV12 on the GPU, encoded by the hardware H.264 encoder (Media
// Foundation) and sent to one TCP client. Everything runs on its own thread.
// Wire format, all integers big-endian: on connect "WRKV", version, width, height,
// fps (u32 each); then per frame u32 length, u64 sample time in microseconds
// (since the stream started, unique per frame), u64 capture time of its picture
// (clock_us; a picture encoded again keeps it, 0 for one captured before the
// client came; slice o7: the headset measures the latency from it), only in the
// eyes' stream (version 3, branch pc-render) u32 pose id — the headset's pose
// they were drawn with, u8 flags (1 = key frame) and the Annex B H.264 bytes. No more than `fps` new pictures a second are encoded. The headset
// sends messages of 9 bytes, u8 type and u64 (slice o7): 1 — its clock; the
// answer comes in the frame stream as length 0, u64 that clock, u64 clock_us now,
// flags 2, and the headset sets its clock by the PC's to about a millisecond;
// 2 — frames received so far: once these come, no more than a few frames are on
// the way at a time (a slow network then gets fewer frames, not a growing queue).
class StreamBackend {
public:
	// The clock of the capture times: microseconds of QueryPerformanceCounter.
	static uint64_t clock_us();
	static StreamBackend *create();
	virtual ~StreamBackend() = default;

	// Returns once the capture, the encoder and the listening socket are up.
	virtual bool start(void *monitor_handle, int32_t port, int32_t bitrate_kbps, int32_t fps, std::string &error) = 0;
	// Branch pc-render: streams pictures Godot draws (both eyes side by side)
	// instead of a monitor. Two shared textures, opened on Godot's D3D12 device
	// (external_texture: ID3D12Resource, R8G8B8A8, width x height): Godot copies a
	// picture into one, then external_submit signals Godot's queue, and the stream
	// encodes it once the GPU is done.
	// The picture is width x height; it is encoded scaled to out_width x out_height
	// (drawn larger and scaled down, text stays sharper).
	virtual bool start_external(void *d3d12_device, void *d3d12_queue, int32_t width, int32_t height, int32_t out_width,
			int32_t out_height, int32_t port, int32_t bitrate_kbps, int32_t fps, std::string &error) = 0;
	virtual void *external_texture(int32_t slot) const = 0;
	virtual void external_submit(int32_t slot, uint32_t pose_id) = 0;
	virtual void stop() = 0;
	virtual bool running() const = 0;
	virtual StreamStats stats() const = 0;
	// A small CPU copy of the current picture (slice o5c: thumbnails for the
	// headset), `width` pixels wide with the monitor's shape. Asked for here, made
	// on the stream's thread, taken with take_snapshot (RGBA8, false if none yet).
	virtual void request_snapshot(int32_t width) = 0;
	virtual bool take_snapshot(std::vector<uint8_t> &rgba, int32_t &width, int32_t &height) = 0;
};

// Mouse input injected into Windows with SendInput. Coordinates are pixels of the
// virtual desktop (the same space as MonitorInfo::x / y).
void mouse_move(int32_t x, int32_t y);
// Where the cursor is, in real pixels of the virtual desktop.
void mouse_position(int32_t &x, int32_t &y);
void mouse_button(int32_t button, bool down); // 0 left, 1 right, 2 middle
void mouse_wheel(int32_t delta); // 120 is one notch, positive scrolls up
void mouse_hwheel(int32_t delta); // 120 is one notch, positive scrolls right
// Presses the Windows virtual keys in order, then releases them in reverse (a shortcut such as Ctrl+Shift+Z).
void press_keys(const std::vector<uint16_t> &virtual_keys);
void key_event(uint16_t virtual_key, bool down);
// Whether input goes through workplace_agent.exe (tries to connect at most every 2 s).
bool agent_connected();
// Whether the agent reports the secure desktop up (UAC, lock screen, Ctrl+Alt+Del).
// Polls the agent's status messages; false without an agent. Call each frame.
bool secure_desktop_active();

// Copies the agent's latest secure-desktop frame (RGBA, the picture of the secure
// desktop) into `out`, with its size and the captured monitor's virtual-desktop
// origin. False if there is no agent, no frame yet, or nothing new since
// `last_sequence` (which it updates). `out` is a plain byte buffer to avoid Godot
// types here.
bool read_secure_frame(uint32_t &last_sequence, int32_t &width, int32_t &height, int32_t &origin_x, int32_t &origin_y, int32_t &scale,
		std::vector<uint8_t> &out);

// Records one keyboard shortcut from the physical keyboard (a low-level hook, so
// the Godot window need not have focus; keys are swallowed while it records).
bool key_recording_start();
void key_recording_stop();
// True once a shortcut was pressed: `keys` gets the modifiers held (Ctrl, Alt,
// Shift, Win) and then the key, as Windows virtual keys.
bool key_recording_result(std::vector<uint16_t> &keys);
// How many keyboard events the recording hook has seen (for the log).
int key_recording_seen();
// Records text typed on the physical keyboard (slice n2: names of places), in the
// layout of the focused window; keys are swallowed meanwhile, as above. Enter
// ends it, Esc cancels, Backspace takes the last character away.
// key_recording_stop() stops it too.
bool text_recording_start();
// The text so far, and how it ended: 0 still typing, 1 Enter, 2 Esc.
int text_recording_result(std::wstring &text);

// Stops what the module runs in the background (keyboard recording, the agent
// connection); called when the module is unloaded.
void shutdown_backend();

// System-wide hotkey that fires even when the Godot window is not focused.
class HotkeyBackend {
public:
	static HotkeyBackend *create();
	virtual ~HotkeyBackend() = default;

	virtual bool start(bool ctrl, bool alt, bool shift, uint32_t virtual_key) = 0;
	virtual void stop() = 0;
	// True once per press.
	virtual bool consume_pressed() = 0;
};

} // namespace workplace
