extends Node3D
## VR scene with hand joints, controllers, ray pointers and a small button panel
## (exit, add/remove a virtual display). Everything is built in code.

const HAND_TRACKER_NAMES: Array[StringName] = [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]
const CONTROLLER_TRACKER_NAMES: Array[StringName] = [&"left_hand", &"right_hand"]
const SIDE_LABELS: Array[String] = ["Левая", "Правая"]
const SIDE_SIGNS: Array[float] = [-1.0, 1.0]
const HAND_SOURCE_LABELS: Array[String] = ["неизвестен", "камеры шлема", "контроллер", "нет"]
const JOINT_RADIUS := 0.008
const RAY_LENGTH := 2.0
const LOG_INTERVAL_SEC := 1.0

# Tunables for the hand pointer; they move to a settings resource with the full gesture set.
const PINCH_PRESS_DISTANCE := 0.018
const PINCH_RELEASE_DISTANCE := 0.035
const SHOULDER_DROP := 0.2
const SHOULDER_HALF_WIDTH := 0.18
## 0 = ray follows the shoulder-to-hand line only, 1 = the rotation of the hand only.
const HAND_ROTATION_WEIGHT := 0.8
## Adaptive smoothing: slow ray movement (below RAY_SPEED_SLOW rad/s) is smoothed
## with the long time constant to hide tremor, fast movement with the short one.
const RAY_SMOOTHING_SLOW_SEC := 0.2
const RAY_SMOOTHING_FAST_SEC := 0.03
const RAY_SPEED_SLOW := 0.1
const RAY_SPEED_FAST := 1.0
## Measured 14.10.2026 with a still hand, as spread on the panel per second: the
## whole ray 3-10 px, the ray from the hand position alone 2-4 px. The tremor comes
## from the rotation of the hand, so that part gets its own, much wider dead zone
## and slower smoothing; the final ray only a narrow one. Coarse aiming is done
## by turning the wrist, fine aiming by moving the hand.
## Dead zones are in radians: 0.001 rad is about 1.7 px on the panel at 1.1 m.
const ROTATION_DEADBAND := 0.010
const ROTATION_SMOOTHING_SLOW_SEC := 0.25
const RAY_DEADBAND := 0.002
## The wrist rotation is tracked worst exactly when the fingers close. Below this
## thumb-to-index distance, and while a pinch is held, the rotation's contribution
## is frozen and the ray moves only with the position of the hand.
const PINCH_FREEZE_DISTANCE := 0.03
## The hand ray starts at the palm centre and is tilted towards the floor by this
## much relative to where the hand points; adjustable in VR.
const RAY_PITCH_DOWN_DEG := 35.0
const RAY_PITCH_STEP_DEG := 5.0
## Sideways turn of the right-hand ray, positive to the right; mirrored for the left hand.
const RAY_YAW_RIGHT_DEG := 5.0
const RAY_YAW_STEP_DEG := 2.5
## After Quest Link restarts, the OpenXR instance of this process is lost for good
## (every re-initialisation fails with XR_ERROR_INSTANCE_LOST), so the app
## restarts itself and keeps restarting until Link is back.
const XR_RESTART_DELAY_SEC := 5.0
const XR_RESTART_MAX_ATTEMPTS := 60
const XR_LOST_TRACKERS_SEC := 3.0
const XR_RETRY_ENV := "WORKPLACE_XR_RETRY"

## Screen panel: a 1920-px-wide monitor spans this horizontal angle at this distance.
## Larger and closer than a real monitor, because the Quest 3S has few pixels per degree.
const PANEL_DISTANCE := 1.1
const PANEL_WIDTH_DEG := 60.0
const PANEL_CENTER_HEIGHT := 1.45
const EXIT_HOTKEY_VIRTUAL_KEY := 0x7B  # F12, together with Ctrl+Alt+Shift

const BUTTON_SIZE := Vector2(0.28, 0.12)
const SCREEN_BUTTON_HOLD_SEC := 0.6
const EXIT_BUTTON_HOLD_SEC := 1.0
## Creating a driver instance restarts every virtual display and drops Quest Link.
const NEW_INSTANCE_BUTTON_HOLD_SEC := 2.0
const TOPOLOGY_MESSAGES := {
	"detached": "экран отсоединён",
	"attached": "экран присоединён",
	"last_screen": "это последний экран, убирать нельзя",
	"no_free_screen": "свободных экранов нет — «Новый VDD» создаст ещё один (Link переподключится)",
}


## Spread of a point over a stretch of frames: the root-mean-square distance from
## its mean. Used to measure how much the hand ray trembles on the panel.
class Spread:
	var count := 0
	var _sum := Vector2.ZERO
	var _sum_of_squares := 0.0

	func add(point: Vector2) -> void:
		count += 1
		_sum += point
		_sum_of_squares += point.length_squared()

	func deviation() -> float:
		if count < 2:
			return 0.0
		var mean := _sum / count
		return sqrt(maxf(_sum_of_squares / count - mean.length_squared(), 0.0))

	func reset() -> void:
		count = 0
		_sum = Vector2.ZERO
		_sum_of_squares = 0.0


