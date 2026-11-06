extends SceneTree
## Probe for slice q1 (PC VR games): plays the headset for the game host
## (tools/game_host.cmd) and the WoRkPlace SteamVR driver. Connects to the
## control port on this PC, says hello, sends a head turning slowly with a new
## pose id every frame, and once the host tells the eyes' stream, reads it:
## the header, then frames with their pose ids. After 15 s says what came.
## Needs the game host and SteamVR (with the driver) running.

const RUN_SEC := 15.0

var _tcp := StreamPeerTCP.new()
var _channel := PacketPeerStream.new()
var _eyes := StreamPeerTCP.new()
var _eyes_port := 0
var _buffer := PackedByteArray()
var _header_read := false
var _frames := 0
var _keys := 0
var _bytes := 0
var _pose_id := 0
var _sent := {} # pose id -> time sent
var _first_pose := -1
var _last_pose := -1
var _delays: Array[float] = []
var _start := 0.0
var _said_hello := false


func _initialize() -> void:
	_start = Time.get_ticks_msec() / 1000.0
	_tcp.connect_to_host("127.0.0.1", LinkProtocol.REMOTE_CONTROL_PORT)
	_tcp.set_no_delay(true)
	_channel.stream_peer = _tcp


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	_tcp.poll()
	if _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		if not _said_hello:
			_said_hello = true
			_channel.put_var(LinkProtocol.hello("проба игр"))
			print("[probe] связь с хостом игр есть")
		_send_tracking(now)
		while _channel.get_available_packet_count() > 0:
			var message: Variant = _channel.get_var()
			if message is Dictionary and message.get("t") == "eyes" and _eyes_port == 0:
				_eyes_port = message["port"]
				print("[probe] поток глаз: %s" % str(message))
				_eyes.connect_to_host("127.0.0.1", _eyes_port)
	if _eyes_port != 0:
		_read_eyes(now)
	if now - _start > RUN_SEC:
		_report()
		return true
	return false


func _send_tracking(now: float) -> void:
	_pose_id += 1
	_sent[_pose_id] = now
	var head := Transform3D(Basis(Vector3.UP, sin(now - _start) * 0.5), Vector3(0, 1.6, 0))
	var eyes := [Transform3D(Basis(), Vector3(-0.032, 0, 0)), Transform3D(Basis(), Vector3(0.032, 0, 0))]
	var fov := [Vector4(-1.0, 0.85, -1.0, 0.9), Vector4(-0.85, 1.0, -1.0, 0.9)]
	_channel.put_var({"t": "tracking", "id": _pose_id, "head": head, "head_ok": true, "eyes": eyes, "fov": fov,
			"hands": [{"ok": false}, {"ok": false}], "controllers": [{"ok": false}, {"ok": false}], "shown": []})


func _read_eyes(now: float) -> void:
	_eyes.poll()
	var available := _eyes.get_available_bytes()
	if available > 0:
		_buffer.append_array(_eyes.get_data(available)[1])
		_bytes += available
	if not _header_read:
		if _buffer.size() < 20:
			return
		print("[probe] заголовок: %s, версия %d, %dx%d, %d к/с" % [_buffer.slice(0, 4).get_string_from_ascii(),
				_u32(4), _u32(8), _u32(12), _u32(16)])
		_buffer = _buffer.slice(20)
		_header_read = true
	# Frames: u32 length, u64 sample time, u64 capture time, u32 pose, u8 flags, bytes.
	while _buffer.size() >= 25:
		var length := _u32(0)
		if _buffer.size() < 25 + length:
			break
		var pose := _u32(20)
		var flags := _buffer[24]
		if length > 0:
			_frames += 1
			if flags & 1:
				_keys += 1
			if pose != 0:
				if _first_pose < 0:
					_first_pose = pose
				_last_pose = pose
				if _sent.has(pose):
					_delays.append(now - _sent[pose])
		_buffer = _buffer.slice(25 + length)


func _u32(at: int) -> int:
	return _buffer[at] << 24 | _buffer[at + 1] << 16 | _buffer[at + 2] << 8 | _buffer[at + 3]


func _report() -> void:
	var average := 0.0
	for delay in _delays:
		average += delay
	if not _delays.is_empty():
		average /= _delays.size()
	print("[probe] за %d с: поз отправлено %d, кадров %d (ключевых %d), %.1f МБ, номера поз %d..%d, от позы до кадра в среднем %.0f мс" % [
			RUN_SEC, _pose_id, _frames, _keys, _bytes / 1e6, _first_pose, _last_pose, average * 1000.0])
	_channel.put_var({"t": "bye"})
