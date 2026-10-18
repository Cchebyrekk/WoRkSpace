class_name LayoutEdit
## Pure maths for moving one monitor in the Windows layout: no nodes, no engine
## state, covered by tests/run_tests.gd.
##
## Monitors are seen as rows (as in VR, where they stand in rows on the arc). A
## moved monitor goes into the row nearest to where it was dropped, or starts a new
## row above or below all others. Sideways it stays where it was dropped, pulled by
## a magnet to the edges of its row neighbours and to the edges, middles and seams
## of the monitors in the rows next to it (so two can sit over the seams of three).
## If it lands on a neighbour it is moved off to the nearer side, or, when dropped
## well inside the row, the neighbours make room. Afterwards gaps that would leave
## a monitor unconnected are closed, rows are stacked without vertical gaps, and
## the primary monitor is put back at (0, 0), as Windows requires. The result is
## always a layout Windows accepts.

## Magnet reach as a share of the moved monitor's width.
const SNAP_SHARE := 0.15


## Rows top to bottom; each row lists monitor indices left to right. Two monitors
## share a row when their vertical spans overlap by more than half the shorter one.
static func rows(rects: Array[Rect2i]) -> Array[PackedInt32Array]:
	var order: Array[int] = []
	for i in rects.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return _centre(rects[a]).y < _centre(rects[b]).y)
	var result: Array[PackedInt32Array] = []
	for i in order:
		var best := -1
		var best_overlap := 0
		for r in result.size():
			var overlap := _vertical_overlap(rects[i], _row_span(rects, result[r]))
			if overlap > best_overlap:
				best_overlap = overlap
				best = r
		var span := _row_span(rects, result[best]) if best >= 0 else Rect2i()
		if best >= 0 and best_overlap * 2 > mini(rects[i].size.y, span.size.y):
			var row := result[best]
			row.append(i)
			result[best] = row
		else:
			result.append(PackedInt32Array([i]))
	for r in result.size():
		result[r] = _sorted_by_x(rects, result[r])
	result.sort_custom(func(a: PackedInt32Array, b: PackedInt32Array) -> bool:
		return _row_span(rects, a).position.y < _row_span(rects, b).position.y)
	return result


## The layout after monitor `index` is dropped with its centre at `drop` (virtual
## desktop pixels, in the coordinates of `rects`). Same order as `rects`.
static func move(rects: Array[Rect2i], primary_index: int, index: int, drop: Vector2) -> Array[Rect2i]:
	var result: Array[Rect2i] = rects.duplicate()
	var moved := rects[index]

	# The rows without the moved monitor.
	var row_list: Array[PackedInt32Array] = []
	for row in rows(rects):
		var rest := PackedInt32Array()
		for i in row:
			if i != index:
				rest.append(i)
		if not rest.is_empty():
			row_list.append(rest)

	# Which row: the one whose middle is nearest the drop point, or a new row above or below.
	var target := -1
	var new_row := 0  # -1 above everything, +1 below
	var best := INF
	for r in row_list.size():
		var span := _row_span(rects, row_list[r])
		var distance := absf(drop.y - (span.position.y + span.size.y * 0.5))
		if distance < best:
			best = distance
			target = r
	if row_list.is_empty():
		new_row = 1
	else:
		var top := _row_span(rects, row_list[0]).position.y - moved.size.y * 0.5
		var bottom := _row_span(rects, row_list[-1]).end.y + moved.size.y * 0.5
		if absf(drop.y - top) < best:
			best = absf(drop.y - top)
			new_row = -1
		if absf(drop.y - bottom) < best:
			new_row = 1
	if new_row == -1:
		row_list.insert(0, PackedInt32Array())
		target = 0
	elif new_row == 1:
		row_list.append(PackedInt32Array())
		target = row_list.size() - 1

	# Sideways: where it was dropped, with the magnet.
	var x := drop.x - moved.size.x * 0.5
	var candidates: Array[float] = []
	for i in row_list[target]:
		candidates.append(rects[i].end.x)
		candidates.append(rects[i].position.x - moved.size.x)
	for r in [target - 1, target + 1]:
		if r < 0 or r >= row_list.size():
			continue
		for i in row_list[r]:
			var other := rects[i]
			for edge: float in [other.position.x, other.end.x, other.position.x + other.size.x * 0.5]:
				candidates.append(edge - moved.size.x * 0.5)  # middle on its edge or middle
			candidates.append(other.position.x)
			candidates.append(other.end.x - moved.size.x)
	var nearest := moved.size.x * SNAP_SHARE
	var snapped := x
	for candidate in candidates:
		if absf(candidate - x) <= nearest:
			nearest = absf(candidate - x)
			snapped = candidate
	x = snapped

	# Landing on a neighbour: moved off it if that is a short step, otherwise the row makes room.
	var row := row_list[target]
	var free_x := _nearest_free(rects, row, moved.size.x, x)
	if absf(free_x - x) <= moved.size.x * 0.5:
		x = free_x
	result[index] = Rect2i(Vector2i(roundi(x), 0), moved.size)
	# Its place in the row comes from where it was dropped: the magnet may have put
	# it exactly on top of a neighbour.
	var members := Array(row)
	members.append(index)
	members.sort_custom(func(a: int, b: int) -> bool:
		return (drop.x if a == index else _centre(result[a]).x) < (drop.x if b == index else _centre(result[b]).x))
	row = PackedInt32Array(members)
	_make_room(result, row, index)
	row_list[target] = row

	_stack_rows(result, row_list, primary_index)
	_connect(result, row_list, primary_index)

	var shift := -result[primary_index].position
	for i in result.size():
		result[i] = Rect2i(result[i].position + shift, result[i].size)
	return result


