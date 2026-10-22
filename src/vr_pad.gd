class_name VrPad
extends Node3D
## Two values on one plane (the user's wish, 22.10.2026: rather than two sliders
## one above the other): the ray's point on it sets both — across the first,
## up the second. Marks on both axes, a knob where the values are. Snapping per
## axis as on a slider (VrSlider.value_at). The value maths is static and covered
## by tests/run_tests.gd.

const KNOB_SIZE := Vector2(0.03, 0.03)
const LINE := 0.002
const MARGIN := 0.03

var size := Vector2(0.5, 0.32)
var low := Vector2.ZERO
var high := Vector2.ONE
var step := Vector2.ZERO
var notches_x := PackedFloat32Array()
var notches_y := PackedFloat32Array()

var _knob: MeshInstance3D
var _marks: Node3D


func _init(pad_size := Vector2(0.5, 0.32)) -> void:
	size = pad_size
	var plate := _quad(size, Color(0.12, 0.13, 0.17, 0.85))
	(plate.material_override as StandardMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	add_child(plate)
	_marks = Node3D.new()
	add_child(_marks)
	_knob = _quad(KNOB_SIZE, VrButton.COLOR_FILL)
	_knob.position.z = 0.003
	add_child(_knob)


## Ranges of both axes and the steps of their marks (`value_step` 0 = no snapping
## between marks).
func set_ranges(from: Vector2, to: Vector2, marks: Vector2, value_step: Vector2) -> void:
	low = from
	high = to
	step = value_step
	notches_x = VrSlider.notches_for(from.x, to.x, marks.x)
	notches_y = VrSlider.notches_for(from.y, to.y, marks.y)
	for child in _marks.get_children():
		child.queue_free()
	for notch in notches_x:
		var line := _quad(Vector2(LINE, size.y), Color(0.45, 0.5, 0.6))
		line.position = Vector3(_at(Vector2(notch, low.y)).x, 0.0, 0.001)
		_marks.add_child(line)
	for notch in notches_y:
		var line := _quad(Vector2(size.x, LINE), Color(0.45, 0.5, 0.6))
		line.position = Vector3(0.0, _at(Vector2(low.x, notch)).y, 0.001)
		_marks.add_child(line)


func set_value(value: Vector2) -> void:
	var at := _at(value)
	_knob.position = Vector3(at.x, at.y, 0.003)


func hit_distance(origin: Vector3, direction: Vector3) -> float:
	return PointerMath.ray_rect_distance(origin, direction, global_transform, size + Vector2(MARGIN, MARGIN) * 2.0)


## Both values where the ray crosses the pad's plane (NAN if it does not).
func values_from_ray(origin: Vector3, direction: Vector3) -> Vector2:
	var normal := global_transform.basis.z.normalized()
	var denominator := direction.dot(normal)
	if absf(denominator) < 0.0001:
		return Vector2(NAN, NAN)
	var along := (global_position - origin).dot(normal) / denominator
	var local := global_transform.affine_inverse() * (origin + direction * along)
	return VrPad.values_at(Vector2(local.x / size.x + 0.5, local.y / size.y + 0.5), low, high, step, notches_x, notches_y)


## The values at `share` (0..1 across, 0..1 up), each as on a slider.
static func values_at(share: Vector2, from: Vector2, to: Vector2, value_step: Vector2,
		marks_x: PackedFloat32Array, marks_y: PackedFloat32Array) -> Vector2:
	return Vector2(VrSlider.value_at(share.x, from.x, to.x, value_step.x, marks_x),
			VrSlider.value_at(share.y, from.y, to.y, value_step.y, marks_y))


func _at(value: Vector2) -> Vector2:
	var share := Vector2((value.x - low.x) / (high.x - low.x) if high.x > low.x else 0.0,
			(value.y - low.y) / (high.y - low.y) if high.y > low.y else 0.0)
	return (share.clamp(Vector2.ZERO, Vector2.ONE) - Vector2(0.5, 0.5)) * size


func _quad(quad_size: Vector2, color: Color) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = quad_size
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	return instance
