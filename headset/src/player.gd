extends Node3D
## The headset app of the pc-render branch: the PC draws everything. This sends
## the head, the eyes, the hands and the controllers to the PC every frame
## (LinkProtocol "tracking") and shows the eyes' stream that comes back. Each
## picture is tagged with the id of the pose it was drawn with; it is shown on a
## plane where that pose's eye looked, so turning the head turns the picture away
## at once (the delay then shows only at the picture's edges, not as a lag).
## The hybrid (30.10.2026): the screens nearest the gaze come as streams of their
## own, on layers behind the eyes (ScreenLayers); the eyes' alpha (rows of mask
## under them in the video) leaves those places see-through.

const SEARCH_SEC := 1.0
const CONNECT_TIMEOUT_SEC := 3.0
const LOCALHOST := "127.0.0.1"
## How far the planes stand: a turn of the head is right at any distance, but
## where the head is not quite where it was foreseen, only what is this far
## stays in place (the rest drifts by the miss times the difference of the
## inverse distances). So the planes go to the screen looked at: at a fixed 8 m
## the near screens drifted off their own sharp layers while the head moved
## (30.10.2026). Without one in view, PLANE_DISTANCE.
const PLANE_DISTANCE := 1.5
const PLANE_DISTANCE_RANGE := Vector2(0.4, 8.0)
## A screen counts as looked at within this of the gaze (radians, 30°).
const LOOK_CONE := 0.52
const PLANE_DISTANCE_SMOOTHING := 0.2
## Poses kept for the pictures that come later (at 72 Hz: over 3 s).
const POSES_KEPT := 256
const RECEIVER_ID := 1
## The PC draws this much more than the eyes see on each side: a picture shown
## a little late still covers the view when the head turns (its edges showed).
const FOV_MARGIN := 0.15
## Each eye's plane is this much larger than its picture, the picture's edge
## drawn out over the rest: past the margin a quick turn shows a smear, not black.
const PLANE_EXTEND := 2.0
## Cells of the plane's mesh along each side: the foveated picture (Foveation)
## is unwarped by where its vertices sit, straight between them.
const PLANE_CELLS := 64
## The pose sent is where the head will be when its picture is shown: the head's
## speed (smoothed this much per frame) times the delay measured from the pictures.
const VELOCITY_SMOOTHING := 0.3
const DELAY_SMOOTHING := 0.05
const DELAY_START_SEC := 0.05
const DELAY_MAX_SEC := 0.12
const STATUS_OFFSET := Vector3(0.0, -0.15, -0.8)
## The headset's own eye buffer, which the PC's picture is drawn into before the
## compositor bends it for the lenses, made this much larger than the runtime
## recommends: at 1.0 it held fewer pixels than the picture and blurred it a
## second time — text far away smeared however sharp the PC drew (30.10.2026).
const EYE_BUFFER_SCALE := 1.6
## How much the picture is sharpened (EYE_SHADER): it comes through several
## resamplings (mips, warp, video, this plane, the compositor) and each softens;
## Meta's own Link sharpens too (30.10.2026).
const SHARPEN := 0.6

