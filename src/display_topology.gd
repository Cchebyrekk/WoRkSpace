class_name DisplayTopology
extends Node
## Changes the Windows desktop layout by running tools/display_topology.ps1 on a
## worker thread: attaches or detaches one virtual monitor, moves monitors, saves
## and restores the whole layout. Unlike VddControl this does not touch device
## instances, so the driver (and Quest Link) is not restarted.

signal finished(ok: bool, code: String, detail: String)

const SCRIPT_PATH := "res://tools/display_topology.ps1"

var busy := false

var _thread: Thread


func add_screen() -> void:
	_run("add")


func remove_screen() -> void:
	_run("remove")


## `positions`: monitor name (\\.\DISPLAYnn, as ScreenCapture.list_monitors() gives
## it) -> new top-left corner on the virtual desktop. All are moved in one step.
func arrange(positions: Dictionary) -> void:
	var items: PackedStringArray = []
	for monitor_name: String in positions:
		var at: Vector2i = positions[monitor_name]
		items.append("%s=%d,%d" % [monitor_name, at.x, at.y])
	_run("arrange", ["-Positions", ";".join(items)])


## Remembers the current layout and which monitors are attached (to restore on an emergency exit).
func save_layout() -> void:
	_run("save")


func restore_layout() -> void:
	_run("restore")


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
	var parsed: Variant = JSON.parse_string(answer)
	var result: Dictionary = parsed if parsed is Dictionary else {}
	finished.emit(bool(result.get("ok", false)), str(result.get("code", "failed")), str(result.get("detail", answer)))