## Whether Windows takes the layout as it is: the primary at (0, 0), no overlaps,
## every monitor connected to the others by a shared edge.
static func is_valid(rects: Array[Rect2i], primary_index: int) -> bool:
	if rects[primary_index].position != Vector2i.ZERO:
		return false
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if rects[i].intersects(rects[j]):
				return false
	return _connected(rects, primary_index).size() == rects.size()


## A layout that has gone wrong around monitor `index` (e.g. it changed size and
## now overlaps a neighbour) put right: it is dropped again where its middle is.
static func repair(rects: Array[Rect2i], primary_index: int, index: int) -> Array[Rect2i]:
	return move(rects, primary_index, index, Vector2(rects[index].position) + Vector2(rects[index].size) * 0.5)


## The left edge nearest `x` at which a monitor `width` wide overlaps no one in `row`.
static func _nearest_free(rects: Array[Rect2i], row: PackedInt32Array, width: int, x: float) -> float:
	var options: Array[float] = [x]
	for i in row:
		options.append(rects[i].end.x)
		options.append(rects[i].position.x - width)
	var best := INF
	var best_x := x
	for option in options:
		var overlaps := false
		for i in row:
			if option < rects[i].end.x and option + width > rects[i].position.x:
				overlaps = true
				break
		if not overlaps and absf(option - x) < best:
			best = absf(option - x)
			best_x = option
	return best_x


## The monitor `fixed` keeps its place; the others in the row are pushed away from it
## where they overlap, each side in turn.
static func _make_room(rects: Array[Rect2i], row: PackedInt32Array, fixed: int) -> void:
	var at := row.find(fixed)
	for k in range(at + 1, row.size()):
		var previous := rects[row[k - 1]]
		if rects[row[k]].position.x < previous.end.x:
			rects[row[k]] = Rect2i(Vector2i(previous.end.x, rects[row[k]].position.y), rects[row[k]].size)
	for k in range(at - 1, -1, -1):
		var next := rects[row[k + 1]]
		if rects[row[k]].end.x > next.position.x:
			rects[row[k]] = Rect2i(Vector2i(next.position.x - rects[row[k]].size.x, rects[row[k]].position.y), rects[row[k]].size)


## Rows touch top to bottom. Rows above the primary's sit on the row below them
## (bottom-aligned), the primary's row and those below hang from the row above (top-aligned).
static func _stack_rows(rects: Array[Rect2i], row_list: Array[PackedInt32Array], primary_index: int) -> void:
	var heights: Array[int] = []
	var primary_row := 0
	for r in row_list.size():
		var height := 0
		for i in row_list[r]:
			height = maxi(height, rects[i].size.y)
			if i == primary_index:
				primary_row = r
		heights.append(height)
	var tops: Array[int] = []
	tops.resize(row_list.size())
	tops[primary_row] = 0
	for r in range(primary_row - 1, -1, -1):
		tops[r] = tops[r + 1] - heights[r]
	for r in range(primary_row + 1, row_list.size()):
		tops[r] = tops[r - 1] + heights[r - 1]
	for r in row_list.size():
		for i in row_list[r]:
			var y := tops[r] + heights[r] - rects[i].size.y if r < primary_row else tops[r]
			rects[i] = Rect2i(Vector2i(rects[i].position.x, y), rects[i].size)


