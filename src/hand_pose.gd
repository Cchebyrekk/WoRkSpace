class_name HandPose
extends RefCounted
## Hand poses as templates: what a held shape of the hand looks like in numbers,
## recorded by the user or built in, and recognised frame by frame. Pure logic (no
## nodes, no engine state), covered by tests/run_tests.gd.
##
## A pose is described by FEATURE_COUNT features of the hand's own shape, so it
## does not matter where the hand is or how it is turned, nor which hand it is:
##   0-4    how straight each finger is (thumb, index, middle, ring, little; 1 = straight)
##   5-9    each fingertip to the palm centre (m)
##   10-14  how far each finger points along the hand (cosine with wrist -> middle
##          knuckle: 1 = in line, 0 = across, below 0 = curled back)
##   15-17  gaps between neighbouring fingertips: index-middle, middle-ring, ring-little (m)
##   18     thumb tip to the index knuckle (m): how far the thumb is out
## A template keeps, per feature, the middle and how far from it still counts
## (`tolerance`); INF there means "any value".
##
## Added 20.10.2026 for gestures the user picks or records in the settings.

const FEATURE_COUNT := 19
const FEATURE_NAMES := [
	"прямота большого", "прямота указательного", "прямота среднего", "прямота безымянного", "прямота мизинца",
	"большой к ладони", "указательный к ладони", "средний к ладони", "безымянный к ладони", "мизинец к ладони",
	"большой вдоль кисти", "указательный вдоль кисти", "средний вдоль кисти", "безымянный вдоль кисти", "мизинец вдоль кисти",
	"промежуток указательный-средний", "промежуток средний-безымянный", "промежуток безымянный-мизинец",
	"большой отведён",
]
## The narrowest tolerance a recording may get, per kind of feature: tracking
## wobbles about this much even when the hand holds still.
## The "along the hand" angle of a curled finger is the least steady of all: a
## ring finger recorded at -0.8 read anywhere from -0.8 to +0.98 in use (20.10.2026).
const MIN_TOLERANCE := [
	0.15, 0.15, 0.15, 0.15, 0.15,
	0.015, 0.015, 0.015, 0.015, 0.015,
	0.4, 0.4, 0.4, 0.4, 0.4,
	0.012, 0.012, 0.012,
	0.015,
]
## One feature may be out by up to this many tolerances and still count: tracking
## misreads one finger now and then while the rest of the hand holds the pose.
const ONE_OUTLIER_LIMIT := 2.0

## Joint indices as in XRHandTracker.HandJoint (OpenXR order), so that the array
## can be filled straight from the tracker.
const PALM := 0
const WRIST := 1
## [first joint, second, third, tip] of each finger: thumb, index, middle, ring, little.
const FINGERS := [[2, 3, 4, 5], [7, 8, 9, 10], [12, 13, 14, 15], [17, 18, 19, 20], [22, 23, 24, 25]]
const MIDDLE_KNUCKLE := 12
const INDEX_KNUCKLE := 7
const JOINT_COUNT := 26


class Template:
	## "pose:move" for built-in ones, "custom:<n>" for recorded ones.
	var id := ""
	var name := ""
	var middle := PackedFloat32Array()
	var tolerance := PackedFloat32Array()
	## Joints for the preview, in the hand's own frame (see HandPose.local_joints).
	var joints := PackedVector3Array()

	func to_dictionary() -> Dictionary:
		return {"id": id, "name": name, "middle": middle, "tolerance": tolerance, "joints": joints}

	static func from_dictionary(data: Dictionary) -> Template:
		var template := Template.new()
		template.id = str(data.get("id", ""))
		template.name = str(data.get("name", ""))
		template.middle = PackedFloat32Array(data.get("middle", PackedFloat32Array()))
		template.tolerance = PackedFloat32Array(data.get("tolerance", PackedFloat32Array()))
		template.joints = PackedVector3Array(data.get("joints", PackedVector3Array()))
		return template

	func is_valid() -> bool:
		return middle.size() == FEATURE_COUNT and tolerance.size() == FEATURE_COUNT

	## Raises every tolerance to at least MIN_TOLERANCE: poses recorded before the
	## minimum went up keep working the new, steadier way.
	func widen_to_minimum() -> void:
		for f in mini(tolerance.size(), FEATURE_COUNT):
			if not is_inf(tolerance[f]):
				tolerance[f] = maxf(tolerance[f], MIN_TOLERANCE[f])


