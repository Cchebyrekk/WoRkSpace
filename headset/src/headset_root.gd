extends Node3D
## The headset app (branch all-modes, 30.10.2026): one app for both work modes
## that need it (WorkMode). It starts with the mode the PC ran last time and asks
## on both discovery ports while that one has no PC; the answer says what runs
## there now — the link server (HEADSET_WORLD): the world runs here
## (headset_boot.gd); the PC app (PC_DRAWS): this shows what it draws
## (player.gd). An answer for the other mode swaps them.

const SCRIPTS := {
	WorkMode.HEADSET_WORLD: "res://src/headset_boot.gd",
	WorkMode.PC_DRAWS: "res://src/player.gd",
}
const LAST_MODE_PATH := "user://work_mode.txt"
const ASK_SEC := 1.0
## The one running has had no PC this long before the other mode's answer counts:
## a link that only dropped for a moment comes back to the same.
const SWAP_AFTER_SEC := 2.0

var _child: Node
var _mode := -1
var _udp := PacketPeerUDP.new()
var _next_ask := 0.0
## Since when the one running has had no PC (-1 while it has).
var _alone_since := -1.0
var _cable_probe: StreamPeerTCP
var _probe_since := 0.0
var _next_probe := 0.0
var _probe_mode := -1
var _internet_status: InternetLink.Request
var _next_internet_status := 0.0
var _internet_setup: Node3D
var _internet_alone_since := -1.0
var _internet_recovery := false


func _ready() -> void:
	_udp.set_broadcast_enabled(true)
	_udp.bind(0)
	InternetLink.load_profile()
	_start(_last_mode())
	if InternetLink.enabled() and InternetLink.configured() and not InternetLink.bound():
		_show_internet_setup()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if _child == null:
		return
	if is_instance_valid(_internet_setup) and _internet_setup.visible:
		# A transient outage is not a new pairing. Keep discovering the PC's
		# mode and dismiss the recovery notice once the existing link returns.
		if _internet_recovery and InternetLink.enabled() and InternetLink.bound():
			if _child.call(&"connected"):
				_internet_setup.call(&"connection_restored")
			else:
				_poll_internet(now)
		return
	if InternetLink.enabled():
		if _child.call(&"connected"):
			_internet_alone_since = -1.0
		elif _internet_alone_since < 0.0:
			_internet_alone_since = now
		if not InternetLink.configured() or not InternetLink.registered():
			_show_internet_setup()
			return
		_poll_internet(now)
		return
	_internet_alone_since = -1.0
	if InternetLink.configured() and InternetLink.registered() and not InternetLink.bound():
		_poll_internet(now, true)
	if _child != null and _child.call(&"connected"):
		_close_probe()
		_alone_since = -1.0
		while _udp.get_available_packet_count() > 0:
			_udp.get_packet()
		return
	if _alone_since < 0.0:
		_alone_since = now
	if now - _alone_since >= SWAP_AFTER_SEC and _poll_cable(now):
		return
	while _udp.get_available_packet_count() > 0:
		var answer := LinkProtocol.parse_answer(_udp.get_packet())
		if answer.is_empty():
			continue
		var mode := WorkMode.PC_DRAWS if answer["port"] == LinkProtocol.REMOTE_CONTROL_PORT else WorkMode.HEADSET_WORLD
		if mode != _mode and now - _alone_since >= SWAP_AFTER_SEC:
			print("[mode] ПК %s отвечает в режиме «%s»" % [_udp.get_packet_ip(), WorkMode.name_of(mode)])
			_start(mode)
			return
	if now >= _next_ask:
		_next_ask = now + ASK_SEC
		for address in _broadcast_addresses():
			for port in [LinkProtocol.DISCOVERY_PORT, LinkProtocol.REMOTE_DISCOVERY_PORT]:
				_udp.set_dest_address(address, port)
				_udp.put_packet(LinkProtocol.ask_packet())


func _show_internet_setup(recovery := false) -> void:
	# Pairing is an overlay in the existing world, never a work-mode transition.
	_internet_recovery = recovery
	if is_instance_valid(_internet_setup):
		if not _internet_setup.visible:
			_internet_setup.call(&"open_panel")
		if recovery:
			_internet_setup.call(&"set_reconnecting", InternetLink.last_error_code)
		elif not InternetLink.last_error_code.is_empty():
			_internet_setup.call(&"set_connection_error", InternetLink.last_error_code)
		return
	_internet_setup = Node3D.new()
	_internet_setup.set_script(load("res://src/internet_setup.gd"))
	_internet_setup.connect(&"finished", _internet_continue)
	add_child(_internet_setup)
	if recovery:
		_internet_setup.call(&"set_reconnecting", InternetLink.last_error_code)
	elif not InternetLink.last_error_code.is_empty():
		_internet_setup.call(&"set_connection_error", InternetLink.last_error_code)


func _internet_continue() -> void:
	# The original world/camera remain alive. Only its transport reconnects.
	_internet_recovery = false
	_internet_alone_since = -1.0
	_alone_since = -1.0
	if _internet_status != null:
		_internet_status.close()
		_internet_status = null


