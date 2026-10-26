extends Node3D
## WoRkPlace in the headset. Slice o1: OpenXR on the Quest itself, the hands
## drawn as their joints. Slice o2: finds the PC (HeadsetLink). Slice o3: a
## monitor as video on an OpenXR quad layer, decoded by the Java VideoReceiver
## straight into the layer's surface. Slice o4: every monitor on an arc
## (ScreenArc), a ray from each hand (HandPointer) that moves the PC's cursor
## and clicks by pinching (CursorFilter, the PC app's own). The Quest 3S
## decodes at most 6 streams at once: the screens nearest the gaze (and the one
## a hand points at) are live, the others keep their last frame. Built in code, like
## the PC app; the scene file only holds this.

const HAND_TRACKERS: Array[StringName] = [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]
const HAND_COLORS: Array[Color] = [Color(0.45, 0.75, 1.0), Color(1.0, 0.7, 0.45)]
const SIDE_SIGNS: Array[float] = [-1.0, 1.0]
const JOINT_RADIUS := 0.006
## The line of text, low and close, under the screens.
const LABEL_AT := Vector3(0.0, 0.75, -1.0)
const RAY_LENGTH := 3.0
const RAY_WIDTH := 0.003
const DOT_RADIUS := 0.008
const BUTTON_LEFT := 0
const BUTTON_RIGHT := 1
## Hardware decoders the Quest 3S gives one app (the 7th fails with NO_MEMORY).
const MAX_LIVE_SCREENS := 6
## How often the live set is chosen again.
const LIVE_CHECK_SEC := 0.3

var _xr: XRInterface
var _origin: XROrigin3D
var _camera: XRCamera3D
var _label: Label3D
var _hands: Array[MultiMeshInstance3D] = []
var _seen: Array[bool] = [false, false]
var _link: HeadsetLink
## com.workplace.headset.VideoReceiver (headset/java), null off Android.
var _receiver: Variant = null
## Monitor key -> {"layer": OpenXRCompositionLayerQuad, "id": receiver id,
## "video": LinkProtocol.video, "started": bool}.
var _screens: Dictionary = {}
var _next_screen_id := 1
var _video_line := ""
## Receiver id -> frames shown at the last status line.
var _shown_before: Dictionary = {}
var _next_video_line := 0.0
## Keys of the screens that should be decoding now.
var _live: Dictionary = {}
var _next_live_check := 0.0
## The screen each hand pointed at last frame ("" none).
var _pointed: Array[String] = ["", ""]

var _pointers: Array[HandPointer] = [HandPointer.new(-1.0), HandPointer.new(1.0)]
var _filters: Array[CursorFilter] = []
var _rays: Array[Node3D] = []
var _dots: Array[MeshInstance3D] = []
## The hand that moves the cursor (-1 none) and the button it holds (-1 none).
var _driver := -1
var _held_button := -1


func _ready() -> void:
	_xr = XRServer.find_interface("OpenXR")
	if _xr != null and _xr.is_initialized():
		get_viewport().use_xr = true
		# The headset paces the frames; vsync on top of it would only halve them.
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		print("[xr] OpenXR в шлеме поднят")
	else:
		print("[xr] OpenXR не поднялся")
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.08, 0.09, 0.11)
	add_child(environment)
	_origin = XROrigin3D.new()
	add_child(_origin)
	_camera = XRCamera3D.new()
	_origin.add_child(_camera)
	for i in 2:
		_hands.append(_build_hand(HAND_COLORS[i]))
		_build_ray(HAND_COLORS[i])
		var filter := CursorFilter.new()
		# The user switched the double click off in the PC app (24.10.2026).
		filter.double_click_sec = 0.0
		_filters.append(filter)
	_label = Label3D.new()
	_label.position = LABEL_AT
	_label.pixel_size = 0.0008
	_label.font_size = 40
	_label.outline_size = 10
	_origin.add_child(_label)
	_link = HeadsetLink.new(OS.get_model_name())
	if OS.get_name() == "Android":
		_receiver = JavaClassWrapper.wrap("com.workplace.headset.VideoReceiver")
		print("[video] приёмник %s" % ("на месте" if _receiver != null else "не найден"))


## A hand: a small ball at each of its joints, hidden until it is tracked.
func _build_hand(color: Color) -> MultiMeshInstance3D:
	var ball := SphereMesh.new()
	ball.radius = JOINT_RADIUS
	ball.height = JOINT_RADIUS * 2.0
	ball.radial_segments = 8
	ball.rings = 4
	ball.material = _flat(color)
	var joints := MultiMesh.new()
	joints.transform_format = MultiMesh.TRANSFORM_3D
	joints.mesh = ball
	joints.instance_count = XRHandTracker.HAND_JOINT_MAX
	var hand := MultiMeshInstance3D.new()
	hand.multimesh = joints
	hand.visible = false
	# Joint transforms are in the play space: the hands hang under the origin.
	_origin.add_child(hand)
	return hand


