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
## The bend handle sits this much lower than the corner ones, clear of the screens' move grips (m).
const BEND_HANDLE_DROP := 0.08
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
static func settle(cells: Dictionary, keys: PackedStringArray, rects: Array[Rect2i], primary: int,
		elsewhere := {}, blocked: Array[Rect2i] = []) -> Dictionary:
	var result := cells.duplicate()
	var wanted := from_desktop(rects, primary)
	for i in keys.size():
		# Already on the wall: on whole cells, or in a part (`elsewhere`).
		if result.has(keys[i]) or elsewhere.has(keys[i]):
			continue
		var taken: Array[Rect2i] = blocked.duplicate()
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


## The wall's size dragged by a corner (`corner`: (1, 1) lower right, (-1, 1)
## lower left, (-1, -1) upper left, (1, -1) upper right; the user's wish,
## 22.10.2026: not only the lower right) to (u, v): that corner's two edges go to
## the cell boundary nearest the point (mid-gap); never smaller than its screens
## nor than one cell. The other two edges stay.
static func dragged_grid(grid: Rect2i, cells: Array[Rect2i], u: float, v: float, gap := DEFAULT_GAP,
		corner := Vector2i(1, 1)) -> Rect2i:
	var step := pitch(gap)
	var edge := Vector2i(roundi(u / step.x + 0.5), roundi(-v / step.y + 0.5))
	var start := grid.position
	var end := grid.end
	if corner.x > 0:
		end.x = maxi(edge.x, start.x + 1)
	else:
		start.x = mini(edge.x, end.x - 1)
	if corner.y > 0:
		end.y = maxi(edge.y, start.y + 1)
	else:
		start.y = mini(edge.y, end.y - 1)
	var result := Rect2i(start, end - start)
	for cell in cells:
		result = result.merge(cell)
	return result


## Where a size handle is: past that corner of the wall.
static func size_handle_point(grid: Rect2i, gap := DEFAULT_GAP, corner := Vector2i(1, 1)) -> Vector2:
	var wall := area(grid, gap)
	return Vector2(wall.end.x + HANDLE_MARGIN.x if corner.x > 0 else wall.position.x - HANDLE_MARGIN.x,
			wall.position.y - HANDLE_MARGIN.y if corner.y > 0 else wall.end.y + HANDLE_MARGIN.y)


## Where the bend handle is: under the middle of the wall's lower edge (its lower
## left corner is a size handle now), below the screens' own grips.
static func bend_handle_point(grid: Rect2i, gap := DEFAULT_GAP) -> Vector2:
	var wall := area(grid, gap)
	return Vector2(wall.get_center().x, wall.position.y - HANDLE_MARGIN.y - BEND_HANDLE_DROP)


## The wall's outline for drawing as lines (pairs of points, the fixture's space):
## round every cell, part and joined cell, in the middle of the gaps (the outer
## frame half a gap out); a little behind the wall, so only the frame and the gaps
## show past the screens. Bent, lines across follow the arc.
static func outline(grid: Rect2i, gap: float, shape: Shape, wall: Wall = null) -> PackedVector3Array:
	if wall == null:
		wall = Wall.new()
	var lines := PackedVector3Array()
	for leaf in all_leaves(wall, grid):
		var box := wall.area_of(leaf, gap).grow(gap * 0.5)
		for u: float in [box.position.x, box.end.x]:
			lines.append(surface(u, box.position.y, OUTLINE_DEPTH, shape).origin)
			lines.append(surface(u, box.end.y, OUTLINE_DEPTH, shape).origin)
		var pieces := maxi(ceili(box.size.x / 0.2), 1) if shape.bent() else 1
		for v: float in [box.position.y, box.end.y]:
			for k in pieces:
				lines.append(surface(lerpf(box.position.x, box.end.x, float(k) / pieces), v, OUTLINE_DEPTH, shape).origin)
				lines.append(surface(lerpf(box.position.x, box.end.x, float(k + 1) / pieces), v, OUTLINE_DEPTH, shape).origin)
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


## --- Split and joined cells (slice k2, the user's choices 21–22.10.2026) ------
## A cell can be split into columns ("c3") or rows ("r2"), evenly or by weights
## ("cw0.4,0.6"), and a part can be split again. A part is named by its cell and
## the path down to it: "x,y" is the whole cell, "x,y:1" its second part,
## "x,y:1:0" the first part of that. Cells or parts joined together are a cell of
## their own (the user's wish, 22.10.2026: "a real one"), named "B1", "B2"…: it is
## split, joined and deleted like any other ("B1:0" is its first part), and what it
## covers is hidden behind it. A screen stands on whole cells (a rectangle of them)
## or in one place (a part or a joined cell); a split or covered cell is not free
## for screens on whole cells.

## The «÷» grip went through these once: whole, 2 columns, 3, 2 rows, 3, whole again.
const SPLITS: Array[String] = ["", "c2", "c3", "r2", "r3"]
## The smallest side a part may get when split (m; the user's wish, 22.10.2026: no
## limit on how many times, a limit on how small). With the usual 6 cm gap a cell
## splits into up to 9 columns or 5 rows; a part's resolution is raised to the
## driver's smallest side anyway (VddConfig.fitted).
const MIN_PART_SIDE := 0.08
## A screen dropped with its middle this near (share of a cell's pitch) to the line
## between two cells stands staggered over their halves (`straddled`).
const STAGGER_SHARE := 0.12
## Edges this close (m) count as the same line when places are joined.
const JOIN_EPSILON := 0.002


