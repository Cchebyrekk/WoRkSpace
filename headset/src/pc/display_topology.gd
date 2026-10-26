class_name DisplayTopology
extends Node
## Headset stand-in for DisplayTopology (slice o5b): the same signals and calls;
## each call runs the real one on the PC (link_server.gd) and its signals come
## back as events. Like the real one it is `busy` from a call until `idle`, and a
## call made while busy is dropped, as the real one drops it.

signal finished(ok: bool, code: String, detail: String)
signal modes_listed(monitors: Array)
signal instances_counted(working: int, total: int)
signal idle

const NO_PC := "нет связи с ПК"

var busy := false


func _init() -> void:
	PcLink.handlers["topology"] = _on_event


func add_screen(monitor_key := "") -> void:
	_call("add_screen", [monitor_key])


func remove_screen(monitor_key := "") -> void:
	_call("remove_screen", [monitor_key])


func arrange(positions: Dictionary) -> void:
	_call("arrange", [positions])


func list_modes() -> void:
	_call("list_modes")


func set_mode(monitor_name: String, mode: String, scale: int) -> void:
	_call("set_mode", [monitor_name, mode, scale])


func set_modes(modes: Dictionary) -> void:
	_call("set_modes", [modes])


func count_instances() -> void:
	_call("count_instances")


func save_layout(backup := "start") -> void:
	_call("save_layout", [backup])


func restore_layout(backup := "start") -> void:
	_call("restore_layout", [backup])


## The emergency exit's synchronous restore: there is no PC keyboard shortcut in
## the headset, so nothing calls it here.
func restore_layout_now() -> String:
	return ""


func _call(op: String, args: Array = []) -> void:
	if busy:
		return
	if not PcLink.call_pc("topology", op, args):
		finished.emit.call_deferred(false, "headset", NO_PC)
		idle.emit.call_deferred()
		return
	busy = true


## The PC went away mid-call: its answer will not come.
func _process(_delta: float) -> void:
	if busy and not PcLink.connected():
		busy = false
		finished.emit(false, "headset", NO_PC)
		idle.emit()


func _on_event(name: String, args: Array) -> void:
	match name:
		"finished":
			finished.emit(args[0], args[1], args[2])
		"modes_listed":
			modes_listed.emit(args[0])
		"instances_counted":
			instances_counted.emit(args[0], args[1])
		"idle":
			busy = false
			idle.emit()
