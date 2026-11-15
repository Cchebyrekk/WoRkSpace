extends SceneTree
## Exercises the actual Godot TLS/framing code against a loopback-only test gateway.
var _request: InternetLink.Request
var _phase := 0
var _port := 0
var _end := 0
var _received := PackedByteArray()
var _payload := PackedByteArray()
var _expected_error := ""

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		quit(1)
		return
	var config: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not config is Dictionary:
		quit(1)
		return
	InternetLink._loaded = true
	InternetLink.profile = config["profile"]
	InternetLink.identity = config["identity"]
	InternetLink.certificate = X509Certificate.new()
	if InternetLink.certificate.load_from_string(InternetLink.profile["certificate"]) != OK:
		quit(1)
		return
	_expected_error = config.get("expect_error", "")
	if _expected_error == "TLS_ERROR":
		var crypto := Crypto.new()
		var wrong_key := crypto.generate_rsa(2048)
		InternetLink.certificate = crypto.generate_self_signed_certificate(wrong_key, "CN=localhost,O=WoRkPlace", "20200101000000", "20400101000000")
	_port = config["service_port"]
	_request = InternetLink.request("status")
	_end = Time.get_ticks_msec() + 8000
	for i in 4096:
		_payload.append(i % 256)

func _process(_delta: float) -> bool:
	if _request == null:
		return false
	_request.poll()
	if _request.failed and not _expected_error.is_empty():
		var passed := _request.error_code == _expected_error
		print("InternetClientProbe: " + ("PASSED rejection" if passed else "FAILED error stage"))
		quit(0 if passed else 1)
		return false
	if _request.failed or Time.get_ticks_msec() > _end:
		print("InternetClientProbe: FAILED stage %d" % _phase)
		quit(1)
		return false
	if not _request.ready:
		return false
	if _phase == 0:
		if not _request.result.get("trusted", false) or _request.result.get("mode") != 3:
			quit(1)
			return false
		_request.close()
		_request = InternetLink.request("tunnel", {"port": _port})
		_phase = 1
	elif _phase == 1:
		if _request.tls.put_data(_payload) != OK:
			quit(1)
		_phase = 2
	elif _phase == 2:
		var available := _request.tls.get_available_bytes()
		if available > 0:
			var data := _request.tls.get_data(available)
			if data[0] != OK:
				quit(1)
				return false
			_received.append_array(data[1])
		if _received.size() >= _payload.size():
			var passed := _received == _payload
			_request.close()
			print("InternetClientProbe: " + ("PASSED" if passed else "FAILED payload"))
			quit(0 if passed else 1)
	return false