class Pointer:
	## Before smoothing, for the tremor measurement.
	var raw_origin := Vector3.ZERO
	var raw_direction := Vector3.FORWARD
	var shoulder_direction := Vector3.FORWARD
	var spread_raw := Spread.new()
	var spread_position_only := Spread.new()
	var spread_final := Spread.new()
	var active := false
	var mode := "нет"
	var origin := Vector3.ZERO
	var direction := Vector3.FORWARD
	var pressed := false
	var just_pressed := false
	var hit_distance := INF
	var pinch_mm := 0.0
	## Rotation from the shoulder-to-palm line to the full hand ray; see PINCH_FREEZE_DISTANCE.
	var rotation_offset := Quaternion.IDENTITY
	## Filtered direction the hand itself points in (wrist towards the knuckles).
	var rotation_forward := Vector3.ZERO
	## This frame's hand ray came from the runtime's aim pose.
	var runtime_aim := false
	var on_panel := false
	## Where the ray meets the screen panel: 0..1 from its top-left corner.
	var panel_uv := Vector2.ZERO


var _origin: XROrigin3D
var _camera: XRCamera3D
var _controllers: Array[XRController3D] = []
var _controller_visuals: Array[Node3D] = []
var _joint_meshes: Array[MultiMeshInstance3D] = []
var _pointers: Array[Pointer] = [Pointer.new(), Pointer.new()]
var _rays: Array[Node3D] = []
var _buttons: Array[VrButton] = []
var _screen_buttons: Array[VrButton] = []
var _topology: DisplayTopology
var _vdd: VddControl
var _vdd_message := ""
var _status: Label3D
var _log_timer := 0.0
var _xr_ready := false
var _xr: OpenXRInterface
var _capture: ScreenCapture
var _capture_frames_logged := 0
var _panel_viewport: SubViewport
var _panel_layer: OpenXRCompositionLayerQuad
## The captured monitor's rectangle on the Windows virtual desktop, in pixels.
var _panel_monitor := Rect2i()
var _cursor_filter := CursorFilter.new()
## Index of the pointer that drives the Windows cursor, or -1.
var _cursor_owner := -1
var _cursor_press_armed := false
var _recentered := false
## Diagnostic switches, comma-separated in WORKPLACE_DIAG: nolayer, nocopy, nohole, nocapture.
## Do NOT put the capture texture on a 3D material: in VR that removes the D3D12
## device (0x887A0005) and crashes the engine; the composition layer path is fine.
var _diag: PackedStringArray = OS.get_environment("WORKPLACE_DIAG").split(",", false)
var _hotkey: GlobalHotkey
## Hand ray source: true = the runtime's own aim pose (XR_EXT_hand_interaction, the
## ray of the Quest system UI, filtered by Meta), false = the ray computed here
## from the joints. Switchable in VR for comparison.
var _use_runtime_aim := true
var _ray_pitch_down_deg := RAY_PITCH_DOWN_DEG
var _ray_yaw_right_deg := RAY_YAW_RIGHT_DEG
## Seconds until the next reconnect attempt; negative while the session is healthy.
var _reconnect_timer := -1.0
var _last_session_state := -1
var _hand_trackers_seen := false
var _hand_trackers_missing_sec := 0.0


func _ready() -> void:
	_build_world()
	_build_rig()
	_build_buttons()

	_hotkey = GlobalHotkey.new()
	if _hotkey.start(true, true, true, EXIT_HOTKEY_VIRTUAL_KEY):
		print("[app] аварийный выход: Ctrl+Alt+Shift+F12")
	else:
		print("[app] не удалось занять Ctrl+Alt+Shift+F12 — сочетание уже используется")

	var xr: XRInterface = XRServer.find_interface("OpenXR")
	if xr == null or not xr.is_initialized():
		push_error("[xr] OpenXR не инициализирован. Шлем подключён через Link и Link активен?")
		_status.text = "OpenXR не инициализирован"
		# Only while recovering from a lost session; a plain launch without Link just stops here.
		var attempt := OS.get_environment(XR_RETRY_ENV).to_int()
		if attempt > 0 and attempt < XR_RESTART_MAX_ATTEMPTS:
			print("[xr] Link ещё не готов, попытка %d из %d" % [attempt, XR_RESTART_MAX_ATTEMPTS])
			get_tree().create_timer(XR_RESTART_DELAY_SEC).timeout.connect(_restart_app.bind(attempt + 1))
		return
	if OS.get_environment(XR_RETRY_ENV) != "":
		print("[xr] сессия восстановлена после перезапуска, попытка ", OS.get_environment(XR_RETRY_ENV))
		OS.unset_environment(XR_RETRY_ENV)

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_viewport().use_xr = true
	_xr_ready = true

	print("[xr] система: ", xr.get_system_info())
	print("[xr] рендерер: ", RenderingServer.get_current_rendering_driver_name(),
			" / ", RenderingServer.get_current_rendering_method())
	var openxr := xr as OpenXRInterface
	if openxr != null:
		_xr = openxr
		print("[xr] расширение hand tracking поддерживается средой: ", openxr.is_hand_tracking_supported())
		print("[xr] расширение hand interaction (поза прицеливания руки) поддерживается средой: ", openxr.is_hand_interaction_supported())
		openxr.session_begun.connect(_on_session_begun.bind(openxr))
		for event: StringName in [&"session_stopping", &"session_focussed", &"session_visible", &"session_loss_pending", &"instance_exiting"]:
			openxr.connect(event, _on_xr_event.bind(event))

	_build_screen_panel()


