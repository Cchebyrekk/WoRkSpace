class_name MenuEditor
extends Node3D
## The "Меню" settings tab: bins of functions for the radial menu. On the left
## "Все функции" (built in and recorded), on the right a bin per category (up to
## MenuSet.MAX_CATEGORIES, each up to MenuSet.MAX_ITEMS), below "Удалить". A pinch
## (or trigger) on a function picks it up, the ray carries it, letting go over a
## bin moves it there: a function is in one place, "Все" shows those in no
## category; dropped on "Удалить" an own function is deleted (a built-in one goes
## back to "Все").
## "Записать функцию" takes the next shortcut pressed on the physical keyboard.
## The user's design, 20.10.2026. Emits `changed` after every change (main.gd saves).

signal changed

const CHIP := Vector2(0.22, 0.042)
const LIBRARY_COLUMNS := 2
const LIBRARY_ROWS := 15
const LIBRARY := Rect2(-0.97, -0.42, 0.5, 0.84)
const TRASH := Rect2(-0.97, -0.56, 0.5, 0.11)
const BIN_SIZE := Vector2(0.44, 0.44)
const BIN_ORIGIN := Vector2(-0.45, 0.42)
const RECORD_TIMEOUT_SEC := 6.0

var menus: Array = []
## 0 = by finger, 1 = two levels (MenuSet.MODE_*).
var mode := MenuSet.MODE_TWO_LEVEL

var _mode_button: VrButton
var _status: Label3D
var _delete_buttons: Array[VrButton] = []
var _bin_titles: Array[Label3D] = []
var _bin_frames: Array[MeshInstance3D] = []
var _library_chips: Array[Node3D] = []
var _category_chips: Array = []
var _ghost: Node3D
## Dragging: [pointer, from ("library" or category index), id], or empty.
var _drag: Array = []
var _recording_until := -1.0


func build(add_button: Callable) -> void:
	_mode_button = add_button.call(self, "", Vector3(-0.55, 0.53, 0.0), Vector2(0.55, 0.06), 0.25)
	_mode_button.activated.connect(_toggle_mode)
	(add_button.call(self, "+ Категория", Vector3(0.0, 0.53, 0.0), Vector2(0.28, 0.06), 0.4) as VrButton).activated.connect(_add_category)
	(add_button.call(self, "Записать функцию", Vector3(0.42, 0.53, 0.0), Vector2(0.4, 0.06), 0.4) as VrButton).activated.connect(_start_recording)
	_status = _label("Тащите функции щипком между корзинами; внутри корзины — меняет порядок", Vector3(0.0, 0.47, 0.0), 20)
	_frame(LIBRARY, Color(0.13, 0.15, 0.19))
	_label("Все функции", Vector3(LIBRARY.get_center().x, LIBRARY.end.y - 0.025, 0.0), 22)
	_frame(TRASH, Color(0.3, 0.12, 0.12))
	_label("Удалить", Vector3(TRASH.get_center().x, TRASH.get_center().y, 0.0), 22)
	for k in LIBRARY_COLUMNS * LIBRARY_ROWS:
		var chip := _chip()
		chip.position = Vector3(LIBRARY.position.x + 0.13 + (k % LIBRARY_COLUMNS) * 0.245, LIBRARY.end.y - 0.075 - (k / LIBRARY_COLUMNS) * 0.05, 0.004)
		_library_chips.append(chip)
	for c in MenuSet.MAX_CATEGORIES:
		var bin := _bin_rect(c)
		_bin_frames.append(_frame(bin, Color(0.15, 0.17, 0.22)))
		_bin_titles.append(_label("", Vector3(bin.get_center().x - 0.04, bin.end.y - 0.025, 0.0), 22))
		var delete: VrButton = add_button.call(self, "×", Vector3(bin.end.x - 0.03, bin.end.y - 0.025, 0.0), Vector2(0.045, 0.04), 1.0)
		delete.activated.connect(_delete_category.bind(c))
		_delete_buttons.append(delete)
		var chips: Array[Node3D] = []
		for k in MenuSet.MAX_ITEMS:
			var chip := _chip()
			chip.position = Vector3(bin.get_center().x, bin.end.y - 0.075 - k * 0.045, 0.004)
			chips.append(chip)
		_category_chips.append(chips)
	_ghost = _chip()
	_ghost.visible = false
	refresh()


func refresh() -> void:
	if _mode_button == null:
		return
	_mode_button.set_text("Круговое меню: %s" % ("два уровня" if mode == MenuSet.MODE_TWO_LEVEL else "по пальцу"))
	# The common bin holds what no category has (the user's wish, 20.10.2026: a
	# function lives in one place; moving it out of a category puts it back here).
	var placed := {}
	for menu: Dictionary in menus:
		for id: String in MenuSet.items_of(menu):
			placed[id] = true
	var ids := MenuSet.all_ids().filter(func(id: String) -> bool: return not placed.has(id))
	for k in _library_chips.size():
		_show_chip(_library_chips[k], ids[k] if k < ids.size() else "")
	for c in MenuSet.MAX_CATEGORIES:
		var used := c < menus.size()
		_bin_frames[c].visible = used
		_bin_titles[c].visible = used
		_delete_buttons[c].visible = used and menus.size() > 1
		_bin_titles[c].text = (menus[c]["name"] + (" (%s)" % ["средний", "безымянный", "мизинец"][c] if c < 3 and mode == MenuSet.MODE_FINGER else "")) if used else ""
		var items := MenuSet.items_of(menus[c]) if used else PackedStringArray()
		for k in MenuSet.MAX_ITEMS:
			_show_chip(_category_chips[c][k], items[k] if used and k < items.size() else "")


