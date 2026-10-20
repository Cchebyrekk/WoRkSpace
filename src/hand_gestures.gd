class_name HandGestures
extends RefCounted
## Gesture recogniser for one hand. Pure logic (no nodes, no engine state),
## covered by tests/run_tests.gd.
##
##   thumb tip + index tip                    -> left button
##   thumb tip + middle tip                   -> right button
##   thumb tip against the side of the index  -> middle button
##   (the defaults: since 20.10.2026 any touch of Contact can make any button,
##   see Settings.left_contact and GestureCatalog)
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
## The thumb touching: a fingertip or the side of the index finger.
enum Contact { INDEX = 0, MIDDLE = 1, RING = 2, PINKY = 3, SIDE = 4 }
const CONTACT_COUNT := 5


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
	## A finger counts as starting to close on the thumb when it comes nearer than
	## this; the press is placed where the ray was at that moment (see anchor_time).
	var approach := 0.045
	## Disc pose: index and middle at least this straight (1 = fully straight)...
	var disc_straightness := 0.8
	## ...in line with the hand, not bent at the knuckle (cosine between finger and
	## wrist-to-knuckle direction: 1 = straight on)...
	var disc_align := 0.8
	## ...held together (tip to tip)...
	var disc_together := 0.025
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
	## What the scroll pose does: 0 = scroll in the direction the hand moves from
	## where the pose formed (ScrollStick), 1 = turn the disc (ScrollDisc).
	var scroll_mode := 0
	## ScrollStick: 1 = inverted.
	var invert_vertical := 0
	var invert_horizontal := 0
	## ScrollStick: wheel units per second at full offset (120 = one notch).
	var stick_speed := 2400.0
	## The plane the hand works in for scrolling (ScrollStick) and moving
	## (Locomotion), tipped forward from upright: 0 = hand up/down, 90 = hand
	## towards/away (the user wanted to choose, 20.10.2026).
	var ring_tilt_degrees := 0.0
	## Open-hand swipe: 0 = back / forward (Alt+Left / Alt+Right), 1 = undo / redo (Ctrl+Z / Ctrl+Shift+Z).
	var swipe_mode := 0
	## How far the open hand has to travel sideways within 0.3 s.
	var swipe_distance := 0.18
	## Two-hand zoom: wheel units (with Ctrl) per metre the hands move apart.
	var zoom_speed := 1200.0
	## How a hand grabs a screen panel to move it: 0 = pinch on the bar under the
	## panel, 1 = also a fist anywhere on the panel. Controllers always use the bar.
	var grab_mode := 0
	## Fist: the tips of all four fingers nearer the palm than this.
	var fist_curl := 0.07
	## Which touch makes which button (Contact, -1 = the button is off). The user
	## picks them in the settings (GestureCatalog); a touch bound to no button does
	## nothing at all. Ring and little fingertips use the pinch thresholds.
	var left_contact := 0  # Contact.INDEX
	var right_contact := 1  # Contact.MIDDLE
	var middle_contact := 4  # Contact.SIDE


## One frame of hand data. Distances in metres; `*_align` are cosines between the
## finger (knuckle to tip) and the hand (wrist to knuckle).
class Frame:
	var time := 0.0
	var thumb_index := 1.0
	var thumb_middle := 1.0
	var thumb_ring := 1.0
	var thumb_pinky := 1.0
	## Thumb tip to the first segment (knuckle to middle joint) of the index finger.
	var thumb_side := 1.0
	## The scroll pose as decided by the caller (a pose the user picked: 1 held,
	## 0 not), or -1 to use the built-in scroll pose below.
	var scroll_pose := -1
	var index_straightness := 0.0
	var middle_straightness := 0.0
	var index_align := 0.0
	var middle_align := 0.0
	var index_middle := 1.0
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
	## On the frame a button is decided: when the deciding finger started closing on
	## the thumb. The press belongs where the ray was then, before the hand moved.
	var anchor_time := NAN


