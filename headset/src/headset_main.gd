extends Node3D
## WoRkPlace in the headset (slice o1): the first scene on the Quest itself —
## OpenXR running on the headset, the hands drawn as their joints, a line with
## the frame rate. Built in code, like the PC app; the scene file only holds this.
## Slice o2: finds the PC (HeadsetLink) and shows its monitors as grey frames
## laid out like the Windows desktop. Slice o3: the PC's primary monitor as
## video on an OpenXR quad layer; the Java VideoReceiver decodes into its surface.

const HAND_TRACKERS: Array[StringName] = [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]
const HAND_COLORS: Array[Color] = [Color(0.45, 0.75, 1.0), Color(1.0, 0.7, 0.45)]
const JOINT_RADIUS := 0.006
## The line of text: this far ahead of where the user stood at the start, at eye height.
const LABEL_AT := Vector3(0.0, 1.85, -1.4)
## The video screen: its centre and width; the height follows the picture.
const SCREEN_AT := Vector3(0.0, 1.25, -1.4)
const SCREEN_WIDTH := 1.6
## The PC's desktop in miniature: its centre here, this many metres per pixel.
const DESKTOP_AT := Vector3(0.0, 0.6, -1.1)
## ...but never wider than DESKTOP_WIDTH.
const METRES_PER_PIXEL := 0.0004
const DESKTOP_WIDTH := 0.8
const FRAME_GAP := 0.01

var _xr: XRInterface
var _origin: XROrigin3D
var _camera: XRCamera3D
var _label: Label3D
var _hands: Array[MultiMeshInstance3D] = []
var _seen: Array[bool] = [false, false]
var _link: HeadsetLink
var _desktop: Node3D
## com.workplace.headset.VideoReceiver (headset/java), null off Android.
var _receiver: Variant = null
var _screen: OpenXRCompositionLayerQuad
## The stream waiting for the layer's surface to exist, {} if none.
var _pending_video: Dictionary = {}
var _video_line := ""
var _shown_before := 0
var _next_video_line := 0.0


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
	_label = Label3D.new()
	_label.position = LABEL_AT
	_label.pixel_size = 0.0012
	_label.font_size = 40
	_label.outline_size = 10
	_origin.add_child(_label)
	_desktop = Node3D.new()
	_desktop.position = DESKTOP_AT
	_origin.add_child(_desktop)
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
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	ball.material = material
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


func _process(_delta: float) -> void:
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
	var now := Time.get_ticks_msec() / 1000.0
	_link.poll(now)
	if _link.monitors_changed:
		_link.monitors_changed = false
		_show_desktop(_link.monitors)
	if _link.video_changed:
		_link.video_changed = false
		_show_video(_link.video)
	_update_video(now)
	_label.text = "WoRkPlace в шлеме\n%d к/с  |  руки: %s, %s\n%s" % [Engine.get_frames_per_second(),
			"левая" if _seen[0] else "—", "правая" if _seen[1] else "—", _link.describe() + _video_line]


## Starts or stops showing the PC's stream. The layer gets its Android surface
## a frame or more after it is set up, so the receiver starts in _update_video.
func _show_video(video: Dictionary) -> void:
	_pending_video = {}
	if _receiver != null:
		_receiver.stop()
	if _screen != null:
		_screen.queue_free()
		_screen = null
	_video_line = ""
	if video.is_empty():
		return
	_screen = OpenXRCompositionLayerQuad.new()
	_screen.use_android_surface = true
	_screen.android_surface_size = Vector2i(video["w"], video["h"])
	_screen.quad_size = Vector2(SCREEN_WIDTH, SCREEN_WIDTH * video["h"] / video["w"])
	_screen.position = SCREEN_AT
	_origin.add_child(_screen)
	_pending_video = video


func _update_video(now: float) -> void:
	if not _pending_video.is_empty() and _screen != null and _receiver != null:
		var surface: Variant = _screen.get_android_surface()
		if surface != null:
			_receiver.start(surface, _link.pc_address, _pending_video["port"])
			print("[video] принимаю с %s:%d" % [_link.pc_address, _pending_video["port"]])
			_pending_video = {}
			_shown_before = 0
			_next_video_line = now
	if _screen == null or _receiver == null or not _pending_video.is_empty() or now < _next_video_line:
		return
	_next_video_line = now + 1.0
	var shown: int = _receiver.framesShown()
	_video_line = "\nвидео: %s, %d к/с, декодер %.0f мс, принято %.1f МБ" % [_receiver.status(), shown - _shown_before,
			_receiver.decodeMs(), _receiver.bytesReceived() / 1e6]
	_shown_before = shown


## Each monitor a grey frame with its name and size, placed as on the desktop.
func _show_desktop(monitors: Array) -> void:
	for child in _desktop.get_children():
		child.queue_free()
	if monitors.is_empty():
		return
	var bounds := Rect2i(monitors[0]["x"], monitors[0]["y"], monitors[0]["w"], monitors[0]["h"])
	for monitor: Dictionary in monitors:
		bounds = bounds.merge(Rect2i(monitor["x"], monitor["y"], monitor["w"], monitor["h"]))
	var centre := Vector2(bounds.get_center())
	var scale := minf(METRES_PER_PIXEL, DESKTOP_WIDTH / bounds.size.x)
	for monitor: Dictionary in monitors:
		var rect := Rect2(monitor["x"], monitor["y"], monitor["w"], monitor["h"])
		var frame := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = rect.size * scale - Vector2(FRAME_GAP, FRAME_GAP)
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(0.32, 0.36, 0.42) if monitor["primary"] else Color(0.22, 0.24, 0.28)
		quad.material = material
		frame.mesh = quad
		# Desktop y grows downwards.
		var at := (rect.get_center() - centre) * scale
		frame.position = Vector3(at.x, -at.y, 0.0)
		_desktop.add_child(frame)
		var caption := Label3D.new()
		caption.text = "%s\n%d×%d" % [String(monitor["name"]).trim_prefix("\\\\.\\"), monitor["w"], monitor["h"]]
		caption.pixel_size = 0.0004 * scale / METRES_PER_PIXEL + 0.0002
		caption.font_size = 32
		caption.position = Vector3(0.0, 0.0, 0.002)
		frame.add_child(caption)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		if _receiver != null:
			_receiver.stop()
		if _link != null:
			_link.close()