## Every frame: recording, and carrying functions between bins. `pointers` are
## main.gd's pointers (origin, direction, active, pressed, just_pressed, hit_distance).
func update(pointers: Array) -> void:
	_update_recording()
	if not is_visible_in_tree():
		_drag.clear()
		_ghost.visible = false
		return
	if _drag.is_empty():
		for pointer: Variant in pointers:
			if not pointer.active:
				continue
			var at := _plane_point(pointer.origin, pointer.direction)
			if is_nan(at.x):
				continue
			var picked := _pick(at)
			if picked.is_empty():
				continue
			pointer.hit_distance = minf(pointer.hit_distance, pointer.origin.distance_to(global_transform * Vector3(at.x, at.y, 0.0)))
			if pointer.just_pressed:
				_drag = [pointer, picked[0], picked[1]]
				_show_chip(_ghost, picked[1])
				break
		return
	var carrier: Variant = _drag[0]
	var point := _plane_point(carrier.origin, carrier.direction)
	if not is_nan(point.x):
		_ghost.visible = true
		_ghost.position = Vector3(point.x, point.y, 0.012)
		carrier.hit_distance = minf(carrier.hit_distance, carrier.origin.distance_to(global_transform * Vector3(point.x, point.y, 0.0)))
	if carrier.active and carrier.pressed:
		return
	var from: Variant = _drag[1]
	var id: String = _drag[2]
	_drag.clear()
	_ghost.visible = false
	if not is_nan(point.x):
		_drop(from, id, point)


func _drop(from: Variant, id: String, point: Vector2) -> void:
	var label: String = MenuSet.action(id)[0]
	if TRASH.has_point(point):
		if MenuSet.custom.has(id):
			MenuSet.custom.erase(id)
			for menu: Dictionary in menus:
				menu["items"] = (menu["items"] as Array).filter(func(item: String) -> bool: return item != id)
			_status.text = "Функция «%s» удалена" % label
		elif from is int:
			_remove(from, id)
			_status.text = "Готовые не удаляются: «%s» вернулась во «Все функции»" % label
		else:
			_status.text = "Готовые функции не удаляются — только свои"
			return
		_changed()
		return
	if LIBRARY.has_point(point):
		if from is int:
			_remove(from, id)
			_status.text = "«%s» убрана из «%s» и лежит во «Всех функциях»" % [label, menus[from]["name"]]
			_changed()
		return
	for c in menus.size():
		if not _bin_rect(c).has_point(point):
			continue
		var items: Array = (menus[c]["items"] as Array).filter(func(item: String) -> bool: return MenuSet.has_action(item))
		# The place it was dropped on: the order in the bin is the order on the ring.
		var place := clampi(int(round((_bin_rect(c).end.y - 0.075 - point.y) / 0.045)), 0, MenuSet.MAX_ITEMS - 1)
		if from is int and from == c:
			var reordered := MenuSet.moved(items, id, place)
			if reordered != items:
				menus[c]["items"] = reordered
				_status.text = "«%s» — %d-я в «%s»" % [label, reordered.find(id) + 1, menus[c]["name"]]
				_changed()
			return
		if items.has(id):
			_status.text = "В «%s» уже есть «%s»" % [menus[c]["name"], MenuSet.action(id)[0]]
			return
		if items.size() >= MenuSet.MAX_ITEMS:
			_status.text = "В «%s» уже %d функций — больше не помещается" % [menus[c]["name"], MenuSet.MAX_ITEMS]
			return
		menus[c]["items"] = MenuSet.moved(items, id, place)
		if from is int:
			_remove(from, id)
		_status.text = "«%s» → «%s»" % [MenuSet.action(id)[0], menus[c]["name"]]
		_changed()
		return


func _remove(category: int, id: String) -> void:
	menus[category]["items"] = (menus[category]["items"] as Array).filter(func(item: String) -> bool: return item != id)


## What is under `point`: [from, id] ("library" or a category index), or empty.
func _pick(point: Vector2) -> Array:
	for chip in _library_chips:
		if chip.visible and _chip_rect(chip).has_point(point):
			return ["library", chip.get_meta("id")]
	for c in menus.size():
		for chip: Node3D in _category_chips[c]:
			if chip.visible and _chip_rect(chip).has_point(point):
				return [c, chip.get_meta("id")]
	return []


func _toggle_mode() -> void:
	mode = MenuSet.MODE_FINGER if mode == MenuSet.MODE_TWO_LEVEL else MenuSet.MODE_TWO_LEVEL
	_changed()


