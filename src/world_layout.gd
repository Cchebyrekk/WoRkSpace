class_name WorldLayout
extends RefCounted
## The world's fixtures: things that hold screen panels (slice j: spheres; slice
## k: walls, see WallLayout; slice l: columns — walls bent outwards). Each has its place in the world, its own monitors (a
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
	## The centre: where the eyes are when seated (world space); for a wall, the
	## seat's middle, before any sliding along it.
	var centre := Vector3(0.0, 1.45, 0.0)
	## Which way its middle is, as seen from the centre (radians about up; 0 = -Z).
	var yaw := 0.0
	## A sphere's radius; a wall's (or a column's) distance from the seat.
	var radius := DEFAULT_RADIUS
	## Keys of the monitors on it (ScreenPanel.monitor_key).
	var monitors := PackedStringArray()
	## A wall's bend: a share of a full circle, 0 = flat .. 1 = a closed cylinder (WallLayout.Shape).
	## A column (kind "column", slice l) is a wall bent the other way: its screens face out.
	var bend := 0.0
	## A wall's lean (radians; > 0 its face looks up): bent, a cone (WallLayout.Shape.tilt).
	var tilt := 0.0
	## Thinner than its cells (WallLayout.Shape.squeeze, 1 = as its cells).
	var squeeze := 1.0
	## A wall's screens: monitor key -> Rect2i of cells (WallLayout).
	var cells := {}
	## A wall's size in cells (empty = as big as its screens) and the gap between cells (m).
	var grid := Rect2i()
	var gap := WallLayout.DEFAULT_GAP
	## A wall's screens in parts of split cells (monitor key -> part) and how its
	## cells are split (cell or part -> "c2", "c3", "r2", "r3"); see WallLayout.Wall.
	var parts := {}
	var splits := {}
	## Joined cells: "B<n>" -> what each covers, "a+b+…" (WallLayout.Wall.blocks).
	var blocks := {}

	## From the fixture's own space (centre at the origin, its middle along -Z) to the world.
	func frame() -> Transform3D:
		return Transform3D(Basis(Vector3.UP, yaw), centre)

	func to_dictionary() -> Dictionary:
		var stored := {}
		for key: String in cells:
			var cell: Rect2i = cells[key]
			stored[key] = [cell.position.x, cell.position.y, cell.size.x, cell.size.y]
		return {"id": id, "kind": kind, "name": name, "centre": centre, "yaw": yaw, "radius": radius, "monitors": monitors,
				"bend": bend, "cells": stored, "gap": gap, "grid": [grid.position.x, grid.position.y, grid.size.x, grid.size.y],
				"parts": parts, "splits": splits, "blocks": blocks, "tilt": tilt, "squeeze": squeeze}

	static func from_dictionary(data: Dictionary) -> Fixture:
		var fixture := Fixture.new()
		fixture.id = int(data.get("id", 0))
		fixture.kind = str(data.get("kind", "sphere"))
		fixture.name = str(data.get("name", ""))
		fixture.centre = data.get("centre", fixture.centre)
		fixture.yaw = float(data.get("yaw", 0.0))
		fixture.radius = clampf(float(data.get("radius", DEFAULT_RADIUS)), MIN_RADIUS, MAX_RADIUS)
		fixture.monitors = PackedStringArray(data.get("monitors", PackedStringArray()))
		fixture.bend = clampf(float(data.get("bend", 0.0)), 0.0, 1.0)
		fixture.tilt = clampf(float(data.get("tilt", 0.0)), -WallLayout.MAX_TILT, WallLayout.MAX_TILT)
		fixture.squeeze = clampf(float(data.get("squeeze", 1.0)), WallLayout.MIN_SQUEEZE, 1.0)
		var stored: Variant = data.get("cells", {})
		if stored is Dictionary:
			for key: Variant in stored:
				var cell: Variant = stored[key]
				if cell is Array and cell.size() == 4:
					fixture.cells[str(key)] = Rect2i(int(cell[0]), int(cell[1]), maxi(int(cell[2]), 1), maxi(int(cell[3]), 1))
		fixture.gap = clampf(float(data.get("gap", WallLayout.DEFAULT_GAP)), 0.0, WallLayout.MAX_GAP)
		var grid: Variant = data.get("grid", [])
		if grid is Array and grid.size() == 4:
			fixture.grid = Rect2i(int(grid[0]), int(grid[1]), maxi(int(grid[2]), 0), maxi(int(grid[3]), 0))
		for field: String in ["parts", "splits", "blocks"]:
			var stored_map: Variant = data.get(field, {})
			if stored_map is Dictionary:
				var clean := {}
				for key: Variant in stored_map:
					clean[str(key)] = str(stored_map[key])
				fixture.set(field, clean)
		# Saved before joined cells were cells of their own (22.10.2026): each group
		# "a+b" becomes "B<n>", and a screen that stood in the group stands in it.
		var old_joins: Variant = data.get("joins", [])
		if old_joins is Array:
			for entry: Variant in old_joins:
				var n := 1
				while fixture.blocks.has("B%d" % n):
					n += 1
				var id := "B%d" % n
				fixture.blocks[id] = str(entry)
				for key: String in fixture.parts:
					if fixture.parts[key] == str(entry):
						fixture.parts[key] = id
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


