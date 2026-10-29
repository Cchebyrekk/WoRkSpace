extends Node
## The PC side of the own link (slice o2): no VR here, the headset draws. It
## answers the headset's search, keeps one control channel and tells the
## headset which monitors there are. While a headset is connected every monitor
## is streamed (ScreenStreamer, slices o3, o4) and the headset's pointer moves
## the real cursor and presses its buttons. Slice o5b: the headset's world runs
## the PC's services here — the Windows layout (DisplayTopology), the driver
## (VddControl, its settings file), recording from the PC keyboard — only the
## calls LinkProtocol.CALLS lists; their signals go back as events. It also
## tells the headset about the agent and the secure desktop, whose picture it
## sends while it is up. Run: scenes/link_server.tscn
## (`--headless --xr-mode off --path . res://scenes/link_server.tscn`).

## How often the monitor list is looked at for changes.
const MONITORS_CHECK_SEC := 2.0
const VIDEO_BITRATE_KBPS := 12000
const VIDEO_FPS := 60
## How often a running stream reports into the log.
const VIDEO_LOG_SEC := 10.0

var _discovery := PacketPeerUDP.new()
var _server := TCPServer.new()
var _tcp: StreamPeerTCP
var _channel: PacketPeerStream
var _device := ""
var _last_heard := 0.0
var _monitors: Array = []
var _monitors_signature := ""
var _next_monitors_check := 0.0
var _pc_name := ""
## The monitor list changed and has not been passed on yet.
var _monitors_unsettled := false
## A VDD answer that came while no headset was there: the next one gets it (a
## driver restart can take the link down while the helper is still working).
var _vdd_answer_waiting: Array = []
var _next_unknown_log := 0.0
## The USB way (slice o5c): while no headset is connected, every few seconds a
## thread asks adb for headsets on the cable and points their ports here with
## `adb reverse` (the headset then finds the PC at 127.0.0.1).
const ADB_CHECK_SEC := 5.0
## Control, then a video port for each of up to 16 monitors.
const REVERSED_PORTS := 17
var _adb_path := ""
## Thumbnails (slice o5c): while the headset shows the plane of groups, every
## THUMB_SEC each stream makes a small picture, sent as JPEG.
const THUMB_SEC := 0.5
const THUMB_WIDTH := 480
const THUMB_JPEG_QUALITY := 0.7
var _thumbs_on := false
var _next_thumbs := 0.0
var _adb_thread: Thread
var _next_adb := 0.0
## Monitor key -> its ScreenStreamer.
var _streamers: Dictionary = {}
var _next_video_log := 0.0
## Monitor key -> its stats at the last log line.
var _video_logged: Dictionary = {}
## Mouse buttons the headset holds down: released when it goes away.
var _buttons_down: Dictionary = {}
## Keys the headset holds down (Ctrl for zoom): let go when it goes away.
var _keys_down: Dictionary = {}
## Input to Windows goes through here, off the main loop (slice o5c).
var _input := InputWorker.new()
var _topology: DisplayTopology
var _vdd: VddControl
var _secure := SecureDesktop.new()
## The last PC state told to the headset (a change is sent).
var _state_sent: Dictionary = {}
## While the headset records from the PC keyboard: what it was last told.
var _recording := false
var _recording_sent: Dictionary = {}
var _next_secure_frame := 0.0
## Pictures of the secure desktop sent while it is up (a line for the first, and
## for none after a few tries: 29.10.2026 the prompt never showed in the headset).
var _secure_sent := 0
var _secure_tries := 0
## The secure desktop's picture goes at most this often (JPEG, a few hundred KB).
const SECURE_FRAME_SEC := 0.25
const SECURE_JPEG_QUALITY := 0.8


