class_name PointerMath
## Pure pointer helpers: no nodes, no engine state, covered by tests/run_tests.gd.


## Distance along the ray to a rectangle lying in the local XY plane of
## `rect_transform`, centred on its origin. Returns -1.0 on a miss.
static func ray_rect_distance(origin: Vector3, direction: Vector3, rect_transform: Transform3D, size: Vector2) -> float:
	var inverse := rect_transform.affine_inverse()
	var local_origin := inverse * origin
	var local_direction := inverse.basis * direction
	if is_zero_approx(local_direction.z):
		return -1.0
	var distance := -local_origin.z / local_direction.z
	if distance < 0.0:
		return -1.0
	var point := local_origin + local_direction * distance
	if absf(point.x) > size.x * 0.5 or absf(point.y) > size.y * 0.5:
		return -1.0
	return distance


## Pinch with hysteresis: closes below `press_distance`, opens above `release_distance`.
static func pinch_state(was_pinched: bool, tip_distance: float, press_distance: float, release_distance: float) -> bool:
	if was_pinched:
		return tip_distance < release_distance
	return tip_distance < press_distance


## Hand ray in the style of the Quest system pointer: it mostly follows where the
## hand itself points (`hand_forward`, wrist towards the knuckles), steadied by
## the shoulder-to-hand line. `rotation_weight`: 0 = shoulder only, 1 = hand only.
static func blend_ray_direction(shoulder_direction: Vector3, hand_forward: Vector3, rotation_weight: float) -> Vector3:
	if hand_forward.length_squared() < 0.0001:
		return shoulder_direction
	return shoulder_direction.slerp(hand_forward.normalized(), clampf(rotation_weight, 0.0, 1.0)).normalized()


## Tilts a direction towards the floor by `down_radians` (negative tilts it up),
## keeping its heading. A vertical direction is returned unchanged.
static func pitch_direction(direction: Vector3, down_radians: float) -> Vector3:
	var axis := direction.cross(Vector3.UP)
	if axis.length_squared() < 0.0001:
		return direction
	return direction.rotated(axis.normalized(), -down_radians)


## Exponential smoothing of a direction; `time_constant` <= 0 disables it.
static func smooth_direction(previous: Vector3, target: Vector3, delta: float, time_constant: float) -> Vector3:
	if time_constant <= 0.0 or previous.length_squared() < 0.0001:
		return target
	return previous.slerp(target, 1.0 - exp(-delta / time_constant)).normalized()


## Shoulder component of the hand ray: from an estimated shoulder through the
## palm. `side_sign` is -1 left, +1 right.
static func hand_ray_direction(head: Transform3D, palm: Vector3, side_sign: float, shoulder_drop: float, shoulder_half_width: float) -> Vector3:
	var right := Vector3(head.basis.x.x, 0.0, head.basis.x.z)
	right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT
	var shoulder := head.origin + Vector3.DOWN * shoulder_drop + right * (side_sign * shoulder_half_width)
	var direction := palm - shoulder
	return direction.normalized() if direction.length_squared() > 0.0001 else -head.basis.z
