extends Node3D
## Offline pairing panel. No keyboard input or credential is sent to the PC's desktop.

signal finished
var blocking := true
var _camera: Camera3D
var _panel: Node3D
var _label: Label3D
var _digits: Label3D
var _buttons: Array[VrButton] = []
var _down: Array[bool] = [false, false]
var _dots: Array[MeshInstance3D] = []
var _code := ""
var _request: InternetLink.Request
var _phase := ""
var _next_status := 0.0
var _waiting := false
var _approval_until := 0.0
var _internet_button: VrButton
var _placed := false
var _closing := false
var _await_open_release := true
var _inputs_frame := -1
var _captured: Array[bool] = [false, false]
var _held: Array[bool] = [false, false]
var _hit_distances: Array[float] = [INF, INF]
var _fallback_rays: Array[MeshInstance3D] = []


func _ready() -> void:
	process_priority = 100
	InternetLink.setup_input = accept_inputs
	_panel = Node3D.new()
	add_child(_panel)
	_label = Label3D.new()
	_label.no_depth_test = true
	_label.render_priority = 102
	_label.pixel_size = 0.0007
	_label.font_size = 30
	_label.position.y = 0.29
	_panel.add_child(_label)
	_label.text = "Вход через интернет\nСоздай код в окне WoRkPlace на ПК"
	if InternetLink.bound():
		_label.text = "Нет связи через интернет.\nМожно повторить вход или вернуться к кабелю / Wi-Fi."
	print("[internet] панель подключения открыта")
	_digits = Label3D.new()
	_digits.no_depth_test = true
	_digits.render_priority = 102
	_digits.pixel_size = 0.001
	_digits.position.y = 0.19
	_panel.add_child(_digits)
	for i in 12:
		var text: String = str(i + 1) if i < 9 else ["←", "0", "C"][i - 9]
		var key := VrButton.new(text, Vector2(0.07, 0.065), 0.35)
		key.position = Vector3((i % 3 - 1) * 0.085, 0.1 - floori(i / 3.0) * 0.08, 0)
		key.activated.connect(_key.bind(text))
		_panel.add_child(key)
		_buttons.append(key)
	var login := VrButton.new("Ввести код", Vector2(0.23, 0.09), 0.45)
	login.position = Vector3(0.26, 0.0, 0)
	login.activated.connect(_login)
	_panel.add_child(login)
	_buttons.append(login)
	for internet in [false, true]:
		var button := VrButton.new("Интернет" if internet else "Кабель / Wi-Fi", Vector2(0.24, 0.08), 0.45)
		button.position = Vector3(0.2 if internet else -0.2, -0.27, 0)
		button.activated.connect(_choose.bind(internet))
		_panel.add_child(button)
		_buttons.append(button)
		if internet:
			_internet_button = button
	for i in 2:
		var dot := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.004
		sphere.height = 0.008
		dot.mesh = sphere
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(0.3, 1, 0.6)
		dot.material_override = material
		add_child(dot)
		_dots.append(dot)
		var ray := MeshInstance3D.new()
		var line := CylinderMesh.new()
		line.top_radius = 0.001
		line.bottom_radius = 0.001
		ray.mesh = line
		ray.material_override = material
		ray.visible = false
		add_child(ray)
		_fallback_rays.append(ray)
	for button in _buttons:
		button._material.no_depth_test = true
		button._material.render_priority = 100
		(button._fill.material_override as StandardMaterial3D).no_depth_test = true
		(button._fill.material_override as StandardMaterial3D).render_priority = 101
		button._label.no_depth_test = true
		button._label.render_priority = 102
	_update_digits()
	open_panel()


func open_panel() -> void:
	visible = true
	blocking = true
	_closing = false
	_await_open_release = true
	_placed = false
	InternetLink.setup_visible = true
	_update_digits()
	_place_in_world()


func set_reconnecting(code: String) -> void:
	_label.text = "Связь временно прервана.\nПереподключаюсь автоматически…"
	if not code.is_empty():
		_label.text += "\n[%s]" % code


func set_connection_error(code: String) -> void:
	var messages := {"TCP_CONNECT": "Не удалось соединиться с сервером",
		"TCP_TIMEOUT": "Сервер не ответил на сетевое подключение",
		"TLS_ERROR": "Защищённый канал не установлен",
		"TLS_TIMEOUT": "Сервер не завершил защищённое подключение",
		"AUTH_FAILED": "Сохранённый вход не принят сервером",
		"DEVICE_NOT_PAIRED": "Устройство не подтверждено на ПК",
		"CONFIG_REQUIRED": "Подготовь подключение в окне сервера на ПК"}
	_label.text = "%s\n[%s]" % [messages.get(code, "Не удалось завершить подключение"), code]


