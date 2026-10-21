class_name WallLayout
extends RefCounted
## A wall of screens (slice k): a grid of cells, one cell the size of a 1920×1080
## screen in VR; a screen takes one cell or a rectangle of them (a 4K one 2×2).
## The wall is flat or bent round a vertical axis; the seat in front of it slides
## along it. Positions on the wall are in metres: u along it (to the right, along
## the arc when bent), v up; cell (0, 0) is straight ahead of the seat's middle.
## Columns grow to the right, rows downwards (as on the desktop). The wall has a
## size of its own (`grid`, in cells), at least as big as its screens; the gap
## between cells is the wall's own setting. Pure logic, covered by
## tests/run_tests.gd. Decided with the user on 21.10.2026.

const CELL := Vector2(WorldLayout.PANEL_WIDTH_M, WorldLayout.PANEL_WIDTH_M * 9.0 / 16.0)
## Between cells, the same across and down (m); the grips sit in the gap below a panel.
const DEFAULT_GAP := 0.06
const MAX_GAP := 0.3
const MAX_SPAN := 4
const DEFAULT_DISTANCE := 1.5
## Below this bend (a share of a full circle) the wall is flat.
const FLAT_BEND := 0.005
## The bend handle sticks to every this many degrees of arc (30°, 45°, 60°...).
const BEND_MAGNET_STEP_DEG := 15.0
## The backing behind the screens: from this far behind the wall to that far (m),
## and this much bigger than the cells all round.
const BACKING_FRONT := -0.015
const BACKING_BACK := -0.05
const BACKING_MARGIN := 0.05
## How far past the wall's lower corners its handles sit (m).
const HANDLE_MARGIN := Vector2(0.12, 0.06)
## The outline lies this far behind the wall, so the screens hide it.
const OUTLINE_DEPTH := -0.01
const OUTLINE_ARC_STEPS := 24


## From one cell's middle to the next one's (m).
static func pitch(gap := DEFAULT_GAP) -> Vector2:
	return CELL + Vector2(gap, gap)


## Middle of a cell rectangle on the wall (u, v).
static func cell_centre(cell: Rect2i, gap := DEFAULT_GAP) -> Vector2:
	var step := pitch(gap)
	return Vector2((cell.position.x + (cell.size.x - 1) * 0.5) * step.x, -(cell.position.y + (cell.size.y - 1) * 0.5) * step.y)


## Width and height of a cell rectangle, gaps between its cells included (m).
static func cell_size(cell: Rect2i, gap := DEFAULT_GAP) -> Vector2:
	return Vector2(cell.size.x * CELL.x + (cell.size.x - 1) * gap, cell.size.y * CELL.y + (cell.size.y - 1) * gap)


## The screen's size in its cells: as big as fits, keeping the monitor's shape.
static func panel_size(cell: Rect2i, pixels: Vector2i, gap := DEFAULT_GAP) -> Vector2:
	var box := cell_size(cell, gap)
	if pixels.x <= 0 or pixels.y <= 0:
		return box
	var aspect := float(pixels.x) / float(pixels.y)
	return Vector2(box.y * aspect, box.y) if box.x / box.y > aspect else Vector2(box.x, box.x / aspect)


## How many cells a monitor takes at first: one per 1920×1080 of it.
static func span_for(pixels: Vector2i) -> Vector2i:
	return Vector2i(clampi(roundi(pixels.x / 1920.0), 1, MAX_SPAN), clampi(roundi(pixels.y / 1080.0), 1, MAX_SPAN))


## The cell rectangle of size `span` whose middle is nearest to (u, v).
static func cell_at(u: float, v: float, span: Vector2i, gap := DEFAULT_GAP) -> Rect2i:
	var step := pitch(gap)
	return Rect2i(Vector2i(roundi(u / step.x - (span.x - 1) * 0.5), roundi(-v / step.y - (span.y - 1) * 0.5)), span)


static func overlaps(cell: Rect2i, others: Array[Rect2i]) -> bool:
	for other in others:
		if cell.intersects(other):
			return true
	return false


## `wanted` itself if free, else the free rectangle of its size nearest to it.
static func nearest_free(wanted: Rect2i, taken: Array[Rect2i]) -> Rect2i:
	if not overlaps(wanted, taken):
		return wanted
	var best := wanted
	var best_distance := INF
	for ring in range(1, 32):
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dy)) != ring:
					continue
				var candidate := Rect2i(wanted.position + Vector2i(dx, dy), wanted.size)
				var distance := Vector2(dx, dy).length()
				if distance < best_distance and not overlaps(candidate, taken):
					best = candidate
					best_distance = distance
		# Nothing on a later ring can be nearer than this ring's own radius.
		if best_distance <= ring:
			break
	return best