## Recognises one template on one hand: it has to match for `dwell` seconds to
## come on, then holds while within `stay` times its tolerance, and survives a
## loss of match or tracking shorter than `grace` (tracking drops a finger now
## and then, worst when the hand hides it from the cameras).
class Matcher:
	var dwell := 0.12
	var grace := 0.4
	var stay := 1.35

	var on := false
	var _since := NAN
	var _last_match := -INF

	## `features` empty = the hand is not tracked this frame. True while the pose is on.
	func update(template: Template, features: PackedFloat32Array, time: float) -> bool:
		var limit := stay if on else 1.0
		var matches := not features.is_empty() and HandPose.distance(template, features) <= limit
		if matches:
			_last_match = time
			if is_nan(_since):
				_since = time
			if not on and time - _since >= dwell:
				on = true
		else:
			_since = NAN
			if on and time - _last_match > grace:
				on = false
		return on

	func reset() -> void:
		on = false
		_since = NAN
		_last_match = -INF


## The features of a hand from its joints (JOINT_COUNT positions, any one frame of
## reference: only distances and angles between joints are used).
static func features(joints: PackedVector3Array) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	if joints.size() < JOINT_COUNT:
		return result
	result.resize(FEATURE_COUNT)
	var palm := joints[PALM]
	var axis := (joints[MIDDLE_KNUCKLE] - joints[WRIST]).normalized()
	for f in 5:
		var finger: Array = FINGERS[f]
		var a := joints[finger[0]]
		var tip := joints[finger[3]]
		result[f] = HandGestures.straightness(a, joints[finger[1]], joints[finger[2]], tip)
		result[5 + f] = tip.distance_to(palm)
		result[10 + f] = (tip - a).normalized().dot(axis)
	for g in 3:
		result[15 + g] = joints[FINGERS[g + 1][3]].distance_to(joints[FINGERS[g + 2][3]])
	result[18] = joints[FINGERS[0][3]].distance_to(joints[INDEX_KNUCKLE])
	return result


## How far `values` are from the template, each feature in units of its
## tolerance; 1 or less = the pose. The single worst feature is forgiven if it is
## within ONE_OUTLIER_LIMIT (then the second worst counts), so one misread finger
## does not drop a pose the rest of the hand clearly holds.
static func distance(template: Template, values: PackedFloat32Array) -> float:
	if not template.is_valid() or values.size() != FEATURE_COUNT:
		return INF
	var worst := 0.0
	var second := 0.0
	for f in FEATURE_COUNT:
		var tolerance := template.tolerance[f]
		if is_inf(tolerance) or tolerance <= 0.0:
			continue
		var off := absf(values[f] - template.middle[f]) / tolerance
		if off > worst:
			second = worst
			worst = off
		elif off > second:
			second = off
	return second if worst <= ONE_OUTLIER_LIMIT else worst


## Which features are out of the template's range, worst first, as text for the
## log: "указательный к ладони 0.112 (0.042..0.098)". Up to three.
static func describe_miss(template: Template, values: PackedFloat32Array) -> String:
	if not template.is_valid() or values.size() != FEATURE_COUNT:
		return "нет данных"
	var misses := []
	for f in FEATURE_COUNT:
		var tolerance := template.tolerance[f]
		if is_inf(tolerance) or tolerance <= 0.0:
			continue
		var off := absf(values[f] - template.middle[f]) / tolerance
		if off > 1.0:
			misses.append([off, f])
	misses.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var parts: PackedStringArray = []
	for miss: Array in misses.slice(0, 3):
		var f: int = miss[1]
		parts.append("%s %.3f (%.3f..%.3f)" % [FEATURE_NAMES[f], values[f],
				template.middle[f] - template.tolerance[f], template.middle[f] + template.tolerance[f]])
	return ", ".join(parts) if not parts.is_empty() else "в пределах, но меньше выдержки"


## A template from frames recorded while the user held the pose (and moved the
## hand about a little). Each feature gets the middle of what was recorded and a
## tolerance a margin wider than nearly all of it, never narrower than
## MIN_TOLERANCE. Null if fewer than `min_frames` frames.
static func record(samples: Array[PackedFloat32Array], id: String, name: String, joints := PackedVector3Array(),
		min_frames := 40) -> Template:
	if samples.size() < min_frames:
		return null
	var template := Template.new()
	template.id = id
	template.name = name
	template.joints = joints
	template.middle.resize(FEATURE_COUNT)
	template.tolerance.resize(FEATURE_COUNT)
	for f in FEATURE_COUNT:
		var column := PackedFloat32Array()
		for sample in samples:
			if sample.size() == FEATURE_COUNT:
				column.append(sample[f])
		column.sort()
		var low := column[int(column.size() * 0.1)]
		var high := column[int(column.size() * 0.9)]
		template.middle[f] = column[column.size() / 2]
		var half_range := maxf(template.middle[f] - low, high - template.middle[f])
		template.tolerance[f] = maxf(MIN_TOLERANCE[f], half_range * 1.3 + MIN_TOLERANCE[f] * 0.5)
	return template


