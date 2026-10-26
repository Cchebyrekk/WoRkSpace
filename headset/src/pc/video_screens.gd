class_name VideoScreens
extends RefCounted
## The PC's video streams shown on the panels' layers (slice o5): each panel's
## ScreenCapture stand-in attaches its layer here; the Java VideoReceiver decodes
## the monitor's stream straight into the layer's Android surface. The Quest 3S
## gives an app 6 hardware decoders (slice o4): the panels nearest the gaze are
## live, the others keep their last frame.

const MAX_LIVE := 6
const LIVE_CHECK_SEC := 0.3

## com.workplace.headset.VideoReceiver, null off Android.
var _receiver: Variant = null
## Monitor key -> {"layer", "id", "started", "port"}.
var _attached: Dictionary = {}
var _next_id := 1
var _live: Dictionary = {}
var _next_live_check := 0.0
## The streams offered when the attached receivers were started (a change restarts them).
var _videos_signature := ""


func _init() -> void:
	if OS.get_name() == "Android":
		_receiver = JavaClassWrapper.wrap("com.workplace.headset.VideoReceiver")
		print("[video] приёмник %s" % ("на месте" if _receiver != null else "не найден"))


## A panel's layer for monitor `key`; a new layer for the same key replaces the old.
func attach(key: String, layer: OpenXRCompositionLayer) -> void:
	detach(key)
	_attached[key] = {"layer": layer, "id": _next_id, "started": false, "port": 0}
	_next_id += 1


func detach(key: String) -> void:
	if not _attached.has(key):
		return
	var screen: Dictionary = _attached[key]
	if _receiver != null and screen["started"]:
		_receiver.stop(screen["id"])
	_attached.erase(key)


func frames(key: String) -> int:
	if _receiver == null or not _attached.has(key):
		return 0
	return _receiver.framesShown(_attached[key]["id"])


## Every frame: follows the PC's stream list, picks the live panels by the gaze
## (`camera` may be null) and starts receivers whose surfaces are ready.
func poll(now: float, camera: Camera3D) -> void:
	if _receiver == null:
		return
	var videos := PcLink.link.videos if PcLink.link != null else []
	var signature := str(videos)
	if signature != _videos_signature:
		_videos_signature = signature
		for key: String in _attached:
			_stop(_attached[key])
	if now >= _next_live_check and camera != null:
		_next_live_check = now + LIVE_CHECK_SEC
		_choose_live(camera)
	for key: String in _attached:
		var screen: Dictionary = _attached[key]
		if screen["started"] or not _live.has(key):
			continue
		var port := _port_of(videos, key)
		var layer: OpenXRCompositionLayer = screen["layer"]
		if port <= 0 or not is_instance_valid(layer):
			continue
		var surface: Variant = layer.get_android_surface()
		if surface == null:
			continue
		_receiver.start(screen["id"], surface, PcLink.link.pc_address, port)
		screen["started"] = true
		screen["port"] = port
		print("[video] %s: принимаю с %s:%d" % [key, PcLink.link.pc_address, port])


## Forgets every panel (the world is being built again).
func reset() -> void:
	stop_all()
	_attached.clear()
	_live.clear()


func stop_all() -> void:
	if _receiver != null:
		_receiver.stopAll()
	for key: String in _attached:
		_attached[key]["started"] = false


## A line for the status: how many panels decode and the slowest decoder.
func describe() -> String:
	var live := 0
	for key: String in _attached:
		live += 1 if _attached[key]["started"] else 0
	return "экранов %d, живых %d" % [_attached.size(), live]


func _stop(screen: Dictionary) -> void:
	if screen["started"]:
		_receiver.stop(screen["id"])
		screen["started"] = false


func _choose_live(camera: Camera3D) -> void:
	var forward := -camera.global_basis.z
	var eye := camera.global_position
	var ranked: Array = []
	for key: String in _attached:
		var layer: OpenXRCompositionLayer = _attached[key]["layer"]
		if is_instance_valid(layer):
			ranked.append([forward.angle_to(layer.global_position - eye), key])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	_live.clear()
	for i in mini(MAX_LIVE, ranked.size()):
		_live[ranked[i][1]] = true
	for key: String in _attached:
		if not _live.has(key):
			_stop(_attached[key])


static func _port_of(videos: Array, key: String) -> int:
	for video: Dictionary in videos:
		if video["key"] == key:
			return video["port"]
	return 0