## The cells of monitors placed as in the Windows layout: the primary at (0, 0),
## the others where their desktop position falls, each in the free spot nearest to
## it (nearest to the primary first).
static func from_desktop(rects: Array[Rect2i], primary: int) -> Array[Rect2i]:
	var cells: Array[Rect2i] = []
	cells.resize(rects.size())
	if rects.is_empty():
		return cells
	primary = clampi(primary, 0, rects.size() - 1)
	var origin := rects[primary].position
	var order: Array[int] = []
	for i in rects.size():
		order.append(i)
	var centre := Vector2(rects[primary].get_center())
	order.sort_custom(func(a: int, b: int) -> bool:
		return Vector2(rects[a].get_center()).distance_to(centre) < Vector2(rects[b].get_center()).distance_to(centre))
	var taken: Array[Rect2i] = []
	for i in order:
		var wanted := Rect2i(Vector2i(roundi((rects[i].position.x - origin.x) / 1920.0), roundi((rects[i].position.y - origin.y) / 1080.0)),
				span_for(rects[i].size))
		cells[i] = nearest_free(wanted, taken)
		taken.append(cells[i])
	return cells


## Every monitor in `keys` with a cell: those already on the wall keep theirs, new
## ones go as near as is free to where the Windows layout would put them.
## Monitors no longer there keep their cells (they come back after a driver restart).
static func settle(cells: Dictionary, keys: PackedStringArray, rects: Array[Rect2i], primary: int) -> Dictionary:
	var result := cells.duplicate()
	var wanted := from_desktop(rects, primary)
	for i in keys.size():
		if result.has(keys[i]):
			continue
		var taken: Array[Rect2i] = []
		for key: String in result:
			taken.append(result[key])
		result[keys[i]] = nearest_free(wanted[i], taken)
	return result


## Monitor `key` put at `target`; screens it lands on move aside to the free spot
## nearest to where they were.
static func moved(cells: Dictionary, key: String, target: Rect2i) -> Dictionary:
	var result := cells.duplicate()
	result[key] = target
	for other: String in cells:
		if other == key or not (result[other] as Rect2i).intersects(target):
			continue
		var taken: Array[Rect2i] = []
		for placed: String in result:
			if placed != other:
				taken.append(result[placed])
		result[other] = nearest_free(result[other], taken)
	return result


## The wall's shape: how far its middle is from the seat's, how much it bends
## (a share of a full circle: 0 flat, 0.25 a quarter round, 1 a closed cylinder;
## the user's wish, 21.10.2026), and where its middle is and how long it is along
## u: it bends round its middle, the axis on the seat's side.
class Shape:
	var distance := DEFAULT_DISTANCE
	var bend := 0.0
	var middle := 0.0
	var length := 1.0

	func bent() -> bool:
		return bend >= FLAT_BEND

	func radius() -> float:
		return length / (bend * TAU) if bent() else INF

	func axis() -> Vector3:
		return Vector3(middle, 0.0, -distance + radius())


static func shape_of(grid: Rect2i, gap: float, distance: float, bend: float) -> Shape:
	var shape := Shape.new()
	var wall := area(grid, gap)
	shape.distance = distance
	shape.bend = bend
	shape.middle = wall.get_center().x
	shape.length = maxf(wall.size.x, 0.01)
	return shape


## The point (u, v) of the wall, `depth` metres in front of it, in the fixture's
## space (the seat's middle at the origin, the wall ahead along -Z); its -Z looks
## into the wall, so a panel placed there faces the inside of the bend.
static func surface(u: float, v: float, depth: float, shape: Shape) -> Transform3D:
	if not shape.bent():
		return Transform3D(Basis.IDENTITY, Vector3(u, v, -shape.distance + depth))
	var radius := shape.radius()
	var angle := (u - shape.middle) / radius
	var into := Vector3(sin(angle), 0.0, -cos(angle))
	return Transform3D(Basis.looking_at(into, Vector3.UP), shape.axis() + into * (radius - depth) + Vector3.UP * v)