func _process(delta: float) -> void:
	if _hotkey != null and _hotkey.consume_pressed():
		print("[app] нажато Ctrl+Alt+Shift+F12")
		_quit()
		return
	if not _xr_ready:
		return
	if _capture != null and not _diag.has("nocopy"):
		_capture.update()
	_update_xr_session(delta)

	var lines: PackedStringArray = []
	for i in 2:
		var joints := _update_hand(i)
		_update_pointer(i, delta)
		var controller := _controllers[i]
		var pointer := _pointers[i]
		# With the hand interaction profile the controller node is tracked for bare hands too.
		_controller_visuals[i].visible = pointer.mode == "контроллер"
		lines.append("%s: суставов %d/%d (источник: %s) | контроллер: %s, триггер %.2f, grip %.2f, стик %s | луч: %s%s" % [
			SIDE_LABELS[i], joints, XRHandTracker.HAND_JOINT_MAX, _hand_source_label(i),
			"да" if controller.get_has_tracking_data() else "нет",
			controller.get_float(&"trigger"), controller.get_float(&"grip"),
			controller.get_vector2(&"primary"),
			pointer.mode, ", нажат" if pointer.pressed else "",
		])
		if pointer.mode == "рука":
			lines[-1] += " | щипок %.0f мм, луч %s" % [pointer.pinch_mm, "Meta" if pointer.runtime_aim else "свой"]

	_update_buttons(delta)
	_update_cursor()
	_update_rays()

	lines.append("Экранов Windows: %d  |  наклон луча %.0f°, вбок %.1f°%s" % [DisplayServer.get_screen_count(), _ray_pitch_down_deg, _ray_yaw_right_deg, ("  |  " + _vdd_message) if _vdd_message != "" else ""])
	_status.text = "\n".join(lines)

	_log_timer += delta
	if _log_timer >= LOG_INTERVAL_SEC:
		_log_timer = 0.0
		if _panel_layer != null:
			_log_tremor()
		if _capture != null:
			var frames := _capture.get_frame_count()
			lines.append("Захват: %s, кадров %d (+%d за интервал)" % [_capture.get_size(), frames, frames - _capture_frames_logged])
			_capture_frames_logged = frames
		for line in lines:
			print("[track] ", line)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_ESCAPE:
		_quit()


func _quit() -> void:
	print("[app] выход")
	get_tree().quit()


func _on_session_begun(openxr: OpenXRInterface) -> void:
	print("[xr] сессия начата, частота: ", openxr.display_refresh_rate, " Гц")


func _exit_tree() -> void:
	# Never leave Windows with a mouse button stuck down.
	if _cursor_filter.is_held():
		MouseInput.set_button(MouseInput.BUTTON_LEFT, false)
	if _capture != null:
		_capture.stop()


## Adds where a ray meets the plane of the panel (inside it or not), in panel pixels.
func _add_plane_point(spread: Spread, origin: Vector3, direction: Vector3) -> void:
	var panel_transform := _panel_layer.global_transform
	var distance := PointerMath.ray_rect_distance(origin, direction, panel_transform, Vector2(1000.0, 1000.0))
	if distance >= 0.0:
		spread.add(PointerMath.rect_uv(origin + direction * distance, panel_transform, _panel_layer.quad_size) * Vector2(_panel_monitor.size))


## Once per log interval: how much each hand ray trembled on the panel, in pixels.
func _log_tremor() -> void:
	for i in 2:
		var pointer := _pointers[i]
		if pointer.spread_final.count >= 20:
			print("[jitter] %s (%s): разброс за интервал, px — сырой луч %.1f, только положение руки %.1f, итог после фильтров %.1f (кадров %d, щипок %.0f мм)" % [
					SIDE_LABELS[i], "Meta" if pointer.runtime_aim else "свой", pointer.spread_raw.deviation(),
					pointer.spread_position_only.deviation(), pointer.spread_final.deviation(), pointer.spread_final.count, pointer.pinch_mm])
		pointer.spread_raw.reset()
		pointer.spread_position_only.reset()
		pointer.spread_final.reset()


