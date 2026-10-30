class_name RemoteXR
extends XRInterfaceExtension
## The PC-rendered variant of the own link (branch pc-render): the headset sends
## its head, eyes, hands and controllers; this interface stands in for OpenXR on
## the PC so main.gd runs unchanged against those trackers, and Godot renders the
## two eyes into its render target, which `frame_drawn` hands on for streaming.
## The trackers carry the names OpenXR gives them (main.gd looks them up by name).

## Called on the rendering thread after the eyes are drawn: (texture RID of the
## render target — a 2-layer array, one layer per eye; the head pose they were
## drawn with; its id from the headset).
signal frame_drawn(texture: RID, head: Transform3D, pose_id: int)

const HAND_TRACKER_NAMES: Array[StringName] = [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]
const CONTROLLER_TRACKER_NAMES: Array[StringName] = [&"left_hand", &"right_hand"]
## The controller inputs passed over (OpenXR's default action map, as main.gd reads them).
const FLOAT_INPUTS: Array[StringName] = [&"trigger", &"grip"]
const VECTOR_INPUTS: Array[StringName] = [&"primary"]
const BUTTON_INPUTS: Array[StringName] = [&"trigger_click", &"trigger_touch", &"grip_click", &"primary_click",
		&"primary_touch", &"ax_button", &"ax_touch", &"by_button", &"by_touch", &"menu_button"]

## Per-eye picture size; the headset's own is larger, a stream this size keeps the bitrate sane.
var render_size := Vector2i(1440, 1536)
## The head in the headset's reference space, and each eye relative to the head.
var head := Transform3D.IDENTITY
var head_tracked := false
var eyes: Array[Transform3D] = [Transform3D(Basis.IDENTITY, Vector3(-0.032, 0, 0)), Transform3D(Basis.IDENTITY, Vector3(0.032, 0, 0))]
## Each eye's field of view as tangents: left (negative), right, bottom (negative), top.
var fov: Array[Vector4] = [Vector4(-1.0, 0.85, -1.0, 0.9), Vector4(-0.85, 1.0, -1.0, 0.9)]
## Id of the pose the next frame is drawn with (the headset's, to match the frame to it).
var pose_id := 0

var _initialized := false
var _head_tracker: XRPositionalTracker
var _hands: Array[XRHandTracker] = []
var _controllers: Array[XRControllerTracker] = []
## Pose id and head of the frame being drawn (set in _pre_render, on the main thread).
var _drawn_head := Transform3D.IDENTITY
var _drawn_id := 0


func _get_name() -> StringName:
	return &"WoRkPlaceRemote"


func _get_capabilities() -> int:
	return XR_STEREO | XR_VR


func _is_initialized() -> bool:
	return _initialized


func _initialize() -> bool:
	if _initialized:
		return true
	_head_tracker = XRPositionalTracker.new()
	_head_tracker.type = XRServer.TRACKER_HEAD
	_head_tracker.name = &"head"
	XRServer.add_tracker(_head_tracker)
	for i in 2:
		var hand := XRHandTracker.new()
		hand.name = HAND_TRACKER_NAMES[i]
		hand.hand = XRPositionalTracker.TRACKER_HAND_LEFT if i == 0 else XRPositionalTracker.TRACKER_HAND_RIGHT
		XRServer.add_tracker(hand)
		_hands.append(hand)
		var controller := XRControllerTracker.new()
		controller.name = CONTROLLER_TRACKER_NAMES[i]
		controller.hand = hand.hand
		XRServer.add_tracker(controller)
		_controllers.append(controller)
	_initialized = true
	XRServer.primary_interface = self
	return true


func _uninitialize() -> void:
	if not _initialized:
		return
	XRServer.remove_tracker(_head_tracker)
	for i in 2:
		XRServer.remove_tracker(_hands[i])
		XRServer.remove_tracker(_controllers[i])
	_hands.clear()
	_controllers.clear()
	if XRServer.primary_interface == self:
		XRServer.primary_interface = null
	_initialized = false


func _get_tracking_status() -> XRInterface.TrackingStatus:
	return XRInterface.XR_NORMAL_TRACKING if head_tracked else XRInterface.XR_NOT_TRACKING