## Where a ray (in the fixture's space) meets the wall, as (u, v); NAN if it does
## not. Bent: from inside the bend the far side (the screens face inwards), from
## outside the near one.
static func hit(origin: Vector3, direction: Vector3, shape: Shape) -> Vector2:
	var none := Vector2(NAN, NAN)
	if not shape.bent():
		if absf(direction.z) < 0.00001:
			return none
		var along := (-shape.distance - origin.z) / direction.z
		if along <= 0.0:
			return none
		var point := origin + direction * along
		return Vector2(point.x, point.y)
	var radius := shape.radius()
	var axis := shape.axis()
	var flat_origin := Vector2(origin.x - axis.x, origin.z - axis.z)
	var flat_direction := Vector2(direction.x, direction.z)
	var a := flat_direction.length_squared()
	var b := 2.0 * flat_origin.dot(flat_direction)
	var c := flat_origin.length_squared() - radius * radius
	var discriminant := b * b - 4.0 * a * c
	if a < 0.000000001 or discriminant < 0.0:
		return none
	var inside := c < 0.0
	var along := (-b + sqrt(discriminant)) / (2.0 * a) if inside else (-b - sqrt(discriminant)) / (2.0 * a)
	if along <= 0.0:
		return none
	var point := origin + direction * along
	var angle := atan2(point.x - axis.x, -(point.z - axis.z))
	return Vector2(shape.middle + angle * radius, point.y)


## The eyes of a user seated at (u, v) of the slide: the wall's distance in front
## of that point, looking straight at it (along a bend too). On a bent wall never
## farther than its axis, the middle of the cylinder (the user's wish, 21.10.2026:
## past it the seat went behind the axis and sliding ran backwards).
static func eye(slide: Vector2, shape: Shape) -> Transform3D:
	return surface(slide.x, slide.y, seat_depth(shape), shape)


## A point (the fixture's space) seen from the wall: x, y = u, v of the wall
## straight in front of it, z = how far in front of the wall it is (negative behind).
static func project(point: Vector3, shape: Shape) -> Vector3:
	if not shape.bent():
		return Vector3(point.x, point.y, point.z + shape.distance)
	var radius := shape.radius()
	var axis := shape.axis()
	var off := Vector2(point.x - axis.x, point.z - axis.z)
	return Vector3(shape.middle + atan2(off.x, -off.y) * radius, point.y, radius - off.length())


## Middle of the screen nearest to (u, v), or (u, v) itself on a wall with no screens.
static func nearest_screen(cells: Array[Rect2i], u: float, v: float, gap := DEFAULT_GAP) -> Vector2:
	var best := Vector2(u, v)
	var best_distance := INF
	for cell in cells:
		var middle := cell_centre(cell, gap)
		var distance := middle.distance_to(Vector2(u, v))
		if distance < best_distance:
			best = middle
			best_distance = distance
	return best


## How far in front of the wall the seat is: its distance, at most the bend's radius.
static func seat_depth(shape: Shape) -> float:
	return minf(shape.distance, shape.radius()) if shape.bent() else shape.distance


## The farthest a seat may be from the wall (a bent one's axis).
static func max_distance(shape: Shape, limit: float) -> float:
	return minf(limit, shape.radius()) if shape.bent() else limit


## A cell rectangle on the wall in metres: u, v of its lower left corner, and its size.
static func area(cell: Rect2i, gap := DEFAULT_GAP) -> Rect2:
	var size := cell_size(cell, gap)
	return Rect2(cell_centre(cell, gap) - size * 0.5, size)


## The wall's cells: `grid`, grown to hold every screen; a wall with no size yet
## is just as big as its screens (one cell if it has none).
static func settle_grid(grid: Rect2i, cells: Array[Rect2i]) -> Rect2i:
	var result := grid
	for cell in cells:
		result = cell if result.size == Vector2i.ZERO else result.merge(cell)
	return result if result.size != Vector2i.ZERO else Rect2i(0, 0, 1, 1)


## The wall's size dragged by its lower right corner to (u, v): the right and
## bottom edges go to the cell boundary nearest the point (mid-gap); never smaller
## than its screens nor than one cell. The left and top edges stay.
static func dragged_grid(grid: Rect2i, cells: Array[Rect2i], u: float, v: float, gap := DEFAULT_GAP) -> Rect2i:
	var step := pitch(gap)
	var end := Vector2i(roundi(u / step.x + 0.5), roundi(-v / step.y + 0.5))
	var result := Rect2i(grid.position, (end - grid.position).max(Vector2i.ONE))
	for cell in cells:
		result = result.merge(cell)
	return result


## Where the size handle is: past the wall's lower right corner (the user wanted
## the corner ball to change the wall's length and height, 21.10.2026).
static func size_handle_point(grid: Rect2i, gap := DEFAULT_GAP) -> Vector2:
	var wall := area(grid, gap)
	return Vector2(wall.end.x + HANDLE_MARGIN.x, wall.position.y - HANDLE_MARGIN.y)


## Where the bend handle is: past the lower left corner (dragged sideways, like a
## panel's curve grip; the user's wish, 21.10.2026).
static func bend_handle_point(grid: Rect2i, gap := DEFAULT_GAP) -> Vector2:
	var wall := area(grid, gap)
	return Vector2(wall.position.x - HANDLE_MARGIN.x, wall.position.y - HANDLE_MARGIN.y)