## Drives the Windows cursor from the pointer aimed at the screen panel: the ray's
## hit point becomes a pixel on that monitor, a pinch or trigger the left button.
func _update_cursor() -> void:
	if _panel_layer == null:
		return
	var panel_transform := _panel_layer.global_transform
	var panel_size := _panel_layer.quad_size
	for pointer in _pointers:
		pointer.on_panel = false
		if not pointer.active:
			continue
		var distance := PointerMath.ray_rect_distance(pointer.origin, pointer.direction, panel_transform, panel_size)
		if distance < 0.0:
			continue
		pointer.on_panel = true
		pointer.panel_uv = PointerMath.rect_uv(pointer.origin + pointer.direction * distance, panel_transform, panel_size)
		pointer.hit_distance = minf(pointer.hit_distance, distance)
		if pointer.mode == "рука":
			pointer.spread_final.add(pointer.panel_uv * Vector2(_panel_monitor.size))
			_add_plane_point(pointer.spread_raw, pointer.raw_origin, pointer.raw_direction)
			_add_plane_point(pointer.spread_position_only, pointer.raw_origin, pointer.shoulder_direction)

	# One pointer owns the cursor: whoever pressed last, otherwise whoever aims at
	# the panel (right hand first). The owner cannot change while the button is held.
	if not _cursor_filter.is_held():
		for i in 2:
			if _pointers[i].on_panel and _pointers[i].just_pressed:
				_cursor_owner = i
		if _cursor_owner < 0 or not _pointers[_cursor_owner].on_panel:
			_cursor_owner = -1
			for i: int in [1, 0]:
				if _pointers[i].on_panel:
					_cursor_owner = i
					break

	var now := Time.get_ticks_usec() / 1000000.0
	var result: CursorFilter.Result
	if _cursor_owner < 0:
		_cursor_press_armed = false
		result = _cursor_filter.update(Vector2.ZERO, false, false, now)
	else:
		var owner_pointer := _pointers[_cursor_owner]
		# A press counts only if it began on the panel, not if a held pinch wandered onto it.
		if owner_pointer.on_panel and owner_pointer.just_pressed:
			_cursor_press_armed = true
		elif not owner_pointer.pressed:
			_cursor_press_armed = false
		var target := Vector2(_panel_monitor.position) + owner_pointer.panel_uv * Vector2(_panel_monitor.size - Vector2i.ONE)
		result = _cursor_filter.update(target, owner_pointer.on_panel, owner_pointer.pressed and _cursor_press_armed, now)

	var pixel := Vector2i(result.position.round())
	if result.move:
		MouseInput.move_to(pixel)
	if result.press:
		if result.double_click:
			# A full click first: the press that follows is then the second one of a
			# double click by Windows' own timing, however slow the hand was.
			MouseInput.set_button(MouseInput.BUTTON_LEFT, true)
			MouseInput.set_button(MouseInput.BUTTON_LEFT, false)
		MouseInput.set_button(MouseInput.BUTTON_LEFT, true)
		print("[cursor] %s: нажатие в %s, луч в этот момент в %.0f px от точки%s" % [SIDE_LABELS[_cursor_owner], pixel,
				_cursor_filter.last_press_offset, ", двойной щелчок" if result.double_click else ""])
	if result.release:
		MouseInput.set_button(MouseInput.BUTTON_LEFT, false)
		print("[cursor] отпускание в %s через %.2f с, за время удержания луч уходил на %.0f px" % [
				pixel, _cursor_filter.last_hold_sec, _cursor_filter.last_hold_excursion])


## One monitor as a live panel in front of the user. The picture goes through an
## OpenXR composition layer, which the runtime samples directly and which is
## noticeably sharper for text than a textured mesh.
func _build_screen_panel() -> void:
	if not _diag.is_empty():
		print("[diag] ", _diag)
	if _diag.has("nocapture"):
		return
	var monitors := ScreenCapture.list_monitors()
	print("[capture] мониторы: ", monitors)
	var monitor_index := 0
	for i in monitors.size():
		if monitors[i]["primary"]:
			monitor_index = i

	_capture = ScreenCapture.new()
	if not _capture.start(monitor_index):
		print("[capture] ошибка: ", _capture.get_last_error())
		_capture = null
		return
	var pixels := _capture.get_size()
	_panel_monitor = Rect2i(monitors[monitor_index]["position"], pixels)
	print("[capture] захват монитора %d (%s) запущен, %s" % [monitor_index, monitors[monitor_index]["name"], pixels])

	if not _diag.has("nolayer"):
		_build_panel_layer(pixels)


