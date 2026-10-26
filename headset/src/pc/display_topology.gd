class_name DisplayTopology
extends Node
## Headset stand-in for DisplayTopology (slice o5a): the same signals and calls,
## but nothing reaches Windows yet, every change answers "not in the headset
## yet" (slice o5b sends them to the PC). Signals go out deferred, as the real
## one's do from its worker thread.

const NOT_YET := "в шлеме пока недоступно (срез o5b)"

signal finished(ok: bool, code: String, detail: String)
signal modes_listed(monitors: Array)
signal instances_counted(working: int, total: int)
signal idle

var busy := false


func add_screen(_monitor_key := "") -> void:
	_refuse("add")


func remove_screen(_monitor_key := "") -> void:
	_refuse("remove")


func arrange(_positions: Dictionary) -> void:
	_refuse("arrange")


func list_modes() -> void:
	modes_listed.emit.call_deferred([])
	idle.emit.call_deferred()


func set_mode(_monitor_name: String, _mode: String, _scale: int) -> void:
	_refuse("set_mode")


func set_modes(_modes: Dictionary) -> void:
	_refuse("set_modes")


## Without an answer main.gd keeps the instance count it had.
func count_instances() -> void:
	idle.emit.call_deferred()


func save_layout(_backup := "start") -> void:
	idle.emit.call_deferred()


func restore_layout(_backup := "start") -> void:
	idle.emit.call_deferred()


func restore_layout_now() -> String:
	return ""


func _refuse(action: String) -> void:
	print("[screens] %s: %s" % [action, NOT_YET])
	finished.emit.call_deferred(false, "headset", NOT_YET)
	idle.emit.call_deferred()
