class_name HandPointer
extends RefCounted
## One hand as a pointer in the headset (slice o4): a short version of the PC
## app's hand ray (main.gd) — from an estimated shoulder through the palm, turned
## partly by the hand itself, smoothed more when it moves slowly. Pinches have
## hysteresis: thumb to index is the left button, thumb to middle the right one.

const SHOULDER_DROP := 0.2
const SHOULDER_HALF_WIDTH := 0.18
## 0 = the shoulder line only, 1 = where the hand points only.
const ROTATION_WEIGHT := 0.42
## Where the ray starts, in the wrist's frame (x mirrored for the left hand).
const AIM_ORIGIN_IN_WRIST := Vector3(0.02, 0.11, 0.06)
const SMOOTHING_SLOW_SEC := 0.2
const SMOOTHING_FAST_SEC := 0.03
const SPEED_SLOW := 0.1
const SPEED_FAST := 1.0
const DEADBAND := 0.002
const PINCH_PRESS := 0.018
const PINCH_RELEASE := 0.035
## Fingers closer than this to the thumb are about to pinch: the hand's own
## rotation, which a pinch disturbs, stops steering the ray until they open.
const FREEZE_DISTANCE := 0.03

## -1 left, +1 right.
var side_sign := 1.0
var active := false
var origin := Vector3.ZERO
var direction := Vector3.FORWARD
## Thumb to index / to middle closed.
var left := false
var right := false
var _rotation_offset := Quaternion.IDENTITY


func _init(p_side_sign: float) -> void:
	side_sign = p_side_sign


## `to_world`: the XR origin's global transform (joints are in its space);
## `head`: the camera's global transform.
func update(tracker: XRHandTracker, to_world: Transform3D, head: Transform3D, delta: float) -> void:
	if tracker == null or not tracker.has_tracking_data \
			or tracker.hand_tracking_source == XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER \
			or not tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID:
		active = false
		left = false
		right = false
		return
	var palm := to_world * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM).origin
	var wrist := to_world * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST)
	var knuckle := to_world * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL).origin
	var thumb := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin
	var index_tip := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
	var middle_tip := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP).origin
	var index_distance := thumb.distance_to(index_tip)
	var middle_distance := thumb.distance_to(middle_tip)
	left = PointerMath.pinch_state(left, index_distance, PINCH_PRESS, PINCH_RELEASE)
	right = not left and PointerMath.pinch_state(right, middle_distance, PINCH_PRESS, PINCH_RELEASE)

	var shoulder_direction := PointerMath.hand_ray_direction(head, palm, side_sign, SHOULDER_DROP, SHOULDER_HALF_WIDTH)
	var target := PointerMath.blend_ray_direction(shoulder_direction, knuckle - wrist.origin, ROTATION_WEIGHT)
	var closing := minf(index_distance, middle_distance) < FREEZE_DISTANCE
	if not active or (not left and not right and not closing):
		_rotation_offset = Quaternion(shoulder_direction, target)
	target = _rotation_offset * shoulder_direction
	var ray_origin := wrist * Vector3(AIM_ORIGIN_IN_WRIST.x * side_sign, AIM_ORIGIN_IN_WRIST.y, AIM_ORIGIN_IN_WRIST.z)
	if not active:
		origin = ray_origin
		direction = target
		active = true
		return
	var smoothing := PointerMath.adaptive_smoothing(direction.angle_to(target) / maxf(delta, 0.001),
			SMOOTHING_SLOW_SEC, SMOOTHING_FAST_SEC, SPEED_SLOW, SPEED_FAST)
	origin = origin.lerp(ray_origin, 1.0 - exp(-delta / smoothing))
	direction = PointerMath.smooth_direction(direction, PointerMath.deadband_direction(direction, target, DEADBAND),
			delta, smoothing)
