#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace workplace {
class CaptureBackend;
class HotkeyBackend;
} // namespace workplace

namespace godot {

// Live picture of one Windows monitor as a GPU texture (no CPU copies).
// Requires the D3D12 rendering driver.
class ScreenCapture : public RefCounted {
	GDCLASS(ScreenCapture, RefCounted)

	workplace::CaptureBackend *backend = nullptr;
	// The shared D3D11 texture as Godot sees it. Godot's D3D12 driver cannot make
	// a Texture2DRD out of an external resource, so every new frame is copied on
	// the GPU into `texture_rid`, which Godot owns.
	RID source_rid;
	RID texture_rid;
	Ref<Texture2DRD> texture;
	int64_t copied_frame = -1;
	String last_error;

protected:
	static void _bind_methods();

public:
	~ScreenCapture();

	// Each entry: name (String), position (Vector2i), size (Vector2i), primary (bool).
	static TypedArray<Dictionary> list_monitors();

	// Index into list_monitors(). On failure returns false; see get_last_error().
	bool start(int p_monitor_index);
	void stop();
	bool is_running() const;
	// Call once per rendered frame: brings the texture up to date if a new frame arrived.
	void update();

	Ref<Texture2DRD> get_texture() const;
	Vector2i get_size() const;
	// Grows with every captured frame; the desktop only produces frames when it changes.
	int64_t get_frame_count() const;
	String get_last_error() const;
};

// System-wide keyboard shortcut that works while another window has focus.
class GlobalHotkey : public RefCounted {
	GDCLASS(GlobalHotkey, RefCounted)

	workplace::HotkeyBackend *backend = nullptr;

protected:
	static void _bind_methods();

public:
	~GlobalHotkey();

	// `p_virtual_key` is a Windows virtual-key code (F12 is 0x7B). False if the combination is taken.
	bool start(bool p_ctrl, bool p_alt, bool p_shift, int p_virtual_key);
	void stop();
	// True once per press; poll it every frame.
	bool consume_pressed();
};

} // namespace godot
