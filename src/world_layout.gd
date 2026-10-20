class_name WorldLayout
extends RefCounted
## The world's fixtures: things that hold screen panels (slice j: spheres; walls
## and pillars follow). Each has its place in the world, its own monitors (a
## monitor hangs on exactly one fixture) and its seat. Pure logic, covered by
## tests/run_tests.gd. Decided with the user on 20.10.2026.

## A screen panel 1920 px wide spans this many metres on every fixture (as the
## first sphere did: 60 degrees at 1.1 m), so a bigger sphere moves the screens
## away and fits more around instead of making them bigger.
const PANEL_WIDTH_M := 1.27
const DEFAULT_RADIUS := 1.1
const MIN_RADIUS := 0.6
const MAX_RADIUS := 6.0


class Fixture:
	var id := 0
	var kind := "sphere"
	var name := ""
	## The centre: for a sphere, where the eyes are when seated (world space).
	var centre := Vector3(0.0, 1.45, 0.0)
	## Which way its middle is, as seen from the centre (radians about up; 0 = -Z).
	var yaw := 0.0
	var radius := DEFAULT_RADIUS
	## Keys of the monitors on it (ScreenPanel.monitor_key).
	var monitors := PackedStringArray()

	## From the fixture's own space (centre at the origin, its middle along -Z) to the world.
	func frame() -> Transform3D:
		return Transform3D(Basis(Vector3.UP, yaw), centre)

	func to_dictionary() -> Dictionary:
		return {"id": id, "kind": kind, "name": name, "centre": centre, "yaw": yaw, "radius": radius, "monitors": monitors}

	static func from_dictionary(data: Dictionary) -> Fixture:
		var fixture := Fixture.new()
		fixture.id = int(data.get("id", 0))
		fixture.kind = str(data.get("kind", "sphere"))
		fixture.name = str(data.get("name", ""))
		fixture.centre = data.get("centre", fixture.centre)
		fixture.yaw = float(data.get("yaw", 0.0))
		fixture.radius = clampf(float(data.get("radius", DEFAULT_RADIUS)), MIN_RADIUS, MAX_RADIUS)
		fixture.monitors = PackedStringArray(data.get("monitors", PackedStringArray()))
		return fixture


## The angle a 1920-pixel-wide panel spans at `radius` (PanelLayout.arrange's scale).
static func degrees_per_1920(radius: float) -> float:
	return rad_to_deg(2.0 * atan(PANEL_WIDTH_M * 0.5 / radius))


## The world as it was before fixtures: one sphere where the panels always stood,
## holding every monitor.
static func default_fixtures(monitor_keys: PackedStringArray) -> Array[Fixture]:
	var sphere := Fixture.new()
	sphere.id = 1
	sphere.name = "Шар 1"
	sphere.monitors = monitor_keys.duplicate()
	var fixtures: Array[Fixture] = [sphere]
	return fixtures


## Every monitor on exactly one fixture: monitors no fixture has go to the first
## one; a monitor on several stays on the first of them. Monitors that are gone
## stay listed (they come back after a driver restart).
static func settle(fixtures: Array[Fixture], monitor_keys: PackedStringArray) -> void:
	if fixtures.is_empty():
		fixtures.append_array(default_fixtures(monitor_keys))
		return
	var seen := {}
	for fixture in fixtures:
		var kept := PackedStringArray()
		for key in fixture.monitors:
			if not seen.has(key):
				seen[key] = true
				kept.append(key)
		fixture.monitors = kept
	for key in monitor_keys:
		if not seen.has(key):
			fixtures[0].monitors.append(key)


## Moves monitor `key` onto the fixture with id `target`.
static func assign(fixtures: Array[Fixture], key: String, target: int) -> void:
	for fixture in fixtures:
		var at := fixture.monitors.find(key)
		if at >= 0:
			fixture.monitors.remove_at(at)
	for fixture in fixtures:
		if fixture.id == target:
			fixture.monitors.append(key)


## The fixture holding monitor `key`, or the first one.
static func fixture_of(fixtures: Array[Fixture], key: String) -> Fixture:
	for fixture in fixtures:
		if fixture.monitors.has(key):
			return fixture
	return fixtures[0] if not fixtures.is_empty() else null


static func find(fixtures: Array[Fixture], id: int) -> Fixture:
	for fixture in fixtures:
		if fixture.id == id:
			return fixture
	return null


## The next free id and a name like "Шар 3".
static func new_fixture(fixtures: Array[Fixture], kind: String, centre: Vector3, yaw: float) -> Fixture:
	var fixture := Fixture.new()
	for other in fixtures:
		fixture.id = maxi(fixture.id, other.id)
	fixture.id += 1
	fixture.kind = kind
	var count := 1
	for other in fixtures:
		if other.kind == kind:
			count += 1
	fixture.name = "Шар %d" % count if kind == "sphere" else "%s %d" % [kind, count]
	fixture.centre = centre
	fixture.yaw = yaw
	return fixture


## Removes the fixture with id `id`; its monitors go to the first remaining one.
## The last fixture cannot go (the monitors need somewhere to hang).
static func remove(fixtures: Array[Fixture], id: int) -> bool:
	if fixtures.size() <= 1:
		return false
	var gone := find(fixtures, id)
	if gone == null:
		return false
	fixtures.erase(gone)
	fixtures[0].monitors.append_array(gone.monitors)
	return true


## The fixture whose seat is offered to a user at `head`: the nearest one whose
## centre is within its radius plus `reach`, or null.
static func nearby(fixtures: Array[Fixture], head: Vector3, reach: float) -> Fixture:
	var best: Fixture = null
	var best_distance := INF
	for fixture in fixtures:
		var distance := head.distance_to(fixture.centre)
		if distance <= fixture.radius + reach and distance < best_distance:
			best = fixture
			best_distance = distance
	return best


## The rig placed so that the head (at `head_local` in the rig's space) is at the
## fixture's centre looking at its middle: the seat of a sphere.
static func seat_rig(fixture: Fixture, head_local: Transform3D) -> Transform3D:
	var forward := -head_local.basis.z
	var head_yaw := atan2(-forward.x, -forward.z)
	var turn := Basis(Vector3.UP, fixture.yaw - head_yaw)
	return Transform3D(turn, fixture.centre - turn * head_local.origin)


## Where a sphere's one radius handle is: on the sphere, low in front of the
## seat (below the screens, near the knees of a seated user; the user wanted one
## per sphere and not under the screens, 20.10.2026).
const HANDLE_ELEVATION_DEG := -70.0


static func radius_handle(fixture: Fixture) -> Vector3:
	return fixture.frame() * (PanelLayout.direction_of(0.0, deg_to_rad(HANDLE_ELEVATION_DEG)) * fixture.radius)


## A radius dragged by a grip: the hand's distance from the centre now against
## when the grip was taken, times `gain`, kept within MIN_RADIUS..MAX_RADIUS.
static func dragged_radius(start_radius: float, start_distance: float, distance: float, gain := 2.0) -> float:
	return clampf(start_radius + (distance - start_distance) * gain, MIN_RADIUS, MAX_RADIUS)