func _ready() -> void:
	# Nothing to draw: no reason to spin the CPU.
	Engine.max_fps = 60
	_pc_name = OS.get_environment("COMPUTERNAME")
	if _pc_name == "":
		_pc_name = "ПК"
	var error := _discovery.bind(LinkProtocol.DISCOVERY_PORT)
	print("[link] поиск: порт UDP %d %s" % [LinkProtocol.DISCOVERY_PORT, "слушаю" if error == OK else "занят (%d)" % error])
	# C:/Android/Sdk: the SDK installed from the Claude app (29.10.2026) had landed in
	# its MSIX package's private AppData, seen by nothing started outside it — the
	# server started by the watchdog found no adb; a copy is there.
	for sdk: String in [OS.get_environment("ANDROID_HOME"), "C:/Android/Sdk", OS.get_environment("LOCALAPPDATA").path_join("Android/Sdk")]:
		if sdk != "" and FileAccess.file_exists(sdk.path_join("platform-tools/adb.exe")):
			_adb_path = sdk.path_join("platform-tools/adb.exe")
			break
	print("[link] кабель: %s" % ("adb найден, порты пробрасываются сами" if _adb_path != "" else "adb не найден — только Wi-Fi"))
	_topology = DisplayTopology.new()
	add_child(_topology)
	_topology.finished.connect(func(ok: bool, code: String, detail: String) -> void: _event("topology", "finished", [ok, code, detail]))
	_topology.modes_listed.connect(func(monitors: Array) -> void: _event("topology", "modes_listed", [monitors]))
	_topology.instances_counted.connect(func(working: int, total: int) -> void: _event("topology", "instances_counted", [working, total]))
	_topology.idle.connect(func() -> void: _event("topology", "idle", []))
	_vdd = VddControl.new()
	add_child(_vdd)
	_vdd.finished.connect(_on_vdd_finished)
	error = _server.listen(LinkProtocol.CONTROL_PORT)
	print("[link] связь: порт TCP %d %s" % [LinkProtocol.CONTROL_PORT, "слушаю" if error == OK else "занят (%d)" % error])
	_refresh_monitors()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	# Reads the SYSTEM agent's status messages, as the module wants every frame:
	# left unread they fill its pipe, the agent stops taking input and the next
	# cursor move blocks the server for good (it hung so with a real headset, o4).
	# The agent's status is read on the input thread (InputWorker), every 16 ms.
	var secure := _input.secure_desktop_active()
	_answer_searches()
	if _server.is_connection_available():
		_accept(now)
	if _channel != null:
		_serve(now)
	if now >= _next_monitors_check:
		_next_monitors_check = now + MONITORS_CHECK_SEC
		# The cursor uses the new list at once; the headset and the streams only once
		# it has stayed the same for a check: while the driver restarts it changes
		# again and again, and restarting every stream each time stalled the server
		# until the headset dropped the link (26.10.2026, «Применить»).
		if _refresh_monitors():
			_monitors_unsettled = true
		elif _monitors_unsettled:
			_monitors_unsettled = false
			if _connected():
				print("[link] мониторы изменились: %d" % _monitors.size())
				_send(LinkProtocol.monitors_message(_monitors))
				# Indices and sizes may have moved: the streams start over.
				_start_videos()
	if not _streamers.is_empty():
		_watch_videos(now)
	if _adb_path != "" and not _connected() and now >= _next_adb and (_adb_thread == null or not _adb_thread.is_alive()):
		_next_adb = now + ADB_CHECK_SEC
		if _adb_thread != null:
			_adb_thread.wait_to_finish()
		_adb_thread = Thread.new()
		_adb_thread.start(_reverse_over_usb)
	if _connected() and _thumbs_on:
		_send_thumbs(now)
	if _connected():
		_send_state(secure)
		_send_recording()
		if not secure:
			_secure_sent = 0
			_secure_tries = 0
		if secure and now >= _next_secure_frame:
			_next_secure_frame = now + SECURE_FRAME_SEC
			_send_secure_frame()


func _answer_searches() -> void:
	while _discovery.get_available_packet_count() > 0:
		var packet := _discovery.get_packet()
		var version := LinkProtocol.ask_version(packet)
		if version < 0:
			continue
		var ip := _discovery.get_packet_ip()
		var port := _discovery.get_packet_port()
		_discovery.set_dest_address(ip, port)
		_discovery.put_packet(LinkProtocol.answer_packet(_pc_name, LinkProtocol.CONTROL_PORT))
		print("[link] шлем ищет ПК: %s:%d, версия %d" % [ip, port, version])