func _add_category() -> void:
	if menus.size() >= MenuSet.MAX_CATEGORIES:
		_status.text = "Категорий уже %d — больше не помещается" % MenuSet.MAX_CATEGORIES
		return
	menus.append({"name": "Категория %d" % (menus.size() + 1), "items": []})
	_status.text = "Добавлена «%s»: перетащите в неё функции" % menus.back()["name"]
	_changed()


func _delete_category(index: int) -> void:
	if index >= menus.size() or menus.size() <= 1:
		return
	_status.text = "Категория «%s» удалена" % menus[index]["name"]
	menus.remove_at(index)
	_changed()


func _start_recording() -> void:
	if not MouseInput.start_key_recording():
		_status.text = "Не удалось перехватить клавиатуру"
		return
	_recording_until = Time.get_ticks_msec() / 1000.0 + RECORD_TIMEOUT_SEC
	_status.text = "Нажмите сочетание на клавиатуре (%d с)…" % int(RECORD_TIMEOUT_SEC)
	print("[menus] запись сочетания")


func _update_recording() -> void:
	if _recording_until < 0.0:
		return
	var keys := MouseInput.get_recorded_keys()
	if keys.is_empty():
		if Time.get_ticks_msec() / 1000.0 > _recording_until:
			var seen := MouseInput.get_key_recording_seen()
			MouseInput.stop_key_recording()
			_recording_until = -1.0
			_status.text = "Сочетание не нажато — запись отменена"
			print("[menus] запись сочетания: время вышло, перехватчик видел событий: %d" % seen)
		return
	MouseInput.stop_key_recording()
	_recording_until = -1.0
	var pressed := Array(keys)
	var label := MenuSet.shortcut_label(pressed)
	for id: String in MenuSet.custom:
		if MenuSet.custom[id][1] == pressed:
			_status.text = "«%s» уже есть среди функций" % label
			return
	var number := 1
	while MenuSet.custom.has("custom:%d" % number):
		number += 1
	MenuSet.custom["custom:%d" % number] = [label, pressed]
	_status.text = "Записано «%s» — теперь перетащите в категорию" % label
	print("[menus] записано сочетание %s (перехватчик видел событий: %d; 0 — найдено опросом)" % [label, MouseInput.get_key_recording_seen()])
	_changed()


func _changed() -> void:
	refresh()
	changed.emit()


func _bin_rect(index: int) -> Rect2:
	var column := index % 3
	var row := index / 3
	var top_left := BIN_ORIGIN + Vector2(column * (BIN_SIZE.x + 0.04), -row * (BIN_SIZE.y + 0.04))
	return Rect2(top_left.x, top_left.y - BIN_SIZE.y, BIN_SIZE.x, BIN_SIZE.y)


func _chip_rect(chip: Node3D) -> Rect2:
	return Rect2(chip.position.x - CHIP.x * 0.5, chip.position.y - CHIP.y * 0.5, CHIP.x, CHIP.y)


## Where the ray crosses the tab's plane, in the tab's own coordinates (NAN if not).
func _plane_point(origin: Vector3, direction: Vector3) -> Vector2:
	var to_local := global_transform.affine_inverse()
	var local_origin := to_local * origin
	var local_direction := to_local.basis * direction
	if absf(local_direction.z) < 0.0001:
		return Vector2(NAN, NAN)
	var along := -local_origin.z / local_direction.z
	if along <= 0.0:
		return Vector2(NAN, NAN)
	var hit := local_origin + local_direction * along
	return Vector2(hit.x, hit.y)


func _chip() -> Node3D:
	var chip := Node3D.new()
	var mesh := QuadMesh.new()
	mesh.size = CHIP
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = VrButton.COLOR_HOVER
	var body := MeshInstance3D.new()
	body.mesh = mesh
	body.material_override = material
	chip.add_child(body)
	var text := Label3D.new()
	text.pixel_size = 0.001
	text.font_size = 22
	text.position = Vector3(0.0, 0.0, 0.002)
	chip.add_child(text)
	add_child(chip)
	return chip


func _show_chip(chip: Node3D, id: String) -> void:
	chip.visible = id != ""
	chip.set_meta("id", id)
	if id != "":
		(chip.get_child(1) as Label3D).text = MenuSet.action(id)[0]
		var own := MenuSet.custom.has(id)
		((chip.get_child(0) as MeshInstance3D).material_override as StandardMaterial3D).albedo_color = \
				Color(0.32, 0.3, 0.45) if own else VrButton.COLOR_HOVER


func _frame(rect: Rect2, color: Color) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = rect.size
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	var frame := MeshInstance3D.new()
	frame.mesh = mesh
	frame.material_override = material
	frame.position = Vector3(rect.get_center().x, rect.get_center().y, 0.0)
	add_child(frame)
	return frame


func _label(text: String, at: Vector3, size: int) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.pixel_size = 0.001
	label.font_size = size
	label.outline_size = 8
	label.position = at + Vector3(0.0, 0.0, 0.003)
	add_child(label)
	return label
