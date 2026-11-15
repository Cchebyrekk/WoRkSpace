extends SceneTree

func _init() -> void:
	InternetLink._loaded = true
	InternetLink.profile = {}
	InternetLink.certificate = null
	var missing := InternetLink.request("status")
	var passed := missing.failed and missing.error_code == "CONFIG_REQUIRED"
	InternetLink.profile = {"host": "127.0.0.1", "port": 0}
	InternetLink.certificate = X509Certificate.new()
	var invalid := InternetLink.request("status")
	passed = passed and invalid.failed and invalid.error_code == "TCP_CONNECT"
	for pair in [["unauthorized", "AUTH_FAILED"], ["forbidden", "DEVICE_NOT_PAIRED"],
			["unavailable", "PC_SERVICE_UNAVAILABLE"], ["unexpected_details", "GATEWAY_REJECTED"]]:
		passed = passed and InternetLink.Request.rejection_code(pair[0]) == pair[1]
	print("Internet error codes: " + ("PASSED" if passed else "FAILED"))
	quit(0 if passed else 1)