## A new headset takes the place of the old one: there is only one user.
func _accept(now: float) -> void:
	if _tcp != null:
		print("[link] новое подключение, старое закрываю")
		_drop("заменено")
	_tcp = _server.take_connection()
	_tcp.set_no_delay(true)
	_channel = PacketPeerStream.new()
	_channel.input_buffer_max_size = LinkProtocol.CHANNEL_BUFFER
	_channel.output_buffer_max_size = LinkProtocol.CHANNEL_BUFFER
	_channel.stream_peer = _tcp
	_last_heard = now
	print("[link] подключился %s:%d" % [_tcp.get_connected_host(), _tcp.get_connected_port()])


func _serve(now: float) -> void:
	_tcp.poll()
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_drop("соединение закрыто")
		return
	while _channel != null and _channel.get_available_packet_count() > 0:
		var message: Variant = _channel.get_var()
		var problem := LinkProtocol.problem(message)
		if problem != "":
			print("[link] плохое сообщение: %s" % problem)
			if message is Dictionary and message.get("t") == "hello":
				_drop("несовместимая версия")
			continue
		_last_heard = now
		match message["t"]:
			"hello":
				_device = message["device"]
				print("[link] шлем «%s» поздоровался; мониторов %d" % [_device, _monitors.size()])
				_send(LinkProtocol.welcome(_pc_name, _monitors))
				_state_sent = {}
				# A fresh reader: its first frame goes to the new headset even if the
				# secure desktop has not changed since.
				_secure = SecureDesktop.new()
				_send_vdd_config()
				if not _vdd_answer_waiting.is_empty():
					_event("vdd", "finished", _vdd_answer_waiting)
					_vdd_answer_waiting = []
				var settings := FileAccess.get_file_as_string("user://settings.cfg")
				if settings != "":
					_send(LinkProtocol.settings_message(settings))
				_start_videos()
			"pointer":
				_move_pointer(message["key"], Vector2i(message["x"], message["y"]))
			"button":
				_input.push(message)
				if message["down"]:
					_buttons_down[message["b"]] = true
				else:
					_buttons_down.erase(message["b"])
			"call":
				_run_call(message["target"], message["op"], message["args"])
			"wheel", "keys":
				_input.push(message)
			"key":
				_input.push(message)
				if message["down"]:
					_keys_down[message["vk"]] = true
				else:
					_keys_down.erase(message["vk"])
			"ping":
				_send(LinkProtocol.pong(message["time"]))
			"bye":
				_drop("шлем попрощался")
	if _channel != null and now - _last_heard > LinkProtocol.LINK_TIMEOUT_SEC:
		_drop("шлем молчит %.0f с" % LinkProtocol.LINK_TIMEOUT_SEC)


func _connected() -> bool:
	return _channel != null and _device != ""


func _send(message: Dictionary) -> void:
	# A send can fail and drop the link while a list of messages is going out.
	if _channel == null:
		return
	var error := _channel.put_var(message)
	if error != OK:
		_drop("не отправилось (%d)" % error)


func _drop(why: String) -> void:
	print("[link] отключился%s: %s" % [" «%s»" % _device if _device != "" else "", why])
	if _tcp != null:
		_tcp.disconnect_from_host()
	_tcp = null
	_channel = null
	_device = ""
	_thumbs_on = false
	for b: int in _buttons_down:
		_input.push(LinkProtocol.button(b, false))
	_buttons_down.clear()
	for vk: int in _keys_down:
		_input.push(LinkProtocol.key(vk, false))
	_keys_down.clear()
	_stop_videos()
	if _recording:
		MouseInput.stop_key_recording()
		_recording = false


## On the adb thread: each headset on USB gets the link's ports reversed to this
## PC, unless they already are (`adb reverse --list`).
func _reverse_over_usb() -> void:
	var output := []
	if OS.execute(_adb_path, ["devices"], output, true) != 0 or output.is_empty():
		return
	for line: String in str(output[0]).split("\n"):
		var parts := line.strip_edges().split("\t")
		if parts.size() != 2 or parts[1] != "device" or parts[0].contains(":"):
			continue
		var serial := parts[0]
		var listed := []
		OS.execute(_adb_path, ["-s", serial, "reverse", "--list"], listed, true)
		if not listed.is_empty() and str(listed[0]).contains("tcp:%d" % LinkProtocol.CONTROL_PORT):
			continue
		for i in REVERSED_PORTS:
			var port := LinkProtocol.CONTROL_PORT + i
			OS.execute(_adb_path, ["-s", serial, "reverse", "tcp:%d" % port, "tcp:%d" % port], [], true)
		print("[link] кабель: порты %d–%d проброшены на шлем %s" % [LinkProtocol.CONTROL_PORT,
				LinkProtocol.CONTROL_PORT + REVERSED_PORTS - 1, serial])


