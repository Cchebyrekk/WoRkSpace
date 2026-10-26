class_name HeadsetLink
extends RefCounted
## The headset side of the own link (slice o2): finds the PC, holds the control
## channel, keeps the PC's name, its monitors and the round trip. Call poll()
## every frame; read the fields; `monitors_changed` is set when the list is new.

enum State { SEARCHING, CONNECTING, CONNECTED }

## A search round: broadcast the question, try the USB route (adb reverse).
const SEARCH_SEC := 1.0
const CONNECT_TIMEOUT_SEC := 3.0
const LOCALHOST := "127.0.0.1"

var state := State.SEARCHING
var pc_name := ""
var pc_address := ""
var monitors: Array = []
var monitors_changed := false
## The last ping's round trip, -1 until one came back.
var rtt_ms := -1.0
## The streams the PC offers (LinkProtocol.video: port, key, w, h each);
## `videos_changed` is set when the list is new.
var videos: Array = []
var videos_changed := false
## Grows with every stream list the PC sends, even an unchanged one: the PC
## sends it after restarting its streams, and the receivers must connect again.
var videos_serial := 0
## The PC app's settings file as it sent it ("" until then); `settings_changed` on arrival.
var pc_settings := ""
var settings_changed := false
## Messages for the stand-ins of the PC's services (event, pc_state, vdd_config,
## secure_frame), in order; PcLink.dispatch takes them every frame.
var inbox: Array[Dictionary] = []

var _device := ""
var _udp := PacketPeerUDP.new()
var _tcp: StreamPeerTCP
var _channel: PacketPeerStream
var _next_search := 0.0
var _started := 0.0
var _last_heard := 0.0
var _next_ping := 0.0
var _greeted := false


func _init(device: String) -> void:
	_device = device
	_udp.set_broadcast_enabled(true)
	_udp.bind(0)


func poll(now: float) -> void:
	match state:
		State.SEARCHING:
			_search(now)
		State.CONNECTING:
			_connecting(now)
		State.CONNECTED:
			_connected(now)


func describe() -> String:
	match state:
		State.SEARCHING:
			return "Ищу ПК…"
		State.CONNECTING:
			return "Подключаюсь к %s…" % pc_address
		_ when not _greeted:
			return "Здороваюсь с %s…" % pc_address
		_:
			return "ПК %s (%s), мониторов %d, задержка %s" % [pc_name, pc_address, monitors.size(),
					"%.0f мс" % rtt_ms if rtt_ms >= 0.0 else "—"]


## Sends a message to the PC if connected (input: LinkProtocol.pointer, button).
func send(message: Dictionary) -> void:
	if state == State.CONNECTED and _greeted:
		_channel.put_var(message)


func close() -> void:
	if _channel != null and _greeted:
		_channel.put_var({"t": "bye"})
	_reset("приложение закрывается")


func _search(now: float) -> void:
	while _udp.get_available_packet_count() > 0:
		var answer := LinkProtocol.parse_answer(_udp.get_packet())
		var ip := _udp.get_packet_ip()
		if answer.is_empty():
			continue
		if answer["version"] != LinkProtocol.VERSION:
			print("[link] ПК %s говорит на версии %d, а я на %d" % [answer["pc"], answer["version"], LinkProtocol.VERSION])
			continue
		print("[link] нашёл ПК %s на %s" % [answer["pc"], ip])
		_connect(ip, answer["port"], now)
		return
	if now < _next_search:
		return
	_next_search = now + SEARCH_SEC
	var mode := _mode()
	if mode == HeadsetOptions.LINK_CABLE:
		_connect(LOCALHOST, LinkProtocol.CONTROL_PORT, now)
		return
	for address in _broadcast_addresses():
		_udp.set_dest_address(address, LinkProtocol.DISCOVERY_PORT)
		_udp.put_packet(LinkProtocol.ask_packet())
	# Over the cable the PC is reachable here after `adb reverse`; the attempt
	# fails at once when nothing listens, so it can go every round.
	if mode == HeadsetOptions.LINK_AUTO:
		_connect(LOCALHOST, LinkProtocol.CONTROL_PORT, now)


## The user's choice (HeadsetOptions.link_mode), "either way" before the world has it.
func _mode() -> int:
	return HeadsetOptions.current.link_mode if HeadsetOptions.current != null else HeadsetOptions.LINK_AUTO


