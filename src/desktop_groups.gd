class_name DesktopGroups
extends RefCounted
## The Windows layout made of groups (the user's wish, 23.10.2026): every
## fixture's screens are one group, laid out inside as they stand in VR (a
## wall's cells, a sphere's arc), so neighbours in VR are neighbours in Windows;
## the groups stand one after another, or where the user dragged them on the
## plane of groups (slice n). Pure logic, covered by tests/run_tests.gd.


## The rectangle round all of `rects`.
static func bounds(rects: Array[Rect2i]) -> Rect2i:
	if rects.is_empty():
		return Rect2i()
	var result := rects[0]
	for rect in rects:
		result = result.merge(rect)
	return result


## The same rectangles moved so that their bounds start at (0, 0).
static func normalized(rects: Array[Rect2i]) -> Array[Rect2i]:
	var low := bounds(rects).position
	var result: Array[Rect2i] = []
	for rect in rects:
		result.append(Rect2i(rect.position - low, rect.size))
	return result


## The groups placed: each at its offset (top left of its bounds) if it has one,
## else after the rightmost one so far, at the top. `blocks` are normalized.
## Returns the rectangles of each group where they stand.
static func compose(blocks: Array, ids: Array, offsets: Dictionary) -> Array:
	var placed := []
	var right := 0
	for k in blocks.size():
		if offsets.has(ids[k]):
			right = maxi(right, (offsets[ids[k]] as Vector2i).x + bounds(blocks[k]).size.x)
	for k in blocks.size():
		var block: Array[Rect2i] = blocks[k]
		var at := Vector2i(right, 0)
		if offsets.has(ids[k]):
			at = offsets[ids[k]]
		else:
			right += bounds(block).size.x
		var moved: Array[Rect2i] = []
		for rect in block:
			moved.append(Rect2i(rect.position + at, rect.size))
		placed.append(moved)
	return placed


## A group of `size` dropped at `at` (its top left) sticks to the others within
## `reach` (px), each way on its own: edge to edge, and edges in line.
static func snapped(at: Vector2i, size: Vector2i, others: Array[Rect2i], reach: int) -> Vector2i:
	var result := at
	for axis in 2:
		var best := reach + 1
		for other in others:
			for candidate: int in [other.end[axis], other.position[axis] - size[axis], other.position[axis], other.end[axis] - size[axis]]:
				var off := absi(candidate - at[axis])
				if off < best:
					best = off
					result[axis] = candidate
	return result


## Whether two rectangles share a stretch of edge (the cursor can go from one into the other).
static func touches(a: Rect2i, b: Rect2i) -> bool:
	var side := (a.end.x == b.position.x or b.end.x == a.position.x) and mini(a.end.y, b.end.y) > maxi(a.position.y, b.position.y)
	var top := (a.end.y == b.position.y or b.end.y == a.position.y) and mini(a.end.x, b.end.x) > maxi(a.position.x, b.position.x)
	return side or top


## The same rectangles moved by `by`.
static func shifted(rects: Array[Rect2i], by: Vector2i) -> Array[Rect2i]:
	var result: Array[Rect2i] = []
	for rect in rects:
		result.append(Rect2i(rect.position + by, rect.size))
	return result


## Whether any of `rects` lies on any of `others`.
static func overlaps(rects: Array[Rect2i], others: Array[Rect2i]) -> bool:
	for rect in rects:
		for other in others:
			if rect.intersects(other):
				return true
	return false


## The screens' area (pixels).
static func area(rects: Array[Rect2i]) -> int:
	var total := 0
	for rect in rects:
		total += rect.get_area()
	return total


## How much of the smaller of the two groups the other lies on (0..1): a group
## dropped on another pushes it aside only from half (the user's wish 23.10.2026:
## a slip onto a neighbour swapped them).
static func covered(rects: Array[Rect2i], others: Array[Rect2i]) -> float:
	var shared := 0
	for rect in rects:
		for other in others:
			shared += rect.intersection(other).get_area()
	return float(shared) / float(maxi(mini(area(rects), area(others)), 1))


## A group's screens can stand at `rects`: on none of the others' screens, and
## one of them sharing an edge with one of theirs.
static func fits(rects: Array[Rect2i], others: Array[Rect2i]) -> bool:
	var touching := others.is_empty()
	for rect in rects:
		for other in others:
			if rect.intersects(other):
				return false
			touching = touching or touches(rect, other)
	return touching


