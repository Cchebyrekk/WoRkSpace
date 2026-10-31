class_name PassthroughAreas
extends RefCounted
## Places of the room that always show through (31.10.2026, the user's wish: a
## desk, the real keyboard), passthrough on or off: boxes in the tracking space
## (the rig's own, the headset's Stage space, so they stay on the real room
## wherever the user goes in the world and between starts). Marked by hand: a pinch at one corner, let go at the opposite one; a
## short pinch inside one removes it. Each box is {"centre", "size", "yaw"},
## upright and turned about up by yaw. Pure logic, covered by tests/run_tests.gd.

## No side thinner than this (a box drawn flat on a desk still has some depth).
const MIN_SIDE := 0.05
## A pinch let go nearer than this to where it began is a tap, not a box
## (31.10.2026: 3 cm made boxes of every pinch on a button while marking).
const TAP_METRES := 0.08
const MAX_AREAS := 8


## The box spanning `a` and `b` (opposite corners) in a frame turned by `yaw`.
static func box_between(a: Vector3, b: Vector3, yaw: float) -> Dictionary:
	var turn := Basis(Vector3.UP, yaw)
	var low := turn.inverse() * a
	var high := turn.inverse() * b
	var size := (high - low).abs().max(Vector3.ONE * MIN_SIDE)
	return {"centre": (a + b) * 0.5, "size": size, "yaw": yaw}


static func is_tap(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) < TAP_METRES


static func transform_of(box: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, float(box["yaw"])), box["centre"])


## The yaw of an upright frame (about up, as Basis(Vector3.UP, yaw) has it).
static func yaw_of(basis: Basis) -> float:
	return atan2(-basis.x.z, basis.x.x)


## `box` given in `frame` (an anchor, upright), in the space `frame` is in.
static func moved(box: Dictionary, frame: Transform3D) -> Dictionary:
	return {"centre": frame * (box["centre"] as Vector3), "size": box["size"], "yaw": float(box["yaw"]) + yaw_of(frame.basis)}


static func contains(box: Dictionary, point: Vector3) -> bool:
	var local := transform_of(box).affine_inverse() * point
	var half: Vector3 = box["size"] * 0.5
	return absf(local.x) <= half.x and absf(local.y) <= half.y and absf(local.z) <= half.z


## The index of the box `point` is in (the smallest of those), or -1.
static func find(areas: Array, point: Vector3) -> int:
	var best := -1
	var best_volume := INF
	for i in areas.size():
		if contains(areas[i], point):
			var size: Vector3 = areas[i]["size"]
			if size.x * size.y * size.z < best_volume:
				best = i
				best_volume = size.x * size.y * size.z
	return best


## A portal (01.11.2026): a door-sized box standing on the floor, as thick as a
## head is wide (5 cm at first: going through, the eyes were out of it at once).
const PORTAL_SIZE := Vector3(0.9, 2.0, 0.2)


## A new portal at `foot` (on the floor, rig space), its face turned by `yaw`.
static func portal_at(foot: Vector3, yaw: float) -> Dictionary:
	return {"centre": foot + Vector3(0.0, PORTAL_SIZE.y * 0.5, 0.0), "size": PORTAL_SIZE, "yaw": yaw}


## Which side of a portal's face `point` is on: 1 in front (+Z), -1 behind.
static func side_of(portal: Dictionary, point: Vector3) -> int:
	return 1 if (transform_of(portal).affine_inverse() * point).z >= 0.0 else -1


## Whether going from `from` to `to` passes through the portal's opening (not
## round its sides): the crossing of its face is inside its width and height.
static func passes(portal: Dictionary, from: Vector3, to: Vector3) -> bool:
	var inverse := transform_of(portal).affine_inverse()
	var a := inverse * from
	var b := inverse * to
	if (a.z >= 0.0) == (b.z >= 0.0) or is_equal_approx(a.z, b.z):
		return false
	var at := a.lerp(b, a.z / (a.z - b.z))
	var half: Vector3 = portal["size"] * 0.5
	return absf(at.x) <= half.x and absf(at.y) <= half.y


## A portal's sides between these (metres).
const PORTAL_MIN_SIDE := 0.2
const PORTAL_MAX_SIDE := 5.0
## Edges of a portal for resizing: left, right, bottom, top (its face's -x, +x, -y, +y).
const EDGES := [Vector2(-1.0, 0.0), Vector2(1.0, 0.0), Vector2(0.0, -1.0), Vector2(0.0, 1.0)]


## The middle of edge `edge` (EDGES), in the space the portal is in.
static func edge_point(portal: Dictionary, edge: int) -> Vector3:
	var half: Vector3 = portal["size"] * 0.5
	var towards: Vector2 = EDGES[edge]
	return transform_of(portal) * Vector3(towards.x * half.x, towards.y * half.y, 0.0)


## The portal with edge `edge` brought to `point` (only its place across that
## edge counts); the opposite edge stays.
static func resized(portal: Dictionary, edge: int, point: Vector3) -> Dictionary:
	var frame := transform_of(portal)
	var local := frame.affine_inverse() * point
	var size: Vector3 = portal["size"]
	var half := size * 0.5
	var towards: Vector2 = EDGES[edge]
	var centre_local := Vector3.ZERO
	if towards.x != 0.0:
		var fixed := -towards.x * half.x
		var side := clampf(absf(local.x - fixed), PORTAL_MIN_SIDE, PORTAL_MAX_SIDE)
		size.x = side
		centre_local.x = fixed + towards.x * side * 0.5
	else:
		var fixed := -towards.y * half.y
		var side := clampf(absf(local.y - fixed), PORTAL_MIN_SIDE, PORTAL_MAX_SIDE)
		size.y = side
		centre_local.y = fixed + towards.y * side * 0.5
	return {"centre": frame * centre_local, "size": size, "yaw": portal["yaw"]}


static func is_valid(box: Variant) -> bool:
	if not box is Dictionary:
		return false
	var d := box as Dictionary
	return d.get("centre") is Vector3 and d.get("size") is Vector3 and (d.get("yaw") is float or d.get("yaw") is int)


## The saved boxes that are boxes, at most MAX_AREAS.
static func from_config(value: Variant) -> Array:
	var areas: Array = []
	if value is Array:
		for box: Variant in value:
			if is_valid(box) and areas.size() < MAX_AREAS:
				var size: Vector3 = (box as Dictionary)["size"]
				areas.append({"centre": box["centre"], "size": size.max(Vector3.ONE * MIN_SIDE), "yaw": float(box["yaw"])})
	return areas