func _build_panel_layer(pixels: Vector2i) -> void:
	var picture := TextureRect.new()
	picture.texture = _capture.get_texture()
	picture.stretch_mode = TextureRect.STRETCH_SCALE
	picture.set_anchors_preset(Control.PRESET_FULL_RECT)
	var viewport := SubViewport.new()
	viewport.size = pixels
	viewport.disable_3d = true
	# Stays off until the session is visible: rendering the layer earlier makes
	# OpenXR acquire its swapchain image twice ("image_acquired" errors).
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.add_child(picture)
	add_child(viewport)
	_panel_viewport = viewport

	var width := 2.0 * PANEL_DISTANCE * tan(deg_to_rad(PANEL_WIDTH_DEG * 0.5)) * (pixels.x / 1920.0)
	var layer := OpenXRCompositionLayerQuad.new()
	layer.layer_viewport = viewport
	layer.quad_size = Vector2(width, width * pixels.y / pixels.x)
	# Behind the scene with a hole punched through it, so hands and rays draw over the panel.
	if not _diag.has("nohole"):
		layer.sort_order = -1
		layer.enable_hole_punch = true
		get_viewport().transparent_bg = true
	_origin.add_child(layer)
	_panel_layer = layer
	_place_panel()
	print("[capture] панель %.2f x %.2f м на расстоянии %.2f м" % [layer.quad_size.x, layer.quad_size.y, PANEL_DISTANCE])


## The layer has to be a child of the origin, but it belongs at a fixed place in
## the world (in front of the user, facing them), so it is positioned globally.
func _place_panel() -> void:
	if _panel_layer != null:
		_panel_layer.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, PANEL_CENTER_HEIGHT, -PANEL_DISTANCE))


## Turns and shifts the play space so that the user stands at the world origin
## looking along -Z, where the panels and buttons are. The headset's own "forward"
## comes from the room setup and can point anywhere.
func _recenter() -> void:
	var head := _camera.transform
	var forward := -head.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.01:
		return
	var yaw := PI - atan2(forward.x, forward.z)
	var turn := Basis(Vector3.UP, yaw)
	_origin.transform = Transform3D(turn, -(turn * Vector3(head.origin.x, 0.0, head.origin.z)))
	_place_panel()
	_recentered = true
	print("[xr] сцена выровнена по взгляду, поворот %.0f°" % rad_to_deg(yaw))


func _on_xr_event(event: StringName) -> void:
	print("[xr] событие: ", event)
	# A moment after focus, so that the head pose is valid.
	if event == &"session_focussed" and not _recentered:
		get_tree().create_timer(0.5).timeout.connect(_recenter)
	if _panel_viewport != null:
		if event == &"session_visible" or event == &"session_focussed":
			_panel_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		elif event == &"session_stopping":
			_panel_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if event == &"session_loss_pending" or event == &"instance_exiting":
		_schedule_reconnect()


func _schedule_reconnect() -> void:
	if _reconnect_timer < 0.0:
		_reconnect_timer = XR_RESTART_DELAY_SEC


func _restart_app(attempt: int) -> void:
	print("[xr] перезапускаю приложение, попытка %d" % attempt)
	OS.set_environment(XR_RETRY_ENV, str(attempt))
	# Launched through a delayed PowerShell so the new process starts after this one
	# is gone. OS.set_restart_on_exit() is not used: after a lost OpenXR instance
	# the engine never got as far as restarting.
	var command := "Start-Sleep -Seconds 2; Start-Process -FilePath '%s' -ArgumentList '--path','%s'" % [
		OS.get_executable_path(), ProjectSettings.globalize_path("res://").trim_suffix("/"),
	]
	var pid := OS.create_process("powershell.exe", ["-NoProfile", "-WindowStyle", "Hidden", "-Command", command])
	print("[xr] запуск нового процесса через PowerShell, pid ", pid)
	get_tree().quit()


## Logs session state changes and restarts the app after the runtime drops the
## session (Quest Link restarts whenever a display driver instance is toggled).
func _update_xr_session(delta: float) -> void:
	if _xr == null:
		return
	if _xr.has_method(&"get_session_state"):
		var state: int = _xr.call(&"get_session_state")
		if state != _last_session_state:
			_last_session_state = state
			print("[xr] состояние сессии: ", state)

	# The runtime does not always announce the loss; vanished hand trackers also mean it.
	if XRServer.get_tracker(HAND_TRACKER_NAMES[0]) != null:
		_hand_trackers_seen = true
		_hand_trackers_missing_sec = 0.0
	elif _hand_trackers_seen and _reconnect_timer < 0.0:
		_hand_trackers_missing_sec += delta
		if _hand_trackers_missing_sec > XR_LOST_TRACKERS_SEC:
			print("[xr] трекеры рук пропали — считаю сессию потерянной")
			_hand_trackers_seen = false
			_schedule_reconnect()

	if _reconnect_timer < 0.0:
		return
	_reconnect_timer -= delta
	if _reconnect_timer > 0.0:
		return
	_restart_app(1)


func _on_ray_pitch_button(step_deg: float) -> void:
	_ray_pitch_down_deg = clampf(_ray_pitch_down_deg + step_deg, -30.0, 60.0)
	print("[ray] наклон луча вниз: %.0f°" % _ray_pitch_down_deg)


