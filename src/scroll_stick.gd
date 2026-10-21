class_name ScrollStick
extends RefCounted
## Joystick-style scrolling, the default alternative to ScrollDisc: where the
## fingertips were when the pose formed is the centre; moving them up, down,
## left or right from it scrolls in that direction, the further the faster. Only
## the dominant direction scrolls, so a diagonal wobble does not scroll both ways.
## Pure geometry, covered by tests/run_tests.gd.

var origin := Vector3.ZERO
## Within this distance of the centre nothing scrolls.
var dead_zone := 0.015
## At this distance the speed is at its maximum.
var full_offset := 0.08
## Wheel units per second at full offset (120 = one notch).
var max_speed := 2400.0
var invert_vertical := false
var invert_horizontal := false
## In-plane axes as the user sees them.
var right := Vector3.RIGHT
var up := Vector3.UP


## Centres the stick on `fingertip`, in a plane turned towards `viewer`: upright,
## or tipped away from the viewer by `tilt_degrees` (90 = lying flat, so moving
## the hand away scrolls "up"; the same setting as the moving ring, 20.10.2026).
func start(fingertip: Vector3, viewer: Vector3, tilt_degrees := 0.0) -> void:
	var toward_viewer := PointerMath.horizontal_toward(fingertip, viewer)
	right = (-toward_viewer).cross(Vector3.UP).normalized()
	up = Locomotion.plane_up(-toward_viewer, tilt_degrees)
	origin = fingertip


## Offset of the fingertips from the centre in the plane: x right, y up (metres).
func offset(fingertip: Vector3) -> Vector2:
	var local := fingertip - origin
	return Vector2(local.dot(right), local.dot(up))


## Wheel units for this frame: x = horizontal (positive right), y = vertical
## (positive up), already inverted as configured.
func scroll(fingertip: Vector3, delta: float) -> Vector2:
	var shift := offset(fingertip)
	var horizontal := absf(shift.x) > absf(shift.y)
	var amount := absf(shift.x) if horizontal else absf(shift.y)
	var strength := clampf((amount - dead_zone) / maxf(full_offset - dead_zone, 0.001), 0.0, 1.0)
	var units := strength * max_speed * delta
	if horizontal:
		return Vector2(signf(shift.x) * units * (-1.0 if invert_horizontal else 1.0), 0.0)
	return Vector2(0.0, signf(shift.y) * units * (-1.0 if invert_vertical else 1.0))


## The fingertips' position for the marker, kept within the outer circle.
func marker(fingertip: Vector3) -> Vector3:
	var shift := offset(fingertip).limit_length(full_offset)
	return origin + right * shift.x + up * shift.y


## Orientation for drawing a TorusMesh (lies in its local XZ plane): local Y points at the viewer.
func basis() -> Basis:
	return Basis(right, right.cross(up), -up)
