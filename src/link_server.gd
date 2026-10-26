extends Node
## The PC side of the own link (slice o2): no VR here, the headset draws. It
## answers the headset's search, keeps one control channel and tells the
## headset which monitors there are. While a headset is connected every monitor
## is streamed (ScreenStreamer, slices o3, o4) and the headset's pointer moves
## the real cursor and presses its buttons. Run: scenes/link_server.tscn
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
## Monitor key -> its ScreenStreamer.
var _streamers: Dictionary = {}
var _next_video_log := 0.0
## Monitor key -> its stats at the last log line.
var _video_logged: Dictionary = {}
## Mouse buttons the headset holds down: released when it goes away.
var _buttons_down: Dictionary = {}
## Keys the headset holds down (Ctrl for zoom): let go when it goes away.
var _keys_down: Dictionary = {}


func _ready() -> void:
	# Nothing to draw: no reason to spin the CPU.
	Engine.max_fps = 60
	_pc_name = OS.get_environment("COMPUTERNAME")
	if _pc_name == "":
		_pc_name = "ПК"
	var error := _discovery.bind(LinkProtocol.DISCOVERY_PORT)
	print("[link] поиск: порт UDP %d %s" % [LinkProtocol.DISCOVERY_PORT, "слушаю" if error == OK else "занят (%d)" % error])
	error = _server.listen(LinkProtocol.CONTROL_PORT)
	print("[link] связь: порт TCP %d %s" % [LinkProtocol.CONTROL_PORT, "слушаю" if error == OK else "занят (%d)" % error])
	_refresh_monitors()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	# Reads the SYSTEM agent's status messages, as the module wants every frame:
	# left unread they fill its pipe, the agent stops taking input and the next
	# cursor move blocks the server for good (it hung so with a real headset, o4).
	MouseInput.is_secure_desktop_active()
	_answer_searches()
	if _server.is_connection_available():
		_accept(now)
	if _channel != null:
		_serve(now)
	if now >= _next_monitors_check:
		_next_monitors_check = now + MONITORS_CHECK_SEC
		if _refresh_monitors() and _connected():
			print("[link] мониторы изменились: %d" % _monitors.size())
			_send(LinkProtocol.monitors_message(_monitors))
			# Indices and sizes may have moved: the stream starts over.
			_start_videos()
	if not _streamers.is_empty():
		_watch_videos(now)


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
				var settings := FileAccess.get_file_as_string("user://settings.cfg")
				if settings != "":
					_send(LinkProtocol.settings_message(settings))
				_start_videos()
			"pointer":
				_move_pointer(message["key"], Vector2i(message["x"], message["y"]))
			"button":
				MouseInput.set_button(message["b"], message["down"])
				if message["down"]:
					_buttons_down[message["b"]] = true
				else:
					_buttons_down.erase(message["b"])
			"wheel":
				if message["up"] != 0:
					MouseInput.scroll(message["up"])
				if message["right"] != 0:
					MouseInput.scroll_horizontal(message["right"])
			"keys":
				MouseInput.press_keys(PackedInt32Array(message["keys"]))
			"key":
				MouseInput.set_key(message["vk"], message["down"])
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
	for b: int in _buttons_down:
		MouseInput.set_button(b, false)
	_buttons_down.clear()
	for vk: int in _keys_down:
		MouseInput.set_key(vk, false)
	_keys_down.clear()
	_stop_videos()


## The pointer is in pixels of one monitor; the cursor wants the virtual desktop.
func _move_pointer(key: String, at: Vector2i) -> void:
	for monitor: Dictionary in _monitors:
		if monitor["key"] == key:
			var inside := at.clamp(Vector2i.ZERO, Vector2i(monitor["w"] - 1, monitor["h"] - 1))
			MouseInput.move_to(Vector2i(monitor["x"], monitor["y"]) + inside)
			return


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
	_server.stop()
	_discovery.close()
