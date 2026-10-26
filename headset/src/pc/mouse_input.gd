class_name MouseInput
extends RefCounted
## Headset stand-in for the PC module's MouseInput (slice o5): the same static
## calls, sent to the PC over the link, where the server makes them real. The
## agent and the secure desktop are unknown here yet (slice o5b); recording keys
## or text from the PC's keyboard is not available yet either.

const BUTTON_LEFT := 0
const BUTTON_RIGHT := 1
const BUTTON_MIDDLE := 2

static var _position := Vector2i.ZERO


static func move_to(position: Vector2i) -> void:
	if position == _position:
		return
	var monitor := PcLink.monitor_at(position)
	if monitor.is_empty():
		return
	_position = position
	PcLink.send(LinkProtocol.pointer(monitor["key"], position - Vector2i(monitor["x"], monitor["y"])))


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
	return false


static func is_secure_desktop_active() -> bool:
	return false


static func start_key_recording() -> bool:
	return false


static func stop_key_recording() -> void:
	pass


static func get_recorded_keys() -> PackedInt32Array:
	return PackedInt32Array()


static func get_key_recording_seen() -> int:
	return 0


static func start_text_recording() -> bool:
	return false


static func get_recorded_text() -> String:
	return ""


static func get_text_recording_end() -> int:
	return 0
