#include "workplace_classes.h"

#include "game_link.h"
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

void ScreenStreamer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start", "monitor_index", "port", "bitrate_kbps", "fps"), &ScreenStreamer::start);
	ClassDB::bind_method(D_METHOD("stop"), &ScreenStreamer::stop);
	ClassDB::bind_method(D_METHOD("is_running"), &ScreenStreamer::is_running);
	ClassDB::bind_method(D_METHOD("get_stats"), &ScreenStreamer::get_stats);
	ClassDB::bind_method(D_METHOD("get_last_error"), &ScreenStreamer::get_last_error);
	ClassDB::bind_method(D_METHOD("request_snapshot", "width"), &ScreenStreamer::request_snapshot);
	ClassDB::bind_method(D_METHOD("get_snapshot"), &ScreenStreamer::get_snapshot);
	ClassDB::bind_static_method("ScreenStreamer", D_METHOD("clock_usec"), &ScreenStreamer::clock_usec);
}

void SoundStreamer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start", "port"), &SoundStreamer::start);
	ClassDB::bind_method(D_METHOD("stop"), &SoundStreamer::stop);
	ClassDB::bind_method(D_METHOD("is_running"), &SoundStreamer::is_running);
	ClassDB::bind_method(D_METHOD("get_stats"), &SoundStreamer::get_stats);
	ClassDB::bind_method(D_METHOD("get_last_error"), &SoundStreamer::get_last_error);
}

SoundStreamer::~SoundStreamer() {
	stop();
}

bool SoundStreamer::start(int p_port) {
	stop();
	backend = workplace::SoundBackend::create();
	std::string error;
	if (!backend->start(p_port, error)) {
		last_error = String::utf8(error.c_str());
		delete backend;
		backend = nullptr;
		return false;
	}
	last_error = "";
	return true;
}

void SoundStreamer::stop() {
	if (backend) {
		backend->stop();
		delete backend;
		backend = nullptr;
	}
}

bool SoundStreamer::is_running() const {
	return backend && backend->running();
}

Dictionary SoundStreamer::get_stats() const {
	Dictionary result;
	if (!backend) {
		return result;
	}
	workplace::SoundStats stats = backend->stats();
	result["bytes_sent"] = static_cast<int64_t>(stats.bytes_sent);
	result["frames_captured"] = static_cast<int64_t>(stats.frames_captured);
	result["frames_dropped"] = static_cast<int64_t>(stats.frames_dropped);
	result["rate"] = stats.sample_rate;
	result["channels"] = stats.source_channels;
	result["device"] = String::utf8(stats.device.c_str());
	result["client"] = String::utf8(stats.client.c_str());
	result["error"] = String::utf8(stats.error.c_str());
	return result;
}

String SoundStreamer::get_last_error() const {
	return last_error;
}

void GameBridge::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open"), &GameBridge::open);
	ClassDB::bind_method(D_METHOD("get_last_error"), &GameBridge::get_last_error);
	ClassDB::bind_method(D_METHOD("set_headset", "connected"), &GameBridge::set_headset);
	ClassDB::bind_method(D_METHOD("write_head", "pose_id", "head", "head_ok", "eyes", "fov"), &GameBridge::write_head);
	ClassDB::bind_method(D_METHOD("write_controllers", "controllers"), &GameBridge::write_controllers);
	ClassDB::bind_method(D_METHOD("take_haptics"), &GameBridge::take_haptics);
	ClassDB::bind_method(D_METHOD("write_hands", "hands"), &GameBridge::write_hands);
	ClassDB::bind_method(D_METHOD("get_driver"), &GameBridge::get_driver);
}

namespace {

workplace::GameLink *game_link() {
	std::string error;
	return workplace::game_link_open(error);
}

void put_transform(workplace::GameTransform &out, const Transform3D &transform) {
	Quaternion rotation = transform.basis.get_rotation_quaternion();
	out.rotation[0] = rotation.x;
	out.rotation[1] = rotation.y;
	out.rotation[2] = rotation.z;
	out.rotation[3] = rotation.w;
	out.position[0] = transform.origin.x;
	out.position[1] = transform.origin.y;
	out.position[2] = transform.origin.z;
}

} // namespace

bool GameBridge::open() {
	std::string error;
	if (!workplace::game_link_open(error)) {
		last_error = String::utf8(error.c_str());
		return false;
	}
	last_error = "";
	return true;
}

