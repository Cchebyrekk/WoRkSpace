#include "workplace_classes.h"

#include "win_backend.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <vector>

namespace godot {

void ScreenCapture::_bind_methods() {
	ClassDB::bind_static_method("ScreenCapture", D_METHOD("list_monitors"), &ScreenCapture::list_monitors);
	ClassDB::bind_method(D_METHOD("start", "monitor_index"), &ScreenCapture::start);
	ClassDB::bind_method(D_METHOD("stop"), &ScreenCapture::stop);
	ClassDB::bind_method(D_METHOD("is_running"), &ScreenCapture::is_running);
	ClassDB::bind_method(D_METHOD("update"), &ScreenCapture::update);
	ClassDB::bind_method(D_METHOD("get_texture"), &ScreenCapture::get_texture);
	ClassDB::bind_method(D_METHOD("get_size"), &ScreenCapture::get_size);
	ClassDB::bind_method(D_METHOD("get_frame_count"), &ScreenCapture::get_frame_count);
	ClassDB::bind_method(D_METHOD("get_last_error"), &ScreenCapture::get_last_error);
}

ScreenCapture::~ScreenCapture() {
	stop();
}

TypedArray<Dictionary> ScreenCapture::list_monitors() {
	TypedArray<Dictionary> result;
	for (const workplace::MonitorInfo &monitor : workplace::enumerate_monitors()) {
		Dictionary entry;
		entry["name"] = String::utf8(monitor.device_name.c_str());
		entry["position"] = Vector2i(monitor.x, monitor.y);
		entry["size"] = Vector2i(monitor.width, monitor.height);
		entry["primary"] = monitor.primary;
		entry["path"] = String::utf8(monitor.device_path.c_str());
		result.push_back(entry);
	}
	return result;
}

bool ScreenCapture::start(int p_monitor_index) {
	stop();
	last_error = String();

	std::vector<workplace::MonitorInfo> monitors = workplace::enumerate_monitors();
	if (p_monitor_index < 0 || p_monitor_index >= static_cast<int>(monitors.size())) {
		last_error = "monitor index out of range";
		return false;
	}
	RenderingServer *rendering_server = RenderingServer::get_singleton();
	RenderingDevice *rendering_device = rendering_server->get_rendering_device();
	// The shared texture is opened on Godot's own device, which only works for D3D12.
	if (rendering_device == nullptr || rendering_server->get_current_rendering_driver_name() != String("d3d12")) {
		last_error = "the D3D12 rendering driver is required";
		return false;
	}
	uint64_t d3d12_device = rendering_device->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_LOGICAL_DEVICE, RID(), 0);
	if (d3d12_device == 0) {
		last_error = "could not get the D3D12 device from the RenderingDevice";
		return false;
	}

	backend = workplace::CaptureBackend::create();
	std::string error;
	if (!backend->start(monitors[p_monitor_index].handle, reinterpret_cast<void *>(d3d12_device), error)) {
		last_error = String::utf8(error.c_str());
		delete backend;
		backend = nullptr;
		return false;
	}

	source_rid = rendering_device->texture_create_from_extension(
			RenderingDevice::TEXTURE_TYPE_2D, RenderingDevice::DATA_FORMAT_B8G8R8A8_UNORM, RenderingDevice::TEXTURE_SAMPLES_1,
			RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT,
			reinterpret_cast<uint64_t>(backend->d3d12_resource()), backend->width(), backend->height(), 1, 1);
	if (!source_rid.is_valid()) {
		last_error = "texture_create_from_extension failed";
		stop();
		return false;
	}

	Ref<RDTextureFormat> format;
	format.instantiate();
	format->set_format(RenderingDevice::DATA_FORMAT_B8G8R8A8_UNORM);
	format->set_width(backend->width());
	format->set_height(backend->height());
	format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT);
	// Texture2DRD makes an sRGB view of the texture next to the linear one.
	format->add_shareable_format(RenderingDevice::DATA_FORMAT_B8G8R8A8_UNORM);
	format->add_shareable_format(RenderingDevice::DATA_FORMAT_B8G8R8A8_SRGB);
	Ref<RDTextureView> view;
	view.instantiate();
	texture_rid = rendering_device->texture_create(format, view);
	if (!texture_rid.is_valid()) {
		last_error = "texture_create failed";
		stop();
		return false;
	}
	texture.instantiate();
	texture->set_texture_rd_rid(texture_rid);
	copied_frame = -1;
	return true;
}

