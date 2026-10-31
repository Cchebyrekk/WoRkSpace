class_name RemoteHost
extends Node
## Branch pc-render: the PC app (main.gd) draws the headset's eyes itself. This
## node answers the headset's search, holds its control channel, passes its poses
## to RemoteXR (which stands in for OpenXR) and streams the drawn eyes back
## (EyeStreamer: both eyes side by side, H.264, each frame tagged with the id of
## the pose it was drawn with — the headset turns the picture to where the head is
## by then). Started by main.gd when WORKPLACE_REMOTE is set.
## The hybrid (30.10.2026): the monitors drawn into the eyes came out soft however
## the shared picture was tuned, so the screens nearest the gaze also go as their
## own streams (ScreenStreamer, as variant 1's link server sends them) and the
## headset shows them on layers behind the eyes' picture, which is see-through
## there (ScreenPanel's holes; the alpha travels as extra rows of the video).

## In place of OpenXR's session events (main.gd draws the panels' pictures only
## while the session is visible): the headset came, the headset went.
signal headset_joined
signal headset_left

## Per-eye picture as RemoteXR draws it, and as it is sent: drawn larger, sent
## at the Quest 3S's own eye size but foveated (Foveation: the middle keeps
## about the drawn density, the edges less); the stream is twice as wide.
## 1440x1536 sent as is looked much softer than the monitors' own streams, and
## 2048 scaled down evenly still soft (30.10.2026). Once the headset's own eye
## buffer grew to 2688x2816 (player.gd EYE_BUFFER_SCALE) 2560 was below it, with
## the margin besides: drawn at 3200 the middle keeps about the buffer's density.
const EYE_SIZE := Vector2i(3200, 3360)
const SENT_EYE_SIZE := Vector2i(1832, 1920)
const BITRATE_KBPS := 60000
## Rows of alpha under the eyes (a quarter of their height: the holes' edges only).
const MASK_ROWS := 480
## The screens' own streams: the headset decodes at most 6 streams (slice o4),
## one of them the eyes'.
const SCREEN_KBPS := LinkProtocol.VIDEO_KBPS
const SCREEN_FPS := LinkProtocol.VIDEO_FPS
const LIVE_SCREENS := 5
const LIVE_CHECK_SEC := 0.3
## A live screen keeps its place until another is this much nearer the gaze
## (20°): each swap shows the PC's softer picture of the screen for a moment.
const LIVE_STICKINESS := 0.35
const FPS := 72
## Mip level bias for the main viewport's textures (the panels): a distant
## monitor is picked from a sharper level — box-averaged mips and the resampling
## after them (warp, video, the headset's plane) each soften (30.10.2026).
const MIPMAP_BIAS := -0.7

var xr := RemoteXR.new()
## main.gd's panels (set by it every frame).
var panels: Array[ScreenPanel] = []

var _discovery := PacketPeerUDP.new()
var _server := TCPServer.new()
var _tcp: StreamPeerTCP
var _channel: PacketPeerStream
var _device := ""
var _last_heard := 0.0
var _pc_name := ""
## EyeStreamer (the native module's): by name, so this file parses in the headset
## project too (main.gd, synced there, refers to this class).
var _streamer: Variant = null
## The pose id of the frame drawn last (its picture goes out at frame_post_draw).
var _drawn_id := 0
var _tracking_count := 0
var _foveation := Foveation.new()
var _warp_failed := false
var _next_log := 0.0
## Monitor key -> its ScreenStreamer (by name, as _streamer); the panels' keys
## and indices they were started for.
var _screen_streamers: Dictionary = {}
var _screens_for := ""
var _live: Dictionary = {}
var _next_live_check := 0.0
## Keys whose stream the headset shows now (from its tracking).
var _shown: Dictionary = {}
## What the PC plays (31.10.2026), while «Звук ПК в шлеме» is on (HeadsetOptions);
## a SoundStreamer, by name as _streamer. Looked at every SOUND_CHECK_SEC.
var _sound: Variant = null
var _next_sound_check := 0.0
const SOUND_CHECK_SEC := 1.0
const SOUND_RETRY_SEC := 10.0
var _sent_layers: Array = []


## Puts RemoteXR in place of OpenXR; false if it could not start.
func start() -> bool:
	xr.render_size = EYE_SIZE
	XRServer.add_interface(xr)
	if not xr.initialize():
		print("[remote] RemoteXR не поднялся")
		return false
	xr.frame_drawn.connect(_on_frame_drawn)
	RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
	Engine.max_fps = FPS
	get_viewport().texture_mipmap_bias = MIPMAP_BIAS
	_pc_name = OS.get_environment("COMPUTERNAME")
	var error := _discovery.bind(LinkProtocol.REMOTE_DISCOVERY_PORT)
	print("[remote] поиск: порт UDP %d %s" % [LinkProtocol.REMOTE_DISCOVERY_PORT, "слушаю" if error == OK else "занят (%d)" % error])
	error = _server.listen(LinkProtocol.REMOTE_CONTROL_PORT)
	print("[remote] связь: порт TCP %d %s" % [LinkProtocol.REMOTE_CONTROL_PORT, "слушаю" if error == OK else "занят (%d)" % error])
	return true