String GameBridge::get_last_error() const {
	return last_error;
}

void GameBridge::set_headset(bool p_connected) {
	workplace::GameLink *link = game_link();
	if (!link) {
		return;
	}
	link->sequence.fetch_add(1);
	link->headset = p_connected ? 1 : 0;
	link->sequence.fetch_add(1);
	workplace::game_link_signal();
}

void GameBridge::write_head(int64_t p_pose_id, const Transform3D &p_head, bool p_head_ok, const Array &p_eyes, const Array &p_fov) {
	workplace::GameLink *link = game_link();
	if (!link || p_eyes.size() < 2 || p_fov.size() < 2) {
		return;
	}
	link->sequence.fetch_add(1);
	link->headset = 1;
	link->pose_id = static_cast<uint32_t>(p_pose_id);
	link->head_ok = p_head_ok ? 1 : 0;
	link->written_us = workplace::StreamBackend::clock_us();
	put_transform(link->head, p_head);
	for (int i = 0; i < 2; i++) {
		put_transform(link->eyes[i], p_eyes[i]);
		Vector4 fov = p_fov[i];
		link->fov[i][0] = fov.x;
		link->fov[i][1] = fov.y;
		link->fov[i][2] = fov.z;
		link->fov[i][3] = fov.w;
	}
	link->sequence.fetch_add(1);
	workplace::game_link_signal();
}

void GameBridge::write_controllers(const Array &controllers) {
	auto *link = game_link();
	if (!link || controllers.size() != 2) return;
	link->sequence.fetch_add(1);
	for (int i = 0; i < 2; i++) {
		auto &out = link->controllers[i];
		out = {};
		Dictionary data = controllers[i];
		String profile = data.get("profile", "");
		if (!bool(data.get("ok", false)) || profile.is_empty() || profile.contains("hand_interaction")) continue;
		out.ok = 1;
		put_transform(out.aim, data.get("aim", Transform3D()));
		put_transform(out.grip, data.get("grip", Transform3D()));
		Dictionary inputs = data.get("inputs", Dictionary());
		out.trigger = CLAMP(double(inputs.get("trigger", 0.0)), 0.0, 1.0);
		out.grip_value = CLAMP(double(inputs.get("grip", 0.0)), 0.0, 1.0);
		Vector2 stick = inputs.get("primary", Vector2());
		out.stick[0] = CLAMP(stick.x, -1.0, 1.0); out.stick[1] = CLAMP(stick.y, -1.0, 1.0);
		const char *clicks[] = {"ax_button", "by_button", "menu_button", "primary_click", "trigger_click", "grip_click", "thumbrest_touch"};
		const char *touches[] = {"ax_touch", "by_touch", "", "primary_touch", "trigger_touch", "", "thumbrest_touch"};
		for(int bit=0;bit<7;bit++) {
			if(bool(inputs.get(clicks[bit], false))) out.buttons |= 1u << bit;
			if(bool(inputs.get(touches[bit], false))) out.touches |= 1u << bit;
		}
	}
	link->sequence.fetch_add(1);
	workplace::game_link_signal();
}

