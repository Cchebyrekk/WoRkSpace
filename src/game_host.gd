extends Node
var _hand_probe := PacketPeerUDP.new()
var _hand_state := ""
## Slice q1, PC VR games over the own link (no Quest Link): the PC side next to
## the WoRkPlace SteamVR driver (native/steamvr_driver). To the headset it looks
## like «ПК рисует» (RemoteHost): it answers the search on the same ports, holds
## the control channel and takes the headset's poses (player.gd); but what the
## headset sees is drawn by SteamVR and the game. The poses go to the driver
## through GameBridge (a shared mapping); the driver streams the compositor's
## frames itself, on the eyes' port, tagged with the pose ids, and says here how
## big they are — this tells the headset. The PC's sound goes as in the other
## modes. Runs without a window: scenes/game_host.tscn.

## How often the driver's state is looked at (SteamVR started, stream up).
const DRIVER_CHECK_SEC := 0.5
const SOUND_RETRY_SEC := 10.0

var _discovery := PacketPeerUDP.new()
var _server := TCPServer.new()
var _tcp: StreamPeerTCP
var _channel: PacketPeerStream
var _device := ""
var _last_heard := 0.0
var _pc_name := ""
## GameBridge and SoundStreamer (the native module's), by name: the script parses without it.
var _bridge: Variant = null
var _sound: Variant = null
var _next_sound_try := 0.0
var _next_driver_check := 0.0
## The eyes' stream told to the headset ("" none): "port:w:h".
var _eyes_told := ""
var _driver_alive := false
var _tracking_count := 0
var _next_log := 0.0
var _driver_wait_since := -1.0
var _had_vr_app := false
var _app_closed_since := -1.0
var _leaving := false
var _profile := 1


func _ready() -> void:
	_pc_name = OS.get_environment("COMPUTERNAME")
	_bridge = ClassDB.instantiate(&"GameBridge")
	if _bridge == null or not _bridge.open():
		print("[games] нет связи с драйвером SteamVR: ", "" if _bridge == null else _bridge.get_last_error())
	var config := ConfigFile.new()
	config.load("user://settings.cfg")
	var saved_profile := 0 if int(config.get_value("headset", "game_queue_frames", 3)) == 6 else 1
	_profile = clampi(int(config.get_value("headset", "game_ab_profile", saved_profile)), 0, 1)
	var error := _discovery.bind(LinkProtocol.REMOTE_DISCOVERY_PORT)
	print("[games] поиск: порт UDP %d %s" % [LinkProtocol.REMOTE_DISCOVERY_PORT, "слушаю" if error == OK else "занят (%d)" % error])
	error = _server.listen(LinkProtocol.REMOTE_CONTROL_PORT)
	print("[games] связь: порт TCP %d %s" % [LinkProtocol.REMOTE_CONTROL_PORT, "слушаю" if error == OK else "занят (%d)" % error])


func _process(_delta: float) -> void:
	if _leaving:
		return
	var now := Time.get_ticks_msec() / 1000.0
	_answer_searches()
	if _server.is_connection_available():
		_accept(now)
	if _channel != null:
		_serve(now)
	if now >= _next_driver_check:
		_next_driver_check = now + DRIVER_CHECK_SEC
		_check_driver()
		var driver: Dictionary = _bridge.get_driver() if _bridge != null else {}
		if driver.get("scene_pid", 0) != 0:
			_had_vr_app = true
			_app_closed_since = -1.0
		elif _had_vr_app:
			if _app_closed_since < 0:
				_app_closed_since = now
			elif now - _app_closed_since > 3.0:
				print("[games] VR-приложение закрыто; возвращаю предыдущий режим")
				_leave_games()
				return
		if not _driver_alive:
			if _driver_wait_since < 0.0:
				_driver_wait_since = now
			elif now - _driver_wait_since > 45.0:
				print("[games] драйвер WoRkPlace не появился за 45 с; возвращаю рабочий мир")
				_leave_games()
				return
		else:
			_driver_wait_since = -1.0
	_update_sound(now)
	if now >= _next_log and _device != "":
		_next_log = now + 10.0
		var driver: Dictionary = _bridge.get_driver() if _bridge != null else {}
		print("[games] поз за 10 с: %d; SteamVR %s, кадров отдано %d" % [_tracking_count,
				"работает" if driver.get("alive", false) else "не запущен", driver.get("frames", 0)])
		_tracking_count = 0