## Runs what the headset asked for; LinkProtocol.problem has already checked
## that it is on the list.
func _run_call(target: String, op: String, args: Array) -> void:
	print("[link] шлем просит %s.%s" % [target, op])
	match target:
		"topology":
			_topology.callv(op, args)
		"vdd":
			_vdd.callv(op, args)
		"vdd_config":
			var wanted: Array[Vector2i] = []
			for size: Variant in (args[0] if not args.is_empty() and args[0] is Array else []):
				if size is Vector2i:
					wanted.append(size)
			var problem := VddConfig.write(wanted)
			_event("vdd_config", "written", [problem])
			_send_vdd_config()
		"thumbs":
			_thumbs_on = op == "start"
			_next_thumbs = 0.0
		"keyboard":
			match op:
				"start_key_recording":
					_recording = MouseInput.start_key_recording()
				"start_text_recording":
					_recording = MouseInput.start_text_recording()
				"stop_key_recording":
					MouseInput.stop_key_recording()
					_recording = false
			_recording_sent = {}
			_event("keyboard", "started", [_recording])


## Sends the pictures the streams have made and asks for the next ones.
func _send_thumbs(now: float) -> void:
	for key: String in _streamers:
		var image: Image = _streamers[key].get_snapshot()
		if image != null:
			_send(LinkProtocol.thumb(key, image.save_jpg_to_buffer(THUMB_JPEG_QUALITY)))
	if now >= _next_thumbs:
		_next_thumbs = now + THUMB_SEC
		for key: String in _streamers:
			_streamers[key].request_snapshot(THUMB_WIDTH)


func _event(target: String, name: String, args: Array) -> void:
	if _connected():
		_send(LinkProtocol.event(target, name, args))


func _on_vdd_finished(ok: bool, message: String) -> void:
	if not _connected():
		_vdd_answer_waiting = [ok, message]
		print("[link] ответ помощника VDD придержан до подключения шлема")
		return
	_event("vdd", "finished", [ok, message])
	# The helper may have changed the driver's list: the headset gets it again.
	_send_vdd_config()


func _send_vdd_config() -> void:
	if _connected():
		_send(LinkProtocol.vdd_config(FileAccess.get_file_as_string(VddConfig.PATH) if FileAccess.file_exists(VddConfig.PATH) else ""))


func _send_state(secure: bool) -> void:
	var state := {"agent": _input.agent_connected(), "secure": secure, "vdd_installed": _vdd.is_installed()}
	if state != _state_sent:
		_state_sent = state
		_send(LinkProtocol.pc_state(state["agent"], state["secure"], state["vdd_installed"]))


## What the keyboard recording has so far, when it changed.
func _send_recording() -> void:
	if not _recording:
		return
	var now := {"keys": MouseInput.get_recorded_keys(), "seen": MouseInput.get_key_recording_seen(),
			"text": MouseInput.get_recorded_text(), "end": MouseInput.get_text_recording_end()}
	if now != _recording_sent:
		_recording_sent = now
		_event("keyboard", "recording", [now])


func _send_secure_frame() -> void:
	_secure_tries += 1
	var image: Image = _secure.get_image() if _secure.update() else null
	if image == null:
		if _secure_sent == 0 and _secure_tries == 10:
			print("[link] защищённый стол: картинки от агента нет")
		return
	if _secure_sent == 0:
		print("[link] защищённый стол: шлю картинку %s" % image.get_size())
	_secure_sent += 1
	_send(LinkProtocol.secure_frame(image.save_jpg_to_buffer(SECURE_JPEG_QUALITY), _secure.get_frame_origin(), _secure.get_frame_size(),
			_secure.get_frame_scale()))