## A ray: a thin box one metre long along -Z, stretched to length by the parent's
## scale; and a dot where it meets a screen.
func _build_ray(color: Color) -> void:
	var ray := Node3D.new()
	ray.visible = false
	var line := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(RAY_WIDTH, RAY_WIDTH, 1.0)
	box.material = _flat(Color(color, 0.5))
	line.mesh = box
	line.position = Vector3(0.0, 0.0, -0.5)
	ray.add_child(line)
	add_child(ray)
	_rays.append(ray)
	var dot := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = DOT_RADIUS
	ball.height = DOT_RADIUS * 2.0
	ball.material = _flat(color)
	dot.mesh = ball
	dot.visible = false
	add_child(dot)
	_dots.append(dot)


func _flat(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	if color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for i in 2:
		var tracker := XRServer.get_tracker(HAND_TRACKERS[i]) as XRHandTracker
		var tracked := tracker != null and tracker.has_tracking_data
		_hands[i].visible = tracked
		if tracked:
			for joint in XRHandTracker.HAND_JOINT_MAX:
				_hands[i].multimesh.set_instance_transform(joint, Transform3D(Basis.IDENTITY,
						tracker.get_hand_joint_transform(joint).origin))
		if tracked != _seen[i]:
			_seen[i] = tracked
			print("[hands] %s: %s" % ["левая" if i == 0 else "правая", "видна" if tracked else "пропала"])
		_pointers[i].update(tracker, _origin.global_transform, _camera.global_transform, delta)
	_link.poll(now)
	if _link.videos_changed or _link.monitors_changed:
		_link.videos_changed = false
		_link.monitors_changed = false
		_sync_screens()
	if now >= _next_live_check:
		_next_live_check = now + LIVE_CHECK_SEC
		_choose_live()
	_start_receivers()
	_point(now)
	_update_video_line(now)
	_label.text = "WoRkPlace в шлеме  |  %d к/с  |  руки: %s, %s\n%s%s" % [Engine.get_frames_per_second(),
			"левая" if _seen[0] else "—", "правая" if _seen[1] else "—", _link.describe(), _video_line]


## Brings the screens in line with the streams the PC offers and puts them on the arc.
func _sync_screens() -> void:
	var offered := {}
	for video: Dictionary in _link.videos:
		offered[video["key"]] = video
	for key: String in _screens.keys():
		if not offered.has(key) or offered[key] != _screens[key]["video"]:
			_drop_screen(key)
	var placed := ScreenArc.place(_link.monitors.filter(func(monitor: Dictionary) -> bool: return offered.has(monitor["key"])))
	for key: String in offered:
		if not placed.has(key):
			continue
		var video: Dictionary = offered[key]
		if not _screens.has(key):
			var layer := OpenXRCompositionLayerQuad.new()
			layer.use_android_surface = true
			layer.android_surface_size = Vector2i(video["w"], video["h"])
			# The scene is drawn over the layer with a hole cut for it, so the hands
			# and rays stay in front of the screens.
			layer.enable_hole_punch = true
			_origin.add_child(layer)
			_screens[key] = {"layer": layer, "id": _next_screen_id, "video": video, "started": false}
			_next_screen_id += 1
		var screen_layer: OpenXRCompositionLayerQuad = _screens[key]["layer"]
		screen_layer.transform = placed[key]["transform"]
		screen_layer.quad_size = placed[key]["size"]
	print("[video] экранов %d" % _screens.size())


func _drop_screen(key: String) -> void:
	var screen: Dictionary = _screens[key]
	if _receiver != null and screen["started"]:
		_receiver.stop(screen["id"])
	screen["layer"].queue_free()
	_screens.erase(key)


## A layer gets its Android surface a frame or more after it is set up: each
## receiver starts once its surface is there.
func _start_receivers() -> void:
	if _receiver == null:
		return
	for key: String in _screens:
		var screen: Dictionary = _screens[key]
		if screen["started"] or not _live.has(key):
			continue
		var surface: Variant = screen["layer"].get_android_surface()
		if surface != null:
			_receiver.start(screen["id"], surface, _link.pc_address, screen["video"]["port"])
			screen["started"] = true
			print("[video] %s: принимаю с %s:%d" % [key, _link.pc_address, screen["video"]["port"]])


## Picks the screens to decode: the ones a hand points at, then the nearest to
## where the user looks; the rest stop and keep their last frame on the layer.
func _choose_live() -> void:
	var forward := -_camera.global_basis.z
	var eye := _camera.global_position
	var ranked: Array = []
	for key: String in _screens:
		var layer: OpenXRCompositionLayerQuad = _screens[key]["layer"]
		var angle := forward.angle_to(layer.global_position - eye)
		if key in _pointed:
			angle = -1.0
		ranked.append([angle, key])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	_live.clear()
	for i in mini(MAX_LIVE_SCREENS, ranked.size()):
		_live[ranked[i][1]] = true
	if _receiver == null:
		return
	for key: String in _screens:
		var screen: Dictionary = _screens[key]
		if screen["started"] and not _live.has(key):
			_receiver.stop(screen["id"])
			screen["started"] = false


## The rays, the dots and the cursor. One hand drives the cursor at a time: the
## one holding a button keeps it; otherwise the right hand if it is on a screen.
func _point(now: float) -> void:
	var hits: Array = [null, null]
	for i in 2:
		var pointer := _pointers[i]
		_rays[i].visible = pointer.active
		_dots[i].visible = false
		if not pointer.active:
			_pointed[i] = ""
			continue
		var hit := _hit(pointer.origin, pointer.direction)
		_pointed[i] = hit.get("key", "")
		var length := RAY_LENGTH
		if not hit.is_empty():
			hits[i] = hit
			length = hit["distance"]
			_dots[i].visible = true
			_dots[i].global_position = pointer.origin + pointer.direction * length
		_rays[i].global_transform = Transform3D(Basis.looking_at(pointer.direction), pointer.origin) \
				.scaled_local(Vector3(1.0, 1.0, length))
	if _held_button < 0:
		_driver = 1 if hits[1] != null else (0 if hits[0] != null else -1)
	if _driver < 0:
		return
	var hit: Variant = hits[_driver]
	var pointer := _pointers[_driver]
	var on_screen := hit != null
	var desktop := Vector2(hit["desktop"]) if on_screen else Vector2.ZERO
	var result := _filters[_driver].update(desktop, on_screen, pointer.left or pointer.right, now)
	if result.move:
		_send_pointer(result.position)
	if result.press:
		_held_button = BUTTON_LEFT if pointer.left else BUTTON_RIGHT
		_link.send(LinkProtocol.button(_held_button, true))
	if result.release and _held_button >= 0:
		_link.send(LinkProtocol.button(_held_button, false))
		_held_button = -1
	if not pointer.active and _held_button >= 0:
		# The hand was lost while holding: let go rather than drag forever.
		_link.send(LinkProtocol.button(_held_button, false))
		_held_button = -1


## The nearest screen along the ray: {"distance", "key", "desktop": Vector2i}, or {}.
func _hit(origin: Vector3, direction: Vector3) -> Dictionary:
	var best := {}
	for key: String in _screens:
		var layer: OpenXRCompositionLayerQuad = _screens[key]["layer"]
		var distance := PointerMath.ray_rect_distance(origin, direction, layer.global_transform, layer.quad_size)
		if distance < 0.0 or (not best.is_empty() and distance >= best["distance"]):
			continue
		var uv := PointerMath.rect_uv(origin + direction * distance, layer.global_transform, layer.quad_size)
		var monitor := _monitor(key)
		if monitor.is_empty():
			continue
		var pixel := Vector2i((uv * Vector2(monitor["w"], monitor["h"])).floor())
		best = {"distance": distance, "key": key, "desktop": Vector2i(monitor["x"], monitor["y"]) + pixel}
	return best


func _monitor(key: String) -> Dictionary:
	for monitor: Dictionary in _link.monitors:
		if monitor["key"] == key:
			return monitor
	return {}


## The cursor filter works in desktop pixels (one space for every screen); the
## PC wants them relative to a monitor.
func _send_pointer(desktop: Vector2) -> void:
	var at := Vector2i(desktop)
	for monitor: Dictionary in _link.monitors:
		var rect := Rect2i(monitor["x"], monitor["y"], monitor["w"], monitor["h"])
		if rect.has_point(at):
			_link.send(LinkProtocol.pointer(monitor["key"], at - rect.position))
			return


func _update_video_line(now: float) -> void:
	if _receiver == null or _screens.is_empty():
		_video_line = ""
		return
	if now < _next_video_line:
		return
	_next_video_line = now + 1.0
	var shown := 0
	var live := 0
	var bytes := 0
	var slowest := 0.0
	var problems: Array[String] = []
	for key: String in _screens:
		var id: int = _screens[key]["id"]
		var frames: int = _receiver.framesShown(id)
		shown += maxi(0, frames - _shown_before.get(id, 0))
		_shown_before[id] = frames
		live += 1 if _screens[key]["started"] else 0
		bytes += _receiver.bytesReceived(id)
		slowest = maxf(slowest, _receiver.decodeMs(id))
		var status: String = _receiver.status(id)
		if status.begins_with("ошибка"):
			problems.append(status)
	_video_line = "\nэкранов %d, живых %d: %d к/с всего, декодер до %.0f мс, принято %.0f МБ%s" % [_screens.size(),
			live, shown, slowest, bytes / 1e6, ("\n" + problems[0]) if not problems.is_empty() else ""]


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		if _held_button >= 0 and _link != null:
			_link.send(LinkProtocol.button(_held_button, false))
			_held_button = -1
		if _receiver != null:
			_receiver.stopAll()
		for key: String in _screens.keys():
			_screens[key]["started"] = false
		if _link != null:
			_link.close()