## Share (0..1) of `samples` that `template` would take for itself: how much a new
## recording looks like a pose already in use.
static func overlap(template: Template, samples: Array[PackedFloat32Array]) -> float:
	if samples.is_empty():
		return 0.0
	var hits := 0
	for sample in samples:
		if distance(template, sample) <= 1.0:
			hits += 1
	return float(hits) / samples.size()


## Joints in the hand's own frame for previews: wrist at the origin, fingers along
## +Y, palm facing +Z, thumb towards +X; a left hand is mirrored so that every
## preview looks like a right hand. `side_sign`: -1 left, +1 right.
static func local_joints(joints: PackedVector3Array, side_sign: float) -> PackedVector3Array:
	var result := PackedVector3Array()
	if joints.size() < JOINT_COUNT:
		return result
	var wrist := joints[WRIST]
	var up := (joints[MIDDLE_KNUCKLE] - wrist).normalized()
	# Towards the thumb side on either hand. A left hand is a mirror image of a
	# right one, which no rotation undoes: its frame is left-handed (the palm on
	# the other side of across x up), and that frame's inverse mirrors it back.
	var across := (joints[INDEX_KNUCKLE] - joints[FINGERS[4][0]]).normalized()
	var facing := across.cross(up).normalized() * side_sign
	across = up.cross(facing).normalized() * side_sign
	var to_local := Basis(across, up, facing).inverse()
	for joint in joints:
		result.append(to_local * (joint - wrist))
	return result


## A hand drawn from simple numbers, for the previews of the built-in gestures:
## `curls` per finger (thumb first, 0 = straight, 1 = fully curled), `thumb_out`
## (0 = along the index, 1 = far out to the side), and an optional point the thumb
## tip reaches for (a touch), in the same frame as local_joints().
static func synthesize(curls: Array[float], thumb_out := 0.6, thumb_target := Vector3(NAN, NAN, NAN)) -> PackedVector3Array:
	var joints := PackedVector3Array()
	joints.resize(JOINT_COUNT)
	joints[WRIST] = Vector3.ZERO
	# Knuckles across the top of the palm (m), thumb side at +X; bone lengths.
	var knuckles := [Vector3(0.026, 0.084, 0.0), Vector3(0.006, 0.09, 0.0), Vector3(-0.014, 0.086, 0.0), Vector3(-0.031, 0.077, 0.0)]
	var bones := [[0.045, 0.026, 0.022], [0.05, 0.03, 0.024], [0.047, 0.029, 0.024], [0.038, 0.022, 0.021]]
	for f in 4:
		var finger: Array = FINGERS[f + 1]
		var at: Vector3 = knuckles[f]
		joints[finger[0] - 1] = at * 0.5  # metacarpal
		joints[finger[0]] = at
		var direction := Vector3(at.x * 0.6, 1.0, 0.0).normalized()
		var bend := clampf(curls[f + 1] if f + 1 < curls.size() else 0.0, 0.0, 1.0) * deg_to_rad(85.0)
		for b in 3:
			# Each joint bends the finger further towards the palm side (+Z).
			direction = direction.rotated(Vector3(1.0, -at.x * 0.6, 0.0).normalized(), bend)
			at += direction * float(bones[f][b])
			joints[finger[b + 1]] = at
	joints[PALM] = Vector3(0.0, 0.045, 0.0)
	# Thumb: from the base of the palm out to the side, then curling across it.
	var base := Vector3(0.02, 0.02, 0.012)
	joints[FINGERS[0][0]] = base
	var out := clampf(thumb_out, 0.0, 1.0)
	var thumb_direction := Vector3(0.55 + 0.35 * out, 0.8 - 0.3 * out, 0.25).normalized()
	var thumb_bend := clampf(curls[0] if not curls.is_empty() else 0.0, 0.0, 1.0) * deg_to_rad(60.0)
	var thumb_lengths := [0.035, 0.03, 0.025]
	var at := base
	for b in 3:
		thumb_direction = thumb_direction.rotated(Vector3(0.3, 0.3, -1.0).normalized(), -thumb_bend)
		at += thumb_direction * float(thumb_lengths[b])
		joints[FINGERS[0][b + 1]] = at
	if not is_nan(thumb_target.x):
		# A touch: the thumb's last joints reach straight for the point.
		var from := joints[FINGERS[0][1]]
		joints[FINGERS[0][2]] = from.lerp(thumb_target, 0.55)
		joints[FINGERS[0][3]] = thumb_target
	return joints
