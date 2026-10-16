class_name ExtraGestures
extends RefCounted
## Pure helpers for the gestures beyond clicking and scrolling: radial menu,
## swipe, two-hand pause, and tuning thresholds from a recording. No nodes, no
## engine state; covered by tests/run_tests.gd.


## Normal of the palm (pointing out of the palm side) from the wrist and the index
## and little finger knuckles. `side_sign` is -1 for the left hand, +1 for the right.
static func palm_normal(wrist: Vector3, index_knuckle: Vector3, little_knuckle: Vector3, side_sign: float) -> Vector3:
	var normal := (index_knuckle - wrist).cross(little_knuckle - wrist) * side_sign
	return normal.normalized() if normal.length_squared() > 0.0 else Vector3.ZERO


## Radial menu: items around a centre in a vertical plane facing the user. The
## hand keeps the pinch, moves towards an item and lets go to run it; letting go
## near the centre cancels.
class Radial:
	## [label, Windows virtual-key codes of the shortcut]
	const ITEMS := [
		["Копировать", [0x11, 0x43]],
		["Вставить", [0x11, 0x56]],
		["Вырезать", [0x11, 0x58]],
		["Сохранить", [0x11, 0x53]],
		["Пуск", [0x5B]],
		["Alt+Tab", [0x12, 0x09]],
		["Повторить", [0x11, 0x10, 0x5A]],
		["Отменить", [0x11, 0x5A]],
	]
	var centre := Vector3.ZERO
	var right := Vector3.RIGHT
	var up := Vector3.UP
	var radius := 0.13
	## Closer to the centre than this nothing is selected.
	var dead_zone := 0.03

	func open(at: Vector3, viewer: Vector3) -> void:
		var toward_viewer := Vector3(viewer.x - at.x, 0.0, viewer.z - at.z)
		toward_viewer = toward_viewer.normalized() if toward_viewer.length_squared() > 0.0001 else Vector3.BACK
		up = Vector3.UP
		right = (-toward_viewer).cross(up).normalized()
		centre = at

	## Index of the item the hand points at, or -1. Items go clockwise from the top.
	func selection(hand: Vector3) -> int:
		var local := hand - centre
		return Radial.item_at(Vector2(local.dot(right), local.dot(up)), dead_zone, ITEMS.size())

	## Where item `index` is drawn.
	func item_position(index: int) -> Vector3:
		var angle := index * TAU / ITEMS.size()
		return centre + (right * sin(angle) + up * cos(angle)) * radius

	static func item_at(offset: Vector2, dead: float, count: int) -> int:
		if offset.length() < dead:
			return -1
		var angle := fposmod(atan2(offset.x, offset.y), TAU)
		return int(round(angle / (TAU / count))) % count


## Swipe of an open hand sideways: returns -1 (left), +1 (right) or 0.
class Swipe:
	## The hand must travel this far sideways...
	var distance := 0.18
	## ...within this time.
	var window := 0.3
	## After a swipe nothing triggers for this long.
	var cooldown := 0.8

	var _history: Array[Vector2] = []  # (time, sideways position)
	var _blocked_until := -INF

	func update(time: float, sideways: float, open_hand: bool) -> int:
		if not open_hand or time < _blocked_until:
			_history.clear()
			return 0
		_history.append(Vector2(time, sideways))
		while not _history.is_empty() and _history[0].x < time - window:
			_history.pop_front()
		var travel := sideways - _history[0].y
		if absf(travel) >= distance:
			_history.clear()
			_blocked_until = time + cooldown
			return 1 if travel > 0.0 else -1
		return 0


## Two-hand pause: palms facing each other, close together, held for a moment.
## Returns true on the frame the pose completes; the pose has to be broken
## before it can trigger again.
class Pause:
	var hold_sec := 0.6
	var max_gap := 0.35
	## Cosine: how squarely each palm must face the other.
	var facing := 0.6

	var _since := NAN
	var _fired := false

	func update(time: float, left_palm: Vector3, left_normal: Vector3, right_palm: Vector3, right_normal: Vector3) -> bool:
		var between := right_palm - left_palm
		var gap := between.length()
		var pose := gap > 0.01 and gap < max_gap \
				and left_normal.dot(between / gap) > facing and right_normal.dot(-between / gap) > facing
		if not pose:
			_since = NAN
			_fired = false
			return false
		if is_nan(_since):
			_since = time
		if not _fired and time - _since >= hold_sec:
			_fired = true
			return true
		return false

	func reset() -> void:
		_since = NAN
		_fired = false


## Thresholds of the scroll pose from frames recorded while the user holds it
## (and moves the hand around). Each sample: [index_straightness,
## middle_straightness, index_align, middle_align, index_middle, thumb_spread,
## ring_to_palm]. Returns HandGestures.Settings property names with values, or
## an empty dictionary if the recording is too short. Each threshold sits a margin
## outside what nearly all recorded frames showed, so the pose holds while used.
static func calibrate_pose(samples: Array[PackedFloat32Array]) -> Dictionary:
	if samples.size() < 30:
		return {}
	var columns: Array[PackedFloat32Array] = []
	for feature in 7:
		var column := PackedFloat32Array()
		for sample in samples:
			column.append(sample[feature])
		column.sort()
		columns.append(column)
	var low := func(feature: int) -> float: return columns[feature][int(columns[feature].size() * 0.1)]
	var high := func(feature: int) -> float: return columns[feature][int(columns[feature].size() * 0.9)]
	return {
		"disc_straightness": clampf(minf(low.call(0), low.call(1)) - 0.05, 0.5, 0.95),
		"disc_align": clampf(minf(low.call(2), low.call(3)) - 0.05, 0.3, 0.98),
		"disc_together": clampf(high.call(4) + 0.005, 0.01, 0.06),
		"disc_thumb_spread": clampf(low.call(5) - 0.01, 0.02, 0.12),
		"disc_ring_curl": clampf(high.call(6) + 0.01, 0.03, 0.15),
	}


## Thresholds from a recording of one contact (e.g. thumb to index tip, metres)
## made while the user repeatedly touches and opens. Returns (press, release), or
## Vector2.ZERO if the recording does not show at least `min_touches` clear touches.
static func calibrate(distances: PackedFloat32Array, min_touches := 3) -> Vector2:
	if distances.size() < 30:
		return Vector2.ZERO
	var sorted := distances.duplicate()
	sorted.sort()
	var low := sorted[int(sorted.size() * 0.02)]
	var high := sorted[int(sorted.size() * 0.98)]
	var middle := (low + high) * 0.5
	var touching: Array[float] = []
	var open: Array[float] = []
	var touches := 0
	var was_touching := false
	for value in distances:
		var is_touching := value < middle
		if is_touching:
			touching.append(value)
		else:
			open.append(value)
		if is_touching and not was_touching:
			touches += 1
		was_touching = is_touching
	if touches < min_touches or touching.size() < 5 or open.size() < 5:
		return Vector2.ZERO
	touching.sort()
	open.sort()
	# The loosest real touch and the tightest real opening frame the gap.
	var touch_edge := touching[int(touching.size() * 0.9)]
	var open_edge := open[int(open.size() * 0.1)]
	var gap := open_edge - touch_edge
	if gap < 0.005:
		return Vector2.ZERO
	return Vector2(touch_edge + gap * 0.35, touch_edge + gap * 0.7)