## A wall's screens: on whole cells, in parts; how cells are split and joined.
class Wall:
	## Monitor key -> Rect2i of whole cells.
	var cells := {}
	## Monitor key -> the place it stands in (a part or a joined cell).
	var parts := {}
	## Cell, part or joined cell -> how it is split.
	var splits := {}
	## Joined cell "B<n>" -> what it covers, "a+b+…" (cells or parts, hidden behind it).
	var blocks := {}
	## A wall that is only read (main.gd keeps one per wall until it changes): what
	## is asked of it is remembered. Worked out every frame on a wall of ~1800 parts
	## (22.10.2026, «Стена 2») it took the frame rate down to 38 and below.
	var frozen := false
	var _hidden: Variant = null
	var _areas := {}
	var _areas_gap := NAN
	var _under := {}
	var _leaves := {}

	func copy() -> Wall:
		var other := Wall.new()
		other.cells = cells.duplicate()
		other.parts = parts.duplicate()
		other.splits = splits.duplicate()
		other.blocks = blocks.duplicate()
		return other

	## A cell, part or joined cell on the wall in metres.
	func area_of(slot: String, gap: float) -> Rect2:
		if not frozen:
			return WallLayout.slot_area(slot, splits, gap, blocks)
		if gap != _areas_gap:
			_areas = {}
			_areas_gap = gap
		if not _areas.has(slot):
			_areas[slot] = WallLayout.slot_area(slot, splits, gap, blocks)
		return _areas[slot]

	## Every slot hidden behind a joined cell -> that joined cell.
	func hidden() -> Dictionary:
		if frozen and _hidden != null:
			return _hidden
		var result := {}
		for id: String in blocks:
			for member in (blocks[id] as String).split("+", false):
				result[member] = id
		if frozen:
			_hidden = result
		return result

	## Where screens on whole cells cannot go: other screens on whole cells, split
	## cells and cells under joined cells.
	func taken(except := "") -> Array[Rect2i]:
		var result: Array[Rect2i] = []
		for key: String in cells:
			if key != except:
				result.append(cells[key])
		result.append_array(WallLayout.split_cells(splits, blocks))
		return result

	## The screen in a place, or on a cell alone ("x,y"), or "".
	func occupant(slot: String) -> String:
		for key: String in parts:
			if parts[key] == slot:
				return key
		if not slot.contains(":") and not slot.begins_with("B"):
			var whole := Rect2i(WallLayout.cell_of(slot), Vector2i.ONE)
			for key: String in cells:
				if cells[key] == whole:
					return key
		return ""

	## Every cell holding a screen (for the wall's size).
	func used_cells() -> Array[Rect2i]:
		var result: Array[Rect2i] = []
		for key: String in cells:
			result.append(cells[key])
		for key: String in parts:
			result.append(WallLayout.screen_cells(self, key))
		return result

	func has(key: String) -> bool:
		return cells.has(key) or parts.has(key)


## The split cells and the cells under joined cells, as rectangles (not free for
## screens on whole cells).
static func split_cells(splits: Dictionary, blocks := {}) -> Array[Rect2i]:
	var result: Array[Rect2i] = []
	for slot: String in splits:
		if not slot.contains(":") and not slot.begins_with("B"):
			result.append(Rect2i(cell_of(slot), Vector2i.ONE))
	for id: String in blocks:
		for member in (blocks[id] as String).split("+", false):
			if not member.contains(":") and not member.begins_with("B"):
				result.append(Rect2i(cell_of(member), Vector2i.ONE))
	return result


## Every place on the wall a screen could stand in: the unsplit parts and whole
## cells of the grid and of the joined cells, not those hidden behind joined cells.
static func all_leaves(wall: Wall, grid: Rect2i) -> PackedStringArray:
	if wall.frozen and wall._leaves.has(grid):
		return wall._leaves[grid]
	var hidden := wall.hidden()
	var result := PackedStringArray()
	for y in range(grid.position.y, grid.end.y):
		for x in range(grid.position.x, grid.end.x):
			for leaf in leaves(slot_of(Vector2i(x, y)), wall.splits):
				if not hidden.has(leaf):
					result.append(leaf)
	for id: String in wall.blocks:
		for leaf in leaves(id, wall.splits):
			if not hidden.has(leaf):
				result.append(leaf)
	if wall.frozen:
		wall._leaves[grid] = result
	return result


## A screen of `pixels` as big as fits in `box` (m), its shape kept.
static func fit(box: Vector2, pixels: Vector2i) -> Vector2:
	if pixels.x <= 0 or pixels.y <= 0:
		return box
	var aspect := float(pixels.x) / float(pixels.y)
	return Vector2(box.y * aspect, box.y) if box.x / box.y > aspect else Vector2(box.x, box.x / aspect)


## The resolution (among `available`) for a screen shown `box` metres big on a
## wall: the one nearest its shape, then its size at a cell's 1920 px per width;
## Vector2i.ZERO if none is within 5 % of the shape (experimental, 22.10.2026).
static func best_resolution(box: Vector2, available: Array[Vector2i]) -> Vector2i:
	if box.x <= 0.0 or box.y <= 0.0:
		return Vector2i.ZERO
	var wanted := Vector2(wanted_resolution(box))
	var shape := box.x / box.y
	var best := Vector2i.ZERO
	var best_score := INF
	for size in available:
		if size.x <= 0 or size.y <= 0:
			continue
		var off := absf(log(float(size.x) / size.y / shape))
		if off > log(1.05):
			continue
		var score := off * 10.0 + absf(log(float(size.x) / wanted.x))
		if score < best_score:
			best = size
			best_score = score
	return best


static func slot_of(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]


static func cell_of(slot: String) -> Vector2i:
	var head := slot.get_slice(":", 0)
	return Vector2i(int(head.get_slice(",", 0)), int(head.get_slice(",", 1)))


