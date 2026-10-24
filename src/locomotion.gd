class_name Locomotion
extends RefCounted
## Moving through the world: pure maths for the user's movement and turning, the
## floor, the orientation grid and the comfort vignette. No nodes, no engine
## state; covered by tests/run_tests.gd. Slice (i), 20.10.2026.
##
## The hand works like a stick (as ScrollStick does for scrolling): where the
## hand was when the pose formed is the centre; how far it has moved from there
## sets the speed, its direction the way to go.


## Settings of the world (the "Мир" tab). Every comfort aid can be switched off.
class Options:
	## 0 = space (fly freely, up and down too), 1 = gravity (walk on the floor).
	## Not "move_mode": the settings tabs find their rows by property name, and
	## PanelOptions has one by that name.
	var travel_mode := 1
	## Top speed (m/s) and how far the hand moves from the centre to reach it (m).
	var move_speed := 2.0
	var hand_reach := 0.15
	## (The tilt of the moving hand's plane is a gesture setting shared with
	## scrolling: HandGestures.Settings.ring_tilt_degrees.)
	## Turning: 0 = in steps, 1 = smooth, 2 = off.
	var turn_mode := 0
	var snap_degrees := 30.0
	var turn_speed_degrees := 90.0
	## Darkening of the edges of the view while moving or turning: 0 = off, 1 = strongest.
	var vignette := 0.5
	## Orientation dots: 0 = off, 1 = on; spacing (m).
	var grid := 1
	var grid_step := 1.0
	## Panels farther than this are not drawn (nor their pictures copied); 0 = no limit (m).
	var render_radius := 0.0
	## Panels farther than this take no clicks; 0 = no limit (m).
	var interact_radius := 8.0
	## What a controller's thumbstick does: 0 = scroll while its ray is on a
	## screen, move otherwise; 1 = always scroll; 2 = always move.
	var stick_mode := 0
	## The network of places (slice m): how long the flight to a place takes (s,
	## 0 = at once) and how many nearest places each one links to by itself.
	var flight_sec := 0.5
	## The world editor (slice n2): its grid's step (m) and the turn's step (°; 0 = free).
	var edit_step := 0.25
	var edit_turn_degrees := 15.0
	var auto_links := 2
	## Seated at a wall: which hand (and stick) slides along it, 0 = left, 1 = right;
	## the other brings the wall closer or farther (the user's choice, 21.10.2026).
	var wall_slide_hand := 1
	## Fixtures drawn as thin outlines (a wall's frame and cells, a sphere's circles): 0 = off, 1 = on.
	var outlines := 1
	## Which handles of the fixtures are there (the user's wish, 21.10.2026: every
	## handle can be switched off): a sphere's radius, a wall's size and bend, the
	## «÷» that splits a wall's cells. 0 = off, 1 = on.
	var sphere_handle := 1
	var wall_size_handle := 1
	var wall_bend_handle := 1
	## A wall's or column's tilt ball over its top (slice l).
	var wall_tilt_handle := 1
	var split_handle := 1
	## Handles always (0) or only in the editing mode (1; the radial menu's
	## «Редактирование» switches it, the user's wish 22.10.2026).
	var handles_mode := 0
	## Experimental: a screen on a wall also gets the resolution of its cell's or
	## part's shape (from the driver's list); in the editing mode only after it.
	var wall_resolution := 0
	## Settings with a few choices: switched by pressing − / + (0) or picked from a
	## drop-down list (1); the user's wish, 22.10.2026.
	var option_lists := 0


## The hand's offset from the centre below this does nothing (tracking jitter).
const DEADZONE := 0.02


## Velocity (m/s) for an offset of the hand from where the pose formed. Nothing
## within DEADZONE, full `max_speed` at `reach`, in between a smooth rise (squared,
## so that small corrections are slow). `planar` keeps it horizontal (gravity).
static func stick_velocity(offset: Vector3, reach: float, max_speed: float, planar: bool) -> Vector3:
	if planar:
		offset.y = 0.0
	var length := offset.length()
	if length <= DEADZONE or reach <= DEADZONE:
		return Vector3.ZERO
	var share := _share(length, reach)
	return offset / length * max_speed * share * share


## How far an offset has got from the dead zone to full reach (0..1).
static func _share(length: float, reach: float) -> float:
	return clampf((length - DEADZONE) / (reach - DEADZONE), 0.0, 1.0)