func _on_ray_source_button() -> void:
	_use_runtime_aim = not _use_runtime_aim
	print("[ray] источник луча рук: ", "Meta (поза прицеливания среды)" if _use_runtime_aim else "свой (по суставам)")


func _on_ray_yaw_button(step_deg: float) -> void:
	_ray_yaw_right_deg = clampf(_ray_yaw_right_deg + step_deg, -45.0, 45.0)
	print("[ray] поворот луча правой руки вправо: %.1f° (левая зеркально)" % _ray_yaw_right_deg)


func _on_button_pressed(button: String, side: int) -> void:
	print("[input] ", SIDE_LABELS[side], " контроллер: нажато ", button)


func _screens_busy() -> bool:
	return _topology.busy or _vdd.busy


func _on_screen_button(add: bool) -> void:
	if _screens_busy():
		return
	_vdd_message = "присоединяю экран…" if add else "отсоединяю экран…"
	print("[screens] ", _vdd_message)
	if add:
		_topology.add_screen()
	else:
		_topology.remove_screen()


func _on_topology_finished(ok: bool, code: String, detail: String) -> void:
	var text: String = TOPOLOGY_MESSAGES.get(code, code)
	_vdd_message = ("готово: " if ok else "ошибка: ") + text + ((" (" + detail + ")") if detail != "" else "")
	print("[screens] ", _vdd_message)


func _on_new_instance_button() -> void:
	if _screens_busy():
		return
	_vdd_message = "создаю экземпляр VDD, Link переподключится…"
	print("[vdd] ", _vdd_message)
	_vdd.add_screen()


func _on_vdd_finished(ok: bool, message: String) -> void:
	_vdd_message = ("готово: " if ok else "ошибка: ") + message
	print("[vdd] ", _vdd_message)


## Moves the joint spheres of one hand; returns how many joints have a valid position.
func _update_hand(index: int) -> int:
	var mesh_instance := _joint_meshes[index]
	var tracker := XRServer.get_tracker(HAND_TRACKER_NAMES[index]) as XRHandTracker
	if tracker == null or not tracker.has_tracking_data:
		mesh_instance.visible = false
		return 0

	var valid := 0
	var multimesh := mesh_instance.multimesh
	for joint_index in XRHandTracker.HAND_JOINT_MAX:
		var joint := joint_index as XRHandTracker.HandJoint
		if tracker.get_hand_joint_flags(joint) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID:
			multimesh.set_instance_transform(valid, Transform3D(Basis.IDENTITY, tracker.get_hand_joint_transform(joint).origin))
			valid += 1
	multimesh.visible_instance_count = valid
	mesh_instance.visible = valid > 0
	return valid


