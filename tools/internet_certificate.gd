extends SceneTree
## A local server identity: contains no network or device metadata.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		quit(1)
		return
	var directory := args[0]
	DirAccess.make_dir_recursive_absolute(directory)
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(3072)
	if key == null:
		quit(1)
		return
	var cert := crypto.generate_self_signed_certificate(key, "CN=localhost,O=WoRkPlace", "20200101000000", "20400101000000")
	if cert == null:
		quit(1)
		return
	if key.save(directory.path_join("server.key")) != OK or cert.save(directory.path_join("server.crt")) != OK:
		quit(1)
		return
	print("CertificateReady=True")
	quit()