func _place_in_world() -> void:
	_camera = get_viewport().get_camera_3d()
	if not is_instance_valid(_camera):
		_panel.visible = false
		_placed = false
		return
	if _placed:
		return
	_panel.global_transform = _camera.global_transform * Transform3D(Basis.IDENTITY, Vector3(0, -0.05, -0.8))
	_panel.visible = true
	_placed = true


func _exit_tree() -> void:
	InternetLink.setup_visible = false
	InternetLink.setup_input = Callable()
	InternetLink.setup_capture = [false, false]
	if _request != null:
		_request.close()


func _key(value: String) -> void:
	if value == "C":
		if _request != null:
			_request.close()
			_request = null
		_waiting = false
		_code = ""
		_label.text = "Вход через интернет\nСоздай код в окне WoRkPlace на ПК"
		_update_digits()
		return
	if _request != null or _waiting:
		return
	if value == "←":
		_code = _code.left(maxi(0, _code.length() - 1))
	elif value == "C":
		_code = ""
	elif _code.length() < 8:
		_code += value
	_update_digits()


func _update_digits() -> void:
	_digits.text = _code + "·".repeat(8 - _code.length())
	_internet_button.enabled = InternetLink.bound()


func _login() -> void:
	if _code.length() != 8 or _request != null or _waiting:
		return
	_phase = "claim" if InternetLink.registered() else "register"
	_request = InternetLink.request(_phase, {"code": _code} if _phase == "claim" else {}, true)
	_label.text = "Защищённое подключение к ПК…"


func _choose(internet: bool) -> void:
	if _closing or (internet and not InternetLink.bound()):
		return
	_apply_choice(internet)
	# Keep world input blocked through the press that closes this panel.
	_closing = true
	if _request != null:
		_request.close()
		_request = null


func _apply_choice(internet: bool) -> void:
	InternetLink.select(internet)
	if HeadsetOptions.settings_saved.is_valid():
		HeadsetOptions.settings_saved.call()


func _hide_panel() -> void:
	blocking = false
	visible = false
	InternetLink.setup_visible = false
	InternetLink.setup_capture = [false, false]
	_waiting = false
	if _request != null:
		_request.close()
		_request = null
	finished.emit()


func connection_restored() -> void:
	if not _closing:
		_label.text = "Связь восстановлена"
		print("[internet] связь восстановлена")
	# Release any held PIN press before returning its pointer to the world.
	_closing = true
	if _request != null:
		_request.close()
		_request = null


func _process(delta: float) -> void:
	if not visible:
		return
	_place_in_world()
	if not _placed:
		return
	if _inputs_frame != Engine.get_process_frames():
		_update_inputs(delta)
	if not _down[0] and not _down[1]:
		_await_open_release = false
	if _closing:
		if not _down[0] and not _down[1]:
			_hide_panel()
		return
	if _request != null:
		_request.poll()
		if _request.failed:
			_label.text = "Подключение не выполнено.\nПроверь сервер и код на ПК; USB нужен для первой привязки."
			_request.close()
			_request = null
			_waiting = false
		elif _request.ready:
			var result := _request.result
			_request.close()
			_request = null
			if _phase == "register":
				if not InternetLink.save_identity(result):
					_label.text = "Не удалось сохранить вход на этом устройстве"
					return
				_phase = "claim"
				_request = InternetLink.request("claim", {"code": _code}, true)
			elif _phase == "claim":
				print("[internet] ожидаю подтверждение на ПК")
				_label.text = "Сравни с ПК: %s\nКабель / Wi-Fi возвращает к экранам для подтверждения на ПК" % str(result.get("check", ""))
				_waiting = true
				_approval_until = Time.get_ticks_msec() / 1000.0 + 120.0
			elif _phase == "status" and result.get("trusted", false):
				InternetLink.identity["trusted"] = true
				InternetLink.save_identity(InternetLink.identity)
				_label.text = "Устройство привязано.\nМожно выбрать интернет или локальную связь."
				_waiting = false
				_update_digits()
	if _waiting and Time.get_ticks_msec() / 1000.0 >= _approval_until:
		_waiting = false
		_label.text = "Время подтверждения истекло.\nСоздай новый код на ПК; C очищает ввод."
	if _waiting and _request == null and Time.get_ticks_msec() / 1000.0 >= _next_status:
		_next_status = Time.get_ticks_msec() / 1000.0 + 2.0
		_phase = "status"
		_request = InternetLink.request("status", {}, true)