## Offsets of a block (its screens, top left of their bounds at (0, 0)) along one
## axis that put one of its screens edge to edge or in line with one of the others'.
static func _lines(block: Array[Rect2i], others: Array[Rect2i], axis: int) -> Array[int]:
	var result: Array[int] = []
	for mine in block:
		for other in others:
			for line: int in [other.end[axis] - mine.position[axis], other.position[axis] - mine.end[axis],
					other.position[axis] - mine.position[axis], other.end[axis] - mine.end[axis]]:
				if not result.has(line):
					result.append(line)
	return result


## Where a group (`block`) dropped at `at` stands (the user's wishes, 23.10.2026:
## groups lay on each other; the magnet should go corner to corner of screens,
## not of the groups' frames): the nearest place where it lies on no screen and
## one of its screens touches another's — slid along an edge or corner to corner —
## then corner to corner within `reach` of that if it still fits there.
static func placed(at: Vector2i, block: Array[Rect2i], others: Array[Rect2i], reach: int) -> Vector2i:
	if others.is_empty():
		return at
	var xs := _lines(block, others, 0)
	var ys := _lines(block, others, 1)
	var nearer := func(a: Vector2i, b: Vector2i) -> bool: return (a - at).length_squared() < (b - at).length_squared()
	var candidates: Array[Vector2i] = []
	for x in xs:
		candidates.append(Vector2i(x, at.y))
		for y in ys:
			candidates.append(Vector2i(x, y))
	for y in ys:
		candidates.append(Vector2i(at.x, y))
	candidates.sort_custom(nearer)
	var best := at
	for candidate in candidates:
		if fits(shifted(block, candidate), others):
			best = candidate
			break
	var corners: Array[Vector2i] = []
	for x in xs:
		for y in ys:
			if absi(x - best.x) <= reach and absi(y - best.y) <= reach:
				corners.append(Vector2i(x, y))
	corners.sort_custom(nearer)
	for corner in corners:
		if fits(shifted(block, corner), others):
			return corner
	return best


## The block at `at` with its screens' edges stuck to the others' within `reach`,
## each axis on its own, lying on them or not (a group dropped on another).
static func magnet(at: Vector2i, block: Array[Rect2i], others: Array[Rect2i], reach: int) -> Vector2i:
	var result := at
	for axis in 2:
		var best := reach + 1
		for line in _lines(block, others, axis):
			var off := absi(line - at[axis])
			if off < best:
				best = off
				result[axis] = line
	return result


## The groups (id -> their screens) after `moved` was put where it stands now
## (the user's wish 23.10.2026: a group dropped on another pushes it aside): each
## group it lies on moves, whole, to the nearest place on none of the others and
## touching one; the rest stay where they are.
static func pushed(groups: Dictionary, moved: int) -> Dictionary:
	var result := groups.duplicate()
	for id: int in groups:
		if id == moved or not overlaps(result[id], result[moved]):
			continue
		var others: Array[Rect2i] = []
		for other: int in result:
			if other != id:
				others.append_array(result[other])
		var block := normalized(result[id])
		result[id] = shifted(block, placed(bounds(result[id]).position, block, others, 0))
	return result


## Every group joined to the rest (Windows needs them touching, and a cut-off
## group was set right screen by screen, breaking it up): starting from `anchor`,
## each group (id -> its screens) not touching the joined ones moves, whole, to
## the nearest place that touches them.
static func joined(groups: Dictionary, anchor: int) -> Dictionary:
	var result := groups.duplicate()
	if not groups.has(anchor):
		return result
	var done: Array[int] = [anchor]
	var left: Array = groups.keys().filter(func(id: int) -> bool: return id != anchor)
	while not left.is_empty():
		var placed_rects: Array[Rect2i] = []
		for id in done:
			placed_rects.append_array(result[id])
		# The ones already touching join as they are; else the first one moves.
		var next: int = left[0]
		var as_is := false
		for id: int in left:
			if fits(result[id], placed_rects):
				next = id
				as_is = true
				break
		if not as_is:
			var block := normalized(result[next])
			result[next] = shifted(block, placed(bounds(result[next]).position, block, placed_rects, 0))
		done.append(next)
		left.erase(next)
	return result


## Saved offsets ({"id": [x, y]}) back into Vector2i by fixture id, and out.
static func offsets_from(saved: Variant) -> Dictionary:
	var result := {}
	if saved is Dictionary:
		for key: Variant in saved:
			var value: Variant = saved[key]
			if value is Array and value.size() == 2:
				result[int(key)] = Vector2i(int(value[0]), int(value[1]))
	return result


static func offsets_to(offsets: Dictionary) -> Dictionary:
	var result := {}
	for id: int in offsets:
		var at: Vector2i = offsets[id]
		result[str(id)] = [at.x, at.y]
	return result