## The grid cell a place lies on (a joined cell's first one).
static func _cell_of(wall: Wall, slot: String) -> Vector2i:
	var head := slot.get_slice(":", 0)
	if head.begins_with("B"):
		var members := (wall.blocks.get(head, "") as String).split("+", false)
		return _cell_of(wall, members[0]) if not members.is_empty() else Vector2i.ZERO
	return cell_of(head)


## A cell, part or joined cell on the wall in metres (as `area`): the parts of a
## split share it, with the wall's gap between them; rows count from the top. A
## joined cell is the rectangle round what it covers (`blocks`).
static func slot_area(slot: String, splits: Dictionary, gap := DEFAULT_GAP, blocks := {}) -> Rect2:
	var path := slot.split(":")
	var current := path[0]
	var rect := Rect2()
	if current.begins_with("B"):
		for member in (blocks.get(current, "") as String).split("+", false):
			var spot := slot_area(member, splits, gap, blocks)
			rect = spot if rect.size == Vector2.ZERO else rect.merge(spot)
	else:
		rect = area(Rect2i(cell_of(current), Vector2i.ONE), gap)
	for k in range(1, path.size()):
		var spec: String = splits.get(current, "")
		if spec == "":
			break
		rect = _part(rect, spec, int(path[k]), gap)
		current += ":" + path[k]
	return rect


## Part `index` of `rect` split as `spec`: "c3" three equal columns, "r2" two equal
## rows (counted from the top), "cw0.4,0.6" columns sharing the room by those
## weights (a joined place cut into equal parts cuts its cells unevenly;
## 22.10.2026). Never a negative size (a wider gap after small parts were made).
static func _part(rect: Rect2, spec: String, index: int, gap: float) -> Rect2:
	var weights := _weights(spec)
	var total := 0.0
	var before := 0.0
	for i in weights.size():
		total += weights[i]
		if i < index:
			before += weights[i]
	var columns := spec.begins_with("c")
	var room := maxf((rect.size.x if columns else rect.size.y) - (weights.size() - 1) * gap, 0.0)
	var size := room * weights[index] / total
	var offset := room * before / total + index * gap
	if columns:
		return Rect2(rect.position.x + offset, rect.position.y, size, rect.size.y)
	return Rect2(rect.position.x, rect.end.y - offset - size, rect.size.x, size)


## How many parts a split `spec` has.
static func spec_count(spec: String) -> int:
	return _weights(spec).size()


## The share of each part of a split `spec` (all 1 for an even split).
static func _weights(spec: String) -> PackedFloat64Array:
	var result := PackedFloat64Array()
	if spec.substr(1, 1) == "w":
		for weight in spec.substr(2).split(","):
			result.append(maxf(float(weight), 0.0001))
		return result
	for i in maxi(int(spec.substr(1)), 1):
		result.append(1.0)
	return result


## A split `kind` with these weights: even as "c3", else "cw…".
static func _spec(kind: String, weights: PackedFloat64Array) -> String:
	var even := true
	for weight in weights:
		even = even and is_equal_approx(weight, weights[0])
	if even:
		return kind + str(weights.size())
	var parts := PackedStringArray()
	for weight in weights:
		parts.append("%.5f" % weight)
	return kind + "w" + ",".join(parts)


## The unsplit parts under `slot`, in order (the slot itself if it is not split).
static func leaves(slot: String, splits: Dictionary) -> PackedStringArray:
	var spec: String = splits.get(slot, "")
	if spec == "":
		return PackedStringArray([slot])
	var result := PackedStringArray()
	for i in spec_count(spec):
		result.append_array(leaves("%s:%d" % [slot, i], splits))
	return result


## The place at (u, v) on `cell`: down the cell's splits, and on into the joined
## cell where the part found is hidden behind one.
static func leaf_at(wall: Wall, cell: Vector2i, u: float, v: float, gap := DEFAULT_GAP) -> String:
	var hidden := wall.hidden()
	var slot := _descend(wall, slot_of(cell), u, v, gap)
	for guard in 16:
		if not hidden.has(slot):
			break
		slot = _descend(wall, hidden[slot], u, v, gap)
	return slot


## The unsplit part of `slot` at (u, v).
static func _descend(wall: Wall, slot: String, u: float, v: float, gap: float) -> String:
	while wall.splits.has(slot):
		var spec: String = wall.splits[slot]
		var count := spec_count(spec)
		var rect := wall.area_of(slot, gap)
		var index := count - 1
		for i in count:
			var part := _part(rect, spec, i, gap)
			# Up to the middle of the gap after the part.
			if (u <= part.end.x + gap * 0.5) if spec.begins_with("c") else (v >= part.position.y - gap * 0.5):
				index = i
				break
		slot = "%s:%d" % [slot, index]
	return slot


## Where a screen is on the wall (m): its cells or its place.
static func screen_area(wall: Wall, key: String, gap := DEFAULT_GAP) -> Rect2:
	if wall.parts.has(key):
		return wall.area_of(wall.parts[key], gap)
	return area(wall.cells.get(key, Rect2i()), gap)


## The cells a screen stands on (for a screen in a place: the cells under it).
static func screen_cells(wall: Wall, key: String) -> Rect2i:
	if wall.cells.has(key):
		return wall.cells[key]
	return _cells_under(wall, wall.parts.get(key, "0,0"))


static func _cells_under(wall: Wall, slot: String) -> Rect2i:
	var head := slot.get_slice(":", 0)
	if not head.begins_with("B"):
		return Rect2i(cell_of(head), Vector2i.ONE)
	if wall.frozen and wall._under.has(head):
		return wall._under[head]
	var result := Rect2i()
	for member in (wall.blocks.get(head, "") as String).split("+", false):
		var under := _cells_under(wall, member)
		result = under if result.size == Vector2i.ZERO else result.merge(under)
	if wall.frozen:
		wall._under[head] = result
	return result