void GameBridge::write_hands(const Array &hands) {
	auto *link=game_link(); if(!link || hands.size()!=2) return;
	link->sequence.fetch_add(1);
	for(int h=0;h<2;h++) {
		link->hand_ok[h]=0;
		Dictionary data=hands[h];
		// Controller-generated fingers are not optical hands.
		int source=int(data.get("source",0));
		if(!bool(data.get("ok",false)) || source==2 || source==3 || (source==0 && link->controllers[h].ok)) continue;
		PackedFloat32Array joints=data.get("joints",PackedFloat32Array());
		PackedInt32Array flags=data.get("flags",PackedInt32Array());
		if(joints.size()!=26*7 || flags.size()!=26) continue;
		Transform3D world[31]; bool valid=true;
		for(int j=0;j<26;j++) {
			if((flags[j]&5)!=5) {valid=false;break;}
			Quaternion q(joints[j*7],joints[j*7+1],joints[j*7+2],joints[j*7+3]);
			if(!q.is_finite() || q.length_squared()<0.5) {valid=false;break;}
			Vector3 p(joints[j*7+4],joints[j*7+5],joints[j*7+6]);
			if(!p.is_finite()) {valid=false;break;}
			world[j]=Transform3D(Basis(q.normalized()),p);
		}
		if(!valid) continue;
		// Construct a controller frame pointing along the fingers. A joint frame
		// is not a controller grip frame (raw wrist axes produced a sideways ray).
		Vector3 forward=(world[11].origin-world[1].origin).normalized();
		Vector3 normal=world[1].basis.get_column(1);
		if(forward.length_squared()<0.5 || forward.cross(normal).length_squared()<0.01) continue;
		Transform3D grip(Basis::looking_at(forward,normal),world[1].origin);
		put_transform(link->hand_grip[h],grip);
		if(data.has("aim")) grip = data["aim"];
		put_transform(link->wrist[h],grip);
		world[0]=grip;
		float distance=world[5].origin.distance_to(world[10].origin);
		bool pressed=link->hand_trigger[h]>0.5f;
		link->hand_trigger[h]=(distance < (pressed?0.035f:0.025f))?1.0f:0.0f;
		const int tips[]={5,10,15,20,25};
		for(int i=0;i<5;i++) world[26+i]=world[tips[i]];
		for(int j=0;j<31;j++) {
			int parent=j-1;
			if(j==0 || j==1) parent=0;
			if(j==2||j==6||j==11||j==16||j==21) parent=1;
			if(j>=26) parent=0;
			put_transform(link->bones[h][j],world[parent].affine_inverse()*world[j]);
		}
		link->hand_ok[h]=1;
	}
	link->sequence.fetch_add(1);
	workplace::game_link_signal();
}

Array GameBridge::take_haptics() {
	Array result;
	auto *link = game_link(); if(!link) return result;
	for(int hand=0;hand<2;hand++) {
		uint64_t pulse = link->haptics[hand].exchange(0);
		if(!pulse) continue;
		Dictionary item; item["t"]="haptic"; item["hand"]=hand;
		item["duration"]=double(pulse & 65535)/1000.0;
		item["amplitude"]=double((pulse >> 16)&1023)/1000.0;
		item["frequency"]=double((pulse >> 26)&65535);
		result.append(item);
	}
	return result;
}

Dictionary GameBridge::get_driver() const {
	Dictionary result;
	workplace::GameLink *link = game_link();
	if (!link) {
		return result;
	}
	uint64_t beat = link->driver_beat_us.load();
	uint64_t now = workplace::StreamBackend::clock_us();
	result["alive"] = beat != 0 && now >= beat && now - beat < 2'000'000;
	result["port"] = static_cast<int64_t>(link->eyes_port.load());
	result["width"] = static_cast<int64_t>(link->eyes_width.load());
	result["height"] = static_cast<int64_t>(link->eyes_height.load());
	result["frames"] = static_cast<int64_t>(link->frames_presented.load());
	result["scene_pid"] = static_cast<int64_t>(link->scene_pid.load());
	return result;
}

void EyeStreamer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start", "eye_width", "eye_height", "out_eye_width", "out_eye_height", "port",
			"bitrate_kbps", "fps"), &EyeStreamer::start);
	ClassDB::bind_method(D_METHOD("stop"), &EyeStreamer::stop);
	ClassDB::bind_method(D_METHOD("is_running"), &EyeStreamer::is_running);
	ClassDB::bind_method(D_METHOD("copy_eyes", "render_target_texture"), &EyeStreamer::copy_eyes);
	ClassDB::bind_method(D_METHOD("submit", "pose_id"), &EyeStreamer::submit);
	ClassDB::bind_method(D_METHOD("get_target"), &EyeStreamer::get_target);
	ClassDB::bind_method(D_METHOD("mark_written"), &EyeStreamer::mark_written);
	ClassDB::bind_method(D_METHOD("get_stats"), &EyeStreamer::get_stats);
	ClassDB::bind_method(D_METHOD("get_last_error"), &EyeStreamer::get_last_error);
}

EyeStreamer::~EyeStreamer() {
	stop();
}