func connected() -> bool:
	return _channel != null and _device != ""


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	_answer_searches()
	if _server.is_connection_available():
		_accept(now)
	if _channel != null:
		_serve(now)
	_update_screens(now)
	_update_sound(now)
	if now >= _next_log and _streamer != null:
		_next_log = now + 10.0
		var stats: Dictionary = _streamer.get_stats()
		print("[remote] поз за 10 с: %d; глаза: кадров %d, отправлено %d, %.1f МБ, кодирование %.1f мс" % [_tracking_count,
				stats.get("frames_captured", 0), stats.get("frames_sent", 0), stats.get("bytes_sent", 0) / 1e6,
				stats.get("encode_ms", 0.0)])
		_tracking_count = 0


func _exit_tree() -> void:
	_stop_eyes()
	_stop_screens()
	if _sound != null:
		_sound.stop()
		_sound = null
	_foveation.release()
	if _channel != null:
		_channel.put_var({"t": "bye"})
	xr.uninitialize()


func _answer_searches() -> void:
	while _discovery.get_available_packet_count() > 0:
		var packet := _discovery.get_packet()
		if LinkProtocol.ask_version(packet) < 0:
			continue
		_discovery.set_dest_address(_discovery.get_packet_ip(), _discovery.get_packet_port())
		_discovery.put_packet(LinkProtocol.answer_packet(_pc_name, LinkProtocol.REMOTE_CONTROL_PORT))


func _accept(now: float) -> void:
	if _tcp != null:
		_drop("новое подключение")
	_tcp = _server.take_connection()
	_tcp.set_no_delay(true)
	_channel = PacketPeerStream.new()
	_channel.input_buffer_max_size = LinkProtocol.CHANNEL_BUFFER
	_channel.output_buffer_max_size = LinkProtocol.CHANNEL_BUFFER
	_channel.stream_peer = _tcp
	_last_heard = now
	print("[remote] подключился %s" % _tcp.get_connected_host())


func _serve(now: float) -> void:
	_tcp.poll()
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_drop("соединение закрыто")
		return
	var tracking: Dictionary = {}
	while _channel != null and _channel.get_available_packet_count() > 0:
		var message: Variant = _channel.get_var()
		var problem := LinkProtocol.problem(message)
		if problem != "":
			print("[remote] плохое сообщение: ", problem)
			continue
		_last_heard = now
		match message["t"]:
			"hello":
				_device = message["device"]
				print("[remote] шлем «%s» поздоровался" % _device)
				_start_eyes()
				headset_joined.emit()
			"tracking":
				tracking = message
			"ping":
				_send(LinkProtocol.pong(message["time"]))
			"bye":
				_drop("шлем попрощался")
	# Only the newest poses matter.
	if not tracking.is_empty():
		xr.apply(tracking)
		_shown.clear()
		for key: Variant in tracking.get("shown", []):
			_shown[key] = true
		_tracking_count += 1
	if _channel != null and now - _last_heard > LinkProtocol.LINK_TIMEOUT_SEC:
		_drop("шлем молчит")


func _send(message: Dictionary) -> void:
	if _channel != null and _channel.put_var(message) != OK:
		_drop("не отправилось")


func _drop(why: String) -> void:
	print("[remote] отключился: ", why)
	if _tcp != null:
		_tcp.disconnect_from_host()
	_tcp = null
	_channel = null
	var was_there := _device != ""
	_device = ""
	xr.head_tracked = false
	_stop_eyes()
	_stop_screens()
	if was_there:
		headset_left.emit()


func _start_eyes() -> void:
	_stop_eyes()
	_streamer = ClassDB.instantiate(&"EyeStreamer")
	# The warp writes the sent size itself; the stream takes it as is.
	if not _streamer.start(SENT_EYE_SIZE.x, SENT_EYE_SIZE.y + MASK_ROWS, SENT_EYE_SIZE.x, SENT_EYE_SIZE.y + MASK_ROWS,
			LinkProtocol.REMOTE_EYES_PORT, BITRATE_KBPS, FPS):
		print("[remote] поток глаз не запустился: ", _streamer.get_last_error())
		_streamer = null
		return
	print("[remote] поток глаз: рисую %dx%d, шлю %dx%d с фовеацией %.2f, HEVC %d кбит/с, %d к/с" % [EYE_SIZE.x * 2,
			EYE_SIZE.y, SENT_EYE_SIZE.x * 2, SENT_EYE_SIZE.y, Foveation.STRENGTH, BITRATE_KBPS, FPS])
	_send({"t": "eyes", "port": LinkProtocol.REMOTE_EYES_PORT, "w": SENT_EYE_SIZE.x * 2,
			"h": SENT_EYE_SIZE.y + MASK_ROWS, "mask": MASK_ROWS, "foveation": Foveation.STRENGTH})


