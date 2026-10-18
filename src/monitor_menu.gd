class_name MonitorMenu
extends Node3D
## A small floating menu for one monitor: resolution, refresh rate and Windows
## scale, each stepped with < >, and "Применить" to send them to Windows at once.
## It floats in front of the lower part of the monitor's panel; while a ray is on
## it the panel behind does not get clicks (main.gd asks hit_distance()).

signal apply_requested(monitor_name: String, mode: String, scale: int)
signal close_requested

const SIZE := Vector2(0.64, 0.38)
const ROW_HEIGHT := 0.075
const STEP_BUTTON := Vector2(0.07, 0.06)
const BACKGROUND := Color(0.06, 0.07, 0.1, 0.92)
## Rows: what is changed.
const ROWS := ["Разрешение", "Частота", "Масштаб"]

var monitor_name := ""
## The menu's buttons; main.gd drives them like its other VR buttons.
var buttons: Array[VrButton] = []

var _title: Label3D
var _values: Array[Label3D] = []
var _note: Label3D
var _apply: VrButton
var _loaded := false
## "WxH" -> refresh rates offered at that size, in order.
var _rates := {}
var _sizes: Array[String] = []
var _scales: Array[int] = []
var _current_size := ""
var _current_rate := 0
var _current_scale := 0
var _size := ""
var _rate := 0
var _scale := 0


func _init() -> void:
	var background := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = SIZE
	background.mesh = quad
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = BACKGROUND
	# Drawn before the labels: transparent things are otherwise sorted by distance,
	# and the background was drawn over the text, which looked dimmed.
	material.render_priority = -1
	background.material_override = material
	background.position = Vector3(0.0, 0.0, -0.003)
	add_child(background)

	var top := SIZE.y * 0.5 - 0.04
	_title = _label("", Vector3(0.0, top, 0.0), 26)
	for row in ROWS.size():
		var y := top - 0.065 - row * ROW_HEIGHT
		var name_label := _label(ROWS[row], Vector3(-0.29, y, 0.0), 26)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_add_button("<", Vector3(-0.02, y, 0.0), STEP_BUTTON, 0.2).activated.connect(_step.bind(row, -1))
		_values.append(_label("", Vector3(0.12, y, 0.0), 26))
		_add_button(">", Vector3(0.26, y, 0.0), STEP_BUTTON, 0.2).activated.connect(_step.bind(row, 1))
	var bottom := -SIZE.y * 0.5 + 0.045
	_apply = _add_button("Применить", Vector3(-0.13, bottom, 0.0), Vector2(0.26, 0.065), 1.0)
	_apply.activated.connect(_on_apply)
	_add_button("Закрыть", Vector3(0.17, bottom, 0.0), Vector2(0.22, 0.065), 0.3).activated.connect(func() -> void: close_requested.emit())
	_note = _label("", Vector3(0.0, bottom + 0.06, 0.0), 22)


## While the monitor's modes are being read.
func show_loading(name_of_monitor: String) -> void:
	monitor_name = name_of_monitor
	_loaded = false
	_title.text = "%s: читаю режимы…" % _short(monitor_name)
	for value in _values:
		value.text = ""
	_note.text = ""
	_refresh()


## `entry` is this monitor's dictionary from DisplayTopology.modes_listed.
func set_modes(entry: Dictionary) -> void:
	_rates.clear()
	_sizes.clear()
	for mode: String in entry.get("modes", []):
		var parts := mode.split("@")
		if parts.size() != 2:
			continue
		if not _rates.has(parts[0]):
			_rates[parts[0]] = [] as Array[int]
			_sizes.append(parts[0])
		(_rates[parts[0]] as Array[int]).append(parts[1].to_int())
	_sizes.sort_custom(func(a: String, b: String) -> bool: return _pixels(a) < _pixels(b))
	for size: String in _sizes:
		(_rates[size] as Array[int]).sort()
	_scales.assign(entry.get("scales", []))
	_current_size = "%dx%d" % [int(entry.get("width", 0)), int(entry.get("height", 0))]
	_current_rate = int(entry.get("refresh", 0))
	_current_scale = int(entry.get("scale", 0))
	_size = _current_size
	_rate = _current_rate
	_scale = _current_scale
	_loaded = _sizes.has(_size)
	_title.text = "%s: сейчас %s, %d Гц, %d %%" % [_short(monitor_name), _current_size.replace("x", "×"),
			_current_rate, _current_scale]
	_refresh()


## Distance along the ray to the menu's background, or -1.0 on a miss.
func hit_distance(origin: Vector3, direction: Vector3) -> float:
	if not visible:
		return -1.0
	return PointerMath.ray_rect_distance(origin, direction, global_transform if is_inside_tree() else transform, SIZE)


func _step(row: int, direction: int) -> void:
	if not _loaded:
		return
	match row:
		0:
			var at := clampi(_sizes.find(_size) + direction, 0, _sizes.size() - 1)
			_size = _sizes[at]
			# Keep the refresh rate if the new size offers it, else the nearest one.
			var rates: Array[int] = _rates[_size]
			if not rates.has(_rate):
				var nearest := rates[0]
				for rate in rates:
					if absi(rate - _rate) < absi(nearest - _rate):
						nearest = rate
				_rate = nearest
		1:
			var rates: Array[int] = _rates[_size]
			_rate = rates[clampi(rates.find(_rate) + direction, 0, rates.size() - 1)]
		2:
			if not _scales.is_empty():
				_scale = _scales[clampi(_scales.find(_scale) + direction, 0, _scales.size() - 1)]
	_refresh()


func _refresh() -> void:
	if not _loaded:
		_apply.enabled = false
		return
	var changed_scale := _scale != _current_scale
	_values[0].text = _size.replace("x", "×") + (" *" if _size != _current_size else "")
	_values[1].text = "%d Гц%s" % [_rate, " *" if _rate != _current_rate else ""]
	_values[2].text = "%d %%%s" % [_scale, " *" if changed_scale else ""]
	_apply.enabled = _size != _current_size or _rate != _current_rate or changed_scale
	_note.text = "* — изменится после «Применить»" if _apply.enabled else ""


func _on_apply() -> void:
	var mode := "%s@%d" % [_size, _rate] if _size != _current_size or _rate != _current_rate else ""
	apply_requested.emit(monitor_name, mode, _scale if _scale != _current_scale else 0)
	_title.text = "%s: применяю…" % _short(monitor_name)
	_loaded = false
	_apply.enabled = false


func _label(text: String, at: Vector3, font_size: int) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.position = at + Vector3(0.0, 0.0, 0.002)
	label.pixel_size = 0.001
	label.font_size = font_size
	label.outline_size = 6
	label.render_priority = 2
	label.outline_render_priority = 1
	add_child(label)
	return label


func _add_button(text: String, at: Vector3, size: Vector2, hold: float) -> VrButton:
	var button := VrButton.new(text, size, hold)
	button.position = at
	add_child(button)
	buttons.append(button)
	return button


static func _short(name_of_monitor: String) -> String:
	return name_of_monitor.trim_prefix("\\\\.\\")


static func _pixels(size: String) -> int:
	var parts := size.split("x")
	return parts[0].to_int() * parts[1].to_int() if parts.size() == 2 else 0