func _get_render_target_size() -> Vector2:
	return Vector2(render_size)


func _get_view_count() -> int:
	return 2


func _get_camera_transform() -> Transform3D:
	return XRServer.world_origin * XRServer.get_reference_frame() * _scaled(head)


func _get_transform_for_view(view: int, cam_transform: Transform3D) -> Transform3D:
	return cam_transform * XRServer.get_reference_frame() * _scaled(head * eyes[clampi(view, 0, 1)])


func _get_projection_for_view(view: int, _aspect: float, z_near: float, z_far: float) -> PackedFloat64Array:
	var t := fov[clampi(view, 0, 1)]
	var p := Projection.create_frustum(t.x * z_near, t.y * z_near, t.z * z_near, t.w * z_near, z_near, z_far)
	var result := PackedFloat64Array()
	for column in 4:
		for row in 4:
			result.append(p[column][row])
	return result


func _process() -> void:
	_head_tracker.set_pose(&"default", head, Vector3.ZERO, Vector3.ZERO,
			XRPose.XR_TRACKING_CONFIDENCE_HIGH if head_tracked else XRPose.XR_TRACKING_CONFIDENCE_NONE)


func _pre_render() -> void:
	_drawn_head = head
	_drawn_id = pose_id


func _post_draw_viewport(render_target: RID, _screen_rect: Rect2) -> void:
	# No preview on the PC's window: the layered blit has no shader variant on
	# D3D12 Mobile (errors every frame).
	frame_drawn.emit(get_render_target_texture(render_target), _drawn_head, _drawn_id)


## Takes one tracking message from the headset (LinkProtocol.tracking).
func apply(message: Dictionary) -> void:
	pose_id = message["id"]
	head = message["head"]
	head_tracked = message["head_ok"]
	var eye_list: Array = message["eyes"]
	var fov_list: Array = message["fov"]
	for i in 2:
		eyes[i] = eye_list[i]
		fov[i] = fov_list[i]
	var hands: Array = message["hands"]
	for i in 2:
		_apply_hand(_hands[i], hands[i])
	var controllers: Array = message["controllers"]
	for i in 2:
		_apply_controller(_controllers[i], controllers[i])


func _apply_hand(tracker: XRHandTracker, data: Dictionary) -> void:
	tracker.has_tracking_data = data.get("ok", false)
	if not tracker.has_tracking_data:
		return
	tracker.hand_tracking_source = data["source"]
	var joints: PackedFloat32Array = data["joints"]
	var flags: PackedInt32Array = data["flags"]
	for joint in XRHandTracker.HAND_JOINT_MAX:
		var at := joint * 7
		var pose := Transform3D(Basis(Quaternion(joints[at], joints[at + 1], joints[at + 2], joints[at + 3])),
				Vector3(joints[at + 4], joints[at + 5], joints[at + 6]))
		tracker.set_hand_joint_transform(joint, pose)
		tracker.set_hand_joint_flags(joint, flags[joint])
	tracker.set_pose(&"default", tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM), Vector3.ZERO,
			Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func _apply_controller(tracker: XRControllerTracker, data: Dictionary) -> void:
	var profile: String = data.get("profile", "")
	if String(tracker.profile) != profile:
		tracker.profile = profile
	if data.get("ok", false):
		tracker.set_pose(&"aim", data["aim"], Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		tracker.set_pose(&"grip", data["grip"], Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	else:
		tracker.invalidate_pose(&"aim")
		tracker.invalidate_pose(&"grip")
	var inputs: Dictionary = data.get("inputs", {})
	for input: StringName in FLOAT_INPUTS:
		tracker.set_input(input, float(inputs.get(String(input), 0.0)))
	for input: StringName in VECTOR_INPUTS:
		tracker.set_input(input, inputs.get(String(input), Vector2.ZERO) as Vector2)
	for input: StringName in BUTTON_INPUTS:
		tracker.set_input(input, bool(inputs.get(String(input), false)))


func _scaled(transform: Transform3D) -> Transform3D:
	var scaled := transform
	scaled.origin *= XRServer.world_scale
	return scaled
