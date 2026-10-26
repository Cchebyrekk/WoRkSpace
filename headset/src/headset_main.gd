extends Node3D
## WoRkPlace in the headset (slice o1): the first scene on the Quest itself —
## OpenXR running on the headset, the hands drawn as their joints, a line with
## the frame rate. Built in code, like the PC app; the scene file only holds this.

const HAND_TRACKERS: Array[StringName] = [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]
const HAND_COLORS: Array[Color] = [Color(0.45, 0.75, 1.0), Color(1.0, 0.7, 0.45)]
const JOINT_RADIUS := 0.006
## The line of text: this far ahead of where the user stood at the start, at eye height.
const LABEL_AT := Vector3(0.0, 1.45, -1.2)

var _xr: XRInterface
var _origin: XROrigin3D
var _camera: XRCamera3D
var _label: Label3D
var _hands: Array[MultiMeshInstance3D] = []
var _seen: Array[bool] = [false, false]


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
	_label.text = "WoRkPlace в шлеме\n%d к/с  |  руки: %s, %s" % [Engine.get_frames_per_second(),
			"левая" if _seen[0] else "—", "правая" if _seen[1] else "—"]
