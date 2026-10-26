class_name MouseInput
extends RefCounted
## Headset stand-in for the PC module's MouseInput (slice o5): the same static
## calls, sent to the PC over the link, where the server makes them real. Since
## o5b the agent's and the secure desktop's state come from the PC, and recording
## a shortcut or text runs on the PC's own keyboard; what it has so far comes back
## as events (the calls answer at once, as the PC's do: started or not is known
## a moment later).

const BUTTON_LEFT := 0
const BUTTON_RIGHT := 1
const BUTTON_MIDDLE := 2

static var _position := Vector2i.ZERO
## The recording as the PC last reported it.
static var _recording := {}
static var _registered := false
static var _next_outside_log := 0.0


static func move_to(position: Vector2i) -> void:
	if position == _position:
		return
	var monitor := PcLink.monitor_at(position)
	if monitor.is_empty():
		# A panel that knows an older rectangle of its monitor: the nearest monitor
		# takes it, clamped, rather than the move being lost.
		monitor = _nearest_monitor(position)
		if monitor.is_empty():
			return
		var now := Time.get_ticks_msec() / 1000.0
		if now >= _next_outside_log:
			_next_outside_log = now + 5.0
			print("[input] курсор вне мониторов (%d, %d), прижат к %s" % [position.x, position.y, monitor["name"]])
		position = position.clamp(Vector2i(monitor["x"], monitor["y"]),
				Vector2i(monitor["x"] + monitor["w"] - 1, monitor["y"] + monitor["h"] - 1))
	_position = position
	PcLink.cursor_key = monitor["key"]
	PcLink.send(LinkProtocol.pointer(monitor["key"], position - Vector2i(monitor["x"], monitor["y"])))


static func _nearest_monitor(position: Vector2i) -> Dictionary:
	var best := {}
	var best_distance := INF
	for monitor: Dictionary in PcLink.monitors():
		var rect := Rect2(monitor["x"], monitor["y"], monitor["w"], monitor["h"])
		var inside := Vector2(position).clamp(rect.position, rect.end)
		var distance := inside.distance_to(Vector2(position))
		if distance < best_distance:
			best_distance = distance
			best = monitor
	return best


static func get_position() -> Vector2i:
	return _position


static func set_button(button: int, pressed: bool) -> void:
	PcLink.send(LinkProtocol.button(button, pressed))


static func scroll(delta: int) -> void:
	PcLink.send(LinkProtocol.wheel(delta, 0))


static func scroll_horizontal(delta: int) -> void:
	PcLink.send(LinkProtocol.wheel(0, delta))


static func press_keys(virtual_keys: PackedInt32Array) -> void:
	if not virtual_keys.is_empty():
		PcLink.send(LinkProtocol.keys(Array(virtual_keys)))


static func set_key(virtual_key: int, pressed: bool) -> void:
	PcLink.send(LinkProtocol.key(virtual_key, pressed))


static func is_agent_connected() -> bool:
	return PcLink.agent


static func is_secure_desktop_active() -> bool:
	return PcLink.secure


static func start_key_recording() -> bool:
	return _start("start_key_recording")


static func start_text_recording() -> bool:
	return _start("start_text_recording")


static func stop_key_recording() -> void:
	PcLink.call_pc("keyboard", "stop_key_recording")
	_recording = {}


static func get_recorded_keys() -> PackedInt32Array:
	return PackedInt32Array(_recording.get("keys", PackedInt32Array()))


static func get_key_recording_seen() -> int:
	return _recording.get("seen", 0)


static func get_recorded_text() -> String:
	return _recording.get("text", "")


static func get_text_recording_end() -> int:
	return _recording.get("end", 0)


static func _start(op: String) -> bool:
	if not _registered:
		_registered = true
		PcLink.handlers["keyboard"] = _on_event
	_recording = {}
	return PcLink.call_pc("keyboard", op)


static func _on_event(name: String, args: Array) -> void:
	match name:
		"recording":
			_recording = args[0]
		"started":
			if not args[0]:
				print("[input] ПК не смог начать запись с клавиатуры")
