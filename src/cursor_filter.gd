class_name CursorFilter
extends RefCounted
## Turns the raw point a pointer aims at on a screen into cursor moves and button
## events. Pure logic (no nodes, no engine state), covered by tests/run_tests.gd.
##
## The problem it solves: closing the fingers for a pinch moves the hand, so a
## click sent at the moment of the pinch lands next to the target. Therefore the
## press goes to where the pointer was shortly BEFORE the pinch, and the cursor
## then stays put until the hand has clearly moved, which starts a drag.


class Result:
	## Where the cursor should be, in the same units as the targets passed in.
	var position := Vector2.ZERO
	## The cursor has to be moved to `position` this frame.
	var move := false
	var press := false
	## Together with `press`: this press repeats the previous one and should reach
	## Windows as a double click.
	var double_click := false
	var release := false


## The press is placed where the pointer was this long before the pinch closed.
var lookback_sec := 0.1
## While held, the cursor follows only after the pointer has left this radius...
var drag_threshold := 40.0
## ...and only once the press has lasted this long, so a quick click never drags.
var drag_delay_sec := 0.25
## A press this soon after the previous release, and this close to the previous
## press, is a double click: it is placed on exactly the same point and flagged,
## so the caller can send Windows a fast double click. Windows itself wants both
## presses within half a second and a few pixels, which a hand pinch cannot do.
var double_click_sec := 1.0
var double_click_radius := 80.0

const HISTORY_SEC := 0.5

var _history: Array[Vector3] = []  # x, y, time
var _was_pressed := false
var _held := false
var _dragging := false
var _anchor := Vector2.ZERO
var _press_time := 0.0
var _last_release_time := -INF
var _double_click_done := false

## Diagnostics for tuning, valid after a press / a release respectively: how far
## the raw pointer was from where the press was placed, and how far it strayed
## from that point while the button was held.
var last_press_offset := 0.0
var last_hold_excursion := 0.0
var last_hold_sec := 0.0
var _position := Vector2.ZERO
var _has_position := false


func is_held() -> bool:
	return _held


## `target` is only meaningful while `on_screen` is true. A press counts only if
## it starts on the screen; one that started elsewhere and wandered in is ignored.
## `freeze` keeps an unpressed cursor still, e.g. while a gesture is being recognised.
## `anchor_time`, if given on the frame of a press, is when the gesture began; the
## press goes where the pointer was then (at most HISTORY_SEC back) instead of
## `lookback_sec` before now.
func update(target: Vector2, on_screen: bool, pressed: bool, time: float, freeze := false, anchor_time := NAN) -> Result:
	var result := Result.new()
	var just_pressed := pressed and not _was_pressed
	_was_pressed = pressed

	if on_screen:
		_history.append(Vector3(target.x, target.y, time))
	while not _history.is_empty() and _history[0].z < time - HISTORY_SEC:
		_history.pop_front()

	if _held and not pressed:
		_held = false
		_dragging = false
		# The release that ends a double click does not start another one.
		_last_release_time = -INF if _double_click_done else time
		_double_click_done = false
		last_hold_sec = time - _press_time
		result.release = true
	elif just_pressed and on_screen:
		var previous_anchor := _anchor
		_held = true
		_dragging = false
		_press_time = time
		var anchor_at := time - lookback_sec if is_nan(anchor_time) else maxf(anchor_time, time - HISTORY_SEC)
		_anchor = _position_at(anchor_at, target)
		result.double_click = time - _last_release_time <= double_click_sec and _anchor.distance_to(previous_anchor) <= double_click_radius
		if result.double_click:
			_anchor = previous_anchor
			_double_click_done = true
		last_press_offset = target.distance_to(_anchor)
		last_hold_excursion = 0.0
		_move(result, _anchor)
		result.press = true
	elif _held:
		if on_screen:
			last_hold_excursion = maxf(last_hold_excursion, target.distance_to(_anchor))
			if not _dragging and time - _press_time >= drag_delay_sec and target.distance_to(_anchor) > drag_threshold:
				_dragging = true
			if _dragging:
				_move(result, target)
	elif on_screen and not pressed and not freeze:
		_move(result, target)

	result.position = _position
	return result


## Moves the (unpressed) cursor back to where the pointer was at `time` and
## returns that point, or null if nothing that old is remembered. Used when a
## pose that freezes the cursor took a moment to form and dragged it off target.
func recall(time: float) -> Variant:
	if _held or _history.is_empty() or _history[0].z > time:
		return null
	var back := _position_at(time, Vector2.ZERO)
	_position = back
	_has_position = true
	return back


func _move(result: Result, to: Vector2) -> void:
	if _has_position and to == _position:
		return
	_position = to
	_has_position = true
	result.move = true


## The oldest remembered position that is not older than `time`.
func _position_at(time: float, fallback: Vector2) -> Vector2:
	for entry in _history:
		if entry.z >= time:
			return Vector2(entry.x, entry.y)
	return fallback