enum _State { IDLE, PENDING, PRESSED, TAP, DISC_PENDING, DISC, BLOCKED }

var settings := Settings.new()

var _state := _State.IDLE
var _since := 0.0
var _button := Click.NONE
var _in := [false, false, false, false, false]
## Deepest contact of each kind during the recognition window, as distance / press threshold.
var _depth := [INF, INF, INF, INF, INF]
## Last time each contact's distance was beyond `approach` (the finger was open).
var _open_time := [0.0, 0.0, 0.0, 0.0, 0.0]
var _pose := false


## Forgets everything, e.g. when the hand goes to rest: any held button is let go.
func reset() -> void:
	_state = _State.IDLE
	_button = Click.NONE
	_in = [false, false, false, false, false]
	_pose = false


func update(frame: Frame) -> Output:
	var s := settings
	var distances := [frame.thumb_index, frame.thumb_middle, frame.thumb_ring, frame.thumb_pinky, frame.thumb_side]
	var any_in := false
	for contact in CONTACT_COUNT:
		var side := contact == Contact.SIDE
		var press := s.side_press if side else s.pinch_press
		var release := s.side_release if side else s.pinch_release
		# A touch that makes no button is ignored, so it can never click by accident.
		_in[contact] = _button_of(contact) != Click.NONE \
				and distances[contact] < (release if _in[contact] else press)
		if distances[contact] > s.approach:
			_open_time[contact] = frame.time
		any_in = any_in or _in[contact]
	_pose = _is_disc_pose(frame) if frame.scroll_pose < 0 else frame.scroll_pose > 0

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
				_depth = [INF, INF, INF, INF, INF]
				_track_depth(distances)
			elif _pose:
				_state = _State.DISC_PENDING
				_since = frame.time
		_State.PENDING:
			_track_depth(distances)
			if not any_in:
				# Opened again before the window ran out: a quick click.
				_button = _decide()
				_state = _State.TAP
				output.anchor_time = _anchor_time()
			elif frame.time - _since >= s.confirm_delay:
				_button = _decide()
				_state = _State.PRESSED
				output.anchor_time = _anchor_time()
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


func _track_depth(distances: Array) -> void:
	for contact in CONTACT_COUNT:
		if _in[contact]:
			var press := settings.side_press if contact == Contact.SIDE else settings.pinch_press
			_depth[contact] = minf(_depth[contact], distances[contact] / press)


## When the first of the contacts in the window started closing.
func _anchor_time() -> float:
	var earliest := INF
	for contact in CONTACT_COUNT:
		if _depth[contact] < INF:
			earliest = minf(earliest, _open_time[contact])
	return earliest


## The button of the deepest contact in the window.
func _decide() -> Click:
	var best := -1
	for contact in CONTACT_COUNT:
		if _depth[contact] < INF and (best < 0 or _depth[contact] < _depth[best]):
			best = contact
	return _button_of(best) if best >= 0 else Click.NONE


## Which button a contact makes under the current bindings (NONE if it makes none).
func _button_of(contact: int) -> Click:
	if contact == settings.left_contact:
		return Click.LEFT
	if contact == settings.right_contact:
		return Click.RIGHT
	if contact == settings.middle_contact:
		return Click.MIDDLE
	return Click.NONE


func _is_disc_pose(frame: Frame) -> bool:
	var s := settings
	# Looser limits once the pose is on, so that it does not flicker off.
	var slack := 0.1 if _pose else 0.0
	var straight := frame.index_straightness >= s.disc_straightness - slack and frame.middle_straightness >= s.disc_straightness - slack
	var in_line := frame.index_align >= s.disc_align - slack and frame.middle_align >= s.disc_align - slack
	var together := frame.index_middle < s.disc_together + 0.1 * slack
	var thumb_out := frame.thumb_spread >= s.disc_thumb_spread - 0.1 * slack
	var ring_curled := s.disc_ring_curl <= 0.0 or frame.ring_to_palm < s.disc_ring_curl + 0.1 * slack
	return straight and in_line and together and thumb_out and ring_curled


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
