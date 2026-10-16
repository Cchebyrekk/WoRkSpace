class_name HandGestures
extends RefCounted
## Gesture recogniser for one hand. Pure logic (no nodes, no engine state),
## covered by tests/run_tests.gd.
##
##   thumb tip + index tip                    -> left button
##   thumb tip + middle tip                   -> right button
##   thumb tip against the side of the index  -> middle button
##   index and middle straight and pointing up, thumb out to the side, ring
##   finger curled                            -> scroll disc (see ScrollDisc)
##
## The first contact opens a short window (`confirm_delay`) before the button is
## decided, so that a touch passing near one finger on its way to another is not
## taken for the wrong button; if several contacts happened within the window, the
## one that got deepest relative to its threshold wins. While undecided, `pending`
## asks the caller to keep the cursor still. All contacts and the disc pose use
## hysteresis.
##
## The three-finger pinch of the first version was dropped: on 16.10.2026 the user
## could not trigger it reliably and asked for the side touch instead.

enum Click { NONE = -1, LEFT = 0, RIGHT = 1, MIDDLE = 2 }


## Every threshold and delay is tunable in VR (settings panel in main.gd).
## Distances in metres, times in seconds.
class Settings:
	## Thumb tip to index / middle tip: touches below `pinch_press`, lets go above `pinch_release`.
	var pinch_press := 0.018
	var pinch_release := 0.035
	## Thumb tip to the side of the index finger's first segment (middle button).
	var side_press := 0.022
	var side_release := 0.035
	var confirm_delay := 0.12
	## Disc pose: index and middle at least this straight (1 = fully straight)...
	var disc_straightness := 0.8
	## ...pointing up at least this much (cosine to the vertical: 1 = straight up, 0.5 = 60 degrees off)...
	var disc_up := 0.5
	## ...the thumb tip at least this far from the index knuckle (out to the side)...
	var disc_thumb_spread := 0.06
	## ...and the ring finger tip within this distance of the palm (curled); 0 = not required.
	var disc_ring_curl := 0.07
	## The disc appears once the pose has been held this long.
	var disc_dwell := 0.15
	## Disc geometry, used by the caller for ScrollDisc: radius and wheel units
	## (120 = one notch) per full turn.
	var disc_radius := 0.06
	var disc_turn_units := 960.0


## One frame of hand data. Distances in metres; `*_up` are cosines between the
## finger and the world's up direction.
class Frame:
	var time := 0.0
	var thumb_index := 1.0
	var thumb_middle := 1.0
	## Thumb tip to the first segment (knuckle to middle joint) of the index finger.
	var thumb_side := 1.0
	var index_straightness := 0.0
	var middle_straightness := 0.0
	var index_up := 0.0
	var middle_up := 0.0
	## Thumb tip to the index knuckle.
	var thumb_spread := 0.0
	var ring_to_palm := 1.0


class Output:
	## The button held this frame, or NONE.
	var button := Click.NONE
	## Fingers touched but the button is not decided yet: keep the cursor still.
	var pending := false
	## The disc pose is held but the disc has not appeared yet: keep the cursor still.
	var disc_pending := false
	## The disc is up: the caller turns the wheel from the fingertips' circling.
	var disc := false
	## True on the frame the disc appears: the caller places it at the fingertips.
	var disc_started := false


enum _State { IDLE, PENDING, PRESSED, TAP, DISC_PENDING, DISC, BLOCKED }
enum _Contact { INDEX, MIDDLE, SIDE }

var settings := Settings.new()

var _state := _State.IDLE
var _since := 0.0
var _button := Click.NONE
var _in := [false, false, false]
## Deepest contact of each kind during the recognition window, as distance / press threshold.
var _depth := [INF, INF, INF]
var _pose := false