## The general broadcast, and the /24 one of each local address in case the
## system does not route the general one to Wi-Fi.
func _broadcast_addresses() -> Array[String]:
	var result: Array[String] = ["255.255.255.255"]
	for address in IP.get_local_addresses():
		var parts := address.split(".")
		if parts.size() == 4 and parts[0] != "127" and parts[0] != "169":
			result.append("%s.%s.%s.255" % [parts[0], parts[1], parts[2]])
	return result


func _connect(ip: String, port: int, now: float) -> void:
	_tcp = StreamPeerTCP.new()
	if _tcp.connect_to_host(ip, port) != OK:
		_tcp = null
		return
	pc_address = ip
	_started = now
	state = State.CONNECTING


func _connecting(now: float) -> void:
	_tcp.poll()
	match _tcp.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			# Only a connected socket takes this option.
			_tcp.set_no_delay(true)
			_channel = PacketPeerStream.new()
			_channel.input_buffer_max_size = LinkProtocol.CHANNEL_BUFFER
			_channel.output_buffer_max_size = LinkProtocol.CHANNEL_BUFFER
			_channel.stream_peer = _tcp
			_channel.put_var(LinkProtocol.hello(_device))
			_last_heard = now
			_next_ping = now
			state = State.CONNECTED
		StreamPeerTCP.STATUS_CONNECTING:
			if now - _started > CONNECT_TIMEOUT_SEC:
				_reset("%s не ответил" % pc_address if pc_address != LOCALHOST else "")
		_:
			# Nothing at the USB route is the usual case: not worth a line.
			_reset("" if pc_address == LOCALHOST else "%s не пускает" % pc_address)


func _connected(now: float) -> void:
	# The user switched to the other way: this connection goes, the next is found.
	var mode := _mode()
	var cable := pc_address == LOCALHOST
	if (mode == HeadsetOptions.LINK_CABLE and not cable) or (mode == HeadsetOptions.LINK_WIFI and cable):
		_reset("связь переключена на «%s»" % HeadsetOptions.link_mode_name(mode))
		return
	_tcp.poll()
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_reset("связь с %s оборвалась" % pc_address)
		return
	while _channel != null and _channel.get_available_packet_count() > 0:
		var message: Variant = _channel.get_var()
		var problem := LinkProtocol.problem(message)
		if problem != "":
			print("[link] плохое сообщение: %s" % problem)
			if message is Dictionary and message.get("t") == "welcome":
				_reset("несовместимый ПК")
			continue
		_last_heard = now
		match message["t"]:
			"welcome":
				pc_name = message["pc"]
				_greeted = true
				_take_monitors(message["monitors"])
				print("[link] подключён к ПК %s (%s), мониторов %d" % [pc_name, pc_address, monitors.size()])
			"monitors":
				_take_monitors(message["monitors"])
				print("[link] ПК прислал мониторы: %d" % monitors.size())
			"videos":
				videos = message["videos"]
				videos_changed = true
				videos_serial += 1
				print("[link] ПК показывает мониторов: %d" % videos.size())
			"event", "pc_state", "vdd_config", "secure_frame":
				inbox.append(message)
			"settings":
				pc_settings = message["text"]
				settings_changed = true
			"pong":
				rtt_ms = (now - float(message["time"])) * 1000.0
			"bye":
				_reset("ПК закрылся")
	if _channel == null:
		return
	if now - _last_heard > LinkProtocol.LINK_TIMEOUT_SEC:
		_reset("ПК молчит %.0f с" % LinkProtocol.LINK_TIMEOUT_SEC)
	elif now >= _next_ping:
		_next_ping = now + LinkProtocol.PING_SEC
		_channel.put_var(LinkProtocol.ping(now))


func _take_monitors(list: Array) -> void:
	monitors = list
	monitors_changed = true


func _reset(why: String) -> void:
	if why != "":
		print("[link] %s, ищу снова" % why)
	if _tcp != null:
		_tcp.disconnect_from_host()
	_tcp = null
	_channel = null
	_greeted = false
	rtt_ms = -1.0
	if state == State.CONNECTED and not monitors.is_empty():
		monitors = []
		monitors_changed = true
	if not videos.is_empty():
		videos = []
		videos_changed = true
	state = State.SEARCHING
	pc_name = ""
