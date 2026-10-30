extends SceneTree
## Probe for the pc-render branch without a headset: plays the headset against the
## PC app started with WORKPLACE_REMOTE=1 (`--xr-mode on`) — says hello, sends a
## still head looking ahead every frame and counts the eyes' frames that come
## back. `--headless --xr-mode off -s tests/remote_probe.gd`.

const SECONDS := 12.0

var _tcp := StreamPeerTCP.new()
var _channel := PacketPeerStream.new()
var _eyes := StreamPeerTCP.new()
var _eyes_port := 0
var _buffer := PackedByteArray()
var _header_seen := false
var _frames := 0
var _bytes := 0
var _poses: Array[int] = []
var _id := 0
var _start := 0.0
var _greeted := false


func _initialize() -> void:
	_tcp.connect_to_host("127.0.0.1", LinkProtocol.REMOTE_CONTROL_PORT)
	_start = Time.get_ticks_msec() / 1000.0


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	_tcp.poll()
	if _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		if not _greeted:
			_tcp.set_no_delay(true)
			_channel.stream_peer = _tcp
			_channel.put_var(LinkProtocol.hello("probe"))
			_greeted = true
		_id += 1
		_channel.put_var(_tracking())
		while _channel.get_available_packet_count() > 0:
			var message: Dictionary = _channel.get_var()
			if message["t"] == "eyes":
				_eyes_port = message["port"]
				print("[probe] глаза: порт %d, %dx%d" % [_eyes_port, message["w"], message["h"]])
				_eyes.connect_to_host("127.0.0.1", _eyes_port)
	if _eyes_port > 0:
		_eyes.poll()
		if _eyes.get_status() == StreamPeerTCP.STATUS_CONNECTED and _eyes.get_available_bytes() > 0:
			_buffer.append_array(_eyes.get_data(_eyes.get_available_bytes())[1])
			_parse()
	if now - _start > SECONDS:
		print("[probe] кадров глаз %d, %.1f МБ, позы %s…%s, отправлено поз %d" % [_frames, _bytes / 1e6,
				_poses.slice(0, 3), _poses.slice(-3), _id])
		return true
	return false


func _tracking() -> Dictionary:
	var hand := {"ok": false}
	var controller := {"ok": false, "profile": "", "inputs": {}}
	return {"t": "tracking", "id": _id, "head": Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0)), "head_ok": true,
			"eyes": [Transform3D(Basis.IDENTITY, Vector3(-0.032, 0, 0)), Transform3D(Basis.IDENTITY, Vector3(0.032, 0, 0))],
			"fov": [Vector4(-1.0, 0.85, -1.0, 0.9), Vector4(-0.85, 1.0, -1.0, 0.9)],
			"hands": [hand, hand], "controllers": [controller, controller]}


func _parse() -> void:
	if not _header_seen:
		if _buffer.size() < 20:
			return
		print("[probe] заголовок версия %d %dx%d" % [_u32(4), _u32(8), _u32(12)])
		_buffer = _buffer.slice(20)
		_header_seen = true
	while _buffer.size() >= 25:
		var length := _u32(0)
		if _buffer.size() < 25 + length:
			return
		if _buffer[24] & 2 == 0:
			_frames += 1
			_bytes += length
			_poses.append(_u32(20))
		_buffer = _buffer.slice(25 + length)


func _u32(at: int) -> int:
	return (_buffer[at] << 24) | (_buffer[at + 1] << 16) | (_buffer[at + 2] << 8) | _buffer[at + 3]
