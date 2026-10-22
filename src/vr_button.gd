class_name VrButton
extends Node3D
## Flat button activated by pointing a ray at it and holding press for `hold_time`.
## The hold has to start on the button, so a pinch dragged across it does nothing.

signal activated

const COLOR_IDLE := Color(0.18, 0.2, 0.25)
const COLOR_HOVER := Color(0.28, 0.32, 0.4)
const COLOR_FILL := Color(0.3, 0.75, 0.45)

var size := Vector2(0.28, 0.12)
var hold_time := 0.6
var enabled := true

var _material: StandardMaterial3D
var _fill: MeshInstance3D
var _label: Label3D
var _armed := false
var _latched := false
var _progress := 0.0


func _init(text: String, button_size: Vector2, button_hold_time: float) -> void:
	size = button_size
	hold_time = button_hold_time

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = COLOR_IDLE
	var body_mesh := QuadMesh.new()
	body_mesh.size = size
	var body := MeshInstance3D.new()
	body.mesh = body_mesh
	body.material_override = _material
	add_child(body)

	var fill_material := StandardMaterial3D.new()
	fill_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_material.albedo_color = COLOR_FILL
	var fill_mesh := QuadMesh.new()
	fill_mesh.size = Vector2(size.x, size.y * 0.12)
	_fill = MeshInstance3D.new()
	_fill.mesh = fill_mesh
	_fill.material_override = fill_material
	_fill.visible = false
	add_child(_fill)

	_label = Label3D.new()
	_label.text = text
	_label.pixel_size = 0.001
	_label.font_size = 36
	_label.position = Vector3(0.0, 0.0, 0.002)
	add_child(_label)


func set_text(text: String) -> void:
	_label.text = text


## The text, its font made smaller when it would run past the button's edges.
func set_fitted_text(text: String) -> void:
	_label.text = text
	_label.font_size = clampi(int(size.x * 0.9 / (maxi(text.length(), 1) * 0.00055)), 14, 36)


func hit_distance(origin: Vector3, direction: Vector3) -> float:
	return PointerMath.ray_rect_distance(origin, direction, global_transform, size)


## `just_pressed` must be true only on the frame a hovering pointer started pressing.
func update(hovered: bool, pressed: bool, just_pressed: bool, delta: float) -> void:
	if not enabled:
		hovered = false
	if hovered and just_pressed:
		_armed = true
	if not (hovered and pressed):
		_armed = false
		_latched = false
		_progress = 0.0
	elif _armed and not _latched:
		_progress += delta
		if _progress >= hold_time:
			_latched = true
			activated.emit()

	_material.albedo_color = COLOR_HOVER if hovered else COLOR_IDLE
	_label.modulate = Color.WHITE if enabled else Color(1.0, 1.0, 1.0, 0.35)
	var ratio := clampf(_progress / hold_time, 0.0, 1.0)
	_fill.visible = ratio > 0.0 and not _latched
	_fill.scale = Vector3(maxf(ratio, 0.001), 1.0, 1.0)
	_fill.position = Vector3(-size.x * 0.5 * (1.0 - ratio), -size.y * 0.44, 0.001)
