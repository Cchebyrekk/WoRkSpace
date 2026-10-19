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
bool read_secure_frame(uint32_t &last_sequence, int32_t &width, int32_t &height, int32_t &origin_x, int32_t &origin_y,
		std::vector<uint8_t> &out);

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