## Closes gaps until every monitor is connected to the primary by touching edges:
## an unconnected monitor slides sideways to the nearest connected one in its row;
## a row with no connected monitor at all slides to overlap the row next to it.
static func _connect(rects: Array[Rect2i], row_list: Array[PackedInt32Array], primary_index: int) -> void:
	for attempt in rects.size() * 2:
		var connected := _connected(rects, primary_index)
		if connected.size() == rects.size():
			return
		var best_gap := INF
		var best_move := Vector2i.ZERO
		var best_index := -1
		for row in row_list:
			for u in row:
				if connected.has(u):
					continue
				for c in row:
					if not connected.has(c):
						continue
					var a := rects[u]
					var b := rects[c]
					var gap := float(a.position.x - b.end.x) if a.position.x >= b.end.x else float(b.position.x - a.end.x)
					if gap >= 0.0 and gap < best_gap:
						best_gap = gap
						best_index = u
						best_move = Vector2i(b.end.x - a.position.x if a.position.x >= b.end.x else b.position.x - a.end.x, 0)
		if best_index >= 0:
			rects[best_index] = Rect2i(rects[best_index].position + best_move, rects[best_index].size)
			continue
		# A whole row floats: slide it towards the row on the primary's side.
		var primary_row := 0
		for r in row_list.size():
			if row_list[r].has(primary_index):
				primary_row = r
		for r in row_list.size():
			var floating := true
			for i in row_list[r]:
				floating = floating and not connected.has(i)
			if floating and r != primary_row:
				_overlap_row(rects, row_list[r], row_list[r + 1 if r < primary_row else r - 1])
				break


## Indices reachable from `start` through monitors sharing an edge segment.
static func _connected(rects: Array[Rect2i], start: int) -> Dictionary:
	var reached := {start: true}
	var queue: Array[int] = [start]
	while not queue.is_empty():
		var a := rects[queue.pop_back()]
		for i in rects.size():
			if reached.has(i):
				continue
			var b := rects[i]
			var side := (a.end.x == b.position.x or b.end.x == a.position.x) and mini(a.end.y, b.end.y) > maxi(a.position.y, b.position.y)
			var stacked := (a.end.y == b.position.y or b.end.y == a.position.y) and mini(a.end.x, b.end.x) > maxi(a.position.x, b.position.x)
			if side or stacked:
				reached[i] = true
				queue.append(i)
	return reached


## Shifts `row` sideways until it overlaps `anchor` by at least half the narrower of the two.
static func _overlap_row(rects: Array[Rect2i], row: PackedInt32Array, anchor: PackedInt32Array) -> void:
	var span := _row_span(rects, row)
	var other := _row_span(rects, anchor)
	var need := mini(span.size.x, other.size.x) / 2
	var shift := 0
	if span.end.x < other.position.x + need:
		shift = other.position.x + need - span.end.x
	elif span.position.x > other.end.x - need:
		shift = other.end.x - need - span.position.x
	for i in row:
		rects[i] = Rect2i(rects[i].position + Vector2i(shift, 0), rects[i].size)


static func _sorted_by_x(rects: Array[Rect2i], row: PackedInt32Array) -> PackedInt32Array:
	var members := Array(row)
	members.sort_custom(func(a: int, b: int) -> bool: return _centre(rects[a]).x < _centre(rects[b]).x)
	return PackedInt32Array(members)


static func _row_span(rects: Array[Rect2i], row: PackedInt32Array) -> Rect2i:
	var span := rects[row[0]]
	for i in row:
		span = span.merge(rects[i])
	return span


static func _vertical_overlap(a: Rect2i, b: Rect2i) -> int:
	return mini(a.end.y, b.end.y) - maxi(a.position.y, b.position.y)


static func _centre(rect: Rect2i) -> Vector2:
	return Vector2(rect.position) + Vector2(rect.size) * 0.5
