class_name WorldEdit
extends RefCounted
## The world editor (slice n2, the user's wishes 23.10.2026): a fixture is carried
## whole by the ray with a fist (a controller's grip) on it, standing on a grid of
## the editor's own step and turning in steps; new ones are taken from a shelf by
## the hand. Pure logic, covered by tests/run_tests.gd.

## Fixtures newly taken from the shelf appear this far along the ray (m).
const NEW_REACH := 2.5


## The ray's frame where it holds something: `reach` along it, turned with it
## about the vertical only (tilting the ray does not tip what it carries).
static func grip(origin: Vector3, direction: Vector3, reach: float) -> Transform3D:
	var flat := Vector3(direction.x, 0.0, direction.z)
	var yaw := atan2(-flat.x, -flat.z) if flat.length_squared() > 0.000001 else 0.0
	return Transform3D(Basis(Vector3.UP, yaw), origin + direction * reach)


## Where a frame that stood at `start` when the grip was at `grip_start` goes now.
static func carried(start: Transform3D, grip_start: Transform3D, grip_now: Transform3D) -> Transform3D:
	return grip_now * grip_start.affine_inverse() * start


## The turn of a frame about the vertical (as WorldLayout.Fixture.yaw).
static func yaw_of(basis: Basis) -> float:
	var forward := -basis.z
	return atan2(-forward.x, -forward.z)


## The point of a fixture that stands on the grid, in its own space: a sphere's
## centre, a wall's or column's front middle (its centre is the seat before it).
static func anchor_of(kind: String, radius: float) -> Vector3:
	return Vector3.ZERO if kind == "sphere" else Vector3(0.0, 0.0, -radius)


## A fixture's frame on the editor's grid: its anchor on the nearest point of a
## `step` grid, its turn to the nearest `turn` (radians); 0 = free.
static func on_grid(frame: Transform3D, anchor: Vector3, step: float, turn: float) -> Transform3D:
	var yaw := yaw_of(frame.basis)
	if turn > 0.0:
		yaw = wrapf(snappedf(yaw, turn), -PI, PI)
	var basis := Basis(Vector3.UP, yaw)
	var point := frame * anchor
	if step > 0.0:
		point = point.snapped(Vector3.ONE * step)
	return Transform3D(basis, point - basis * anchor)


## A new fixture held at `held` (the ray's grip): it faces along the ray, its
## anchor at the grip, so its seat is on the user's side.
static func new_frame(held: Transform3D, anchor: Vector3) -> Transform3D:
	return Transform3D(held.basis, held.origin - held.basis * anchor)


## How far along a ray (unit `direction`) it meets a sphere's shell; from inside,
## where it leaves; INF if it never does.
static func sphere_hit(origin: Vector3, direction: Vector3, centre: Vector3, radius: float) -> float:
	var to := origin - centre
	var b := to.dot(direction)
	var c := to.length_squared() - radius * radius
	var disc := b * b - c
	if disc < 0.0:
		return INF
	var root := sqrt(disc)
	if -b - root > 0.0:
		return -b - root
	return -b + root if -b + root > 0.0 else INF


## Which of the shelf's `slots` the hand at `hand` is at (within `reach`); -1 if none.
static func slot_at(hand: Vector3, slots: PackedVector3Array, reach: float) -> int:
	var best := -1
	var nearest := reach
	for i in slots.size():
		var off := hand.distance_to(slots[i])
		if off <= nearest:
			nearest = off
			best = i
	return best


## A new world's name: «Мир N», the smallest N not taken.
static func next_world_name(names: Array) -> String:
	var n := 1
	while names.has("Мир %d" % n):
		n += 1
	return "Мир %d" % n