func _update_inputs(delta: float) -> void:
	var origins: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var directions: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var active: Array[bool] = [false, false]
	var pressed: Array[bool] = [false, false]
	var just: Array[bool] = [false, false]
	var stage := _camera.get_parent()
	while stage != null and not stage is XROrigin3D:
		stage = stage.get_parent()
	var to_world: Transform3D = (stage as Node3D).global_transform if stage is Node3D else Transform3D.IDENTITY
	for hand in 2:
		var origin := Vector3.ZERO
		var direction := Vector3.ZERO
		var controller := XRServer.get_tracker(&"left_hand" if hand == 0 else &"right_hand") as XRControllerTracker
		if controller != null:
			var aim := controller.get_pose(&"aim")
			if aim != null and aim.has_tracking_data:
				var world_aim := to_world * aim.transform
				origin = world_aim.origin
				direction = -world_aim.basis.z.normalized()
			var trigger: Variant = controller.get_input(&"trigger")
			pressed[hand] = trigger is float and trigger > 0.7
		var tracker := XRServer.get_tracker(&"/user/hand_tracker/left" if hand == 0 else &"/user/hand_tracker/right") as XRHandTracker
		if tracker != null and tracker.has_tracking_data and tracker.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER:
			var tip := to_world * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
			var thumb := to_world * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin
			pressed[hand] = tip.distance_to(thumb) < 0.025
			if direction.is_zero_approx():
				origin = (tip + thumb) * 0.5
				var shoulder := _camera.global_position + _camera.global_basis * Vector3(-0.15 if hand == 0 else 0.15, -0.18, 0)
				direction = (origin - shoulder).normalized()
		origins[hand] = origin
		directions[hand] = direction
		active[hand] = not direction.is_zero_approx()
		just[hand] = pressed[hand] and not _down[hand]
	_apply_inputs(origins, directions, active, pressed, just, delta, true)


func accept_inputs(pointers: Array, delta: float) -> Array[bool]:
	if not visible:
		return [false, false]
	_place_in_world()
	if not _placed:
		return [false, false]
	if pointers.is_empty():
		_update_inputs(delta)
	else:
		var origins: Array[Vector3] = []
		var directions: Array[Vector3] = []
		var active: Array[bool] = []
		var pressed: Array[bool] = []
		var just: Array[bool] = []
		for pointer: Variant in pointers:
			origins.append(pointer.origin)
			directions.append(pointer.direction)
			active.append(pointer.active and pointer.grab_panel == null and pointer.slider == null)
			pressed.append(pointer.pressed)
			just.append(pointer.just_pressed)
		_apply_inputs(origins, directions, active, pressed, just, delta, false)
		for hand in 2:
			if _captured[hand]:
				pointers[hand].hit_distance = minf(pointers[hand].hit_distance, _hit_distances[hand])
	return _captured.duplicate()


func _apply_inputs(origins: Array[Vector3], directions: Array[Vector3], active: Array[bool], pressed: Array[bool], just_pressed: Array[bool], delta: float, fallback_rays: bool) -> void:
	_inputs_frame = Engine.get_process_frames()
	var hit: Array[int] = [-1, -1]
	for hand in 2:
		var distance := INF
		if active[hand]:
			for i in _buttons.size():
				var candidate := _buttons[i].hit_distance(origins[hand], directions[hand])
				if candidate >= 0.0 and candidate < distance:
					hit[hand] = i
					distance = candidate
		_hit_distances[hand] = distance
		if not pressed[hand]:
			_held[hand] = false
		elif hit[hand] >= 0 and just_pressed[hand] and not _await_open_release:
			_held[hand] = true
		_captured[hand] = hit[hand] >= 0 or _held[hand]
		_dots[hand].visible = hit[hand] >= 0
		if hit[hand] >= 0:
			_dots[hand].global_position = origins[hand] + directions[hand] * distance
		var ray := _fallback_rays[hand]
		ray.visible = fallback_rays and active[hand]
		if ray.visible:
			var length := minf(distance, 2.0)
			(ray.mesh as CylinderMesh).height = maxf(length, 0.001)
			ray.global_transform = Transform3D(Basis(Quaternion(Vector3.UP, directions[hand].normalized())), origins[hand] + directions[hand] * length * 0.5)
	for i in _buttons.size():
		var hover: bool = hit[0] == i or hit[1] == i
		var down: bool = (hit[0] == i and pressed[0]) or (hit[1] == i and pressed[1])
		var just: bool = not _await_open_release and ((hit[0] == i and just_pressed[0]) or (hit[1] == i and just_pressed[1]))
		_buttons[i].update(hover, down, just, delta)
	_down = pressed
	InternetLink.setup_capture = _captured.duplicate()
