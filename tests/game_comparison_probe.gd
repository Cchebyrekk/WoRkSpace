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
var _clicks: Array[int] = []

func _init() -> void:
	_run.call_deferred()

func _check(ok: bool, text: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error(text)

func _clicked(profile: int) -> void:
	_clicks.append(profile)

func _run() -> void:
	for profile in [0, 1]:
		_check(LinkProtocol.problem({"t": "game_profile", "profile": profile}) == "", "valid comparison profile")
	_check(LinkProtocol.problem({"t": "game_profile", "profile": 2}) != "", "out of range profile rejected")
	_check(LinkProtocol.problem({"t": "game_profile", "profile": "0"}) != "", "string profile rejected")
	for mode in [0, 1, 2]:
		_check(LinkProtocol.problem({"t": "games_leaving", "mode": mode}) == "", "valid return mode")
	_check(LinkProtocol.problem({"t": "games_leaving", "mode": 3}) != "", "return to games rejected")
	var ui: Variant = load("res://headset/src/game_comparison.gd").new()
	root.add_child(ui)
	ui.selected.connect(_clicked)
	var aims: Array = [Transform3D(Basis.IDENTITY, Vector3(-0.22, 0, 1)), null]
	var up: Array[bool] = [false, false]
	var down: Array[bool] = [true, false]
	ui.update_inputs(aims, up, 0.01)
	var capture: Array[bool] = ui.update_inputs(aims, down, 0.2)
	_check(capture[0] and _clicks.is_empty(), "hold captures input before activation")
	ui.update_inputs(aims, down, 0.3)
	_check(_clicks == [0], "original button activates after hold")
	ui.update_inputs(aims, down, 1.0)
	_check(_clicks == [0], "held button does not repeat")
	capture = ui.update_inputs(aims, up, 0.01)
	_check(not capture[0], "release ends input capture")
	aims[0] = Transform3D(Basis.IDENTITY, Vector3(10, 0, 1))
	ui.update_inputs(aims, down, 1.0)
	aims[0] = Transform3D(Basis.IDENTITY, Vector3(0.22, 0, 1))
	ui.update_inputs(aims, down, 1.0)
	_check(_clicks == [0], "dragging an existing press onto a button does not activate")
	ui.update_inputs(aims, up, 0.01)
	ui.update_inputs(aims, down, 0.5)
	_check(_clicks == [0, 1], "test button activates")
	ui.free()
	var held_ui: Variant = load("res://headset/src/game_comparison.gd").new()
	root.add_child(held_ui)
	held_ui.selected.connect(_clicked)
	var initial_capture: Array[bool] = held_ui.update_inputs(aims, down, 1.0)
	_check(not initial_capture[0] and _clicks == [0, 1], "a press held before the panel appeared cannot activate it")
	held_ui.free()
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
	print("Game comparison: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
