class_name InternetLink
extends RefCounted
## Per-headset internet identity. Never included in the PC's shared settings.

const PROFILE := "user://internet_connection.json"
const DEVICE := "user://internet_device.json"
const CHOICE := "user://internet_transport_choice.txt"
const MODE := 3
static var profile: Dictionary = {}
static var identity: Dictionary = {}
static var certificate: X509Certificate
static var _loaded := false
static var _selected := false
static var _video_mode := -1
static var setup_visible := false
static var setup_input := Callable()
static var setup_capture: Array[bool] = [false, false]
static var freeze_video := Callable()
static var last_error_code := ""


static func update_setup_inputs(pointers: Array, delta: float) -> Array[bool]:
	if setup_visible and setup_input.is_valid():
		return setup_input.call(pointers, delta)
	return [false, false]


static func prepare_transport_change() -> void:
	if freeze_video.is_valid():
		freeze_video.call()


static func load_profile() -> void:
	if _loaded:
		return
	_loaded = true
	for path in [PROFILE, DEVICE]:
		if FileAccess.file_exists(path):
			var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if data is Dictionary:
				if path == PROFILE:
					profile = data
				else:
					identity = data
	if not profile.is_empty():
		certificate = X509Certificate.new()
		if certificate.load_from_string(str(profile.get("certificate", ""))) != OK:
			profile.clear()
			certificate = null
	var config := ConfigFile.new()
	if config.load("user://settings.cfg") == OK:
		_selected = int(config.get_value("headset", "link_mode", 0)) == MODE


static func configured() -> bool:
	load_profile()
	return certificate != null and not profile.is_empty()


static func bound() -> bool:
	load_profile()
	return registered() and identity.get("trusted", false) == true


static func registered() -> bool:
	return not str(identity.get("device", "")).is_empty() and not str(identity.get("token", "")).is_empty()


static func enabled() -> bool:
	load_profile()
	return HeadsetOptions.current.link_mode == MODE if HeadsetOptions.current != null else _selected


static func configure_video() -> bool:
	if OS.get_name() != "Android":
		return true
	var wanted := 1 if enabled() else 0
	if _video_mode == wanted:
		return true
	var transport = JavaClassWrapper.wrap("com.workplace.headset.InternetTransport")
	if transport == null or not transport.configure(JSON.stringify(profile), JSON.stringify(identity), wanted == 1):
		return false
	_video_mode = wanted
	return true


static func select(value: bool) -> void:
	prepare_transport_change()
	_selected = value
	if HeadsetOptions.current != null:
		HeadsetOptions.current.link_mode = MODE if value else HeadsetOptions.LINK_AUTO
	var config := ConfigFile.new()
	config.load("user://settings.cfg")
	config.set_value("headset", "link_mode", MODE if value else HeadsetOptions.LINK_AUTO)
	config.save("user://settings.cfg")
	var pending := FileAccess.open(CHOICE, FileAccess.WRITE)
	if pending != null:
		pending.store_string("pending")


static func has_local_choice() -> bool:
	return FileAccess.file_exists(CHOICE)


static func clear_local_choice() -> void:
	if FileAccess.file_exists(CHOICE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CHOICE))


static func save_identity(value: Dictionary) -> bool:
	var file := FileAccess.open(DEVICE, FileAccess.WRITE)
	if file == null:
		return false
	identity = {"device": value.get("device", ""), "token": value.get("token", ""), "trusted": value.get("trusted", false)}
	file.store_string(JSON.stringify(identity))
	return true


static func request(operation: String, extra: Dictionary = {}, bootstrap := false) -> Request:
	load_profile()
	var message := identity.duplicate()
	message.merge(extra, true)
	message["v"] = 1
	message["op"] = operation
	return Request.new(message, bootstrap)


class Request extends RefCounted:
	var tcp := StreamPeerTCP.new()
	var tls := StreamPeerTLS.new()
	var result: Dictionary = {}
	var ready := false
	var failed := false
	var error_code := ""
	var _request: Dictionary
	var _stage := 0
	var _since := Time.get_ticks_msec()
	var _line := PackedByteArray()

	func _init(message: Dictionary, bootstrap: bool) -> void:
		_request = message
		if not InternetLink.configured():
			failed = true
			error_code = "CONFIG_REQUIRED"
			return
		var host := "127.0.0.1" if bootstrap else str(InternetLink.profile.get("host", ""))
		var port := int(InternetLink.profile.get("port", 47930))
		if host.is_empty() or port < 1 or port > 65535 or tcp.connect_to_host(host, port) != OK:
			failed = true
			error_code = "TCP_CONNECT"

	func poll() -> void:
		if failed:
			return
		tcp.poll()
		if tcp.get_status() in [StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR]:
			_fail("TCP_CONNECT" if _stage == 0 else "CONNECTION_CLOSED")
			return
		if not ready and Time.get_ticks_msec() - _since > 10000:
			_fail(["TCP_TIMEOUT", "TLS_TIMEOUT", "REPLY_TIMEOUT"][_stage] if _stage < 3 else "REPLY_TIMEOUT")
			return
		if _stage == 0 and tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			tcp.set_no_delay(true)
			if tls.connect_to_stream(tcp, "localhost", TLSOptions.client(InternetLink.certificate, "localhost")) != OK:
				_fail("TLS_ERROR")
				return
			_stage = 1
		if _stage >= 1:
			tls.poll()
			if tls.get_status() in [StreamPeerTLS.STATUS_ERROR, StreamPeerTLS.STATUS_ERROR_HOSTNAME_MISMATCH, StreamPeerTLS.STATUS_DISCONNECTED]:
				_fail("TLS_ERROR" if _stage == 1 else "CONNECTION_CLOSED")
				return
		if _stage == 1 and tls.get_status() == StreamPeerTLS.STATUS_CONNECTED:
			var wire := (JSON.stringify(_request) + "\n").to_utf8_buffer()
			if tls.put_data(wire) != OK:
				_fail("REQUEST_SEND")
				return
			_stage = 2
		if _stage == 2:
			# Read exactly through the JSON newline: binary Godot/video follows it.
			while tls.get_available_bytes() > 0 and _line.size() <= 4096:
				var chunk := tls.get_data(1)
				if chunk[0] != OK:
					_fail("REPLY_READ")
					return
				if chunk[1][0] == 10:
					var parsed: Variant = JSON.parse_string(_line.get_string_from_utf8())
					if parsed is Dictionary:
						result = parsed
					ready = result.get("ok", false) == true
					failed = not ready
					if failed:
						error_code = rejection_code(str(result.get("error", ""))) if parsed is Dictionary else "BAD_REPLY"
					_stage = 3
					return
				_line.append(chunk[1][0])
			if _line.size() > 4096:
				_fail("BAD_REPLY")

	static func rejection_code(reason: String) -> String:
		return {"unauthorized": "AUTH_FAILED", "forbidden": "DEVICE_NOT_PAIRED",
			"rate_limited": "RATE_LIMITED", "capacity": "SERVER_BUSY",
			"unavailable": "PC_SERVICE_UNAVAILABLE", "invalid_code": "PAIR_CODE_INVALID"}.get(reason, "GATEWAY_REJECTED")

	func _fail(code: String) -> void:
		if error_code.is_empty():
			error_code = code
		close()

	func close() -> void:
		failed = true
		tls.disconnect_from_stream()
		tcp.disconnect_from_host()