## The pointer is in pixels of one monitor; the cursor wants the virtual desktop.
func _move_pointer(key: String, at: Vector2i) -> void:
	for monitor: Dictionary in _monitors:
		if monitor["key"] == key:
			var inside := at.clamp(Vector2i.ZERO, Vector2i(monitor["w"] - 1, monitor["h"] - 1))
			_input.push({"t": "pointer", "at": Vector2i(monitor["x"], monitor["y"]) + inside})
			return
	var now := Time.get_ticks_msec() / 1000.0
	if now >= _next_unknown_log:
		_next_unknown_log = now + 5.0
		print("[input] курсор на неизвестном мониторе %s — пропущен" % key)


## Streams every monitor, each on VIDEO_PORT + its index, and tells the headset.
func _start_videos() -> void:
	_stop_videos()
	if _channel == null:
		return
	var videos: Array = []
	for i in _monitors.size():
		var monitor: Dictionary = _monitors[i]
		var streamer := ScreenStreamer.new()
		var port := LinkProtocol.VIDEO_PORT + i
		if not streamer.start(i, port, VIDEO_BITRATE_KBPS, VIDEO_FPS):
			print("[video] %s не запустился: %s" % [monitor["name"], streamer.get_last_error()])
			continue
		var stats := streamer.get_stats()
		_streamers[monitor["key"]] = streamer
		_video_logged[monitor["key"]] = stats
		videos.append(LinkProtocol.video(port, monitor["key"], stats["size"]))
	_next_video_log = Time.get_ticks_msec() / 1000.0 + VIDEO_LOG_SEC
	if not _streamers.is_empty():
		var first: ScreenStreamer = _streamers.values()[0]
		print("[video] потоков %d из %d: %s, %d кбит/с, %d к/с" % [_streamers.size(), _monitors.size(),
				first.get_stats()["encoder"], VIDEO_BITRATE_KBPS, VIDEO_FPS])
	_send(LinkProtocol.videos_message(videos))


func _stop_videos() -> void:
	if _streamers.is_empty():
		return
	for streamer: ScreenStreamer in _streamers.values():
		streamer.stop()
	_streamers.clear()
	_video_logged.clear()
	print("[video] остановлены")


## One log line for all streams: what the headset gets, summed up.
func _watch_videos(now: float) -> void:
	for key: String in _streamers.keys():
		var streamer: ScreenStreamer = _streamers[key]
		if not streamer.is_running():
			print("[video] %s остановился сам: %s" % [key, streamer.get_stats().get("error", "")])
			_streamers.erase(key)
	if now < _next_video_log:
		return
	var seconds := VIDEO_LOG_SEC + now - _next_video_log
	_next_video_log = now + VIDEO_LOG_SEC
	var sent := 0
	var bytes := 0
	var watched := 0
	var slowest := 0.0
	for key: String in _streamers:
		var stats: Dictionary = _streamers[key].get_stats()
		var before: Dictionary = _video_logged.get(key, stats)
		sent += stats["frames_sent"] - before["frames_sent"]
		bytes += stats["bytes_sent"] - before["bytes_sent"]
		watched += 1 if stats["client"] != "" else 0
		slowest = maxf(slowest, stats["encode_ms"])
		_video_logged[key] = stats
	print("[video] шлем смотрит %d из %d: отправлено %.0f к/с, %.1f Мбит/с, кодирование до %.1f мс" % [watched,
			_streamers.size(), sent / seconds, bytes * 8.0 / seconds / 1e6, slowest])


## True if the list differs from the one the headset was last told about.
func _refresh_monitors() -> bool:
	var list: Array = []
	for entry: Dictionary in ScreenCapture.list_monitors():
		list.append(LinkProtocol.monitor(ScreenPanel.key_of(entry["path"]), entry["name"],
				entry["position"], entry["size"], entry["primary"]))
	var signature := str(list)
	if signature == _monitors_signature:
		return false
	_monitors = list
	_monitors_signature = signature
	return true


func _exit_tree() -> void:
	if _channel != null:
		_channel.put_var({"t": "bye"})
		_drop("сервер закрывается")
	# After the drop: the buttons and keys it lets go are still delivered.
	_input.stop()
	if _adb_thread != null:
		_adb_thread.wait_to_finish()
	_server.stop()
	_discovery.close()
