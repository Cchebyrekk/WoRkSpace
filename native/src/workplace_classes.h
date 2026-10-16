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

// Moves the real Windows cursor and presses its buttons. Static methods only.
class MouseInput : public Object {
	GDCLASS(MouseInput, Object)

protected:
	static void _bind_methods();

public:
	enum Button {
		BUTTON_LEFT = 0,
		BUTTON_RIGHT = 1,
		BUTTON_MIDDLE = 2,
	};

	// Pixel on the virtual desktop, the same space as ScreenCapture.list_monitors() positions.
	static void move_to(const Vector2i &p_position);
	static void set_button(Button p_button, bool p_pressed);
	// 120 is one wheel notch; positive scrolls up.
	static void scroll(int p_delta);
	// 120 is one notch; positive scrolls right.
	static void scroll_horizontal(int p_delta);
	// Windows virtual-key codes pressed in order and released in reverse, e.g. [0x11, 0x5A] for Ctrl+Z.
	static void press_keys(const PackedInt32Array &p_virtual_keys);
	static void set_key(int p_virtual_key, bool p_pressed);
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

VARIANT_ENUM_CAST(godot::MouseInput::Button);