## Driver screens that came back under new names take the places of those that
## are gone (22.10.2026: instances made anew got new device paths, and every
## screen landed in the nearest free cell instead of its own). Gone and new ones
## are paired in the order of their keys; only keys containing `marker`.
## Returns old key -> new key.
static func adopt(fixtures: Array[Fixture], present: PackedStringArray, marker := "MTT1337") -> Dictionary:
	var known := {}
	for fixture in fixtures:
		for key in fixture.monitors:
			known[key] = true
	var gone: Array[String] = []
	for key: String in known:
		if key.contains(marker) and not present.has(key):
			gone.append(key)
	var fresh: Array[String] = []
	for key in present:
		if key.contains(marker) and not known.has(key):
			fresh.append(key)
	gone.sort()
	fresh.sort()
	var renamed := {}
	for k in mini(gone.size(), fresh.size()):
		var old := gone[k]
		var new := fresh[k]
		renamed[old] = new
		for fixture in fixtures:
			var at := fixture.monitors.find(old)
			if at >= 0:
				fixture.monitors[at] = new
			for places: Dictionary in [fixture.cells, fixture.parts]:
				if places.has(old):
					places[new] = places[old]
					places.erase(old)
	return renamed


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
	fixture.name = "%s %d" % [{"sphere": "Шар", "wall": "Стена", "column": "Столб"}.get(kind, kind), count]
	fixture.centre = centre
	fixture.yaw = yaw
	if kind == "wall" or kind == "column":
		fixture.radius = WallLayout.DEFAULT_DISTANCE
	if kind == "column":
		fixture.bend = 1.0
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
	return rig_for(Transform3D(Basis(Vector3.UP, fixture.yaw), fixture.centre), head_local)


## The rig placed so that the head is at `eyes` (world space) looking along its -Z,
## level: turned about up only, whatever way the head looks in the rig.
static func rig_for(eyes: Transform3D, head_local: Transform3D) -> Transform3D:
	var forward := -head_local.basis.z
	var head_yaw := atan2(-forward.x, -forward.z)
	var look := -eyes.basis.z
	var turn := Basis(Vector3.UP, atan2(-look.x, -look.z) - head_yaw)
	return Transform3D(turn, eyes.origin - turn * head_local.origin)


## A wall's seat at `slide` (u, v along it) in world space: the eyes there, looking at it.
static func wall_eyes(fixture: Fixture, slide: Vector2, shape: WallLayout.Shape) -> Transform3D:
	return fixture.frame() * WallLayout.eye(slide, shape)


## Where a sphere's one radius handle is: on the sphere, low in front of the
## seat (below the screens, near the knees of a seated user; the user wanted one
## per sphere and not under the screens, 20.10.2026).
const HANDLE_ELEVATION_DEG := -70.0


static func radius_handle(fixture: Fixture) -> Vector3:
	return fixture.frame() * (PanelLayout.direction_of(0.0, deg_to_rad(HANDLE_ELEVATION_DEG)) * fixture.radius)
