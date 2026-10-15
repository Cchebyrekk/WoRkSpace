class_name HandGestures
extends RefCounted
## Gesture recogniser for one hand. Pure logic (no nodes, no engine state),
## covered by tests/run_tests.gd.
##
##   thumb + index            -> left button
##   thumb + middle           -> right button
##   thumb + index + middle   -> middle button
##   index + middle together, thumb away, hand moving up/down -> wheel
##
## The gestures overlap: a three-finger pinch starts as a two-finger one. So the
## first contact opens a short window (`confirm_delay`); the button is decided by
## which fingers touched the thumb within it. While undecided, `pending` asks the
## caller to keep the cursor still. All contacts use hysteresis: a finger touches
## below `pinch_press` and lets go only above `pinch_release`.

enum Click { NONE = -1, LEFT = 0, RIGHT = 1, MIDDLE = 2 }


## Every threshold and delay is tunable in VR (settings panel in main.gd).
## Distances in metres, times in seconds.
class Settings:
	var pinch_press := 0.018
	var pinch_release := 0.035
	var confirm_delay := 0.12
	## Index and middle tips count as together below this distance...
	var scroll_together := 0.02
	## ...and as apart again above this.
	var scroll_apart := 0.03
	## For the wheel the thumb must be at least this far from both tips.
	var scroll_thumb_clear := 0.05
	## Index and middle must be at least this straight (1 = fully straight).
	var scroll_straightness := 0.85
	## Ring finger tip must be within this distance of the palm, i.e. curled; 0 = not required.
	## Without it a relaxed open hand, whose fingers also lie together, would scroll.
	var scroll_ring_curl := 0.07
	## The wheel pose has to be held this long before the wheel turns.
	var scroll_dwell := 0.15
	## Wheel units (120 = one notch) per metre of vertical hand travel.
	var scroll_speed := 2000.0
	## Vertical hand speed (m/s) below which the hand counts as still.
	var scroll_deadzone := 0.03


## One frame of hand data. Distances are in metres; `height` is the hand's
## vertical position in the world.
class Frame:
	var time := 0.0
	var thumb_index := 1.0
	var thumb_middle := 1.0
	var index_middle := 1.0
	var index_straightness := 0.0
	var middle_straightness := 0.0
	var ring_to_palm := 1.0
	var height := 0.0


class Output:
	## The button held this frame, or NONE.
	var button := Click.NONE
	## Fingers touched but the button is not decided yet: keep the cursor still.
	var pending := false
	## The wheel pose is on (also during its dwell): keep the cursor still.
	var scrolling := false
	## Wheel units to send this frame; positive scrolls up.
	var scroll := 0.0


enum _State { IDLE, PENDING, PRESSED, TAP, SCROLL_PENDING, SCROLLING, BLOCKED }

var settings := Settings.new()

var _state := _State.IDLE
var _since := 0.0
var _button := Click.NONE
var _index_in := false
var _middle_in := false
var _index_touched := false
var _middle_touched := false
var _pose := false
var _last_height := 0.0
var _last_time := 0.0


func update(frame: Frame) -> Output:
	var s := settings
	_index_in = frame.thumb_index < (s.pinch_release if _index_in else s.pinch_press)
	_middle_in = frame.thumb_middle < (s.pinch_release if _middle_in else s.pinch_press)
	var any_in := _index_in or _middle_in
	_pose = _is_wheel_pose(frame)

	# A tap is held for exactly one frame.
	if _state == _State.TAP:
		_state = _State.IDLE
		_button = Click.NONE

	match _state:
		_State.IDLE:
			if any_in:
				_state = _State.PENDING
				_since = frame.time
				_index_touched = _index_in
				_middle_touched = _middle_in
			elif _pose:
				_state = _State.SCROLL_PENDING
				_since = frame.time
		_State.PENDING:
			_index_touched = _index_touched or _index_in
			_middle_touched = _middle_touched or _middle_in
			if not any_in:
				# Opened again before the window ran out: a quick click.
				_button = _decide()
				_state = _State.TAP
			elif frame.time - _since >= s.confirm_delay:
				_button = _decide()
				_state = _State.PRESSED
		_State.PRESSED:
			# Held until every finger has let go; a finger joining later changes nothing.
			if not any_in:
				_state = _State.IDLE
				_button = Click.NONE
		_State.SCROLL_PENDING:
			if any_in:
				_state = _State.BLOCKED
			elif not _pose:
				_state = _State.IDLE
			elif frame.time - _since >= s.scroll_dwell:
				_state = _State.SCROLLING
				_last_height = frame.height
				_last_time = frame.time
		_State.SCROLLING:
			if any_in:
				# The thumb came in while scrolling: no click until the fingers are open again.
				_state = _State.BLOCKED
			elif not _pose:
				_state = _State.IDLE
		_State.BLOCKED:
			if not any_in:
				_state = _State.IDLE

	var output := Output.new()
	output.button = _button if _state == _State.PRESSED or _state == _State.TAP else Click.NONE
	output.pending = _state == _State.PENDING
	output.scrolling = _state == _State.SCROLL_PENDING or _state == _State.SCROLLING
	if _state == _State.SCROLLING:
		var travel := frame.height - _last_height
		var elapsed := maxf(frame.time - _last_time, 0.001)
		if absf(travel) / elapsed > s.scroll_deadzone:
			output.scroll = travel * s.scroll_speed
		_last_height = frame.height
		_last_time = frame.time
	return output


func _decide() -> Click:
	if _index_touched and _middle_touched:
		return Click.MIDDLE
	if _middle_touched:
		return Click.RIGHT
	return Click.LEFT


func _is_wheel_pose(frame: Frame) -> bool:
	var s := settings
	var together := frame.index_middle < (s.scroll_apart if _pose else s.scroll_together)
	var thumb_clear := frame.thumb_index > s.scroll_thumb_clear and frame.thumb_middle > s.scroll_thumb_clear
	var straight := frame.index_straightness >= s.scroll_straightness and frame.middle_straightness >= s.scroll_straightness
	var ring_curled := s.scroll_ring_curl <= 0.0 or frame.ring_to_palm < s.scroll_ring_curl
	return together and thumb_clear and straight and ring_curled


## How straight a finger is from its joint positions: 1 when the knuckle-to-tip
## distance equals the length of the segments, less as the finger curls.
static func straightness(proximal: Vector3, intermediate: Vector3, distal: Vector3, tip: Vector3) -> float:
	var length := proximal.distance_to(intermediate) + intermediate.distance_to(distal) + distal.distance_to(tip)
	return proximal.distance_to(tip) / length if length > 0.0001 else 0.0