func update(frame: Frame) -> Output:
	var s := settings
	var distances := [frame.thumb_index, frame.thumb_middle, frame.thumb_side]
	var presses := [s.pinch_press, s.pinch_press, s.side_press]
	var releases := [s.pinch_release, s.pinch_release, s.side_release]
	for contact in 3:
		_in[contact] = distances[contact] < (releases[contact] if _in[contact] else presses[contact])
	var any_in: bool = _in[0] or _in[1] or _in[2]
	_pose = _is_disc_pose(frame)

	# A tap is held for exactly one frame.
	if _state == _State.TAP:
		_state = _State.IDLE
		_button = Click.NONE

	var output := Output.new()
	match _state:
		_State.IDLE:
			if any_in:
				_state = _State.PENDING
				_since = frame.time
				_depth = [INF, INF, INF]
				_track_depth(distances, presses)
			elif _pose:
				_state = _State.DISC_PENDING
				_since = frame.time
		_State.PENDING:
			_track_depth(distances, presses)
			if not any_in:
				# Opened again before the window ran out: a quick click.
				_button = _decide()
				_state = _State.TAP
			elif frame.time - _since >= s.confirm_delay:
				_button = _decide()
				_state = _State.PRESSED
		_State.PRESSED:
			# Held until every contact has let go; another contact joining changes nothing.
			if not any_in:
				_state = _State.IDLE
				_button = Click.NONE
		_State.DISC_PENDING:
			if any_in:
				_state = _State.BLOCKED
			elif not _pose:
				_state = _State.IDLE
			elif frame.time - _since >= s.disc_dwell:
				_state = _State.DISC
				output.disc_started = true
		_State.DISC:
			if any_in:
				# A finger touched the thumb while scrolling: no click until all are open again.
				_state = _State.BLOCKED
			elif not _pose:
				_state = _State.IDLE
		_State.BLOCKED:
			if not any_in:
				_state = _State.IDLE

	output.button = _button if _state == _State.PRESSED or _state == _State.TAP else Click.NONE
	output.pending = _state == _State.PENDING
	output.disc_pending = _state == _State.DISC_PENDING
	output.disc = _state == _State.DISC
	return output


func _track_depth(distances: Array, presses: Array) -> void:
	for contact in 3:
		if _in[contact]:
			_depth[contact] = minf(_depth[contact], distances[contact] / presses[contact])


func _decide() -> Click:
	var best := _Contact.INDEX
	for contact in 3:
		if _depth[contact] < _depth[best]:
			best = contact
	match best:
		_Contact.MIDDLE:
			return Click.RIGHT
		_Contact.SIDE:
			return Click.MIDDLE
	return Click.LEFT


func _is_disc_pose(frame: Frame) -> bool:
	var s := settings
	# Looser limits once the pose is on, so that it does not flicker off.
	var slack := 0.1 if _pose else 0.0
	var straight := frame.index_straightness >= s.disc_straightness - slack and frame.middle_straightness >= s.disc_straightness - slack
	var up := frame.index_up >= s.disc_up - 2.0 * slack and frame.middle_up >= s.disc_up - 2.0 * slack
	var thumb_out := frame.thumb_spread >= s.disc_thumb_spread - 0.1 * slack
	var ring_curled := s.disc_ring_curl <= 0.0 or frame.ring_to_palm < s.disc_ring_curl + 0.1 * slack
	return straight and up and thumb_out and ring_curled


## How straight a finger is from its joint positions: 1 when the knuckle-to-tip
## distance equals the length of the segments, less as the finger curls.
static func straightness(proximal: Vector3, intermediate: Vector3, distal: Vector3, tip: Vector3) -> float:
	var length := proximal.distance_to(intermediate) + intermediate.distance_to(distal) + distal.distance_to(tip)
	return proximal.distance_to(tip) / length if length > 0.0001 else 0.0


## Distance from a point to the segment a-b.
static func distance_to_segment(point: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((point - a).dot(ab) / ab.length_squared(), 0.0, 1.0) if ab.length_squared() > 0.0 else 0.0
	return point.distance_to(a + ab * t)
