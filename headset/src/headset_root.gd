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


func _ready() -> void:
	_udp.set_broadcast_enabled(true)
	_udp.bind(0)
	_start(_last_mode())


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if _child != null and _child.call(&"connected"):
		_alone_since = -1.0
		while _udp.get_available_packet_count() > 0:
			_udp.get_packet()
		return
	if _alone_since < 0.0:
		_alone_since = now
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


func _start(mode: int) -> void:
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
