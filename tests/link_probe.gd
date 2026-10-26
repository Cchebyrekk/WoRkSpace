extends SceneTree
## Probe for slice o2: plays the headset against a running link server on this
## PC (scenes/link_server.tscn) with the headset's own HeadsetLink, for 8 s.

var _link: RefCounted
var _end := 0.0
var _last := ""


func _initialize() -> void:
	_link = load("res://headset/src/headset_link.gd").new("проба")
	_end = Time.get_ticks_msec() / 1000.0 + 8.0


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	_link.poll(now)
	var line: String = _link.describe()
	if line != _last:
		_last = line
		print("[probe] ", line)
	if _link.monitors_changed:
		_link.monitors_changed = false
		for monitor: Dictionary in _link.monitors:
			print("[probe]   ", monitor)
	if now > _end:
		_link.close()
		return true
	return false
