class_name HandPreview
extends Node3D
## A small hand drawn from joints (HandPose.local_joints frame: wrist at the
## origin, fingers up, palm towards +Z = towards the viewer), for telling the
## gestures apart in the settings: joints as dots, bones as thin sticks, the
## fingertips in a warmer colour. Two MultiMeshes, so it costs two draws however
## many joints.

## How tall the preview stands (metres); a real hand is about 0.19 m.
var height := 0.07

var _dots: MultiMeshInstance3D
var _sticks: MultiMeshInstance3D

const BONES := [
	[1, 2], [2, 3], [3, 4], [4, 5],
	[1, 6], [6, 7], [7, 8], [8, 9], [9, 10],
	[1, 11], [11, 12], [12, 13], [13, 14], [14, 15],
	[1, 16], [16, 17], [17, 18], [18, 19], [19, 20],
	[1, 21], [21, 22], [22, 23], [23, 24], [24, 25],
	[7, 12], [12, 17], [17, 22],
]
const TIPS := [5, 10, 15, 20, 25]


func _init(preview_height := 0.07) -> void:
	height = preview_height
	_dots = _layer(_sphere())
	_sticks = _layer(_stick())


## Draws the hand; an empty array hides it (e.g. "Выключено").
func set_joints(joints: PackedVector3Array) -> void:
	visible = joints.size() >= HandPose.JOINT_COUNT
	if not visible:
		return
	var scale_factor := height / 0.19
	# Centred on the hand rather than on the wrist.
	var centre := Vector3.ZERO
	for j in range(1, HandPose.JOINT_COUNT):
		centre += joints[j]
	centre /= HandPose.JOINT_COUNT - 1
	var dots := _dots.multimesh
	dots.instance_count = HandPose.JOINT_COUNT - 1
	for j in range(1, HandPose.JOINT_COUNT):
		var size := 0.012 if j in TIPS else 0.009
		dots.set_instance_transform(j - 1, Transform3D(Basis.from_scale(Vector3.ONE * size * scale_factor),
				(joints[j] - centre) * scale_factor))
		dots.set_instance_color(j - 1, Color(1.0, 0.75, 0.3) if j in TIPS else Color(0.9, 0.95, 1.0))
	var sticks := _sticks.multimesh
	sticks.instance_count = BONES.size()
	for b in BONES.size():
		var a := (joints[BONES[b][0]] - centre) * scale_factor
		var c := (joints[BONES[b][1]] - centre) * scale_factor
		var along := c - a
		var length := along.length()
		var basis := Basis.from_scale(Vector3.ZERO)
		if length > 0.00001:
			var y := along / length
			var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
			basis = Basis(x, y, x.cross(y)).scaled_local(Vector3(0.004 * scale_factor, length, 0.004 * scale_factor))
		sticks.set_instance_transform(b, Transform3D(basis, (a + c) * 0.5))
		sticks.set_instance_color(b, Color(0.55, 0.68, 0.85))


func _layer(mesh: Mesh) -> MultiMeshInstance3D:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	instance.material_override = material
	add_child(instance)
	return instance


func _sphere() -> Mesh:
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 8
	mesh.rings = 4
	return mesh


func _stick() -> Mesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	return mesh