## A real hand wins over a controller; hand joints synthesised from a held
## controller do not count as a hand.
func _update_pointer(index: int, delta: float) -> void:
	var pointer := _pointers[index]
	var was_pressed := pointer.pressed
	var controller := _controllers[index]
	var tracker := XRServer.get_tracker(HAND_TRACKER_NAMES[index]) as XRHandTracker
	pointer.hit_distance = INF

	if tracker != null and tracker.has_tracking_data \
			and tracker.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER \
			and tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID:
		var to_world := _origin.global_transform
		var palm := to_world * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM).origin
		var thumb_tip := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin
		var index_tip := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
		# Wrist and knuckles barely move when the fingers pinch, so they define the ray.
		var wrist := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST).origin
		var middle_knuckle := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL).origin
		var shoulder_direction := PointerMath.hand_ray_direction(_camera.global_transform, palm, SIDE_SIGNS[index], SHOULDER_DROP, SHOULDER_HALF_WIDTH)
		var hand_forward := (to_world.basis * (middle_knuckle - wrist)).normalized()
		var hand_before := pointer.mode == "рука"
		var previous_forward := pointer.rotation_forward if hand_before else Vector3.ZERO
		var forward_speed := previous_forward.angle_to(hand_forward) / maxf(delta, 0.001) if hand_before else INF
		pointer.rotation_forward = PointerMath.smooth_direction(previous_forward,
				PointerMath.deadband_direction(previous_forward, hand_forward, ROTATION_DEADBAND), delta,
				PointerMath.adaptive_smoothing(forward_speed, ROTATION_SMOOTHING_SLOW_SEC, RAY_SMOOTHING_FAST_SEC, RAY_SPEED_SLOW, RAY_SPEED_FAST))
		# SIDE_SIGNS mirrors the turn: what is "right" for the right hand is "left" for the left one.
		var yaw := deg_to_rad(_ray_yaw_right_deg) * SIDE_SIGNS[index]
		var pitch := deg_to_rad(_ray_pitch_down_deg)
		var target := PointerMath.pitch_direction(PointerMath.yaw_direction(
				PointerMath.blend_ray_direction(shoulder_direction, pointer.rotation_forward, HAND_ROTATION_WEIGHT), yaw), pitch)
		# The same ray without the rotation filter, only for the tremor measurement.
		var unfiltered_target := PointerMath.pitch_direction(PointerMath.yaw_direction(
				PointerMath.blend_ray_direction(shoulder_direction, hand_forward, HAND_ROTATION_WEIGHT), yaw), pitch)
		var ray_origin := palm
		pointer.runtime_aim = _use_runtime_aim and controller.get_has_tracking_data()
		if pointer.runtime_aim:
			target = -controller.global_basis.z.normalized()
			unfiltered_target = target
			ray_origin = controller.global_position
		var tip_distance := thumb_tip.distance_to(index_tip)
		var was_hand := pointer.mode == "рука"
		if not was_hand or (not was_pressed and tip_distance > PINCH_FREEZE_DISTANCE):
			pointer.rotation_offset = Quaternion(shoulder_direction, target)
		target = pointer.rotation_offset * shoulder_direction
		pointer.raw_origin = ray_origin
		pointer.raw_direction = unfiltered_target
		pointer.shoulder_direction = shoulder_direction
		var previous := pointer.direction if was_hand else Vector3.ZERO
		var angular_speed := previous.angle_to(target) / maxf(delta, 0.001) if was_hand else INF
		var smoothing := PointerMath.adaptive_smoothing(angular_speed, RAY_SMOOTHING_SLOW_SEC, RAY_SMOOTHING_FAST_SEC, RAY_SPEED_SLOW, RAY_SPEED_FAST)
		pointer.active = true
		pointer.mode = "рука"
		# The origin gets the same smoothing: a palm that jumps 1 cm moves the cursor about 15 px.
		pointer.origin = pointer.origin.lerp(ray_origin, 1.0 - exp(-delta / smoothing)) if was_hand else ray_origin
		pointer.pinch_mm = tip_distance * 1000.0
		# Dead zone first, then smoothing towards its result: the other way round a
		# single smoothed step would always be smaller than the zone.
		pointer.direction = PointerMath.smooth_direction(previous,
				PointerMath.deadband_direction(previous, target, RAY_DEADBAND), delta, smoothing)
		pointer.pressed = PointerMath.pinch_state(was_pressed, thumb_tip.distance_to(index_tip), PINCH_PRESS_DISTANCE, PINCH_RELEASE_DISTANCE)
	elif controller.get_has_tracking_data():
		pointer.active = true
		pointer.mode = "контроллер"
		pointer.origin = controller.global_position
		pointer.direction = -controller.global_basis.z.normalized()
		pointer.pressed = controller.is_button_pressed(&"trigger_click")
	else:
		pointer.active = false
		pointer.mode = "нет"
		pointer.pressed = false
	pointer.just_pressed = pointer.pressed and not was_pressed


func _update_buttons(delta: float) -> void:
	for button in _screen_buttons:
		button.enabled = not _screens_busy()
	for button in _buttons:
		var hovered := false
		var pressed := false
		var just_pressed := false
		for pointer in _pointers:
			if not pointer.active:
				continue
			var distance := button.hit_distance(pointer.origin, pointer.direction)
			if distance < 0.0:
				continue
			hovered = true
			pressed = pressed or pointer.pressed
			just_pressed = just_pressed or pointer.just_pressed
			pointer.hit_distance = minf(pointer.hit_distance, distance)
		button.update(hovered, pressed, just_pressed, delta)


func _update_rays() -> void:
	for i in 2:
		var pointer := _pointers[i]
		var ray := _rays[i]
		ray.visible = pointer.active
		if not pointer.active:
			continue
		var length := minf(pointer.hit_distance, RAY_LENGTH)
		var up := Vector3.FORWARD if absf(pointer.direction.y) > 0.99 else Vector3.UP
		var ray_basis := Basis.looking_at(pointer.direction, up).scaled_local(Vector3(1.0, 1.0, length))
		ray.global_transform = Transform3D(ray_basis, pointer.origin)


func _hand_source_label(index: int) -> String:
	var tracker := XRServer.get_tracker(HAND_TRACKER_NAMES[index]) as XRHandTracker
	if tracker == null:
		return "трекера нет"
	var source := int(tracker.hand_tracking_source)
	return HAND_SOURCE_LABELS[source] if source < HAND_SOURCE_LABELS.size() else str(source)


func _build_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.05, 0.06, 0.08)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.6
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	add_child(light)

	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(6.0, 6.0)
	var floor_instance := MeshInstance3D.new()
	floor_instance.mesh = floor_mesh
	floor_instance.material_override = _flat_material(Color(0.15, 0.17, 0.2))
	add_child(floor_instance)

	_status = Label3D.new()
	_status.position = Vector3(0.0, 2.05, -1.2)
	_status.pixel_size = 0.0012
	_status.font_size = 36
	_status.outline_size = 8
	_status.text = "Запуск…"
	add_child(_status)