func _poll_internet(now: float, pairing_only := false) -> void:
	if _internet_status == null and now >= _next_internet_status:
		_next_internet_status = now + 2.0
		_internet_status = InternetLink.request("status", {}, pairing_only)
	if _internet_status == null:
		return
	_internet_status.poll()
	if _internet_status.failed:
		var code := _internet_status.error_code
		if not code.is_empty() and code != InternetLink.last_error_code:
			InternetLink.last_error_code = code
			print("[internet] ошибка этапа: ", code)
		_internet_status.close()
		_internet_status = null
		if not pairing_only and _internet_alone_since >= 0.0 and now - _internet_alone_since >= 10.0:
			_show_internet_setup(InternetLink.bound())
		return
	if not _internet_status.ready:
		return
	var status := _internet_status.result
	InternetLink.last_error_code = ""
	_internet_status.close()
	_internet_status = null
	if not status.get("trusted", false):
		if pairing_only:
			return
		InternetLink.identity["trusted"] = false
		InternetLink.save_identity(InternetLink.identity)
		_show_internet_setup()
		return
	if not InternetLink.bound():
		InternetLink.identity["trusted"] = true
		InternetLink.save_identity(InternetLink.identity)
	if pairing_only:
		return
	var pc_mode := int(status.get("mode", -1))
	if pc_mode in [WorkMode.HEADSET_WORLD, WorkMode.PC_DRAWS, WorkMode.PC_GAMES]:
		var target := WorkMode.HEADSET_WORLD if pc_mode == WorkMode.HEADSET_WORLD else WorkMode.PC_DRAWS
		if target != _mode:
			_start(target)


func _start(mode: int) -> void:
	_close_probe()
	if _child != null:
		print("[mode] «%s» → «%s»" % [WorkMode.name_of(_mode), WorkMode.name_of(mode)])
		remove_child(_child)
		_child.queue_free()
		# player.gd's (its eye buffer took a new size mid-session, 30.10.2026):
		# the world is opaque and drawn at the headset's own size.
		get_viewport().transparent_bg = false
		var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
		if xr != null:
			xr.render_target_size_multiplier = 1.0
	_mode = mode
	_alone_since = -1.0
	var file := FileAccess.open(LAST_MODE_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("%d\n" % mode)
		file.close()
	_child = Node3D.new()
	_child.set_script(load(SCRIPTS[mode]))
	_child.name = "HeadsetWorld" if mode == WorkMode.HEADSET_WORLD else "Player"
	add_child(_child)
	print("[mode] запущен режим «%s»" % WorkMode.name_of(mode))


func return_from_games(previous_mode: int) -> void:
	var target := WorkMode.PC_DRAWS if previous_mode == WorkMode.PC_DRAWS else WorkMode.HEADSET_WORLD
	print("[mode] подтверждён выход из игр; возвращаю «%s»" % WorkMode.name_of(target))
	_start(target)


func _close_probe() -> void:
	if _cable_probe != null:
		_cable_probe.disconnect_from_host()
	_cable_probe = null


## USB does not carry UDP discovery. Only probe the OTHER mode's control port:
## probing the child's own port would replace its real connection on the server.
func _poll_cable(now: float) -> bool:
	if _cable_probe != null:
		_cable_probe.poll()
		if _cable_probe.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			var target := _probe_mode
			print("[mode] USB отвечает: «%s»" % WorkMode.name_of(target))
			_start(target)
			return true
		if now - _probe_since > 0.8 or _cable_probe.get_status() in [StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE]:
			_close_probe()
	if _cable_probe == null and now >= _next_probe:
		_next_probe = now + ASK_SEC
		if not _cable_allowed():
			return false
		_probe_since = now
		_probe_mode = WorkMode.HEADSET_WORLD if _mode == WorkMode.PC_DRAWS else WorkMode.PC_DRAWS
		_cable_probe = StreamPeerTCP.new()
		_cable_probe.connect_to_host("127.0.0.1", _probe_port_for_mode(_probe_mode))
	return false


func _cable_allowed() -> bool:
	var config := ConfigFile.new()
	return config.load("user://settings.cfg") != OK or int(config.get_value("headset", "link_mode", 0)) != HeadsetOptions.LINK_WIFI


func _probe_port_for_mode(mode: int) -> int:
	return LinkProtocol.CONTROL_PORT if mode == WorkMode.HEADSET_WORLD else LinkProtocol.REMOTE_CONTROL_PORT


func _last_mode() -> int:
	var text := FileAccess.get_file_as_string(LAST_MODE_PATH)
	var mode := WorkMode.parse(text)
	return mode if SCRIPTS.has(mode) else WorkMode.HEADSET_WORLD


func _broadcast_addresses() -> Array[String]:
	var result: Array[String] = ["255.255.255.255"]
	for address in IP.get_local_addresses():
		var parts := address.split(".")
		if parts.size() == 4 and parts[0] != "127" and parts[0] != "169":
			result.append("%s.%s.%s.255" % [parts[0], parts[1], parts[2]])
	return result
