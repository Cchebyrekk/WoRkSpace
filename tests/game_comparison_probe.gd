extends SceneTree

class ProbeRoot extends "res://headset/src/headset_root.gd":
	var allowed := true
	var started: Array[int] = []
	func _start(mode: int) -> void:
		_close_probe()
		_mode = mode
		started.append(mode)
	func _cable_allowed() -> bool:
		return allowed
	func _probe_port_for_mode(mode: int) -> int:
		return 39082 if mode == WorkMode.HEADSET_WORLD else 39083

var _checks := 0
var _failures := 0

func _init() -> void:
	_run.call_deferred()

func _check(ok: bool, text: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error(text)

func _run() -> void:
	for profile in [0, 1]:
		_check(LinkProtocol.problem({"t": "game_profile", "profile": profile}) == "", "valid comparison profile")
	_check(LinkProtocol.problem({"t": "game_profile", "profile": 2}) != "", "out of range profile rejected")
	_check(LinkProtocol.problem({"t": "game_profile", "profile": "0"}) != "", "string profile rejected")
	for mode in [0, 1, 2]:
		_check(LinkProtocol.problem({"t": "games_leaving", "mode": mode}) == "", "valid return mode")
	_check(LinkProtocol.problem({"t": "games_leaving", "mode": 3}) != "", "return to games rejected")
	for previous in [WorkMode.HEADSET_WORLD, WorkMode.PC_DRAWS]:
		var target := WorkMode.PC_DRAWS if previous == WorkMode.HEADSET_WORLD else WorkMode.HEADSET_WORLD
		var server := TCPServer.new()
		var port := 39083 if target == WorkMode.PC_DRAWS else 39082
		var error := server.listen(port, "127.0.0.1")
		_check(error == OK, "isolated USB-mode probe listener")
		var probe := ProbeRoot.new()
		probe._mode = previous
		var deadline := Time.get_ticks_msec() + 2000
		while probe.started.is_empty() and Time.get_ticks_msec() < deadline:
			probe._poll_cable(Time.get_ticks_msec() / 1000.0)
			await process_frame
		_check(probe.started == [target], "USB discovers the other mode without UDP")
		probe.free()
		server.stop()
	var probe := ProbeRoot.new()
	probe.allowed = false
	probe._poll_cable(1.0)
	_check(probe._cable_probe == null, "Wi-Fi only does not probe USB")
	probe.return_from_games(WorkMode.HEADSET_WORLD)
	_check(probe.started.back() == WorkMode.HEADSET_WORLD, "explicit game exit returns local world")
	probe.return_from_games(WorkMode.PC_DRAWS)
	_check(probe.started.back() == WorkMode.PC_DRAWS, "explicit game exit preserves PC-draw mode")
	probe.free()
	print("Game return: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