## The resolution a screen shown `box` metres big should have to be as sharp as a
## whole cell (1920 px across CELL.x), in steps of 8 px.
static func wanted_resolution(box: Vector2) -> Vector2i:
	var per_metre := 1920.0 / CELL.x
	return Vector2i(maxi(roundi(box.x * per_metre / 8.0) * 8, 8), maxi(roundi(box.y * per_metre / 8.0) * 8, 8))


## The next way to split `slot` (whole, 2 columns, 3, 2 rows, 3, whole again).
static func cycled(wall: Wall, slot: String) -> Wall:
	var spec: String = wall.splits.get(slot, "")
	return resplit(wall, slot, SPLITS[(SPLITS.find(spec) + 1) % SPLITS.size()])


## «Разделить» on place `leaf` (`kind` "c" vertically, into columns, or "r"
## horizontally, into rows; the user's choices, 22.10.2026): the place itself — a
## part, a cell or a joined cell — in `count` equal parts, while the parts stay at
## least MIN_PART_SIDE; parts split alike are kept as one even split (`_flatten`:
## four columns, not halves of halves), so deleting one of four leaves three equal ones.
static func split_step(wall: Wall, leaf: String, kind: String, gap := DEFAULT_GAP, count := 2) -> Wall:
	if count < 2 or not is_leaf(wall, leaf) or not can_split(wall, leaf, kind, count, gap):
		return wall
	var result := resplit(wall, leaf, kind + str(count))
	_flatten(result)
	return result


## Whether `leaf` split `kind` in `count` keeps every part at least MIN_PART_SIDE.
static func can_split(wall: Wall, leaf: String, kind: String, count := 2, gap := DEFAULT_GAP) -> bool:
	if count < 2:
		return false
	var box := wall.area_of(leaf, gap)
	var length := box.size.x if kind == "c" else box.size.y
	return (length - (count - 1) * gap) / count >= MIN_PART_SIDE - JOIN_EPSILON


## The places under a rectangle drawn on the wall from `from` to `to` (u, v; the
## user's wish, 22.10.2026: select several cells at once to split or join them).
static func selection(wall: Wall, grid: Rect2i, from: Vector2, to: Vector2, gap := DEFAULT_GAP) -> PackedStringArray:
	var box := Rect2(from, Vector2.ZERO).expand(to)
	var result := PackedStringArray()
	for leaf in all_leaves(wall, grid):
		var spot := wall.area_of(leaf, gap)
		if spot.intersects(box, true) or spot.has_point(from):
			result.append(leaf)
	return result


## Every place in `leaves` split `kind` in `count` equal parts (those that would get too small stay).
static func split_many(wall: Wall, leaves: PackedStringArray, kind: String, count: int, gap := DEFAULT_GAP) -> Wall:
	var result := wall
	for leaf in leaves:
		if is_leaf(result, leaf) and can_split(result, leaf, kind, count, gap):
			result = resplit(result, leaf, kind + str(count))
	if result != wall:
		_flatten(result)
	return result


## The rectangle round some places (m).
static func _box(wall: Wall, slots: PackedStringArray, gap: float) -> Rect2:
	var result := Rect2()
	for slot in slots:
		var spot := wall.area_of(slot, gap)
		result = spot if result.size == Vector2.ZERO else result.merge(spot)
	return result


## `leaves` joined into one cell: first grown until they make a rectangle (every
## place the rectangle around them touches, again and again). Not under a screen on
## several cells; a screen in it stands in all of it, any others go to the free cell nearest.
static func joined_many(wall: Wall, leaves: PackedStringArray, grid: Rect2i, gap := DEFAULT_GAP) -> Wall:
	var members := leaves.duplicate()
	var inside_set := {}
	for leaf in members:
		inside_set[leaf] = true
	var changed := true
	while changed:
		changed = false
		var box := _box(wall, members, gap).grow(-JOIN_EPSILON)
		for leaf in all_leaves(wall, grid):
			if not inside_set.has(leaf) and wall.area_of(leaf, gap).intersects(box):
				members.append(leaf)
				inside_set[leaf] = true
				changed = true
	if members.size() < 2 or not _holds_own(wall, members):
		return wall
	var result := wall.copy()
	var inside: Array[String] = []
	for leaf in members:
		var who := wall.occupant(leaf)
		if who != "" and not inside.has(who):
			inside.append(who)
	for who in inside:
		result.parts.erase(who)
		result.cells.erase(who)
	var seed := _cell_of(wall, members[0])
	var id := _new_block(result, members)
	if not inside.is_empty():
		result.parts[inside[0]] = id
	_tidy(result)
	for k in range(1, inside.size()):
		result.cells[inside[k]] = nearest_free(Rect2i(seed, Vector2i.ONE), result.taken())
	return result


## A new joined cell covering `members`; its name.
static func _new_block(wall: Wall, members: PackedStringArray) -> String:
	var n := 1
	while wall.blocks.has("B%d" % n):
		n += 1
	var id := "B%d" % n
	wall.blocks[id] = "+".join(members)
	_compact(wall, id)
	return id


## What joined cell `id` covers, kept to what says where it is (the user's wish,
## 22.10.2026: «зачем вообще помнить» — 1794 parts were kept under one): a cell or
## part all of whose pieces it covers stands for them, and its splits are
## forgotten. Only cells it covers in part keep the pieces at its edge.
static func _compact(wall: Wall, id: String) -> void:
	var members := {}
	for member in (wall.blocks[id] as String).split("+", false):
		members[member] = true
	var changed := true
	while changed:
		changed = false
		for member: String in members.keys():
			if not members.has(member) or not member.contains(":"):
				continue
			var parent := member.substr(0, member.rfind(":"))
			var under := leaves(parent, wall.splits)
			var all_in := true
			for leaf in under:
				all_in = all_in and members.has(leaf)
			if not all_in:
				continue
			for leaf in under:
				members.erase(leaf)
			for split: String in wall.splits.keys():
				if split == parent or split.begins_with(parent + ":"):
					wall.splits.erase(split)
			members[parent] = true
			changed = true
	wall.blocks[id] = "+".join(PackedStringArray(members.keys()))


