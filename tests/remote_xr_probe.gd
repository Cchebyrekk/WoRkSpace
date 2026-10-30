extends SceneTree
## Probe for RemoteXR (branch pc-render): renders a box in stereo with a made-up
## head pose and reports the render target the eyes land in. Windowed, no OpenXR:
## `--xr-mode off -s tests/remote_xr_probe.gd`.

const PORT := 47990

var _xr := RemoteXR.new()
var _frames := 0
var _reported := false
var _streamer := EyeStreamer.new()
var _tcp := StreamPeerTCP.new()
var _buffer := PackedByteArray()
var _header_seen := false
var _received := 0
var _bytes := 0
var _poses: Array[int] = []


func _initialize() -> void:
	XRServer.add_interface(_xr)
	if not _xr.initialize():
		print("[probe] RemoteXR не поднялся")
		quit(1)
		return
	_xr.head = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	_xr.head_tracked = true
	_xr.frame_drawn.connect(_on_frame)
	root.use_xr = true
	var origin := XROrigin3D.new()
	root.add_child(origin)
	var camera := XRCamera3D.new()
	origin.add_child(camera)
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	box.position = Vector3(0, 1.6, -2)
	root.add_child(box)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 30, 0)
	root.add_child(light)
	print("[probe] интерфейс: ", XRServer.primary_interface.get_name(), ", views ", _xr.get_view_count())
	if not _streamer.start(_xr.render_size.x, _xr.render_size.y, _xr.render_size.x, _xr.render_size.y, PORT, 30000, 72):
		print("[probe] поток глаз не запустился: ", _streamer.get_last_error())
		quit(1)
		return
	print("[probe] поток глаз: ", _streamer.get_stats())
	RenderingServer.frame_post_draw.connect(func() -> void: _streamer.submit(_xr.pose_id))
	_tcp.connect_to_host("127.0.0.1", PORT)


func _process(_delta: float) -> bool:
	_frames += 1
	_xr.pose_id = _frames
	_xr.head = Transform3D(Basis(Vector3.UP, _frames * 0.02), Vector3(0, 1.6, 0))
	_tcp.poll()
	if _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED and _tcp.get_available_bytes() > 0:
		_buffer.append_array(_tcp.get_data(_tcp.get_available_bytes())[1])
		_parse()
	if _frames > 300:
		print("[probe] принято кадров %d, %.1f МБ, позы %s…%s, ПК: %s" % [_received, _bytes / 1e6,
				_poses.slice(0, 3), _poses.slice(-3), _streamer.get_stats()])
		_streamer.stop()
		return true
	return false


func _parse() -> void:
	if not _header_seen:
		if _buffer.size() < 20:
			return
		print("[probe] заголовок %s версия %d %dx%d" % [_buffer.slice(0, 4).get_string_from_ascii(), _u32(4), _u32(8), _u32(12)])
		_buffer = _buffer.slice(20)
		_header_seen = true
	while _buffer.size() >= 25:
		var length := _u32(0)
		if _buffer.size() < 25 + length:
			return
		if _buffer[24] & 2 == 0:
			_received += 1
			_bytes += length
			_poses.append(_u32(20))
		_buffer = _buffer.slice(25 + length)


func _u32(at: int) -> int:
	return (_buffer[at] << 24) | (_buffer[at + 1] << 16) | (_buffer[at + 2] << 8) | _buffer[at + 3]


func _on_frame(texture: RID, head: Transform3D, pose_id: int) -> void:
	_streamer.copy_eyes(texture)
	if pose_id == 5:
		var rd := RenderingServer.get_rendering_device()
		for eye in 2:
			var image := Image.create_from_data(_xr.render_size.x, _xr.render_size.y, false, Image.FORMAT_RGBA8,
					rd.texture_get_data(texture, eye))
			print("[probe] глаз %d: центр %s, угол %s" % [eye, image.get_pixel(_xr.render_size.x / 2, _xr.render_size.y / 2), image.get_pixel(5, 5)])
			image.convert(Image.FORMAT_RGB8)
			image.save_png(OS.get_environment("TEMP") + "/eye%d.png" % eye)
		print("[probe] глаза сохранены в %TEMP%/eye0.png, eye1.png")
	if _reported:
		return
	_reported = true
	var rd := RenderingServer.get_rendering_device()
	var format := rd.texture_get_format(texture)
	print("[probe] кадр: текстура %s, формат %d, %dx%d, слоёв %d, тип %d, usage %d; голова %s, id %d" % [texture,
			format.format, format.width, format.height, format.array_layers, format.texture_type, format.usage_bits,
			head.origin, pose_id])
	print("[probe] D3D12 ресурс: ", rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_TEXTURE, texture, 0))
