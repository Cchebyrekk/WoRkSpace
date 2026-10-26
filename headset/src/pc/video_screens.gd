class_name VideoScreens
extends RefCounted
## The PC's video streams shown on the panels' layers (slice o5): each panel's
## ScreenCapture stand-in attaches its layer here; the Java VideoReceiver decodes
## the monitor's stream straight into the layer's Android surface. The Quest 3S
## gives an app 6 hardware decoders (slice o4): the panels nearest the gaze are
## live, the others keep their last frame.

## Without the world's settings yet (HeadsetOptions.live_screens is the user's).
const DEFAULT_LIVE := 6
const LIVE_CHECK_SEC := 0.3
## A live panel keeps its place until another is this much nearer the gaze
## (radians, 10°): on the edge two panels took turns every few seconds, each
## time a new connection and a key frame (26.10.2026).
const LIVE_STICKINESS := 0.17

## com.workplace.headset.VideoReceiver, null off Android.
var _receiver: Variant = null
## Monitor key -> {"layer", "id", "started", "port"}.
var _attached: Dictionary = {}
var _next_id := 1
var _live: Dictionary = {}
var _next_live_check := 0.0
## The stream list the attached receivers were started for (a new one restarts them).
var _videos_serial := -1
## A receiver whose stream ended is started again after this, doubling with each
## failure in a row up to RETRY_MAX_SEC (each try makes a decoder: trying every
## second with too many screens live made the headset stall, 26.10.2026).
const RETRY_SEC := 1.0
const RETRY_MAX_SEC := 30.0
## How many decoders this headset gives at once, learnt from the first refusal
## (the user's setting may ask for more); learnt again when the setting changes.
var _decoder_limit := 1 << 30
var _limit_for_setting := -1


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
	var serial := PcLink.link.videos_serial if PcLink.link != null else 0
	if serial != _videos_serial:
		_videos_serial = serial
		for key: String in _attached:
			_stop(_attached[key])
	# A stream that ended (the PC restarted it, the connection broke) leaves its
	# panel frozen while it still counts as live (26.10.2026): it starts again,
	# later each time it fails. A decoder refused means the headset has no more:
	# fewer panels stay live from then on.
	for key: String in _attached:
		var screen: Dictionary = _attached[key]
		if not screen["started"]:
			continue
		if _receiver.isAlive(screen["id"]):
			# Showing pictures again: the next failure waits the shortest time.
			if screen.get("failures", 0) > 0 and _receiver.framesShown(screen["id"]) > 0:
				screen["failures"] = 0
			continue
		var failures: int = screen.get("failures", 0) + 1
		screen["failures"] = failures
		screen["retry_at"] = now + minf(RETRY_SEC * pow(2.0, failures - 1), RETRY_MAX_SEC)
		if _receiver.decoderFailed(screen["id"]):
			var working := _working_count()
			if working < _decoder_limit:
				_decoder_limit = maxi(working, 1)
				print("[video] шлем дал только %d декодеров — живых экранов будет не больше" % _decoder_limit)
		else:
			print("[video] %s: поток прервался (%s), снова через %.0f с" % [key, _receiver.status(screen["id"]),
					screen["retry_at"] - now])
		_stop(screen)
	if now >= _next_live_check and camera != null:
		_next_live_check = now + LIVE_CHECK_SEC
		_choose_live(camera)
	for key: String in _attached:
		var screen: Dictionary = _attached[key]
		if screen["started"] or not _live.has(key) or now < screen.get("retry_at", 0.0):
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


## Receivers decoding now.
func _working_count() -> int:
	var count := 0
	for key: String in _attached:
		if _attached[key]["started"] and _receiver.isAlive(_attached[key]["id"]):
			count += 1
	return count


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
			var angle := forward.angle_to(layer.global_position - eye)
			if _attached[key]["started"]:
				angle -= LIVE_STICKINESS
			if key == PcLink.cursor_key:
				angle = -INF
			ranked.append([angle, key])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	_live.clear()
	var wanted := HeadsetOptions.current.live_screens if HeadsetOptions.current != null else DEFAULT_LIVE
	if wanted != _limit_for_setting:
		_limit_for_setting = wanted
		_decoder_limit = 1 << 30
	for i in mini(mini(wanted, _decoder_limit), ranked.size()):
		_live[ranked[i][1]] = true
	for key: String in _attached:
		if not _live.has(key):
			_stop(_attached[key])


static func _port_of(videos: Array, key: String) -> int:
	for video: Dictionary in videos:
		if video["key"] == key:
			return video["port"]
	return 0
