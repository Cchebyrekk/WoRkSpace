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


## Ray direction for a hand: from an estimated shoulder through the palm, so that
## closing the fingers barely moves the pointer. `side_sign` is -1 left, +1 right.
static func hand_ray_direction(head: Transform3D, palm: Vector3, side_sign: float, shoulder_drop: float, shoulder_half_width: float) -> Vector3:
	var right := Vector3(head.basis.x.x, 0.0, head.basis.x.z)
	right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT
	var shoulder := head.origin + Vector3.DOWN * shoulder_drop + right * (side_sign * shoulder_half_width)
	var direction := palm - shoulder
	return direction.normalized() if direction.length_squared() > 0.0001 else -head.basis.z