const EYE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, shadows_disabled;
uniform samplerExternalOES picture;
uniform int eye;
uniform vec2 texel = vec2(0.0005);
uniform float sharpen = 0.0;
// Rows of the video: the eyes', the mask's under them, all.
uniform vec3 rows = vec3(1.0, 0.0, 1.0);
// The picture's share of the decoder's buffer (it can be padded on the right).
uniform vec2 crop = vec2(1.0);
vec3 at(vec2 uv) {
	return texture(picture, vec2((uv.x + float(eye)) * 0.5, uv.y * rows.x / rows.z) * crop).rgb;
}
void fragment() {
	if (int(VIEW_INDEX) != eye) {
		discard;
	}
	// Past the picture (the mesh's outer part) its edge is drawn out, not black.
	vec2 uv = clamp(UV, texel, 1.0 - texel);
	vec3 c = at(uv);
	// Unsharp mask against the 4 neighbours.
	vec3 l = at(uv - vec2(texel.x, 0.0));
	vec3 r = at(uv + vec2(texel.x, 0.0));
	vec3 d = at(uv - vec2(0.0, texel.y));
	vec3 u = at(uv + vec2(0.0, texel.y));
	c = clamp(c + sharpen * (c - (l + r + d + u) * 0.25), 0.0, 1.0);
	ALBEDO = mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
	// Within the mask's own rows (not blurred into the eyes' last row).
	float mask = rows.y > 0.0 ? texture(picture, vec2((uv.x + float(eye)) * 0.5,
			(rows.x + 0.5 + uv.y * (rows.y - 1.0)) / rows.z) * crop).r : 1.0;
	ALPHA = smoothstep(0.25, 0.75, mask);
}
"""

const HAND_TRACKER_NAMES: Array[StringName] = [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]
const CONTROLLER_TRACKER_NAMES: Array[StringName] = [&"left_hand", &"right_hand"]

var _xr: XRInterface
var _origin: XROrigin3D
var _camera: XRCamera3D
var _receiver: Variant = null
## com.workplace.headset.SoundReceiver (31.10.2026): plays while a PC is there;
## the PC sends sound only while «Звук ПК в шлеме» is on there.
var _sound: Variant = null
var _texture := ExternalTexture.new()
var _screens: ScreenLayers
## The eyes' video: rows of the eyes, of the alpha mask under them.
var _eye_rows := 1
var _plane_distance := PLANE_DISTANCE
## The picture's share of the decoder's buffer (EYE_SHADER's crop).
var _crop := Vector2.ONE
var _mask_rows := 0
var _eyes: Array[MeshInstance3D] = []
var _status: Label3D

var _udp := PacketPeerUDP.new()
var _tcp: StreamPeerTCP
var _channel: PacketPeerStream
var _pc_address := ""
var _connecting_since := 0.0
var _next_search := 0.0
var _rounds := 0
var _last_heard := 0.0
var _next_ping := 0.0
var _greeted := false
var _eyes_port := 0
var _receiving := false

var _pose_id := 0
## Pose id -> [head, [eye transforms relative to the head], [fov tangents]].
var _poses: Dictionary = {}
var _shown_pose := -1
var _buffer := 0
var _next_log := 0.0
var _sent := 0
var _pictures := 0
## Pose id -> when it was sent (s), for the delay.
var _sent_at: Dictionary = {}
var _delay := DELAY_START_SEC
var _last_head := Transform3D.IDENTITY
var _last_head_time := -1.0
var _angular_velocity := Vector3.ZERO
var _linear_velocity := Vector3.ZERO


func _ready() -> void:
	_xr = XRServer.find_interface("OpenXR")
	if _xr == null or not _xr.is_initialized():
		print("[player] OpenXR не поднялся")
		return
	_xr.render_target_size_multiplier = EYE_BUFFER_SCALE
	get_viewport().use_xr = true
	# See-through where the eyes' alpha is 0: the screens' layers are behind.
	get_viewport().transparent_bg = true
	_origin = XROrigin3D.new()
	add_child(_origin)
	_camera = XRCamera3D.new()
	_origin.add_child(_camera)
	var shader := Shader.new()
	shader.code = EYE_SHADER
	for eye in 2:
		var material := ShaderMaterial.new()
		material.shader = shader
		material.set_shader_parameter(&"picture", _texture)
		material.set_shader_parameter(&"eye", eye)
		material.set_shader_parameter(&"sharpen", SHARPEN)
		var mesh := MeshInstance3D.new()
		mesh.mesh = _plane_mesh(Foveation.STRENGTH)
		mesh.material_override = material
		mesh.visible = false
		mesh.extra_cull_margin = 16384.0
		_origin.add_child(mesh)
		_eyes.append(mesh)
	_status = Label3D.new()
	_status.pixel_size = 0.0008
	_status.font_size = 36
	_status.outline_size = 8
	_status.no_depth_test = true
	_status.position = STATUS_OFFSET
	_camera.add_child(_status)
	if OS.get_name() == "Android":
		_receiver = JavaClassWrapper.wrap("com.workplace.headset.VideoReceiver")
		_sound = JavaClassWrapper.wrap("com.workplace.headset.SoundReceiver")
	_screens = ScreenLayers.new(_receiver, _origin)
	_udp.set_broadcast_enabled(true)
	_udp.bind(0)
	print("[player] готов, ищу ПК, который рисует")


func _process(_delta: float) -> void:
	if _origin == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _channel == null:
		_search(now)
	else:
		_serve(now)
	_show_picture()
	_status.visible = not _receiving or _buffer == 0
	_status.text = _describe()
	if now >= _next_log:
		_next_log = now + 10.0
		print("[player] %s; поз отправлено %d, картинок %d за 10 с, задержка %.0f мс, кадр глаза %s" % [_describe(), _sent,
				_pictures, _delay * 1000.0, _xr.get_render_target_size()])
		_sent = 0
		_pictures = 0


## For headset_root.gd: whether a PC that draws is there.
func connected() -> bool:
	return _channel != null


## headset_root.gd swaps to the other mode.
func _exit_tree() -> void:
	if _screens != null:
		_reset("режим сменился")
	_udp.close()


func _describe() -> String:
	if _channel == null:
		return "Ищу ПК, который рисует…" if _tcp == null else "Подключаюсь к %s…" % _pc_address
	if not _receiving:
		return "Связь с %s, жду картинку" % _pc_address
	return "ПК %s рисует, %s" % [_pc_address, _screens.describe()]


func _search(now: float) -> void:
	while _udp.get_available_packet_count() > 0:
		var answer := LinkProtocol.parse_answer(_udp.get_packet())
		# A PC that answered over Wi-Fi wins over a try at the cable: with a stale
		# `adb reverse` that one connects and drops at once, round after round.
		if not answer.is_empty() and (_tcp == null or _pc_address == LOCALHOST):
			_connect(_udp.get_packet_ip(), answer["port"], now)
	if _tcp != null:
		_tcp.poll()
		match _tcp.get_status():
			StreamPeerTCP.STATUS_CONNECTED:
				_tcp.set_no_delay(true)
				_channel = PacketPeerStream.new()
				_channel.input_buffer_max_size = LinkProtocol.CHANNEL_BUFFER
				_channel.output_buffer_max_size = LinkProtocol.CHANNEL_BUFFER
				_channel.stream_peer = _tcp
				_channel.put_var(LinkProtocol.hello(OS.get_model_name()))
				_last_heard = now
				_greeted = true
				print("[player] подключён к %s" % _pc_address)
				if _sound != null:
					_sound.start(_pc_address, LinkProtocol.REMOTE_SOUND_PORT)
			StreamPeerTCP.STATUS_CONNECTING:
				if now - _connecting_since > CONNECT_TIMEOUT_SEC:
					_tcp = null
			_:
				_tcp = null
		return
	if now < _next_search:
		return
	_next_search = now + SEARCH_SEC
	for address in _broadcast_addresses():
		_udp.set_dest_address(address, LinkProtocol.REMOTE_DISCOVERY_PORT)
		_udp.put_packet(LinkProtocol.ask_packet())
	# Over the cable (adb reverse tcp:47902 tcp:47902, tcp:47903 tcp:47903), every
	# other round, so a Wi-Fi answer has time to come first.
	_rounds += 1
	if _rounds % 2 == 0:
		_connect(LOCALHOST, LinkProtocol.REMOTE_CONTROL_PORT, now)


func _connect(ip: String, port: int, now: float) -> void:
	_tcp = StreamPeerTCP.new()
	if _tcp.connect_to_host(ip, port) != OK:
		_tcp = null
		return
	_pc_address = ip
	_connecting_since = now


func _broadcast_addresses() -> Array[String]:
	var result: Array[String] = ["255.255.255.255"]
	for address in IP.get_local_addresses():
		var parts := address.split(".")
		if parts.size() == 4 and parts[0] != "127" and parts[0] != "169":
			result.append("%s.%s.%s.255" % [parts[0], parts[1], parts[2]])
	return result


func _serve(now: float) -> void:
	_tcp.poll()
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_reset("связь оборвалась")
		return
	while _channel.get_available_packet_count() > 0:
		var message: Variant = _channel.get_var()
		if LinkProtocol.problem(message) != "":
			continue
		_last_heard = now
		match message["t"]:
			"eyes":
				_eyes_port = message["port"]
				var strength: float = message.get("foveation", 1.0)
				_mask_rows = message.get("mask", 0)
				_eye_rows = message["h"] - _mask_rows
				for mesh in _eyes:
					mesh.mesh = _plane_mesh(strength)
					var material := mesh.material_override as ShaderMaterial
					material.set_shader_parameter(&"rows", Vector3(_eye_rows, _mask_rows, message["h"]))
					material.set_shader_parameter(&"texel", Vector2(2.0 / float(message["w"]), 1.0 / _eye_rows))
				_screens.set_address(_pc_address)
				print("[player] ПК рисует %dx%d, поток на порту %d" % [message["w"], message["h"], _eyes_port])
				if _receiver != null:
					_receiver.startTexture(RECEIVER_ID, _pc_address, _eyes_port)
					_receiving = true
					_buffer = 0
			"videos":
				_screens.set_videos(message["videos"])
			"layers":
				_screens.queue(message["pose"], message["layers"])
			"bye":
				_reset("ПК закрылся")
				return
	if now - _last_heard > LinkProtocol.LINK_TIMEOUT_SEC:
		_reset("ПК молчит")
		return
	if now >= _next_ping:
		_next_ping = now + LinkProtocol.PING_SEC
		_channel.put_var(LinkProtocol.ping(now))
	if _receiving and _receiver != null and not _receiver.isAlive(RECEIVER_ID):
		print("[player] поток глаз прервался: %s, снова" % _receiver.status(RECEIVER_ID))
		_receiver.startTexture(RECEIVER_ID, _pc_address, _eyes_port)
		_buffer = 0
	_screens.poll(now, _camera.transform.origin)
	_send_tracking()


func _reset(why: String) -> void:
	print("[player] %s, ищу снова" % why)
	if _receiver != null:
		_receiver.stopAll()
	if _sound != null:
		_sound.stop()
	if _tcp != null:
		_tcp.disconnect_from_host()
	_tcp = null
	_channel = null
	_greeted = false
	_receiving = false
	_buffer = 0
	_screens.reset()
	for mesh in _eyes:
		mesh.visible = false


func _send_tracking() -> void:
	_pose_id += 1
	var head_tracker := XRServer.get_tracker(&"head") as XRPositionalTracker
	var head_pose: XRPose = head_tracker.get_pose(&"default") if head_tracker != null else null
	var measured := head_pose.transform if head_pose != null else Transform3D.IDENTITY
	var eyes: Array = []
	var fov: Array = []
	for view in 2:
		eyes.append(measured.affine_inverse() * _xr.get_transform_for_view(view, Transform3D.IDENTITY))
		var p := _xr.get_projection_for_view(view, 1.0, 0.05, 100.0)
		fov.append(Vector4((p[2][0] - 1.0) / p[0][0], (p[2][0] + 1.0) / p[0][0],
				(p[2][1] - 1.0) / p[1][1], (p[2][1] + 1.0) / p[1][1]) * (1.0 + FOV_MARGIN))
	var head := _predict(measured)
	var hands: Array = []
	var controllers: Array = []
	for i in 2:
		hands.append(_hand(XRServer.get_tracker(HAND_TRACKER_NAMES[i]) as XRHandTracker))
		controllers.append(_controller(XRServer.get_tracker(CONTROLLER_TRACKER_NAMES[i]) as XRControllerTracker))
	_channel.put_var({"t": "tracking", "id": _pose_id, "head": head,
			"head_ok": head_pose != null and head_pose.has_tracking_data, "eyes": eyes, "fov": fov,
			"hands": hands, "controllers": controllers, "shown": _screens.shown_keys()})
	_poses[_pose_id] = [head, eyes, fov]
	_poses.erase(_pose_id - POSES_KEPT)
	_sent_at[_pose_id] = Time.get_ticks_usec() / 1e6
	_sent_at.erase(_pose_id - POSES_KEPT)
	_sent += 1


## The head `_delay` and a frame from now, going on as it moves (its speed
## smoothed over the last frames).
func _predict(head: Transform3D) -> Transform3D:
	var now := Time.get_ticks_usec() / 1e6
	var dt := now - _last_head_time
	if _last_head_time >= 0.0 and dt > 0.001 and dt < 0.1:
		var turn := head.basis.get_rotation_quaternion() * _last_head.basis.get_rotation_quaternion().inverse()
		var angular := turn.get_axis() * turn.get_angle() / dt if turn.get_angle() > 1e-5 else Vector3.ZERO
		if turn.get_angle() > PI:
			angular = turn.get_axis() * (turn.get_angle() - TAU) / dt
		_angular_velocity = _angular_velocity.lerp(angular, VELOCITY_SMOOTHING)
		_linear_velocity = _linear_velocity.lerp((head.origin - _last_head.origin) / dt, VELOCITY_SMOOTHING)
	_last_head = head
	_last_head_time = now
	var ahead := _delay + 1.0 / maxf(Engine.get_frames_per_second(), 60.0)
	var predicted := head
	var speed := _angular_velocity.length()
	if speed > 1e-4:
		predicted.basis = Basis(_angular_velocity / speed, speed * ahead) * head.basis
	predicted.origin += _linear_velocity * ahead
	return predicted


func _hand(tracker: XRHandTracker) -> Dictionary:
	if tracker == null or not tracker.has_tracking_data:
		return {"ok": false}
	var joints := PackedFloat32Array()
	var flags := PackedInt32Array()
	for joint in XRHandTracker.HAND_JOINT_MAX:
		var pose := tracker.get_hand_joint_transform(joint)
		var rotation := pose.basis.get_rotation_quaternion()
		joints.append_array([rotation.x, rotation.y, rotation.z, rotation.w, pose.origin.x, pose.origin.y, pose.origin.z])
		flags.append(tracker.get_hand_joint_flags(joint))
	return {"ok": true, "source": tracker.hand_tracking_source, "joints": joints, "flags": flags}


func _controller(tracker: XRControllerTracker) -> Dictionary:
	if tracker == null:
		return {"ok": false, "profile": "", "inputs": {}}
	var aim := tracker.get_pose(&"aim")
	var grip := tracker.get_pose(&"grip")
	var inputs := {}
	for input: StringName in RemoteXR.FLOAT_INPUTS + RemoteXR.VECTOR_INPUTS + RemoteXR.BUTTON_INPUTS:
		var value: Variant = tracker.get_input(input)
		if value != null:
			inputs[String(input)] = value
	return {"ok": aim != null and aim.has_tracking_data, "profile": String(tracker.profile),
			"aim": aim.transform if aim != null else Transform3D.IDENTITY,
			"grip": grip.transform if grip != null else Transform3D.IDENTITY, "inputs": inputs}


## An eye's plane in picture coordinates (-1..1 is the picture, the rest its
## drawn-out edge, up to PLANE_EXTEND): each vertex at its place in the view,
## its texture coordinate where the foveated picture keeps that place.
static func _plane_mesh(strength: float) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for row in PLANE_CELLS + 1:
		for column in PLANE_CELLS + 1:
			var s := Vector2(column, row) / PLANE_CELLS * 2.0 * PLANE_EXTEND - Vector2.ONE * PLANE_EXTEND
			vertices.append(Vector3(s.x, -s.y, 0.0))
			var u := Vector2(Foveation.unwarp(clampf(s.x, -1.0, 1.0), strength),
					Foveation.unwarp(clampf(s.y, -1.0, 1.0), strength))
			uvs.append(u * 0.5 + Vector2.ONE * 0.5)
	for row in PLANE_CELLS:
		for column in PLANE_CELLS:
			var at := row * (PLANE_CELLS + 1) + column
			indices.append_array([at, at + 1, at + PLANE_CELLS + 1, at + 1, at + PLANE_CELLS + 2, at + PLANE_CELLS + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## The newest decoded picture, on the planes where the eyes of its pose looked.
func _show_picture() -> void:
	if not _receiving or _receiver == null:
		return
	var buffer: int = _receiver.textureFrame(RECEIVER_ID)
	if buffer == 0:
		return
	if buffer != _buffer:
		var padded := Vector2(_receiver.textureBufferWidth(RECEIVER_ID), _receiver.textureBufferHeight(RECEIVER_ID))
		var picture := Vector2(_receiver.textureWidth(RECEIVER_ID), _receiver.textureHeight(RECEIVER_ID))
		var crop := picture / padded if padded.x > 0.0 and padded.y > 0.0 else Vector2.ONE
		if not crop.is_equal_approx(_crop):
			_crop = crop
			print("[player] картинка %s в буфере %s" % [picture, padded])
			for mesh in _eyes:
				(mesh.material_override as ShaderMaterial).set_shader_parameter(&"crop", crop)
		if _buffer == 0:
			var size := Vector2(_receiver.textureWidth(RECEIVER_ID), _receiver.textureHeight(RECEIVER_ID))
			_texture.set_size(size)
			print("[player] первая картинка")
		_buffer = buffer
		_texture.set_external_buffer_id(buffer)
		_pictures += 1
	var pose_id: int = _receiver.textureFramePose(RECEIVER_ID)
	if pose_id == _shown_pose or not _poses.has(pose_id):
		return
	_shown_pose = pose_id
	_screens.picture_shown(pose_id)
	if _sent_at.has(pose_id):
		var delay: float = Time.get_ticks_usec() / 1e6 - _sent_at[pose_id]
		_delay = clampf(lerpf(_delay, delay, DELAY_SMOOTHING), 0.0, DELAY_MAX_SEC)
	var pose: Array = _poses[pose_id]
	var head: Transform3D = pose[0]
	var looked_at := _screens.looked_at_distance(head.origin, -head.basis.z, LOOK_CONE)
	var target := looked_at if looked_at > 0.0 else PLANE_DISTANCE
	_plane_distance = clampf(lerpf(_plane_distance, target, PLANE_DISTANCE_SMOOTHING),
			PLANE_DISTANCE_RANGE.x, PLANE_DISTANCE_RANGE.y)
	for eye in 2:
		var t: Vector4 = pose[2][eye]
		var mesh := _eyes[eye]
		var half := Vector3((t.y - t.x) * 0.5 * _plane_distance, (t.w - t.z) * 0.5 * _plane_distance, 1.0)
		var centre := Vector3((t.x + t.y) * 0.5 * _plane_distance, (t.z + t.w) * 0.5 * _plane_distance, -_plane_distance)
		mesh.transform = head * (pose[1][eye] as Transform3D) * Transform3D(Basis.from_scale(half), centre)
		mesh.visible = true