## The "up" of the moving hand's plane: straight up tipped `tilt_degrees` towards
## `ahead` (horizontal), so 90 degrees lays the plane flat, pointing ahead.
static func plane_up(ahead: Vector3, tilt_degrees: float) -> Vector3:
	var tilt := deg_to_rad(clampf(tilt_degrees, 0.0, 90.0))
	return (Vector3.UP * cos(tilt) + Vector3(ahead.x, 0.0, ahead.z).normalized() * sin(tilt)).normalized()


## Smooth turning (radians per second) from the sideways offset of the turning
## hand; positive turns right. Same dead zone as moving, but a straight rise: the
## squared one turned so slowly at a small offset that the user took it for not
## turning at all (20.10.2026).
static func turn_rate(sideways: float, reach: float, degrees_per_second: float) -> float:
	var length := absf(sideways)
	if length <= DEADZONE or reach <= DEADZONE:
		return 0.0
	var share := _share(length, reach)
	return signf(sideways) * deg_to_rad(degrees_per_second) * share


## Turning in steps: a step when the hand goes past `trigger` sideways, and
## another every `repeat` seconds while it stays out (20.10.2026: one step per
## reach was too little, the user wanted to keep turning). Bringing the hand back
## within `rearm` lets the next reach step at once.
class SnapTurn:
	var trigger := 0.07
	var rearm := 0.04
	var repeat := 0.45
	var _armed := true
	var _last := -INF

	## -1 = one step left, +1 = one step right, 0 = none this frame.
	func update(sideways: float, time: float) -> int:
		if absf(sideways) < rearm:
			_armed = true
			return 0
		if absf(sideways) >= trigger and (_armed or time - _last >= repeat):
			_armed = false
			_last = time
			return 1 if sideways > 0.0 else -1
		return 0

	func reset() -> void:
		_armed = true


## The rig turned by `angle` (radians, positive = to the right as the user sees
## it) about the vertical line through `pivot` (the head), so the user turns on
## the spot instead of swinging round the rig's origin.
static func turn_about(rig: Transform3D, pivot: Vector3, angle: float) -> Transform3D:
	var turn := Transform3D(Basis(Vector3.UP, -angle), Vector3.ZERO)
	var at := Transform3D(Basis.IDENTITY, Vector3(pivot.x, 0.0, pivot.z))
	return at * turn * at.affine_inverse() * rig


## Gravity: the rig's height eased towards the floor (m/s at most), so switching
## to gravity or making a floor lands the user instead of snapping.
static func settle(height: float, floor_height: float, delta: float, speed := 3.0) -> float:
	var step := speed * delta
	if absf(floor_height - height) <= step:
		return floor_height
	return height + signf(floor_height - height) * step


## Dots of the orientation grid around `centre`: a lattice `step` apart within
## `radius` (a sphere), or only the floor's dots at `floor_height` (a disc) when
## `planar`. Aligned to the world, so they stay put while the user moves.
static func grid_points(centre: Vector3, step: float, radius: float, planar: bool, floor_height := 0.0) -> PackedVector3Array:
	var points := PackedVector3Array()
	if step <= 0.0 or radius <= 0.0:
		return points
	var cells := int(floor(radius / step))
	var base := (centre / step).round()
	var vertical := range(0, 1) if planar else range(-cells, cells + 1)
	for i in range(-cells, cells + 1):
		for k in range(-cells, cells + 1):
			for j: int in vertical:
				var point := Vector3((base.x + i) * step, floor_height if planar else (base.y + j) * step, (base.z + k) * step)
				var offset := point - centre
				if planar:
					offset.y = 0.0
				if offset.length() <= radius:
					points.append(point)
	return points


## How dark the edges get: the setting scaled by how fast the user moves or turns
## compared with the top speed / turn speed (a slow drift barely darkens).
static func vignette_strength(setting: float, speed: float, max_speed: float, turn_rate_radians: float, max_turn_radians: float) -> float:
	if setting <= 0.0:
		return 0.0
	var moving := speed / max_speed if max_speed > 0.0 else 0.0
	var turning := absf(turn_rate_radians) / max_turn_radians if max_turn_radians > 0.0 else 0.0
	return clampf(setting * maxf(moving, turning), 0.0, 1.0)