void ScreenCapture::update() {
	if (backend == nullptr || !source_rid.is_valid() || !texture_rid.is_valid()) {
		return;
	}
	int64_t frame = static_cast<int64_t>(backend->frame_count());
	if (frame == copied_frame) {
		return;
	}
	RenderingDevice *rendering_device = RenderingServer::get_singleton()->get_rendering_device();
	rendering_device->texture_copy(source_rid, texture_rid, Vector3(), Vector3(),
			Vector3(backend->width(), backend->height(), 1), 0, 0, 0, 0);
	copied_frame = frame;
}

void ScreenCapture::stop() {
	// The Godot texture goes first: it refers to the resource the backend owns.
	if (texture.is_valid()) {
		texture->set_texture_rd_rid(RID());
		texture.unref();
	}
	if (texture_rid.is_valid() || source_rid.is_valid()) {
		// At engine shutdown the server can already be gone; the device frees its textures itself then.
		RenderingServer *rendering_server = RenderingServer::get_singleton();
		RenderingDevice *rendering_device = rendering_server != nullptr ? rendering_server->get_rendering_device() : nullptr;
		if (rendering_device != nullptr) {
			if (texture_rid.is_valid()) {
				rendering_device->free_rid(texture_rid);
			}
			if (source_rid.is_valid()) {
				rendering_device->free_rid(source_rid);
			}
		}
		texture_rid = RID();
		source_rid = RID();
	}
	if (backend != nullptr) {
		backend->stop();
		delete backend;
		backend = nullptr;
	}
}

bool ScreenCapture::is_running() const {
	return backend != nullptr;
}

Ref<Texture2DRD> ScreenCapture::get_texture() const {
	return texture;
}

Vector2i ScreenCapture::get_size() const {
	return backend != nullptr ? Vector2i(backend->width(), backend->height()) : Vector2i();
}

int64_t ScreenCapture::get_frame_count() const {
	return backend != nullptr ? static_cast<int64_t>(backend->frame_count()) : 0;
}

String ScreenCapture::get_last_error() const {
	return last_error;
}

void MouseInput::_bind_methods() {
	ClassDB::bind_static_method("MouseInput", D_METHOD("move_to", "position"), &MouseInput::move_to);
	ClassDB::bind_static_method("MouseInput", D_METHOD("get_position"), &MouseInput::get_position);
	ClassDB::bind_static_method("MouseInput", D_METHOD("set_button", "button", "pressed"), &MouseInput::set_button);
	ClassDB::bind_static_method("MouseInput", D_METHOD("scroll", "delta"), &MouseInput::scroll);
	ClassDB::bind_static_method("MouseInput", D_METHOD("scroll_horizontal", "delta"), &MouseInput::scroll_horizontal);
	ClassDB::bind_static_method("MouseInput", D_METHOD("press_keys", "virtual_keys"), &MouseInput::press_keys);
	ClassDB::bind_static_method("MouseInput", D_METHOD("set_key", "virtual_key", "pressed"), &MouseInput::set_key);
	ClassDB::bind_static_method("MouseInput", D_METHOD("is_agent_connected"), &MouseInput::is_agent_connected);
	ClassDB::bind_static_method("MouseInput", D_METHOD("is_secure_desktop_active"), &MouseInput::is_secure_desktop_active);
	ClassDB::bind_static_method("MouseInput", D_METHOD("start_key_recording"), &MouseInput::start_key_recording);
	ClassDB::bind_static_method("MouseInput", D_METHOD("stop_key_recording"), &MouseInput::stop_key_recording);
	ClassDB::bind_static_method("MouseInput", D_METHOD("get_recorded_keys"), &MouseInput::get_recorded_keys);
	ClassDB::bind_static_method("MouseInput", D_METHOD("get_key_recording_seen"), &MouseInput::get_key_recording_seen);
	ClassDB::bind_static_method("MouseInput", D_METHOD("start_text_recording"), &MouseInput::start_text_recording);
	ClassDB::bind_static_method("MouseInput", D_METHOD("get_recorded_text"), &MouseInput::get_recorded_text);
	ClassDB::bind_static_method("MouseInput", D_METHOD("get_text_recording_end"), &MouseInput::get_text_recording_end);

	BIND_ENUM_CONSTANT(BUTTON_LEFT);
	BIND_ENUM_CONSTANT(BUTTON_RIGHT);
	BIND_ENUM_CONSTANT(BUTTON_MIDDLE);
}

Vector2i MouseInput::get_position() {
	int32_t x = 0;
	int32_t y = 0;
	workplace::mouse_position(x, y);
	return Vector2i(x, y);
}

void MouseInput::move_to(const Vector2i &p_position) {
	workplace::mouse_move(p_position.x, p_position.y);
}