func _build_rig() -> void:
	_origin = XROrigin3D.new()
	add_child(_origin)
	_camera = XRCamera3D.new()
	_origin.add_child(_camera)

	var joint_mesh := SphereMesh.new()
	joint_mesh.radius = JOINT_RADIUS
	joint_mesh.height = JOINT_RADIUS * 2.0
	joint_mesh.radial_segments = 12
	joint_mesh.rings = 6
	var side_colors: Array[Color] = [Color(0.3, 0.7, 1.0), Color(1.0, 0.6, 0.3)]

	for i in 2:
		var controller := XRController3D.new()
		controller.tracker = CONTROLLER_TRACKER_NAMES[i]
		controller.pose = &"aim"
		controller.button_pressed.connect(_on_button_pressed.bind(i))
		_origin.add_child(controller)
		_controllers.append(controller)

		var body_mesh := BoxMesh.new()
		body_mesh.size = Vector3(0.04, 0.04, 0.1)
		var body := MeshInstance3D.new()
		body.mesh = body_mesh
		body.material_override = _flat_material(side_colors[i])
		body.visible = false
		controller.add_child(body)
		_controller_visuals.append(body)

		# Unit-length ray along -Z; _update_rays() scales the pivot to the hit distance.
		var ray_mesh := BoxMesh.new()
		ray_mesh.size = Vector3(0.003, 0.003, 1.0)
		var ray_body := MeshInstance3D.new()
		ray_body.mesh = ray_mesh
		ray_body.position = Vector3(0.0, 0.0, -0.5)
		ray_body.material_override = _flat_material(side_colors[i])
		var ray := Node3D.new()
		ray.visible = false
		ray.add_child(ray_body)
		add_child(ray)
		_rays.append(ray)

		# Joint transforms are relative to the origin, so the spheres live under it.
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = joint_mesh
		multimesh.instance_count = XRHandTracker.HAND_JOINT_MAX
		multimesh.visible_instance_count = 0
		var joints := MultiMeshInstance3D.new()
		joints.multimesh = multimesh
		joints.material_override = _flat_material(side_colors[i])
		joints.visible = false
		_origin.add_child(joints)
		_joint_meshes.append(joints)


func _build_buttons() -> void:
	_vdd = VddControl.new()
	_vdd.finished.connect(_on_vdd_finished)
	add_child(_vdd)
	_topology = DisplayTopology.new()
	_topology.finished.connect(_on_topology_finished)
	add_child(_topology)

	var remove_button := _add_button("− экран", Vector3(-0.47, 1.0, -1.2), SCREEN_BUTTON_HOLD_SEC)
	remove_button.activated.connect(_on_screen_button.bind(false))
	var add_button := _add_button("+ экран", Vector3(-0.15, 1.0, -1.2), SCREEN_BUTTON_HOLD_SEC)
	add_button.activated.connect(_on_screen_button.bind(true))
	var new_instance_button := _add_button("Новый VDD", Vector3(-0.31, 0.84, -1.2), NEW_INSTANCE_BUTTON_HOLD_SEC)
	new_instance_button.activated.connect(_on_new_instance_button)
	_screen_buttons = [remove_button, add_button, new_instance_button]

	# Kept apart from the others so that it is not hit by accident.
	var exit_button := _add_button("Выход", Vector3(0.45, 1.0, -1.2), EXIT_BUTTON_HOLD_SEC)
	exit_button.activated.connect(_quit)

	var recenter_button := _add_button("Центр", Vector3(0.45, 0.52, -1.2), 0.6)
	recenter_button.activated.connect(_recenter)
	var ray_source_button := _add_button("Луч: Meta / свой", Vector3(0.13, 0.52, -1.2), 0.6)
	ray_source_button.activated.connect(_on_ray_source_button)

	# Temporary tuning aid: the chosen value ends up in the log and becomes the default.
	var ray_up_button := _add_button("Луч выше", Vector3(0.29, 0.84, -1.2), 0.3)
	ray_up_button.activated.connect(_on_ray_pitch_button.bind(-RAY_PITCH_STEP_DEG))
	var ray_down_button := _add_button("Луч ниже", Vector3(0.61, 0.84, -1.2), 0.3)
	ray_down_button.activated.connect(_on_ray_pitch_button.bind(RAY_PITCH_STEP_DEG))
	var ray_left_button := _add_button("Луч влево", Vector3(0.29, 0.68, -1.2), 0.3)
	ray_left_button.activated.connect(_on_ray_yaw_button.bind(-RAY_YAW_STEP_DEG))
	var ray_right_button := _add_button("Луч вправо", Vector3(0.61, 0.68, -1.2), 0.3)
	ray_right_button.activated.connect(_on_ray_yaw_button.bind(RAY_YAW_STEP_DEG))


func _add_button(text: String, at: Vector3, hold_time: float) -> VrButton:
	var button := VrButton.new(text, BUTTON_SIZE, hold_time)
	button.position = at
	add_child(button)
	_buttons.append(button)
	return button


func _flat_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material
