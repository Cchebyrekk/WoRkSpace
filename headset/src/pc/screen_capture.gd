class_name ScreenCapture
extends RefCounted
## Headset stand-in for the PC module's ScreenCapture (slice o5), so that
## main.gd and ScreenPanel run here unchanged: the monitor list comes over the
## link, and the picture is the PC's video stream decoded straight into the
## panel's layer (ScreenPanel asks for that through attach_layer). There is no
## texture: thumbnails stay empty.

var _key := ""
var _size := Vector2i.ZERO
var _running := false
var _error := ""


## Like the module's: name, position, size, primary, path. The path is the
## monitor's key, which ScreenPanel.key_of leaves as it is.
static func list_monitors() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for monitor: Dictionary in PcLink.monitors():
		result.append({"name": monitor["name"], "position": Vector2i(monitor["x"], monitor["y"]),
				"size": Vector2i(monitor["w"], monitor["h"]), "primary": monitor["primary"], "path": monitor["key"]})
	return result


func start(monitor_index: int) -> bool:
	var monitors := PcLink.monitors()
	if monitor_index < 0 or monitor_index >= monitors.size():
		_error = "нет монитора %d" % monitor_index
		return false
	_key = monitors[monitor_index]["key"]
	_size = Vector2i(monitors[monitor_index]["w"], monitors[monitor_index]["h"])
	_running = true
	return true


## ScreenPanel hands over each layer it makes for this monitor (slice o5).
func attach_layer(layer: OpenXRCompositionLayer) -> void:
	if PcLink.screens != null:
		PcLink.screens.attach(_key, layer)


func stop() -> void:
	if _running and PcLink.screens != null:
		PcLink.screens.detach(_key)
	_running = false


func is_running() -> bool:
	return _running


func update() -> void:
	pass


func get_texture() -> Texture2D:
	return null


func get_size() -> Vector2i:
	return _size


func get_frame_count() -> int:
	return PcLink.screens.frames(_key) if PcLink.screens != null else 0


func get_last_error() -> String:
	return _error