func _stop_eyes() -> void:
	if _streamer != null:
		_streamer.stop()
		_streamer = null


## On the rendering thread, inside the frame: the eyes into the stream's texture.
func _on_frame_drawn(texture: RID, _head: Transform3D, pose_id: int) -> void:
	if _streamer == null:
		return
	if _foveation.warp_eyes(texture, _streamer.get_target(), SENT_EYE_SIZE, MASK_ROWS):
		_streamer.mark_written()
		_drawn_id = pose_id
	elif not _warp_failed:
		_warp_failed = true
		print("[remote] фовеация не работает — картинки не будет")


## After the frame went to the GPU: the stream may take it once the GPU is done.
func _on_frame_post_draw() -> void:
	if _streamer != null:
		_streamer.submit(_drawn_id)


## Every frame while the headset is there: the screens' streams, which of them
## are live, their layers (tagged with the pose this frame is drawn with: the
## headset moves them together with the picture whose holes match) and the holes.
func _update_screens(now: float) -> void:
	if not connected():
		for panel in panels:
			panel.set_remote_hole(false)
		return
	var screens_for := ""
	for panel in panels:
		screens_for += "%s=%d;" % [panel.monitor_key, panel.monitor_index]
	if screens_for != _screens_for:
		_start_screens()
		_screens_for = screens_for
	if now >= _next_live_check:
		_next_live_check = now + LIVE_CHECK_SEC
		_choose_live()
	var layers: Array = []
	for panel in panels:
		var key := panel.monitor_key
		var live := _live.has(key) and _screen_streamers.has(key)
		if live:
			var described := panel.remote_layer()
			if not described.is_empty():
				layers.append(described)
		panel.set_remote_hole(live and _shown.has(key))
	if layers != _sent_layers:
		_sent_layers = layers
		_send({"t": "layers", "pose": xr.pose_id, "layers": layers})


func _update_sound(now: float) -> void:
	if now < _next_sound_check:
		return
	_next_sound_check = now + SOUND_CHECK_SEC
	var wanted := HeadsetOptions.current == null or HeadsetOptions.current.pc_sound != 0
	if wanted and _sound == null:
		_sound = ClassDB.instantiate(&"SoundStreamer")
		if _sound.start(LinkProtocol.REMOTE_SOUND_PORT):
			print("[sound] звук ПК: порт TCP %d, %s" % [LinkProtocol.REMOTE_SOUND_PORT, _sound.get_stats()["device"]])
		else:
			print("[sound] звук ПК не запустился: %s" % _sound.get_last_error())
			_sound = null
			_next_sound_check = now + SOUND_RETRY_SEC
	elif not wanted and _sound != null:
		print("[sound] звук ПК выключен")
		_sound.stop()
		_sound = null


func _choose_live() -> void:
	var ranked: Array = []
	for panel in panels:
		if panel.remote_layer().is_empty() or not _screen_streamers.has(panel.monitor_key):
			continue
		var origin := panel.layer.get_parent() as Node3D
		var head := origin.global_transform * xr.head
		var angle := (-head.basis.z).angle_to(panel.placement.transform.origin - head.origin)
		if _live.has(panel.monitor_key):
			angle -= LIVE_STICKINESS
		ranked.append([angle, panel.monitor_key])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	_live.clear()
	for i in mini(LIVE_SCREENS, ranked.size()):
		_live[ranked[i][1]] = true


func _start_screens() -> void:
	_stop_screens()
	var videos: Array = []
	for panel in panels:
		var streamer: Variant = ClassDB.instantiate(&"ScreenStreamer")
		var port := LinkProtocol.REMOTE_SCREENS_PORT + panel.monitor_index
		if not streamer.start(panel.monitor_index, port, SCREEN_KBPS, SCREEN_FPS):
			print("[remote] поток экрана %s не запустился: %s" % [panel.monitor_name, streamer.get_last_error()])
			continue
		_screen_streamers[panel.monitor_key] = streamer
		var stats: Dictionary = streamer.get_stats()
		videos.append(LinkProtocol.video(port, panel.monitor_key, stats["size"]))
	print("[remote] потоков экранов %d из %d, %d кбит/с, %d к/с" % [_screen_streamers.size(), panels.size(),
			SCREEN_KBPS, SCREEN_FPS])
	_send(LinkProtocol.videos_message(videos))
	_sent_layers = []


func _stop_screens() -> void:
	for streamer: Variant in _screen_streamers.values():
		streamer.stop()
	_screen_streamers.clear()
	_screens_for = ""
	_live.clear()
	_shown.clear()
