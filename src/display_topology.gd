class_name DisplayTopology
extends Node
## Attaches or detaches one virtual monitor to the Windows desktop by running
## tools/display_topology.ps1 on a worker thread. Unlike VddControl this does not
## touch device instances, so the driver (and Quest Link) is not restarted.

signal finished(ok: bool, code: String, detail: String)

const SCRIPT_PATH := "res://tools/display_topology.ps1"

var busy := false

var _thread: Thread


func add_screen() -> void:
	_run("add")


func remove_screen() -> void:
	_run("remove")


func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()


func _run(action: String) -> void:
	if busy:
		return
	busy = true
	if _thread != null:
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_execute.bind(action))


func _execute(action: String) -> void:
	var output: Array = []
	var exit_code := OS.execute("powershell.exe", [
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", ProjectSettings.globalize_path(SCRIPT_PATH), "-Action", action,
	], output, true)
	var text := "" if output.is_empty() else str(output[0]).strip_edges()
	_report.call_deferred(exit_code, text)


func _report(exit_code: int, text: String) -> void:
	busy = false
	# The result is the last line; anything before it is PowerShell noise.
	var last_line := text.get_slice("\n", text.get_slice_count("\n") - 1).strip_edges()
	var parsed: Variant = JSON.parse_string(last_line)
	if parsed is Dictionary:
		var result := parsed as Dictionary
		finished.emit(bool(result.get("ok", false)), str(result.get("code", "")), str(result.get("detail", "")))
	else:
		finished.emit(false, "failed", "код %d: %s" % [exit_code, text])