void MouseInput::set_button(Button p_button, bool p_pressed) {
	workplace::mouse_button(static_cast<int32_t>(p_button), p_pressed);
}

void MouseInput::scroll(int p_delta) {
	workplace::mouse_wheel(p_delta);
}

void MouseInput::scroll_horizontal(int p_delta) {
	workplace::mouse_hwheel(p_delta);
}

void MouseInput::press_keys(const PackedInt32Array &p_virtual_keys) {
	std::vector<uint16_t> keys;
	for (int64_t i = 0; i < p_virtual_keys.size(); i++) {
		keys.push_back(static_cast<uint16_t>(p_virtual_keys[i]));
	}
	workplace::press_keys(keys);
}

void MouseInput::set_key(int p_virtual_key, bool p_pressed) {
	workplace::key_event(static_cast<uint16_t>(p_virtual_key), p_pressed);
}

bool MouseInput::is_agent_connected() {
	return workplace::agent_connected();
}

bool MouseInput::is_secure_desktop_active() {
	return workplace::secure_desktop_active();
}

bool MouseInput::start_key_recording() {
	return workplace::key_recording_start();
}

void MouseInput::stop_key_recording() {
	workplace::key_recording_stop();
}

int MouseInput::get_key_recording_seen() {
	return workplace::key_recording_seen();
}

bool MouseInput::start_text_recording() {
	return workplace::text_recording_start();
}

String MouseInput::get_recorded_text() {
	std::wstring text;
	workplace::text_recording_result(text);
	return String(text.c_str());
}

int MouseInput::get_text_recording_end() {
	std::wstring text;
	return workplace::text_recording_result(text);
}

PackedInt32Array MouseInput::get_recorded_keys() {
	PackedInt32Array result;
	std::vector<uint16_t> keys;
	if (workplace::key_recording_result(keys)) {
		for (uint16_t key : keys) {
			result.append(key);
		}
	}
	return result;
}

void GlobalHotkey::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start", "ctrl", "alt", "shift", "virtual_key"), &GlobalHotkey::start);
	ClassDB::bind_method(D_METHOD("stop"), &GlobalHotkey::stop);
	ClassDB::bind_method(D_METHOD("consume_pressed"), &GlobalHotkey::consume_pressed);
}

GlobalHotkey::~GlobalHotkey() {
	stop();
}

bool GlobalHotkey::start(bool p_ctrl, bool p_alt, bool p_shift, int p_virtual_key) {
	stop();
	backend = workplace::HotkeyBackend::create();
	if (!backend->start(p_ctrl, p_alt, p_shift, static_cast<uint32_t>(p_virtual_key))) {
		delete backend;
		backend = nullptr;
		return false;
	}
	return true;
}

void GlobalHotkey::stop() {
	if (backend != nullptr) {
		backend->stop();
		delete backend;
		backend = nullptr;
	}
}

bool GlobalHotkey::consume_pressed() {
	return backend != nullptr && backend->consume_pressed();
}

void SecureDesktop::_bind_methods() {
	ClassDB::bind_method(D_METHOD("update"), &SecureDesktop::update);
	ClassDB::bind_method(D_METHOD("get_texture"), &SecureDesktop::get_texture);
	ClassDB::bind_method(D_METHOD("get_frame_size"), &SecureDesktop::get_frame_size);
	ClassDB::bind_method(D_METHOD("get_frame_origin"), &SecureDesktop::get_frame_origin);
}

bool SecureDesktop::update() {
	std::vector<uint8_t> buffer;
	int32_t width = 0;
	int32_t height = 0;
	int32_t origin_x = 0;
	int32_t origin_y = 0;
	uint32_t sequence = last_sequence;
	if (!workplace::read_secure_frame(sequence, width, height, origin_x, origin_y, buffer)) {
		return false;
	}
	last_sequence = sequence;
	PackedByteArray data;
	data.resize(static_cast<int64_t>(buffer.size()));
	memcpy(data.ptrw(), buffer.data(), buffer.size());
	Ref<Image> image = Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, data);
	if (image.is_null()) {
		return false;
	}
	if (texture.is_null() || frame_size != Vector2i(width, height)) {
		texture = ImageTexture::create_from_image(image);
	} else {
		texture->update(image);
	}
	frame_size = Vector2i(width, height);
	frame_origin = Vector2i(origin_x, origin_y);
	return true;
}

Ref<ImageTexture> SecureDesktop::get_texture() const {
	return texture;
}

Vector2i SecureDesktop::get_frame_size() const {
	return frame_size;
}

Vector2i SecureDesktop::get_frame_origin() const {
	return frame_origin;
}

} // namespace godot