bool EyeStreamer::start(int p_eye_width, int p_eye_height, int p_out_eye_width, int p_out_eye_height, int p_port,
		int p_bitrate_kbps, int p_fps) {
	stop();
	RenderingServer *rendering_server = RenderingServer::get_singleton();
	RenderingDevice *rendering_device = rendering_server->get_rendering_device();
	if (rendering_device == nullptr || rendering_server->get_current_rendering_driver_name() != String("d3d12")) {
		last_error = "the D3D12 rendering driver is required";
		return false;
	}
	uint64_t device = rendering_device->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_LOGICAL_DEVICE, RID(), 0);
	uint64_t queue = rendering_device->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_COMMAND_QUEUE, RID(), 0);
	if (device == 0 || queue == 0) {
		last_error = "could not get the D3D12 device or queue from the RenderingDevice";
		return false;
	}
	eye_width = p_eye_width & ~1;
	eye_height = p_eye_height & ~1;
	backend = workplace::StreamBackend::create();
	std::string error;
	if (!backend->start_external(reinterpret_cast<void *>(device), reinterpret_cast<void *>(queue), eye_width * 2,
				eye_height, (p_out_eye_width & ~1) * 2, p_out_eye_height & ~1, p_port, p_bitrate_kbps, p_fps, error)) {
		last_error = String::utf8(error.c_str());
		delete backend;
		backend = nullptr;
		return false;
	}
	for (int i = 0; i < 2; i++) {
		slots[i] = rendering_device->texture_create_from_extension(RenderingDevice::TEXTURE_TYPE_2D,
				RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM, RenderingDevice::TEXTURE_SAMPLES_1,
				RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
						RenderingDevice::TEXTURE_USAGE_STORAGE_BIT,
				reinterpret_cast<uint64_t>(backend->external_texture(i)), eye_width * 2, eye_height, 1, 1);
		if (!slots[i].is_valid()) {
			last_error = "texture_create_from_extension failed";
			stop();
			return false;
		}
	}
	last_error = "";
	return true;
}

void EyeStreamer::stop() {
	RenderingServer *rendering_server = RenderingServer::get_singleton();
	RenderingDevice *rendering_device = rendering_server != nullptr ? rendering_server->get_rendering_device() : nullptr;
	for (int i = 0; i < 2; i++) {
		if (slots[i].is_valid() && rendering_device != nullptr) {
			rendering_device->free_rid(slots[i]);
		}
		slots[i] = RID();
	}
	if (backend) {
		backend->stop();
		delete backend;
		backend = nullptr;
	}
	copied = false;
}

bool EyeStreamer::is_running() const {
	return backend && backend->running();
}

void EyeStreamer::copy_eyes(const RID &p_render_target_texture) {
	if (!backend || !slots[slot].is_valid() || !p_render_target_texture.is_valid()) {
		return;
	}
	RenderingDevice *rendering_device = RenderingServer::get_singleton()->get_rendering_device();
	for (int eye = 0; eye < 2; eye++) {
		rendering_device->texture_copy(p_render_target_texture, slots[slot], Vector3(), Vector3(eye * eye_width, 0, 0),
				Vector3(eye_width, eye_height, 1), 0, 0, eye, 0);
	}
	copied = true;
}

RID EyeStreamer::get_target() const {
	return backend ? slots[slot] : RID();
}

void EyeStreamer::mark_written() {
	copied = backend != nullptr;
}

void EyeStreamer::submit(int p_pose_id) {
	if (!backend || !copied) {
		return;
	}
	backend->external_submit(slot, static_cast<uint32_t>(p_pose_id));
	slot = 1 - slot;
	copied = false;
}

Dictionary EyeStreamer::get_stats() const {
	Dictionary result;
	if (!backend) {
		return result;
	}
	workplace::StreamStats stats = backend->stats();
	result["frames_captured"] = static_cast<int64_t>(stats.frames_captured);
	result["frames_encoded"] = static_cast<int64_t>(stats.frames_encoded);
	result["frames_sent"] = static_cast<int64_t>(stats.frames_sent);
	result["bytes_sent"] = static_cast<int64_t>(stats.bytes_sent);
	result["encode_ms"] = stats.encode_ms;
	result["encode_ms_sum"] = stats.encode_ms_sum;
	result["size"] = Vector2i(stats.width, stats.height);
	result["encoder"] = String::utf8(stats.encoder.c_str());
	result["client"] = String::utf8(stats.client.c_str());
	result["error"] = String::utf8(stats.error.c_str());
	return result;
}

String EyeStreamer::get_last_error() const {
	return last_error;
}

int64_t ScreenStreamer::clock_usec() {
	return static_cast<int64_t>(workplace::StreamBackend::clock_us());
}

ScreenStreamer::~ScreenStreamer() {
	stop();
}

