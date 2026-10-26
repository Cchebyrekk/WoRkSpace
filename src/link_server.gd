extends Node
## The PC side of the own link (slice o2): no VR here, the headset draws. It
## answers the headset's search, keeps one control channel and tells the
## headset which monitors there are. Slice o3: streams the primary monitor
## (ScreenStreamer) while a headset is connected. Run: scenes/link_server.tscn
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
var _streamer: ScreenStreamer
var _video_key := ""
var _next_video_log := 0.0
var _video_logged: Dictionary = {}


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
			_start_video()
	if _streamer != null:
		_watch_video(now)


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
				_start_video()
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
	_stop_video()


## Streams the primary monitor (the first one if none is primary) and tells the headset.
func _start_video() -> void:
	_stop_video()
	if _channel == null or _monitors.is_empty():
		return
	var index := 0
	for i in _monitors.size():
		if _monitors[i]["primary"]:
			index = i
			break
	_streamer = ScreenStreamer.new()
	if not _streamer.start(index, LinkProtocol.VIDEO_PORT, VIDEO_BITRATE_KBPS, VIDEO_FPS):
		print("[video] не запустился: %s" % _streamer.get_last_error())
		_streamer = null
		return
	var stats := _streamer.get_stats()
	_video_key = _monitors[index]["key"]
	_video_logged = stats
	_next_video_log = Time.get_ticks_msec() / 1000.0 + VIDEO_LOG_SEC
	print("[video] %s: %s %s, %d кбит/с, %d к/с" % [_monitors[index]["name"], stats["encoder"], stats["size"],
			VIDEO_BITRATE_KBPS, VIDEO_FPS])
	_send(LinkProtocol.video(LinkProtocol.VIDEO_PORT, _video_key, stats["size"]))


func _stop_video() -> void:
	if _streamer != null:
		_streamer.stop()
		_streamer = null
		print("[video] остановлен")
	_video_key = ""


func _watch_video(now: float) -> void:
	if not _streamer.is_running():
		print("[video] остановился сам: %s" % _streamer.get_stats().get("error", ""))
		_streamer = null
		return
	if now < _next_video_log:
		return
	var stats := _streamer.get_stats()
	var seconds := VIDEO_LOG_SEC + now - _next_video_log
	_next_video_log = now + VIDEO_LOG_SEC
	print("[video] шлем %s: снято %.0f к/с, отправлено %.0f к/с, %.1f Мбит/с, кодирование %.1f мс" % [
			stats["client"] if stats["client"] != "" else "не подключён",
			(stats["frames_captured"] - _video_logged["frames_captured"]) / seconds,
			(stats["frames_sent"] - _video_logged["frames_sent"]) / seconds,
			(stats["bytes_sent"] - _video_logged["bytes_sent"]) * 8.0 / seconds / 1e6, stats["encode_ms"]])
	_video_logged = stats


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
