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


## Where a world point lies on a rectangle (see ray_rect_distance), as 0..1
## coordinates with the origin at the top-left corner, like pixels on a screen.
static func rect_uv(point: Vector3, rect_transform: Transform3D, size: Vector2) -> Vector2:
	var local := rect_transform.affine_inverse() * point
	return Vector2(local.x / size.x + 0.5, 0.5 - local.y / size.y)


## A curved panel: `size.x` metres of arc on a cylinder of `radius` with a
## vertical axis, curving towards the viewer. `panel_transform` is at the middle of
## the arc, its +Z towards the viewer, so the cylinder's axis is `radius` in front.
## Returns (distance along the ray, u, v) with u, v 0..1 from the top-left corner,
## or x = -1.0 on a miss.
static func ray_arc(origin: Vector3, direction: Vector3, panel_transform: Transform3D, size: Vector2, radius: float) -> Vector3:
	var inverse := panel_transform.affine_inverse()
	var o := inverse * origin - Vector3(0.0, 0.0, radius)
	var d := inverse.basis * direction
	# x² + z² = radius² around the axis.
	var a := d.x * d.x + d.z * d.z
	if is_zero_approx(a):
		return Vector3(-1.0, 0.0, 0.0)
	var b := o.x * d.x + o.z * d.z
	var c := o.x * o.x + o.z * o.z - radius * radius
	var discriminant := b * b - a * c
	if discriminant < 0.0:
		return Vector3(-1.0, 0.0, 0.0)
	var half_angle := size.x * 0.5 / radius
	for t: float in [(-b - sqrt(discriminant)) / a, (-b + sqrt(discriminant)) / a]:
		if t < 0.0:
			continue
		var point := o + d * t
		var angle := atan2(point.x, -point.z)
		if point.z < 0.0 and absf(angle) <= half_angle and absf(point.y) <= size.y * 0.5:
			return Vector3(t, angle / (2.0 * half_angle) + 0.5, 0.5 - point.y / size.y)
	return Vector3(-1.0, 0.0, 0.0)


## Pinch with hysteresis: closes below `press_distance`, opens above `release_distance`.
static func pinch_state(was_pinched: bool, tip_distance: float, press_distance: float, release_distance: float) -> bool:
	if was_pinched:
		return tip_distance < release_distance
	return tip_distance < press_distance


## Smoothing time constant that depends on how fast the ray turns (rad/s): strong
## for slow movement, where hand tremor shows, and light for fast movement, where
## lag would show instead.
static func adaptive_smoothing(angular_speed: float, slow_time: float, fast_time: float, slow_speed: float, fast_speed: float) -> float:
	return lerpf(slow_time, fast_time, clampf(inverse_lerp(slow_speed, fast_speed, angular_speed), 0.0, 1.0))


## Hand ray in the style of the Quest system pointer: it mostly follows where the
## hand itself points (`hand_forward`, wrist towards the knuckles), steadied by
## the shoulder-to-hand line. `rotation_weight`: 0 = shoulder only, 1 = hand only.
static func blend_ray_direction(shoulder_direction: Vector3, hand_forward: Vector3, rotation_weight: float) -> Vector3:
	if hand_forward.length_squared() < 0.0001:
		return shoulder_direction
	return shoulder_direction.slerp(hand_forward.normalized(), clampf(rotation_weight, 0.0, 1.0)).normalized()


## Turns a direction around the vertical axis; positive `right_radians` turns it
## to the right as seen by the user. Mirror the sign for the other hand.
static func yaw_direction(direction: Vector3, right_radians: float) -> Vector3:
	return direction.rotated(Vector3.UP, -right_radians)


## Tilts a direction towards the floor by `down_radians` (negative tilts it up),
## keeping its heading. A vertical direction is returned unchanged.
static func pitch_direction(direction: Vector3, down_radians: float) -> Vector3:
	var axis := direction.cross(Vector3.UP)
	if axis.length_squared() < 0.0001:
		return direction
	return direction.rotated(axis.normalized(), -down_radians)


## Dead zone for a direction: the output stays where it was while the target is
## within `radius` (radians) of it, and otherwise trails the target by exactly
## `radius`. A hand held still therefore gives a ray that does not move at all.
static func deadband_direction(previous: Vector3, target: Vector3, radius: float) -> Vector3:
	if radius <= 0.0 or previous.length_squared() < 0.0001:
		return target
	var angle := previous.angle_to(target)
	if angle <= radius:
		return previous
	return previous.slerp(target, (angle - radius) / angle).normalized()


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
