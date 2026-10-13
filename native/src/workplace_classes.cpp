#include "workplace_classes.h"

#include "win_backend.h"

#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>

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

} // namespace godot
