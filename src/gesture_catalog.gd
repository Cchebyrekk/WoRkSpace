class_name GestureCatalog
extends RefCounted
## Which gesture does what: the actions the user can bind, the gestures there are
## to choose from (built-in touches and poses, plus the poses the user recorded),
## and the rules for binding them. Pure logic, covered by tests/run_tests.gd.
##
## Clicks take touches only (thumb to a fingertip or to the side of the index):
## they keep the exact timing of HandGestures. Held actions take poses, built in
## or recorded (HandPose). Every action can be switched off. Decided with the
## user on 20.10.2026.

const OFF := "off"
const OFF_NAME := "Выключено"

## [key, label, kind]: kind "touch" or "pose".
const ACTIONS := [
	["left", "Левая кнопка", "touch"],
	["right", "Правая кнопка", "touch"],
	["middle", "Средняя кнопка", "touch"],
	["scroll", "Прокрутка", "pose"],
	["grab", "Перенос панели рукой", "pose"],
	["move", "Движение", "pose"],
	["turn", "Поворот", "pose"],
]

## Touches: id -> [name, contact (HandGestures contact index)].
const TOUCHES := {
	"touch:index": ["Большой к указательному", 0],
	"touch:middle": ["Большой к среднему", 1],
	"touch:ring": ["Большой к безымянному", 2],
	"touch:pinky": ["Большой к мизинцу", 3],
	"touch:side": ["Большой к боку указательного", 4],
}
## Built-in poses: id -> name. The first two keep their own tuned recognisers in
## HandGestures / main.gd; "pose:move" is a template (move_template()).
const POSES := {
	"pose:scroll": "Поза прокрутки",
	"pose:fist": "Кулак",
	"pose:move": "Знак движения",
}

const DEFAULTS := {
	"left": "touch:index", "right": "touch:middle", "middle": "touch:side",
	"scroll": "pose:scroll", "grab": "pose:fist", "move": "pose:move", "turn": "pose:move",
}


static func kind_of(action: String) -> String:
	for entry: Array in ACTIONS:
		if entry[0] == action:
			return entry[2]
	return ""


static func label_of(action: String) -> String:
	for entry: Array in ACTIONS:
		if entry[0] == action:
			return entry[1]
	return action


## What can be chosen for `action`: [[id, name], ...], "Выключено" last.
static func options(action: String, customs: Array[HandPose.Template]) -> Array:
	var result := []
	if kind_of(action) == "touch":
		for id: String in TOUCHES:
			result.append([id, TOUCHES[id][0]])
	else:
		for id: String in POSES:
			result.append([id, POSES[id]])
		for template in customs:
			result.append([template.id, template.name])
	result.append([OFF, OFF_NAME])
	return result


static func name_of(id: String, customs: Array[HandPose.Template]) -> String:
	if id == OFF:
		return OFF_NAME
	if TOUCHES.has(id):
		return TOUCHES[id][0]
	if POSES.has(id):
		return POSES[id]
	var template := find(id, customs)
	return template.name if template != null else id


static func find(id: String, customs: Array[HandPose.Template]) -> HandPose.Template:
	for template in customs:
		if template.id == id:
			return template
	return null


## HandGestures contact index of a touch id, or -1 (off or not a touch).
static func contact_of(id: String) -> int:
	return int(TOUCHES[id][1]) if TOUCHES.has(id) else -1


## Binds `gesture` to `action` and returns the new bindings. One touch makes one
## button only: if another button had it, that button gets the touch this one
## gave up (a swap), so no click is lost by accident. Poses may be shared, e.g.
## the same sign for moving (one hand) and turning (the other).
static func assign(bindings: Dictionary, action: String, gesture: String) -> Dictionary:
	var result := bindings.duplicate()
	var previous: String = result.get(action, OFF)
	if kind_of(action) == "touch" and gesture != OFF:
		for entry: Array in ACTIONS:
			var other: String = entry[0]
			if other != action and entry[2] == "touch" and result.get(other, OFF) == gesture:
				result[other] = previous
	result[action] = gesture
	return result


