class_name DisplayTopology
extends Node
## Changes the Windows desktop layout by running tools/display_topology.ps1 on a
## worker thread: attaches or detaches one virtual monitor, moves monitors, saves
## and restores the whole layout. Unlike VddControl this does not touch device
## instances, so the driver (and Quest Link) is not restarted.

signal finished(ok: bool, code: String, detail: String)
## After list_modes(): one dictionary per monitor: name, width, height, refresh,
## scale (percent), modes ("WxH@Hz" strings), scales (allowed percents).
signal modes_listed(monitors: Array)
## After count_instances(): working and all MttVDD device instances.
signal instances_counted(working: int, total: int)

const SCRIPT_PATH := "res://tools/display_topology.ps1"

var busy := false

var _thread: Thread


## `monitor_key` (ScreenPanel.monitor_key): attach that monitor if it is free,
## else the usual choice.
func add_screen(monitor_key := "") -> void:
	_run("add", ["-Monitor", monitor_key] if monitor_key != "" else [])


## `monitor_key`: detach that monitor if it may be detached, else the usual choice.
func remove_screen(monitor_key := "") -> void:
	_run("remove", ["-Monitor", monitor_key] if monitor_key != "" else [])


## `positions`: monitor name (\\.\DISPLAYnn, as ScreenCapture.list_monitors() gives
## it) -> new top-left corner on the virtual desktop. All are moved in one step.
func arrange(positions: Dictionary) -> void:
	var items: PackedStringArray = []
	for monitor_name: String in positions:
		var at: Vector2i = positions[monitor_name]
		items.append("%s=%d,%d" % [monitor_name, at.x, at.y])
	_run("arrange", ["-Positions", ";".join(items)])


func list_modes() -> void:
	_run("modes")


## Changes one monitor's mode ("2560x1440@60", or "" to keep it) and/or its
## Windows scale in percent (0 to keep it).
func set_mode(monitor_name: String, mode: String, scale: int) -> void:
	var arguments := ["-Monitor", monitor_name]
	if mode != "":
		arguments.append_array(["-Mode", mode])
	if scale > 0:
		arguments.append_array(["-Scale", str(scale)])
	_run("setmode", arguments)


func count_instances() -> void:
	_run("instances")


## Remembers the current layout and which monitors are attached: `backup` "start"
## for the emergency exit, "apply" for after the driver restart of "Apply".
func save_layout(backup := "start") -> void:
	_run("save", ["-Backup", backup])


func restore_layout(backup := "start") -> void:
	_run("restore", ["-Backup", backup])


## For the emergency exit: restores on this thread and returns the script's answer.
func restore_layout_now() -> String:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	return _invoke("restore", [])


func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()


func _run(action: String, arguments: Array = []) -> void:
	if busy:
		return
	busy = true
	print("[screens] запуск display_topology.ps1 -Action %s (%.2f с от старта)" % [action, Time.get_ticks_msec() / 1000.0])
	if _thread != null:
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_execute.bind(action, arguments))


func _execute(action: String, arguments: Array) -> void:
	_report.call_deferred(_invoke(action, arguments))


func _invoke(action: String, arguments: Array) -> String:
	var output: Array = []
	var command := [
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", ProjectSettings.globalize_path(SCRIPT_PATH), "-Action", action,
	]
	command.append_array(arguments)
	var exit_code := OS.execute("powershell.exe", command, output, true)
	var text := "" if output.is_empty() else str(output[0]).strip_edges()
	# The result is the last line; anything before it is PowerShell noise.
	var last_line := text.get_slice("\n", text.get_slice_count("\n") - 1).strip_edges()
	return last_line if last_line.begins_with("{") else JSON.stringify({"ok": false, "code": "failed", "detail": "код %d: %s" % [exit_code, text]})


func _report(answer: String) -> void:
	busy = false
	print("[screens] display_topology.ps1 закончил (%.2f с от старта)" % (Time.get_ticks_msec() / 1000.0))
	var parsed: Variant = JSON.parse_string(answer)
	var result: Dictionary = parsed if parsed is Dictionary else {}
	match str(result.get("code", "")):
		"modes":
			modes_listed.emit(result.get("monitors", []))
			return
		"instances":
			instances_counted.emit(int(result.get("working", 0)), int(result.get("total", 0)))
			return
	finished.emit(bool(result.get("ok", false)), str(result.get("code", "failed")), str(result.get("detail", answer)))