## «Удалить» on `leaf` (the user's rules, 22.10.2026): a part of a split goes, and
## the others of that split share its place equally (by their weights; the last
## one of two takes all of it) — a joined cell's parts too. A whole cell or a joined
## cell goes to the neighbour of the same size — right, else below, above, left —
## which takes its place; with no such neighbour it is not deleted. A screen in it
## goes to the free cell nearest.
static func deleted(wall: Wall, leaf: String, grid: Rect2i, gap := DEFAULT_GAP) -> Wall:
	if not is_leaf(wall, leaf) or not _holds_own(wall, PackedStringArray([leaf])):
		return wall
	var who := wall.occupant(leaf)
	if leaf.contains(":"):
		var result := wall.copy()
		var parent := leaf.substr(0, leaf.rfind(":"))
		var index := int(leaf.substr(leaf.rfind(":") + 1))
		var spec: String = wall.splits[parent]
		var left := spec_count(spec) - 1
		if who != "":
			result.parts.erase(who)
			result.cells.erase(who)
		if left >= 2:
			var weights := _weights(spec)
			weights.remove_at(index)
			result.splits[parent] = _spec(spec.left(1), weights)
		else:
			result.splits.erase(parent)
		_remap(result, func(slot: String) -> String:
			if not slot.begins_with(parent + ":"):
				return slot
			var path := slot.substr(parent.length() + 1).split(":")
			var at := int(path[0])
			if at == index:
				return ""
			path[0] = str(at - 1 if at > index else at)
			return parent + ("" if left < 2 else ":" + path[0]) + (":" + ":".join(path.slice(1)) if path.size() > 1 else ""))
		if who != "":
			result.cells[who] = nearest_free(Rect2i(_cell_of(wall, parent), Vector2i.ONE), result.taken())
		_flatten(result)
		return result
	var size := wall.area_of(leaf, gap).size
	for dir: Vector2i in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(-1, 0)]:
		var target := join_target(wall, leaf, dir, grid, gap)
		if target == "" or not wall.area_of(target, gap).size.is_equal_approx(size):
			continue
		var emptied := wall.copy()
		if who != "":
			emptied.parts.erase(who)
			emptied.cells.erase(who)
		var result := joined(emptied, leaf, dir, grid, gap)
		if who != "":
			result.cells[who] = nearest_free(Rect2i(_cell_of(wall, leaf), Vector2i.ONE), result.taken())
		return result
	return wall


## Splits of every part of a split alike (the same way and count) are one even
## split instead: two columns of two columns are four columns (the same places,
## gaps included), so the parts are equal ones.
static func _flatten(wall: Wall) -> void:
	var changed := true
	while changed:
		changed = false
		for parent: String in wall.splits.keys():
			var spec: String = wall.splits[parent]
			var count := spec_count(spec)
			var first: String = wall.splits.get(parent + ":0", "")
			# Even splits only; uneven ones stay as they are.
			if first == "" or first.left(1) != spec.left(1) or spec.substr(1, 1) == "w" or first.substr(1, 1) == "w":
				continue
			var alike := true
			for i in count:
				alike = alike and wall.splits.get("%s:%d" % [parent, i], "") == first
			if not alike:
				continue
			var each := int(first.substr(1))
			for i in count:
				wall.splits.erase("%s:%d" % [parent, i])
			wall.splits[parent] = spec.left(1) + str(count * each)
			_remap(wall, func(slot: String) -> String:
				if not slot.begins_with(parent + ":"):
					return slot
				var path := slot.substr(parent.length() + 1).split(":")
				if path.size() < 2:
					return ""
				var rest := path.slice(2)
				return "%s:%d" % [parent, int(path[0]) * each + int(path[1])] + (":" + ":".join(rest) if not rest.is_empty() else ""))
			changed = true
			break


## Every slot renamed by `rename` (slot -> new name, "" = gone): split keys, the
## places screens stand in, what joined cells cover (one that covers nothing is gone).
static func _remap(wall: Wall, rename: Callable) -> void:
	var splits := {}
	for slot: String in wall.splits:
		var renamed: String = rename.call(slot)
		if renamed != "":
			splits[renamed] = wall.splits[slot]
	wall.splits = splits
	for id: String in wall.blocks.keys():
		var members := _renamed(wall.blocks[id], rename)
		if members == "":
			wall.blocks.erase(id)
		else:
			wall.blocks[id] = members
	for key: String in wall.parts.keys():
		var place: String = rename.call(wall.parts[key])
		if place == "" or (place.begins_with("B") and not wall.blocks.has(place.get_slice(":", 0))):
			wall.parts.erase(key)
		elif place.contains(":") or place.begins_with("B"):
			wall.parts[key] = place
		else:
			wall.parts.erase(key)
			_put(wall, key, place)


static func _renamed(value: String, rename: Callable) -> String:
	var kept := PackedStringArray()
	for leaf in value.split("+", false):
		var renamed: String = rename.call(leaf)
		if renamed != "":
			kept.append(renamed)
	return "+".join(kept)