func _exit_tree() -> void:
	if _sound != null:
		_sound.stop()
		_sound = null
	if _bridge != null:
		_bridge.set_headset(false)
	if _channel != null:
		_channel.put_var({"t": "bye"})


func connected() -> bool:
	return _channel != null and _device != ""


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
	print("[games] подключился %s" % _tcp.get_connected_host())


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
			print("[games] плохое сообщение: ", problem)
			continue
		_last_heard = now
		match message["t"]:
			"hello":
				_device = message["device"]
				_eyes_told = ""
				print("[games] шлем «%s» поздоровался" % _device)
				var config := ConfigFile.new()
				config.load("user://settings.cfg")
				var ray := {}
				for key: String in config.get_section_keys("ray"):
					ray[key] = config.get_value("ray", key)
				_send({"t": "games", "fov_percent": clampf(float(config.get_value("headset", "game_fov_percent", 0.0)), 0.0, 100.0), "ray": ray,
					"buffer_frames": clampi(int(config.get_value("headset", "game_buffer_frames", 1)), 0, 2), "ab_profile": _profile})
			"game_profile":
				_profile = int(message["profile"])
				_bridge.set_game_profile(_profile)
				var config := ConfigFile.new()
				config.load("user://settings.cfg")
				config.set_value("headset", "game_ab_profile", _profile)
				config.set_value("headset", "game_queue_frames", 6 if _profile == 0 else 3)
				config.set_value("headset", "game_buffer_frames", 1)
				config.save("user://settings.cfg")
				print("[q4-ab] профиль ", _profile)
				_send({"t": "game_profile", "profile": _profile})
			"tracking":
				tracking = message
			"game_metrics":
				for key: String in ["video", "layer", "pacing"]:
					if message[key] is String:
						print("[q4-%s] %s" % [key, message[key].substr(0, 4096)])
			"ping":
				_send(LinkProtocol.pong(message["time"]))
			"bye":
				_drop("шлем попрощался")
				return
			"games_exit":
				_leave_games()
				return
	# Only the newest poses matter.
	# The first poses come before the headset knows it is the games, with the
	# field of view of the other mode (less margin): SteamVR kept the first it
	# was given and drew with it all along (04.11.2026).
	if not tracking.is_empty() and _bridge != null and tracking.get("game", false):
		if _tracking_count % 10 == 0 and tracking.get("sent_us", 0) is int and int(tracking.get("sent_us", 0)) > 0:
			_send({"t": "pose_ack", "sent_us": tracking.get("sent_us", 0), "received_us": _bridge.get_driver().get("clock_us", 0)})
		_bridge.write_head(tracking["id"], tracking["head"], tracking["head_ok"], tracking["eyes"], tracking["fov"])
		_bridge.write_controllers(tracking["controllers"])
		_bridge.write_hands(tracking["hands"])
		var hand_state := ""
		for data: Dictionary in tracking["hands"]:
			var flags: PackedInt32Array = data.get("flags", PackedInt32Array())
			hand_state += "ok=%s source=%s joints=%d wrist_flags=%s; " % [data.get("ok", false), data.get("source", -1), data.get("joints", []).size(), flags[1] if flags.size() > 1 else -1]
		if hand_state != _hand_state:
			_hand_state = hand_state
			print("[hands] ", hand_state)
		if OS.get_environment("WORKPLACE_HAND_PROBE") == "1":
			_hand_probe.set_dest_address("127.0.0.1", 47923)
			var probe_hands: Array = tracking["hands"].duplicate(true)
			for h in 2:
				var controller: Dictionary = tracking["controllers"][h]
				var profile := String(controller.get("profile", ""))
				if probe_hands[h].get("source", 0) == 0 and controller.get("ok", false) and not profile.is_empty() and not profile.contains("hand_interaction"):
					probe_hands[h]["ok"] = false
			_hand_probe.put_packet(var_to_bytes(probe_hands))
		for pulse: Dictionary in _bridge.take_haptics():
			_send(pulse)
			print("[games] haptic hand %d: %.2f s, %.2f amplitude" % [pulse["hand"], pulse["duration"], pulse["amplitude"]])
		_tracking_count += 1
	if _channel != null and now - _last_heard > LinkProtocol.LINK_TIMEOUT_SEC:
		_drop("шлем молчит")