bool ScreenStreamer::start(int p_monitor_index, int p_port, int p_bitrate_kbps, int p_fps) {
	stop();
	std::vector<workplace::MonitorInfo> monitors = workplace::enumerate_monitors();
	if (p_monitor_index < 0 || p_monitor_index >= static_cast<int>(monitors.size())) {
		last_error = "no monitor " + String::num_int64(p_monitor_index);
		return false;
	}
	backend = workplace::StreamBackend::create();
	std::string error;
	if (!backend->start(monitors[p_monitor_index].handle, p_port, p_bitrate_kbps, p_fps, error)) {
		last_error = String::utf8(error.c_str());
		delete backend;
		backend = nullptr;
		return false;
	}
	last_error = "";
	return true;
}

void ScreenStreamer::stop() {
	if (backend) {
		backend->stop();
		delete backend;
		backend = nullptr;
	}
}

bool ScreenStreamer::is_running() const {
	return backend && backend->running();
}

Dictionary ScreenStreamer::get_stats() const {
	Dictionary result;
	if (!backend) {
		return result;
	}
	workplace::StreamStats stats = backend->stats();
	result["frames_captured"] = static_cast<int64_t>(stats.frames_captured);
	result["frames_encoded"] = static_cast<int64_t>(stats.frames_encoded);
	result["frames_sent"] = static_cast<int64_t>(stats.frames_sent);
	result["bytes_sent"] = static_cast<int64_t>(stats.bytes_sent);
	result["encode_ms"] = stats.encode_ms;
	result["encode_ms_sum"] = stats.encode_ms_sum;
	result["size"] = Vector2i(stats.width, stats.height);
	result["encoder"] = String::utf8(stats.encoder.c_str());
	result["client"] = String::utf8(stats.client.c_str());
	result["error"] = String::utf8(stats.error.c_str());
	return result;
}

String ScreenStreamer::get_last_error() const {
	return last_error;
}

void ScreenStreamer::request_snapshot(int p_width) {
	if (backend) {
		backend->request_snapshot(p_width);
	}
}

Ref<Image> ScreenStreamer::get_snapshot() {
	std::vector<uint8_t> rgba;
	int32_t width = 0;
	int32_t height = 0;
	if (!backend || !backend->take_snapshot(rgba, width, height)) {
		return Ref<Image>();
	}
	PackedByteArray data;
	data.resize(static_cast<int64_t>(rgba.size()));
	memcpy(data.ptrw(), rgba.data(), rgba.size());
	return Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, data);
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
	ClassDB::bind_static_method("MouseInput", D_METHOD("get_keyboard_layout"), &MouseInput::get_keyboard_layout);
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

int MouseInput::get_keyboard_layout() {
	return static_cast<int>(workplace::keyboard_layout());
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
	ClassDB::bind_method(D_METHOD("get_image"), &SecureDesktop::get_image);
	ClassDB::bind_method(D_METHOD("get_frame_size"), &SecureDesktop::get_frame_size);
	ClassDB::bind_method(D_METHOD("get_frame_origin"), &SecureDesktop::get_frame_origin);
	ClassDB::bind_method(D_METHOD("get_frame_scale"), &SecureDesktop::get_frame_scale);
}

bool SecureDesktop::update() {
	std::vector<uint8_t> buffer;
	int32_t width = 0;
	int32_t height = 0;
	int32_t origin_x = 0;
	int32_t origin_y = 0;
	int32_t scale = 1;
	uint32_t sequence = last_sequence;
	if (!workplace::read_secure_frame(sequence, width, height, origin_x, origin_y, scale, buffer)) {
		return false;
	}
	last_sequence = sequence;
	PackedByteArray data;
	data.resize(static_cast<int64_t>(buffer.size()));
	memcpy(data.ptrw(), buffer.data(), buffer.size());
	Ref<Image> frame = Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, data);
	if (frame.is_null()) {
		return false;
	}
	image = frame;
	if (texture.is_null() || frame_size != Vector2i(width, height)) {
		texture = ImageTexture::create_from_image(image);
	} else {
		texture->update(image);
	}
	frame_size = Vector2i(width, height);
	frame_origin = Vector2i(origin_x, origin_y);
	frame_scale = scale;
	return true;
}

Ref<Image> SecureDesktop::get_image() const {
	return image;
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

int32_t SecureDesktop::get_frame_scale() const {
	return frame_scale;
}

} // namespace godot