## The place next to `leaf` on side `dir` ((1, 0) right, (-1, 0) left, (0, 1)
## below, (0, -1) above) that it may join: the only one across that side, and the
## side the same length for both (the user's rule, 22.10.2026); neither under a
## screen on several cells. "" if none.
static func join_target(wall: Wall, leaf: String, dir: Vector2i, grid: Rect2i, gap := DEFAULT_GAP) -> String:
	var a := wall.area_of(leaf, gap)
	var found := ""
	for other in all_leaves(wall, grid):
		if other == leaf:
			continue
		var b := wall.area_of(other, gap)
		var across := minf(a.end.y, b.end.y) - maxf(a.position.y, b.position.y) if dir.x != 0 \
				else minf(a.end.x, b.end.x) - maxf(a.position.x, b.position.x)
		var step := 0.0
		match dir:
			Vector2i(1, 0):
				step = b.position.x - a.end.x
			Vector2i(-1, 0):
				step = a.position.x - b.end.x
			Vector2i(0, 1):
				step = a.position.y - b.end.y
			_:
				step = b.position.y - a.end.y
		if absf(step - gap) >= JOIN_EPSILON or across <= JOIN_EPSILON:
			continue
		if found != "":
			return ""
		found = other
	if found == "" or not _holds_own(wall, PackedStringArray([leaf, found])):
		return ""
	var b := wall.area_of(found, gap)
	var same := absf(a.position.y - b.position.y) < JOIN_EPSILON and absf(a.end.y - b.end.y) < JOIN_EPSILON if dir.x != 0 \
			else absf(a.position.x - b.position.x) < JOIN_EPSILON and absf(a.end.x - b.end.x) < JOIN_EPSILON
	return found if same else ""


## Whether no screen on several cells stands on any of these places.
static func _holds_own(wall: Wall, places: PackedStringArray) -> bool:
	for place in places:
		var under := _cells_under(wall, place)
		for key: String in wall.cells:
			var rect: Rect2i = wall.cells[key]
			if rect.size != Vector2i.ONE and rect.intersects(under):
				return false
	return true


## «Соединить» on `leaf`: it and the place on side `dir` (`join_target`) become one
## cell (a joined cell grows instead of a new one being made). A screen in either
## stands in all of it (if both have one, the other goes to the free cell nearest).
## Joined back into everything a split had, the cell or part is simply whole again.
static func joined(wall: Wall, leaf: String, dir: Vector2i, grid: Rect2i, gap := DEFAULT_GAP) -> Wall:
	var target := join_target(wall, leaf, dir, grid, gap)
	if target == "":
		return wall
	var result := wall.copy()
	var keep := wall.occupant(leaf)
	var other := wall.occupant(target)
	if keep == "":
		keep = other
		other = ""
	for who: String in [keep, other]:
		if who != "":
			result.parts.erase(who)
			result.cells.erase(who)
	var whole_a := leaf.begins_with("B") and not leaf.contains(":")
	var whole_b := target.begins_with("B") and not target.contains(":")
	var id := ""
	if whole_a and whole_b:
		id = leaf
		result.blocks[id] = "%s+%s" % [result.blocks[leaf], result.blocks[target]]
		result.blocks.erase(target)
	elif whole_a:
		id = leaf
		result.blocks[id] = "%s+%s" % [result.blocks[leaf], target]
	elif whole_b:
		id = target
		result.blocks[id] = "%s+%s" % [result.blocks[target], leaf]
	else:
		id = _new_block(result, PackedStringArray([leaf, target]))
	_compact(result, id)
	if keep != "":
		result.parts[keep] = id
	_tidy(result)
	if other != "":
		result.cells[other] = nearest_free(Rect2i(_cell_of(wall, leaf), Vector2i.ONE), result.taken())
	return result


## A joined cell that covers exactly everything some cell or part was split into
## stops being one: that cell or part is simply whole again (its screen there).
static func _tidy(wall: Wall) -> void:
	var changed := true
	while changed:
		changed = false
		for id: String in wall.blocks.keys():
			var members := (wall.blocks[id] as String).split("+", false)
			if wall.splits.has(id) or members.is_empty():
				continue
			var slot := members[0]
			# Covering one cell or part only, it is that cell or part.
			if members.size() == 1:
				slot += ":"
			while slot.contains(":") and not changed:
				slot = slot.substr(0, slot.rfind(":"))
				var under := leaves(slot, wall.splits)
				var same := under.size() == members.size()
				for leaf in under:
					same = same and members.has(leaf)
				if not same:
					continue
				wall.blocks.erase(id)
				for split: String in wall.splits.keys():
					if split == slot or split.begins_with(slot + ":"):
						wall.splits.erase(split)
				for key: String in wall.parts.keys():
					if wall.parts[key] == id:
						wall.parts.erase(key)
						_put(wall, key, slot)
				changed = true
			if changed:
				break


## `slot` split as `next` ("" = whole). Screens in it go into its new parts in
## order; those that no longer fit go to the free cell nearest. A cell under a
## screen on several cells is not split; joined cells covering parts of it come apart.
static func resplit(wall: Wall, slot: String, next: String) -> Wall:
	var cell := _cell_of(wall, slot)
	if not slot.begins_with("B"):
		for key: String in wall.cells:
			var rect: Rect2i = wall.cells[key]
			if rect.size != Vector2i.ONE and rect.has_point(cell):
				return wall
	var result := wall.copy()
	var movers: Array[String] = []
	for leaf in leaves(slot, wall.splits):
		var key := wall.occupant(leaf)
		if key != "" and not movers.has(key):
			movers.append(key)
	for id: String in wall.blocks:
		for member in (wall.blocks[id] as String).split("+", false):
			if member == slot or member.begins_with(slot + ":"):
				for leaf in leaves(id, wall.splits):
					var key := wall.occupant(leaf)
					if key != "" and not movers.has(key):
						movers.append(key)
				result.blocks.erase(id)
				for split: String in wall.splits:
					if split == id or split.begins_with(id + ":"):
						result.splits.erase(split)
				break
	for key in movers:
		result.parts.erase(key)
		result.cells.erase(key)
	for other: String in wall.splits:
		if other == slot or other.begins_with(slot + ":"):
			result.splits.erase(other)
	if next != "":
		result.splits[slot] = next
	var new_leaves := leaves(slot, result.splits)
	for k in movers.size():
		if k < new_leaves.size():
			_put(result, movers[k], new_leaves[k])
		else:
			result.cells[movers[k]] = nearest_free(Rect2i(cell, Vector2i.ONE), result.taken())
	return result