## The driver's stream, told to the headset once it is up (and again if it changes).
func _check_driver() -> void:
	if _bridge == null:
		return
	var driver: Dictionary = _bridge.get_driver()
	var alive: bool = driver.get("alive", false)
	if alive != _driver_alive:
		_driver_alive = alive
		print("[games] SteamVR с драйвером WoRkPlace %s" % ("запущен" if alive else "не работает"))
	if not connected():
		return
	var port: int = driver.get("port", 0)
	var told := "%d:%d:%d" % [port, driver.get("width", 0), driver.get("height", 0)] if alive and port > 0 else ""
	if told == _eyes_told:
		return
	_eyes_told = told
	if told == "":
		return
	# Foveated by the driver as RemoteHost sends its eyes; no alpha rows (no screens' layers).
	_send({"t": "eyes", "port": port, "w": driver["width"], "h": driver["height"], "mask": 0, "foveation": Foveation.STRENGTH,
			"game": true})
	print("[games] поток глаз от SteamVR: %dx%d, порт %d" % [driver["width"], driver["height"], port])


func _send(message: Dictionary) -> void:
	if _channel != null and _channel.put_var(message) != OK:
		_drop("не отправилось")


func _drop(why: String) -> void:
	print("[games] отключился: ", why)
	if _tcp != null:
		_tcp.disconnect_from_host()
	_tcp = null
	_channel = null
	_device = ""
	_eyes_told = ""
	if _bridge != null:
		_bridge.set_headset(false)


## The headset's way out (04.11.2026: SteamVR could not be left from the
## headset): SteamVR closes as from its own window (vrmonitor), whatever of it
## stays is ended a few seconds later, the link server comes back (world in the
## headset) and this ends. The headset app follows by itself (headset_root.gd).
func _leave_games() -> void:
	if _leaving:
		return
	_leaving = true
	print("[games] завершаю игровую сессию, возвращаю предыдущий режим")
	var previous := WorkMode.parse(FileAccess.get_file_as_string(WorkMode.file_path().get_base_dir().path_join("before_games.txt")))
	if previous < 0 or previous >= WorkMode.PC_GAMES:
		previous = WorkMode.HEADSET_WORLD
	_send({"t": "games_leaving", "mode": previous})
	if WorkMode.parse(FileAccess.get_file_as_string(WorkMode.file_path())) == WorkMode.PC_GAMES:
		WorkMode.write(previous)
		get_tree().create_timer(0.15).timeout.connect(get_tree().quit)
		return
	OS.create_process("taskkill.exe", ["/IM", "vrmonitor.exe"])
	OS.create_process("powershell.exe", ["-NoProfile", "-WindowStyle", "Hidden", "-Command",
			"Start-Sleep 6; Get-Process vrmonitor,vrserver,vrcompositor,vrdashboard,vrwebhelper,vrstartup -ErrorAction SilentlyContinue | Stop-Process -Force"])
	OS.create_process("cmd.exe", ["/c", ProjectSettings.globalize_path("res://tools/link_server.cmd")])
	get_tree().quit()


func _update_sound(now: float) -> void:
	if _sound != null or now < _next_sound_try:
		return
	_sound = ClassDB.instantiate(&"SoundStreamer")
	if _sound != null and _sound.start(LinkProtocol.REMOTE_SOUND_PORT):
		print("[sound] звук ПК: порт TCP %d, %s" % [LinkProtocol.REMOTE_SOUND_PORT, _sound.get_stats()["device"]])
	else:
		print("[sound] звук ПК не запустился: %s" % ("" if _sound == null else _sound.get_last_error()))
		_sound = null
		_next_sound_try = now + SOUND_RETRY_SEC
