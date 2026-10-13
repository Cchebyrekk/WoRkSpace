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