## A screen dropped with its middle at (u, v): into the place there if that cell is
## split or joined (a screen already in it changes places with this one), else onto
## whole cells as `moved` (a screen from a part takes one cell); a screen on several
## cells does not go into a part.
static func dropped(wall: Wall, key: String, u: float, v: float, gap := DEFAULT_GAP) -> Wall:
	var cell := cell_at(u, v, Vector2i.ONE, gap).position
	var spanning: bool = wall.cells.has(key) and (wall.cells[key] as Rect2i).size != Vector2i.ONE
	# Its middle on the line between two cells: staggered, over their halves.
	var across := u / pitch(gap).x
	if not spanning and absf(across - floorf(across) - 0.5) < STAGGER_SHARE:
		var staggered := straddled(wall, key, Vector2i(floori(across), cell.y))
		if staggered != null:
			return staggered
	var leaf := leaf_at(wall, cell, u, v, gap)
	if leaf != slot_of(cell) and not spanning:
		return into(wall, key, leaf)
	var size: Vector2i = (wall.cells[key] as Rect2i).size if wall.cells.has(key) else Vector2i.ONE
	return onto_cells(wall, key, cell_at(u, v, size, gap))


## Staggered rows (the user's wish, 22.10.2026: «шахматный порядок»): screen `key`
## put on the line between cell `left` and the one to its right takes the right half
## of one and the left half of the other, joined into one cell; whole cells are
## split in two columns for it, a screen alone on one going into its outer half.
## Null if it cannot stand there (a cell split some other way or joined, under a
## screen on several cells).
static func straddled(wall: Wall, key: String, left: Vector2i) -> Wall:
	var result := wall.copy()
	var old_part: String = wall.parts.get(key, "")
	var old_cells: Rect2i = wall.cells.get(key, Rect2i())
	result.parts.erase(key)
	result.cells.erase(key)
	var hidden := wall.hidden()
	var halves := PackedStringArray()
	for side in 2:
		var cell := left + Vector2i(side, 0)
		var slot := slot_of(cell)
		for other: String in result.cells:
			var rect: Rect2i = result.cells[other]
			if rect.size != Vector2i.ONE and rect.has_point(cell):
				return null
		var spec: String = result.splits.get(slot, "")
		var inner := "%s:%d" % [slot, 1 - side]
		if hidden.has(slot) or hidden.has(inner):
			return null
		if spec == "":
			var alone := result.occupant(slot)
			result.splits[slot] = "c2"
			if alone != "":
				result.cells.erase(alone)
				result.parts[alone] = "%s:%d" % [slot, side]
		elif spec != "c2" or result.splits.has(inner):
			return null
		halves.append(inner)
	var displaced: Array[String] = []
	for half in halves:
		var other := result.occupant(half)
		if other != "" and not displaced.has(other):
			displaced.append(other)
	for other in displaced:
		result.parts.erase(other)
	result.parts[key] = _new_block(result, halves)
	# Who stood there takes the carried screen's old place if it is free, else the free cell nearest.
	for other in displaced:
		if old_part != "" and _is_free_leaf(result, old_part):
			result.parts[other] = old_part
			old_part = ""
		elif old_cells.size == Vector2i.ONE and not overlaps(old_cells, result.taken()) and result.occupant(slot_of(old_cells.position)) == "":
			result.cells[other] = old_cells
			old_cells = Rect2i()
		else:
			result.cells[other] = nearest_free(Rect2i(left, Vector2i.ONE), result.taken())
	return result


## Whether `value` is an empty place on the wall now (a part or a joined cell).
static func _is_free_leaf(wall: Wall, value: String) -> bool:
	return (value.contains(":") or value.begins_with("B")) and is_leaf(wall, value) and wall.occupant(value) == ""


## Whether `slot` is a place on the wall now: unsplit, not hidden behind a joined
## cell, and still there (a part named before a change may be gone: 22.10.2026 the
## «÷» grip kept one after a join, and deleting it stopped the frame).
static func is_leaf(wall: Wall, slot: String) -> bool:
	if wall.splits.has(slot) or wall.hidden().has(slot):
		return false
	var path := slot.split(":")
	var current := path[0]
	if current.begins_with("B") and not wall.blocks.has(current):
		return false
	for k in range(1, path.size()):
		var spec: String = wall.splits.get(current, "")
		if spec == "" or int(path[k]) >= spec_count(spec):
			return false
		current += ":" + path[k]
	return true


## Screen `key` into place `leaf`; the screen there takes this one's old place.
static func into(wall: Wall, key: String, leaf: String) -> Wall:
	var result := wall.copy()
	var other := wall.occupant(leaf)
	if other == key:
		return result
	var old_part: String = wall.parts.get(key, "")
	var old_cells: Rect2i = wall.cells.get(key, Rect2i())
	result.parts.erase(key)
	result.cells.erase(key)
	_put(result, key, leaf)
	if other != "":
		result.parts.erase(other)
		result.cells.erase(other)
		if old_part != "":
			result.parts[other] = old_part
		elif old_cells.size == Vector2i.ONE:
			result.cells[other] = old_cells
		else:
			result.cells[other] = nearest_free(Rect2i(_cell_of(wall, leaf), Vector2i.ONE), result.taken())
	return result


