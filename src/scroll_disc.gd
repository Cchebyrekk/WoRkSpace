class_name ScrollDisc
extends RefCounted
## The scroll disc: a ring in front of the hand, in a vertical plane facing the
## user. Moving the fingertips around it turns the mouse wheel, like the click
## wheel of an old music player: counter-clockwise (as the user sees it) scrolls
## up, clockwise scrolls down. Pure geometry, covered by tests/run_tests.gd.

var center := Vector3.ZERO
var radius := 0.06
## Wheel units (120 = one notch) per full turn.
var turn_units := 960.0
## Closer to the centre than this the angle is meaningless and nothing turns.
var dead_radius := 0.015
## In-plane axes as the user sees the disc.
var right := Vector3.RIGHT
var up := Vector3.UP

var _angle := NAN


## Places the disc so that `fingertip` is on its top point, in a vertical plane
## turned towards `viewer`.
func start(fingertip: Vector3, viewer: Vector3) -> void:
	var toward_viewer := Vector3(viewer.x - fingertip.x, 0.0, viewer.z - fingertip.z)
	toward_viewer = toward_viewer.normalized() if toward_viewer.length_squared() > 0.0001 else Vector3.BACK
	up = Vector3.UP
	right = (-toward_viewer).cross(up).normalized()
	center = fingertip - up * radius
	_angle = NAN


## The disc's orientation for drawing a TorusMesh, which lies in its local XZ
## plane: local Y is the disc's axis, pointing at the viewer.
func basis() -> Basis:
	return Basis(right, right.cross(up), -up)


## Wheel units for the fingertips' move to `fingertip`; positive scrolls up.
func turn(fingertip: Vector3) -> float:
	var local := fingertip - center
	var flat := Vector2(local.dot(right), local.dot(up))
	if flat.length() < dead_radius:
		_angle = NAN
		return 0.0
	var angle := atan2(flat.y, flat.x)
	if is_nan(_angle):
		_angle = angle
		return 0.0
	var step := wrapf(angle - _angle, -PI, PI)
	_angle = angle
	return step / TAU * turn_units


## Where the fingertips are on the ring (for the marker), or the top point at first.
func marker() -> Vector3:
	var angle := PI * 0.5 if is_nan(_angle) else _angle
	return center + (right * cos(angle) + up * sin(angle)) * radius