## The wall's outline for drawing as lines (pairs of points, the fixture's space):
## its edges and, in the gaps, the lines between cells; a little behind the wall,
## so only the frame and the gaps show past the screens. Bent, the lines across
## follow the arc.
static func outline(grid: Rect2i, gap: float, shape: Shape) -> PackedVector3Array:
	var lines := PackedVector3Array()
	var step := pitch(gap)
	var wall := area(grid, gap)
	var columns: Array[float] = [wall.position.x, wall.end.x]
	for c in range(grid.position.x + 1, grid.end.x):
		columns.append((c - 0.5) * step.x)
	var rows: Array[float] = [wall.position.y, wall.end.y]
	for r in range(grid.position.y + 1, grid.end.y):
		rows.append(-(r - 0.5) * step.y)
	for u in columns:
		lines.append(surface(u, wall.position.y, OUTLINE_DEPTH, shape).origin)
		lines.append(surface(u, wall.end.y, OUTLINE_DEPTH, shape).origin)
	var pieces := OUTLINE_ARC_STEPS if shape.bent() else 1
	for v in rows:
		for k in pieces:
			var u0 := lerpf(wall.position.x, wall.end.x, float(k) / pieces)
			var u1 := lerpf(wall.position.x, wall.end.x, float(k + 1) / pieces)
			lines.append(surface(u0, v, OUTLINE_DEPTH, shape).origin)
			lines.append(surface(u1, v, OUTLINE_DEPTH, shape).origin)
	return lines


## The wall's backing as triangles (the fixture's space): a slab behind the
## screens, BACKING_FRONT..BACKING_BACK deep, a little bigger than the cells, bent
## like the wall (the user wanted the wall to have a body, 21.10.2026).
static func backing(grid: Rect2i, gap: float, shape: Shape) -> PackedVector3Array:
	var triangles := PackedVector3Array()
	var wall := area(grid, gap).grow(BACKING_MARGIN)
	var pieces := OUTLINE_ARC_STEPS if shape.bent() else 1
	var bottom := wall.position.y
	var top := wall.end.y
	for k in pieces:
		var u0 := lerpf(wall.position.x, wall.end.x, float(k) / pieces)
		var u1 := lerpf(wall.position.x, wall.end.x, float(k + 1) / pieces)
		for depth: float in [BACKING_FRONT, BACKING_BACK]:
			_quad(triangles, surface(u0, bottom, depth, shape).origin, surface(u1, bottom, depth, shape).origin,
					surface(u1, top, depth, shape).origin, surface(u0, top, depth, shape).origin)
		for v: float in [bottom, top]:
			_quad(triangles, surface(u0, v, BACKING_FRONT, shape).origin, surface(u1, v, BACKING_FRONT, shape).origin,
					surface(u1, v, BACKING_BACK, shape).origin, surface(u0, v, BACKING_BACK, shape).origin)
	for u: float in [wall.position.x, wall.end.x]:
		_quad(triangles, surface(u, bottom, BACKING_FRONT, shape).origin, surface(u, top, BACKING_FRONT, shape).origin,
				surface(u, top, BACKING_BACK, shape).origin, surface(u, bottom, BACKING_BACK, shape).origin)
	return triangles


static func _quad(triangles: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	triangles.append_array(PackedVector3Array([a, b, c, a, c, d]))


## A sphere's outline as lines: three circles of `radius` round the origin (level,
## and two upright ones, across and along the view), a little outside the screens.
static func sphere_outline(radius: float, steps := 64) -> PackedVector3Array:
	var lines := PackedVector3Array()
	var r := radius - OUTLINE_DEPTH
	for circle in 3:
		for k in steps:
			for end in 2:
				var angle := TAU * (k + end) / steps
				var a := cos(angle) * r
				var b := sin(angle) * r
				lines.append([Vector3(a, 0.0, b), Vector3(a, b, 0.0), Vector3(0.0, a, b)][circle])
	return lines


## The bend for `degrees` of arc set on the bend slider: kept in 0..360 (flat ..
## cylinder) and pulled to every BEND_MAGNET_STEP_DEG within `magnet_deg` (the
## user's wish, 21.10.2026: 30°, 45°, 60° and so on). A share of a full circle.
static func bend_from_degrees(degrees: float, magnet_deg: float) -> float:
	degrees = clampf(degrees, 0.0, 360.0)
	var nearest := snappedf(degrees, BEND_MAGNET_STEP_DEG)
	if absf(degrees - nearest) < magnet_deg:
		degrees = nearest
	return degrees / 360.0