## Screen `key` onto whole cells at `target` (kept off split cells); screens there
## step aside as in `moved`.
static func onto_cells(wall: Wall, key: String, target: Rect2i) -> Wall:
	var splits_only := Wall.new()
	splits_only.splits = wall.splits
	splits_only.blocks = wall.blocks
	var result := wall.copy()
	result.parts.erase(key)
	var others := wall.cells.duplicate()
	others.erase(key)
	var place := nearest_free(target, splits_only.taken())
	var placed := moved(others.merged({key: place}), key, place)
	# Screens pushed aside keep off split cells too.
	for other: String in placed:
		if other != key:
			var blocked := splits_only.taken()
			for kept: String in placed:
				if kept != other:
					blocked.append(placed[kept])
			placed[other] = nearest_free(placed[other], blocked)
	result.cells = placed
	return result


## The Windows layout for screens as they stand on a wall (slice k2: when the user
## sits at it). `areas` are the screens on the wall (m, as `area`), `pixels` their
## sizes; the primary stays at (0, 0).
##
## It keeps the wall's order, not its distances (22.10.2026: a screen whose
## pixels did not match its place — 960×1080 on 3.9 × 3 m — pushed every other one
## astray): each two screens are kept apart along the axis they are further apart
## in on the wall, in the wall's order (left stays left, above stays above), so no
## two overlap. Screens touching on the wall (within `reach` m) touch on the
## desktop, and a screen is lined up with its neighbour across their shared edge
## by the middle of that edge, in each one's own pixels — the cursor crosses where
## it does on the wall. What Windows would not take is put right by LayoutEdit.
static func desktop(areas: Array[Rect2], pixels: Array[Vector2i], primary: int, reach: float) -> Array[Rect2i]:
	var count := areas.size()
	var rects: Array[Rect2i] = []
	rects.resize(count)
	if count == 0:
		return rects
	# The wall with y going down, like the desktop.
	var boxes: Array[Rect2] = []
	for area in areas:
		boxes.append(Rect2(area.position.x, -area.end.y, area.size.x, area.size.y))
	# before[axis][i]: [j, touching] for each screen j kept before i along that axis.
	# anchors[axis][i]: [j, shared length] for each screen j touching i across the
	# other axis — it lines i up along this one.
	var before := [[], []]
	var anchors := [[], []]
	for axis in 2:
		for i in count:
			(before[axis] as Array).append([])
			(anchors[axis] as Array).append([])
	for i in count:
		for j in range(i + 1, count):
			var a := boxes[i]
			var b := boxes[j]
			var gap := Vector2(maxf(b.position.x - a.end.x, a.position.x - b.end.x), maxf(b.position.y - a.end.y, a.position.y - b.end.y))
			var axis := 0 if gap.x >= gap.y else 1
			var other := 1 - axis
			var first := i if a.get_center()[axis] <= b.get_center()[axis] else j
			var second := j if first == i else i
			var shared := minf(a.end[other], b.end[other]) - maxf(a.position[other], b.position[other])
			var touching := gap[axis] <= reach and shared > 0.0
			(before[axis][second] as Array).append([first, touching])
			if touching:
				(anchors[other][i] as Array).append([j, shared])
				(anchors[other][j] as Array).append([i, shared])
	var per_metre := 1920.0 / CELL.x
	var placed := [[], []]
	for axis in 2:
		(placed[axis] as Array).resize(count)
		var order: Array = range(count)
		order.sort_custom(func(p: int, q: int) -> bool:
			var cp: float = boxes[p].get_center()[axis]
			var cq: float = boxes[q].get_center()[axis]
			return cp < cq or (cp == cq and p < q))
		for k: int in order:
			var lower := -INF
			var tight := false
			for entry: Array in before[axis][k]:
				var j: int = entry[0]
				lower = maxf(lower, float(placed[axis][j]) + pixels[j][axis])
				tight = tight or entry[1]
			var value := lower
			if not tight:
				# Lined up with the placed neighbour across the longest shared edge.
				var anchor := -1
				var longest := 0.0
				for entry: Array in anchors[axis][k]:
					if placed[axis][entry[0]] != null and float(entry[1]) > longest:
						anchor = entry[0]
						longest = entry[1]
				if anchor >= 0:
					var a := boxes[anchor]
					var own := boxes[k]
					var middle := (maxf(a.position[axis], own.position[axis]) + minf(a.end[axis], own.end[axis])) * 0.5
					var lined := float(placed[axis][anchor]) + (middle - a.position[axis]) / a.size[axis] * pixels[anchor][axis] \
							- (middle - own.position[axis]) / own.size[axis] * pixels[k][axis]
					value = maxf(lined, lower)
				elif lower == -INF:
					value = boxes[k].position[axis] * per_metre
			placed[axis][k] = roundi(value)
	var origin := Vector2i(placed[0][primary], placed[1][primary])
	for i in count:
		rects[i] = Rect2i(Vector2i(placed[0][i], placed[1][i]) - origin, pixels[i])
	return rects


static func _put(wall: Wall, key: String, leaf: String) -> void:
	if leaf.contains(":") or leaf.begins_with("B"):
		wall.parts[key] = leaf
	else:
		wall.cells[key] = Rect2i(cell_of(leaf), Vector2i.ONE)


## The bend for `degrees` of arc set on the bend slider: kept in 0..360 (flat ..
## cylinder) and pulled to every BEND_MAGNET_STEP_DEG within `magnet_deg` (the
## user's wish, 21.10.2026: 30°, 45°, 60° and so on). A share of a full circle.
static func bend_from_degrees(degrees: float, magnet_deg: float) -> float:
	degrees = clampf(degrees, 0.0, 360.0)
	var nearest := snappedf(degrees, BEND_MAGNET_STEP_DEG)
	if absf(degrees - nearest) < magnet_deg:
		degrees = nearest
	return degrees / 360.0
