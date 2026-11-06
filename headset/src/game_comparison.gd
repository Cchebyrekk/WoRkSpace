extends Node3D
## Local controls over the streamed game. Never depends on the game's UI/input.
signal selected(profile: int)

var _buttons: Array[VrButton] = []
var _dots: Array[MeshInstance3D] = []
var _previous: Array[bool] = [false, false]
var _captured: Array[bool] = [false, false]
var _caption: Label3D
var _first_sample := true

func _init() -> void:
	_caption = Label3D.new()
	_caption.position = Vector3(0, 0.085, 0.005)
	_caption.font_size = 30
	_caption.pixel_size = 0.0007
	_caption.no_depth_test = true
	add_child(_caption)
	for i in 2:
		var button := VrButton.new("", Vector2(0.4, 0.09), 0.45)
		button.position = Vector3(-0.22 if i == 0 else 0.22, 0, 0)
		button.activated.connect(_pick.bind(i))
		add_child(button)
		_buttons.append(button)
		var dot := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.006
		sphere.height = 0.012
		dot.mesh = sphere
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(1, 0.8, 0.2)
		dot.material_override = material
		dot.visible = false
		add_child(dot)
		_dots.append(dot)
	set_profile(1)

func set_profile(profile: int) -> void:
	var titles := ["Как изначально", "Тест q4"]
	for i in 2:
		_buttons[i].set_fitted_text(("» %s «" if i == profile else "%s") % titles[i])
	_caption.text = "Сравнение: %s · щипок / триггер с удержанием" % titles[clampi(profile, 0, 1)]

func _pick(profile: int) -> void:
	_caption.text = "Переключаю…"
	selected.emit(profile)

func update_inputs(aims: Array, down: Array[bool], delta: float) -> Array[bool]:
	if _first_sample:
		_previous = down.duplicate()
		_first_sample = false
	var hovered: Array[bool] = [false, false]
	var pressed: Array[bool] = [false, false]
	var just_pressed: Array[bool] = [false, false]
	for h in 2:
		if not down[h]:
			_captured[h] = false
		_dots[h].visible = false
		if aims[h] is Transform3D:
			var ray: Transform3D = aims[h]
			var direction := -ray.basis.z
			var best := -1
			var distance := INF
			for i in 2:
				var hit := _buttons[i].hit_distance(ray.origin, direction)
				if hit >= 0 and hit < distance:
					distance = hit
					best = i
			if best >= 0:
				var began := down[h] and not _previous[h]
				if began:
					_captured[h] = true
				hovered[best] = true
				pressed[best] = pressed[best] or down[h]
				just_pressed[best] = just_pressed[best] or began
				_dots[h].global_position = ray.origin + direction * distance + global_basis.z * 0.005
				_dots[h].visible = true
		_previous[h] = down[h]
	for i in 2:
		_buttons[i].update(hovered[i], pressed[i], just_pressed[i], delta)
	return _captured.duplicate()