## Every action bound to something that exists: missing actions get their
## default, gestures that are gone (a deleted recording, a touch on a pose action)
## become "off".
static func sanitize(bindings: Dictionary, customs: Array[HandPose.Template]) -> Dictionary:
	var result := {}
	for entry: Array in ACTIONS:
		var action: String = entry[0]
		var id: String = str(bindings.get(action, DEFAULTS[action]))
		var fits := id == OFF
		if entry[2] == "touch":
			fits = fits or TOUCHES.has(id)
		else:
			fits = fits or POSES.has(id) or find(id, customs) != null
		result[action] = id if fits else OFF
	return result


## The built-in locomotion sign the user showed on 20.10.2026 (both hands, ~270
## frames): an open hand with the index bent forward towards the palm and held
## apart from the middle finger, the thumb out. Tolerances are wide on the index,
## whose bend the tracking reads unsteadily (0.45-0.87) with the palm turned away.
static func move_template() -> HandPose.Template:
	var template := HandPose.Template.new()
	template.id = "pose:move"
	template.name = POSES["pose:move"]
	template.middle = PackedFloat32Array([
		0.97, 0.62, 1.0, 1.0, 0.98,
		0.092, 0.07, 0.119, 0.112, 0.098,
		0.7, 0.28, 0.95, 0.95, 0.93,
		0.09, 0.02, 0.036,
		0.0,
		0.0, 0.0,
	])
	template.tolerance = PackedFloat32Array([
		0.15, 0.25, 0.12, 0.12, 0.14,
		0.035, 0.028, 0.022, 0.022, 0.025,
		INF, 0.3, 0.2, 0.2, 0.2,
		0.028, 0.016, 0.022,
		INF,
		INF, INF,
	])
	template.joints = preview_joints("pose:move", [])
	return template


## The built-in scroll pose as a template, from the same thresholds HandGestures
## uses, so that it can compete with recorded poses: when a hand fits both, the
## nearer one wins (20.10.2026).
static func scroll_template(s: HandGestures.Settings) -> HandPose.Template:
	var ranges := {
		1: [s.disc_straightness, 1.05], 2: [s.disc_straightness, 1.05],
		11: [s.disc_align, 1.05], 12: [s.disc_align, 1.05],
		15: [0.0, s.disc_together],
		18: [s.disc_thumb_spread, s.disc_thumb_spread + 0.08],
	}
	if s.disc_ring_curl > 0.0:
		ranges[8] = [0.0, s.disc_ring_curl]
	return HandPose.box_template("pose:scroll", POSES["pose:scroll"], ranges)


## Joints of the preview hand (HandPose.local_joints frame) for any gesture.
static func preview_joints(id: String, customs: Array[HandPose.Template]) -> PackedVector3Array:
	var curls: Array[float] = []
	match id:
		"pose:scroll":
			curls = [0.1, 0.0, 0.0, 0.9, 0.9]
			return HandPose.synthesize(curls, 0.95)
		"pose:fist":
			curls = [0.7, 1.0, 1.0, 1.0, 1.0]
			return HandPose.synthesize(curls, 0.1)
		"pose:move":
			curls = [0.1, 0.55, 0.0, 0.0, 0.0]
			return HandPose.synthesize(curls, 0.9)
		OFF:
			return PackedVector3Array()
	if TOUCHES.has(id):
		var contact := contact_of(id)
		curls = [0.3, 0.0, 0.0, 0.0, 0.0]
		var target := Vector3.ZERO
		if contact < 4:
			# The touching finger curls a little to meet the thumb tip.
			curls[contact + 1] = 0.45
			target = HandPose.synthesize(curls, 0.5)[HandPose.FINGERS[contact + 1][3]]
		else:
			# The side of the index: between its knuckle and middle joint, a little to the palm side.
			var open := HandPose.synthesize(curls, 0.5)
			target = open[HandPose.FINGERS[1][0]].lerp(open[HandPose.FINGERS[1][1]], 0.5) + Vector3(0.008, 0.0, 0.008)
		return HandPose.synthesize(curls, 0.5, target)
	var template := find(id, customs)
	return template.joints if template != null else PackedVector3Array()
