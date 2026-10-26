extends Node
## The PC side of the own link (slice o2): no VR here, the headset draws. It
## answers the headset's search, keeps one control channel and tells the
## headset which monitors there are. Run: scenes/link_server.tscn
## (`--headless --xr-mode off --path . res://scenes/link_server.tscn`).

## How often the monitor list is looked at for changes.
const MONITORS_CHECK_SEC := 2.0

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
