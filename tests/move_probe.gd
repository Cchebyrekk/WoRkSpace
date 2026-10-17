extends SceneTree
## Does a monitor capture survive a change of the Windows layout? Starts a capture
## per monitor, swaps the two right-most monitors through tools/display_topology.ps1,
## checks that every capture still delivers frames, then puts the layout back.
## Changes the real desktop layout for a few seconds:
##   godot --xr-mode off --path . -s tests/move_probe.gd

var _captures: Array[ScreenCapture] = []
var _names: Array[String] = []
var _original := {}
var _elapsed := 0.0
var _stage := 0
var _frames_before: Array[int] = []


func _initialize() -> void:
	var monitors := ScreenCapture.list_monitors()
	print("probe: мониторы ", monitors)
	for i in monitors.size():
		var capture := ScreenCapture.new()
		if not capture.start(i):
			printerr("probe: захват %d не запустился: %s" % [i, capture.get_last_error()])
			quit(1)
			return
		_captures.append(capture)
		_names.append(monitors[i]["name"])
		_original[monitors[i]["name"]] = monitors[i]["position"]


func _process(delta: float) -> bool:
	for capture in _captures:
		capture.update()
	_elapsed += delta
	if _stage == 0 and _elapsed > 1.5:
		_stage = 1
		_frames_before.clear()
		for capture in _captures:
			_frames_before.append(capture.get_frame_count())
		var by_x := _names.duplicate()
		by_x.sort_custom(func(a: String, b: String) -> bool: return _original[a].x < _original[b].x)
		var swapped := _original.duplicate()
		var a: String = by_x[-2]
		var b: String = by_x[-1]
		swapped[a] = Vector2i(_original[a].x + 1920, _original[a].y)
		swapped[b] = Vector2i(_original[b].x - 1920, _original[b].y)
		var started := Time.get_ticks_msec()
		print("probe: меняю местами ", a, " и ", b, ": ", _run(swapped), " за ", Time.get_ticks_msec() - started, " мс")
	elif _stage == 1 and _elapsed > 5.5:
		_stage = 2
		for i in _captures.size():
			print("probe: %s работает=%s, кадров после перестановки %d, размер %s" % [_names[i], _captures[i].is_running(),
					_captures[i].get_frame_count() - _frames_before[i], _captures[i].get_size()])
		print("probe: мониторы после: ", ScreenCapture.list_monitors())
		print("probe: возвращаю: ", _run(_original))
	elif _stage == 2 and _elapsed > 7.0:
		for capture in _captures:
			capture.stop()
		return true
	return false


func _run(positions: Dictionary) -> String:
	var items: PackedStringArray = []
	for monitor_name: String in positions:
		items.append("%s=%d,%d" % [monitor_name, positions[monitor_name].x, positions[monitor_name].y])
	var output: Array = []
	OS.execute("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
			ProjectSettings.globalize_path("res://tools/display_topology.ps1"), "-Action", "arrange", "-Positions", ";".join(items)], output, true)
	return str(output[0]).strip_edges() if not output.is_empty() else ""
