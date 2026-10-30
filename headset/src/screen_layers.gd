class_name ScreenLayers
extends RefCounted
## The hybrid (pc-render branch, 30.10.2026): the screens nearest the gaze come
## as their own streams, as in variant 1, each decoded straight into the Android
## surface of a layer behind the eyes' picture; the PC's picture is see-through
## there (its alpha mask). The PC says which layers to show and where, tagged
## with the pose of the picture whose holes match them: a layer moves when that
## picture is shown, not when the message comes (the picture is later by the
## encoding), so a panel being carried keeps its hole. The PC opens a hole only
## for a screen this reports as showing pictures (shown_keys).

const FIRST_RECEIVER_ID := 100
## The nearest layer's sort order; each farther one gets one less. All are
## behind the eyes' picture (negative), and the compositor has no depth between
## layers: with one order for all, a screen behind showed over the one in front
## (30.10.2026).
const NEAREST_ORDER := -2
## A stream that ended is started again after this.
const RETRY_SEC := 1.0
## Before the PC has said the stream's size.
const DEFAULT_SIZE := Vector2i(1920, 1080)

## com.workplace.headset.VideoReceiver, null off Android.
var _receiver: Variant
var _origin: XROrigin3D
var _address := ""
## Monitor key -> {"port", "w", "h"} (LinkProtocol.video).
var _videos: Dictionary = {}
## [pose id, layers] not yet shown, oldest first.
var _pending: Array = []
## Monitor key -> {"layer", "kind", "id", "started", "retry_at"}.
var _layers: Dictionary = {}
var _next_id := FIRST_RECEIVER_ID


func _init(receiver: Variant, origin: XROrigin3D) -> void:
	_receiver = receiver
	_origin = origin


func set_address(address: String) -> void:
	_address = address


## The PC's stream list (it starts them anew): every receiver starts again.
func set_videos(videos: Array) -> void:
	_videos.clear()
	for video: Dictionary in videos:
		_videos[video["key"]] = video
	for key: String in _layers:
		_stop(_layers[key])
		_layers[key]["retry_at"] = 0.0
	print("[screens] потоков экранов у ПК: %d" % _videos.size())


func queue(pose: int, layers: Array) -> void:
	_pending.append([pose, layers])


## The eyes' picture of pose `pose` is shown now: the newest layers up to it.
func picture_shown(pose: int) -> void:
	var chosen: Variant = null
	while not _pending.is_empty() and _pending[0][0] <= pose:
		chosen = _pending.pop_front()
	if chosen != null:
		_apply(chosen[1])


## Every frame: the layers ordered by distance from `eye`, receivers whose
## stream ended start again, new layers start once their surface is there.
func poll(now: float, eye: Vector3) -> void:
	_sort(eye)
	if _receiver == null:
		return
	for key: String in _layers:
		var screen: Dictionary = _layers[key]
		if screen["started"]:
			if not _receiver.isAlive(screen["id"]):
				print("[screens] %s: поток прервался (%s)" % [key, _receiver.status(screen["id"])])
				_stop(screen)
				screen["retry_at"] = now + RETRY_SEC
			continue
		if now < screen["retry_at"] or not _videos.has(key) or _address == "":
			continue
		var surface: Variant = (screen["layer"] as OpenXRCompositionLayer).get_android_surface()
		if surface == null:
			continue
		_receiver.start(screen["id"], surface, _address, _videos[key]["port"])
		screen["started"] = true
		print("[screens] %s: принимаю с %s:%d" % [key, _address, _videos[key]["port"]])


## Keys whose layer shows pictures now (the PC opens their holes).
func shown_keys() -> Array:
	var result: Array = []
	if _receiver == null:
		return result
	for key: String in _layers:
		var screen: Dictionary = _layers[key]
		if screen["started"] and _receiver.isAlive(screen["id"]) and _receiver.framesShown(screen["id"]) > 0:
			result.append(key)
	return result


func describe() -> String:
	return "экранов отдельно: %d" % shown_keys().size()


func reset() -> void:
	for key: String in _layers.keys():
		_remove(key)
	_pending.clear()
	_videos.clear()


func _apply(layers: Array) -> void:
	var wanted := {}
	for described: Dictionary in layers:
		var key: String = described["key"]
		wanted[key] = true
		if _layers.has(key) and _layers[key]["kind"] != described["kind"]:
			_remove(key)
		if not _layers.has(key):
			_layers[key] = _make(key, described["kind"])
		var layer: OpenXRCompositionLayer = _layers[key]["layer"]
		layer.transform = described["xf"]
		if layer is OpenXRCompositionLayerCylinder:
			var cylinder := layer as OpenXRCompositionLayerCylinder
			cylinder.radius = described["radius"]
			cylinder.central_angle = described["angle"]
			cylinder.aspect_ratio = described["aspect"]
		else:
			(layer as OpenXRCompositionLayerQuad).quad_size = described["size"]
	for key: String in _layers.keys():
		if not wanted.has(key):
			_remove(key)


## How far the nearest screen is that `eye` looks at along `forward` (within
## `cone` radians of it); -1 if none.
func looked_at_distance(eye: Vector3, forward: Vector3, cone: float) -> float:
	var nearest := -1.0
	for key: String in _layers:
		var middle := _middle(_layers[key]["layer"])
		if forward.angle_to(middle - eye) > cone:
			continue
		var distance := (middle - eye).dot(forward)
		if distance > 0.0 and (nearest < 0.0 or distance < nearest):
			nearest = distance
	return nearest


static func _middle(layer: OpenXRCompositionLayer) -> Vector3:
	if layer is OpenXRCompositionLayerCylinder:
		# A cylinder layer sits at its axis; the screen is `radius` in front.
		return layer.transform * Vector3(0.0, 0.0, -(layer as OpenXRCompositionLayerCylinder).radius)
	return layer.transform.origin


func _sort(eye: Vector3) -> void:
	var ranked: Array = []
	for key: String in _layers:
		var layer: OpenXRCompositionLayer = _layers[key]["layer"]
		ranked.append([_middle(layer).distance_squared_to(eye), layer])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for i in ranked.size():
		var layer: OpenXRCompositionLayer = ranked[i][1]
		if layer.sort_order != NEAREST_ORDER - i:
			layer.sort_order = NEAREST_ORDER - i


func _make(key: String, kind: String) -> Dictionary:
	var layer: OpenXRCompositionLayer = OpenXRCompositionLayerCylinder.new() if kind == "cylinder" \
			else OpenXRCompositionLayerQuad.new()
	layer.use_android_surface = true
	var size := DEFAULT_SIZE
	if _videos.has(key):
		size = Vector2i(_videos[key]["w"], _videos[key]["h"])
	layer.android_surface_size = size
	# As ScreenPanel's: on the Compatibility renderer the surface came upside down.
	layer.set(&"XR_FB_composition_layer_image_layout/vertical_flip", true)
	layer.sort_order = NEAREST_ORDER
	_origin.add_child(layer)
	var screen := {"layer": layer, "kind": kind, "id": _next_id, "started": false, "retry_at": 0.0}
	_next_id += 1
	return screen


func _remove(key: String) -> void:
	var screen: Dictionary = _layers[key]
	_stop(screen)
	(screen["layer"] as Node).queue_free()
	_layers.erase(key)


func _stop(screen: Dictionary) -> void:
	if screen["started"] and _receiver != null:
		_receiver.stop(screen["id"])
	screen["started"] = false

