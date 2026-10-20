class_name VrSlider
extends Node3D
## A slider for the settings panel: a bar with notches and a knob. Pinching (or
## the trigger) on it and moving the ray sets the value; near a notch the value
## sticks to it, between notches it goes by the setting's step. The − / +
## buttons beside it stay for fine steps (the user's wish, 20.10.2026). The value
## maths is static and covered by tests/run_tests.gd.

const BAR_HEIGHT := 0.008
const HIT_HEIGHT := 0.05
const KNOB_SIZE := Vector2(0.014, 0.034)
const NOTCH_SIZE := Vector2(0.002, 0.016)
## Within this share of the range of a notch, the value sticks to it.
const NOTCH_SNAP_SHARE := 0.03
const MAX_NOTCHES := 10

var width := 0.22
## Which settings row it belongs to (main.gd's TUNABLES index).
var tunable := -1
var minimum := 0.0
var maximum := 1.0
var step := 0.1
var notches := PackedFloat32Array()

var _knob: MeshInstance3D
var _knob_material: StandardMaterial3D
var _notch_root: Node3D


func _init(slider_width := 0.22) -> void:
	width = slider_width
	var bar := _quad(Vector2(width, BAR_HEIGHT), Color(0.45, 0.5, 0.6))
	add_child(bar)
	_notch_root = Node3D.new()
	add_child(_notch_root)
	_knob = _quad(KNOB_SIZE, Color.WHITE)
	_knob_material = _knob.material_override as StandardMaterial3D
	_knob_material.albedo_color = VrButton.COLOR_HOVER
	_knob.position.z = 0.002
	add_child(_knob)


func set_range(low: float, high: float, value_step: float) -> void:
	minimum = low
	maximum = high
	step = value_step
	notches = VrSlider.notches_for(low, high, value_step)
	for child in _notch_root.get_children():
		child.queue_free()
	for notch in notches:
		var mark := _quad(NOTCH_SIZE, Color(0.75, 0.8, 0.9))
		mark.position = Vector3(_x_of(notch), 0.0, 0.001)
		_notch_root.add_child(mark)


func set_value(value: float) -> void:
	_knob.position.x = _x_of(value)


func set_active(active: bool, hovered: bool) -> void:
	_knob_material.albedo_color = VrButton.COLOR_FILL if active else (Color.WHITE if hovered else VrButton.COLOR_HOVER)


func hit_distance(origin: Vector3, direction: Vector3) -> float:
	return PointerMath.ray_rect_distance(origin, direction, global_transform, Vector2(width + 0.03, HIT_HEIGHT))


## The value where the ray crosses the slider's plane (NAN if it does not).
func value_from_ray(origin: Vector3, direction: Vector3) -> float:
	var normal := global_transform.basis.z.normalized()
	var denominator := direction.dot(normal)
	if absf(denominator) < 0.0001:
		return NAN
	var along := (global_position - origin).dot(normal) / denominator
	var local := global_transform.affine_inverse() * (origin + direction * along)
	return VrSlider.value_at(local.x / width + 0.5, minimum, maximum, step, notches)


func _x_of(value: float) -> float:
	var share := (value - minimum) / (maximum - minimum) if maximum > minimum else 0.0
	return (clampf(share, 0.0, 1.0) - 0.5) * width


func _quad(size: Vector2, color: Color) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	return instance


## Notches at round multiples of the step, at most MAX_NOTCHES gaps between them,
## always including both ends.
static func notches_for(low: float, high: float, value_step: float) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	if high <= low or value_step <= 0.0:
		return result
	var steps := roundi((high - low) / value_step)
	var every := maxi(1, ceili(float(steps) / MAX_NOTCHES))
	for k in range(0, steps + 1, every):
		result.append(low + k * value_step)
	if not is_equal_approx(result[result.size() - 1], high):
		result.append(high)
	return result


## The value at `share` (0 = left end, 1 = right end): sticks to a notch within
## NOTCH_SNAP_SHARE of the range, else goes by `value_step`, kept within the range.
static func value_at(share: float, low: float, high: float, value_step: float, marks: PackedFloat32Array) -> float:
	var raw := low + clampf(share, 0.0, 1.0) * (high - low)
	for notch in marks:
		if absf(raw - notch) <= NOTCH_SNAP_SHARE * (high - low):
			return notch
	if value_step > 0.0:
		raw = low + snappedf(raw - low, value_step)
	return clampf(raw, low, high)
