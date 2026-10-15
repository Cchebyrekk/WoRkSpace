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
## Measured against the runtime's aim ray on 14.10.2026 (AimStudy): Meta's ray is
## about 0.5 x the shoulder-to-hand line + 0.35 x the hand's own direction, i.e.
## the wrist rotation makes up roughly 0.42 of it.
const HAND_ROTATION_WEIGHT := 0.42
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
## How many frames go into one "[study]" log line comparing the runtime's ray with ours.
const AIM_STUDY_FRAMES := 360
## Where the runtime's aim ray starts, in the wrist joint's frame (metres, right
## hand; X is mirrored for the left). Measured, and stable to a few millimetres.
const AIM_ORIGIN_IN_WRIST := Vector3(0.02, 0.11, 0.06)
## Our ray's constant heading/elevation offset follows the runtime's ray this slowly.
const AIM_CALIBRATION_SEC := 20.0
## ...except for a few seconds after the user changes the mix or asks to recalibrate.
const AIM_CALIBRATION_FAST_SEC := 1.0
const AIM_CALIBRATION_BOOST_SEC := 5.0
const ROTATION_WEIGHT_STEP := 0.05
const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_VERSION := 2
## The wrist rotation is tracked worst exactly when the fingers close. Below this
## thumb-to-index distance, and while a pinch is held, the rotation's contribution
## is frozen and the ray moves only with the position of the hand.
const PINCH_FREEZE_DISTANCE := 0.03
## The hand ray starts at the palm centre and is tilted towards the floor by this
## much relative to where the hand points; adjustable in VR.
const RAY_PITCH_DOWN_DEG := 0.0
const RAY_PITCH_STEP_DEG := 5.0
## Sideways turn of the right-hand ray, positive to the right; mirrored for the left hand.
const RAY_YAW_RIGHT_DEG := 0.0
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
## A row of monitors wider than this arc is shrunk to fit, so that panels never
## wrap around behind the user.
const PANEL_MAX_ARC_DEG := 300.0
const MONITOR_CHECK_SEC := 1.0
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


## Works out how the runtime's aim ray is made: fits, frame by frame, the change
## of its heading and elevation as a mix of the change of the shoulder-to-hand
## line and of the direction the hand itself points in.
class AimStudy:
	var frames := 0
	var _shoulder_squared := 0.0
	var _forward_squared := 0.0
	var _shoulder_forward := 0.0
	var _aim_shoulder := 0.0
	var _aim_forward := 0.0
	var _origin_sum := Vector3.ZERO
	var _direction_sum := Vector3.ZERO
	var _angle_sum := 0.0
	var _has_previous := false
	var _previous_shoulder := Vector2.ZERO
	var _previous_forward := Vector2.ZERO
	var _previous_aim := Vector2.ZERO

	## Heading and elevation in radians; a constant tilt of the ray does not change heading steps.
	static func angles(direction: Vector3) -> Vector2:
		return Vector2(atan2(direction.x, -direction.z), asin(clampf(direction.y, -1.0, 1.0)))

	static func step(from: Vector2, to: Vector2) -> Vector2:
		return Vector2(wrapf(to.x - from.x, -PI, PI), to.y - from.y)

	func add(shoulder: Vector3, forward: Vector3, aim: Vector3, origin_in_wrist: Vector3, direction_in_wrist: Vector3, angle_to_own: float) -> void:
		var shoulder_angles := angles(shoulder)
		var forward_angles := angles(forward)
		var aim_angles := angles(aim)
		if _has_previous:
			var shoulder_step := step(_previous_shoulder, shoulder_angles)
			var forward_step := step(_previous_forward, forward_angles)
			var aim_step := step(_previous_aim, aim_angles)
			_shoulder_squared += shoulder_step.dot(shoulder_step)
			_forward_squared += forward_step.dot(forward_step)
			_shoulder_forward += shoulder_step.dot(forward_step)
			_aim_shoulder += aim_step.dot(shoulder_step)
			_aim_forward += aim_step.dot(forward_step)
		_has_previous = true
		_previous_shoulder = shoulder_angles
		_previous_forward = forward_angles
		_previous_aim = aim_angles
		_origin_sum += origin_in_wrist
		_direction_sum += direction_in_wrist
		_angle_sum += angle_to_own
		frames += 1

	## x: weight of the shoulder-to-hand line, y: weight of the hand's own direction.
	func weights() -> Vector2:
		var determinant := _shoulder_squared * _forward_squared - _shoulder_forward * _shoulder_forward
		if absf(determinant) < 1e-12:
			return Vector2(NAN, NAN)
		return Vector2((_aim_shoulder * _forward_squared - _aim_forward * _shoulder_forward) / determinant,
				(_aim_forward * _shoulder_squared - _aim_shoulder * _shoulder_forward) / determinant)

	func mean_origin_in_wrist() -> Vector3:
		return _origin_sum / maxi(frames, 1)

	func mean_direction_in_wrist() -> Vector3:
		return (_direction_sum / maxi(frames, 1)).normalized()

	func mean_angle_to_own() -> float:
		return _angle_sum / maxi(frames, 1)


class Pointer:
	var study := AimStudy.new()
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
	## The nearest screen panel the ray hits, and where: 0..1 from its top-left corner.
	var panel: ScreenPanel
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
## One live panel per Windows monitor, in the order of ScreenCapture.list_monitors().
var _panels: Array[ScreenPanel] = []
## What the monitor list looked like when the panels were built; a change rebuilds them.
var _monitor_signature := ""
## A changed list has to be seen twice in a row: during a topology change it flickers.
var _pending_monitor_signature := ""
var _monitor_check_timer := 0.0
var _session_visible := false
var _frames_logged := 0
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
## Constant offset (heading, elevation in radians) that turns our blended ray into
## the runtime's aim ray, per hand; learned while the runtime provides its ray.
var _aim_offset: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
## Share of the wrist rotation in our ray: 0 = follows the hand position only, 1 = the rotation only.
var _hand_rotation_weight := HAND_ROTATION_WEIGHT
## While positive, the offset above is re-learned quickly.
var _calibration_boost_sec := 0.0
var _ray_info: Label3D
var _ray_source_button: VrButton
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
	_load_settings()
	_update_ray_info()

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

	if not _diag.is_empty():
		print("[diag] ", _diag)
	_rebuild_panels()


func _process(delta: float) -> void:
	if _hotkey != null and _hotkey.consume_pressed():
		print("[app] нажато Ctrl+Alt+Shift+F12")
		_quit()
		return
	if not _xr_ready:
		return
	_update_panels(delta)
	_calibration_boost_sec = maxf(_calibration_boost_sec - delta, 0.0)
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
		_log_tremor()
		var frames := 0
		for panel in _panels:
			frames += panel.capture.get_frame_count()
		lines.append("Панелей %d, кадров захвата за интервал %d, FPS %d" % [_panels.size(), frames - _frames_logged, Engine.get_frames_per_second()])
		_frames_logged = frames
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
	for panel in _panels:
		panel.capture.stop()


## Adds where a ray meets the plane of a panel (inside it or not), in that panel's pixels.
func _add_plane_point(spread: Spread, panel: ScreenPanel, origin: Vector3, direction: Vector3) -> void:
	var panel_transform := panel.layer.global_transform
	var distance := PointerMath.ray_rect_distance(origin, direction, panel_transform, Vector2(1000.0, 1000.0))
	if distance >= 0.0:
		spread.add(panel.uv_at(origin + direction * distance) * Vector2(panel.monitor_rect.size))


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
		if pointer.study.frames >= AIM_STUDY_FRAMES:
			var weights := pointer.study.weights()
			print("[study] %s: луч Meta = %.2f x линия плечо-рука + %.2f x поворот кисти (по %d кадрам); начало луча в системе запястья %.1v см; направление в системе запястья %.2v; угол до своего луча %.1f°" % [
					SIDE_LABELS[i], weights.x, weights.y, pointer.study.frames, pointer.study.mean_origin_in_wrist() * 100.0,
					pointer.study.mean_direction_in_wrist(), rad_to_deg(pointer.study.mean_angle_to_own())])
			pointer.study = AimStudy.new()
			print("[study] %s: поправка своего луча к лучу Meta — курс %.1f°, возвышение %.1f°" % [
					SIDE_LABELS[i], rad_to_deg(_aim_offset[i].x), rad_to_deg(_aim_offset[i].y)])
			_save_settings()


## Drives the Windows cursor from the pointer aimed at a screen panel: the ray's
## hit point becomes a pixel on that monitor, a pinch or trigger the left button.
func _update_cursor() -> void:
	if _panels.is_empty():
		return
	for pointer in _pointers:
		pointer.on_panel = false
		pointer.panel = null
		if not pointer.active:
			continue
		var nearest := INF
		for panel in _panels:
			var distance := panel.hit_distance(pointer.origin, pointer.direction)
			if distance >= 0.0 and distance < nearest:
				nearest = distance
				pointer.panel = panel
		if pointer.panel == null:
			continue
		pointer.on_panel = true
		pointer.panel_uv = pointer.panel.uv_at(pointer.origin + pointer.direction * nearest)
		pointer.hit_distance = minf(pointer.hit_distance, nearest)
		if pointer.mode == "рука":
			pointer.spread_final.add(pointer.panel_uv * Vector2(pointer.panel.monitor_rect.size))
			_add_plane_point(pointer.spread_raw, pointer.panel, pointer.raw_origin, pointer.raw_direction)
			_add_plane_point(pointer.spread_position_only, pointer.panel, pointer.raw_origin, pointer.shoulder_direction)

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
		var target := owner_pointer.panel.pixel_at(owner_pointer.panel_uv) if owner_pointer.on_panel else Vector2.ZERO
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


## Every frame: keeps the panels' pictures current and, once a second, checks
## whether the Windows monitor layout changed (from outside or by our own buttons).
func _update_panels(delta: float) -> void:
	_monitor_check_timer += delta
	if _monitor_check_timer >= MONITOR_CHECK_SEC:
		_monitor_check_timer = 0.0
		var signature := str(ScreenCapture.list_monitors())
		if signature == _monitor_signature:
			_pending_monitor_signature = ""
		elif signature == _pending_monitor_signature:
			print("[capture] раскладка мониторов изменилась, перестраиваю панели")
			_rebuild_panels()
		else:
			_pending_monitor_signature = signature

	var copy_frames := not _diag.has("nocopy")
	var now := Time.get_ticks_msec() / 1000.0
	for panel in _panels:
		panel.refresh(_session_visible, copy_frames, now)


## One live panel per Windows monitor, arranged like the monitors are in Windows.
func _rebuild_panels() -> void:
	# The cursor may be mid-drag on a panel that is about to disappear.
	if _cursor_filter.is_held():
		MouseInput.set_button(MouseInput.BUTTON_LEFT, false)
	_cursor_filter = CursorFilter.new()
	_cursor_owner = -1
	for pointer in _pointers:
		pointer.panel = null
		pointer.on_panel = false
	for panel in _panels:
		panel.close()
	_panels.clear()
	_frames_logged = 0

	var monitors := ScreenCapture.list_monitors()
	_monitor_signature = str(monitors)
	_pending_monitor_signature = ""
	if _diag.has("nocapture") or _diag.has("nolayer"):
		return
	var hole_punch := not _diag.has("nohole")
	for i in monitors.size():
		var panel := ScreenPanel.create(i, monitors[i], _origin, hole_punch)
		if panel != null:
			add_child(panel)
			_panels.append(panel)
	if hole_punch and not _panels.is_empty():
		get_viewport().transparent_bg = true
	print("[capture] мониторов %d, панелей %d" % [monitors.size(), _panels.size()])
	_place_panels()


## Puts the panels on an arc around the user, mirroring the Windows layout.
func _place_panels() -> void:
	var rects: Array[Rect2i] = []
	var primary_index := 0
	for i in _panels.size():
		rects.append(_panels[i].monitor_rect)
		if _panels[i].primary:
			primary_index = i
	var placements := PanelLayout.arrange(rects, primary_index, Vector3(0.0, PANEL_CENTER_HEIGHT, 0.0),
			PANEL_DISTANCE, PANEL_WIDTH_DEG, PANEL_MAX_ARC_DEG)
	for i in _panels.size():
		_panels[i].place(placements[i])
		print("[layout] %s%s %s в %s -> курс %+.0f°, возвышение %+.0f°, %.2f x %.2f м" % [
				_panels[i].monitor_name, " (основной)" if _panels[i].primary else "", rects[i].size, rects[i].position,
				rad_to_deg(placements[i].heading), rad_to_deg(placements[i].elevation), placements[i].size.x, placements[i].size.y])


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
	_place_panels()
	_recentered = true
	print("[xr] сцена выровнена по взгляду, поворот %.0f°" % rad_to_deg(yaw))


func _on_xr_event(event: StringName) -> void:
	print("[xr] событие: ", event)
	# A moment after focus, so that the head pose is valid.
	if event == &"session_focussed" and not _recentered:
		get_tree().create_timer(0.5).timeout.connect(_recenter)
	if event == &"session_visible" or event == &"session_focussed":
		_session_visible = true
	elif event == &"session_stopping":
		_session_visible = false
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
	_save_settings()
	_update_ray_info()
	print("[ray] наклон луча вниз: %.0f°" % _ray_pitch_down_deg)


func _load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	# Older files predate the reworked joint-based ray; their choice and offsets no longer apply.
	if int(config.get_value("ray", "version", 0)) < SETTINGS_VERSION:
		return
	_use_runtime_aim = config.get_value("ray", "use_runtime_aim", _use_runtime_aim)
	_ray_pitch_down_deg = config.get_value("ray", "trim_pitch_down_deg", _ray_pitch_down_deg)
	_ray_yaw_right_deg = config.get_value("ray", "trim_yaw_right_deg", _ray_yaw_right_deg)
	_hand_rotation_weight = config.get_value("ray", "rotation_weight", _hand_rotation_weight)
	_aim_offset[0] = config.get_value("ray", "aim_offset_left", _aim_offset[0])
	_aim_offset[1] = config.get_value("ray", "aim_offset_right", _aim_offset[1])
	print("[settings] загружено: луч рук %s, наклон %.0f°, вбок %.1f°" % ["Meta" if _use_runtime_aim else "свой", _ray_pitch_down_deg, _ray_yaw_right_deg])


func _save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("ray", "version", SETTINGS_VERSION)
	config.set_value("ray", "use_runtime_aim", _use_runtime_aim)
	config.set_value("ray", "trim_pitch_down_deg", _ray_pitch_down_deg)
	config.set_value("ray", "trim_yaw_right_deg", _ray_yaw_right_deg)
	config.set_value("ray", "rotation_weight", _hand_rotation_weight)
	config.set_value("ray", "aim_offset_left", _aim_offset[0])
	config.set_value("ray", "aim_offset_right", _aim_offset[1])
	var error := config.save(SETTINGS_PATH)
	if error != OK:
		print("[settings] не удалось сохранить: ", error_string(error))


## Shows which hand ray is in use and how ours is set up.
func _update_ray_info() -> void:
	if _ray_source_button != null:
		_ray_source_button.set_text("Луч: Meta" if _use_runtime_aim else "Луч: свой")
	if _ray_info != null:
		_ray_info.text = "Луч рук: %s\nСвой луч: кисть %.2f / рука %.2f,\nнаклон %+.0f°, вбок %+.1f°" % [
				"Meta" if _use_runtime_aim else "свой", _hand_rotation_weight, 1.0 - _hand_rotation_weight,
				_ray_pitch_down_deg, _ray_yaw_right_deg]


func _on_rotation_weight_button(step: float) -> void:
	_hand_rotation_weight = clampf(snappedf(_hand_rotation_weight + step, 0.01), 0.0, 1.0)
	# The mix changes where the blended ray points, so its offset is re-learned at once.
	_calibration_boost_sec = AIM_CALIBRATION_BOOST_SEC
	_save_settings()
	_update_ray_info()
	print("[ray] доля поворота кисти в своём луче: %.2f" % _hand_rotation_weight)


## Back to the measured Meta-like setup: mix, no manual trim, fresh direction calibration.
func _on_ray_reset_button() -> void:
	_hand_rotation_weight = HAND_ROTATION_WEIGHT
	_ray_pitch_down_deg = RAY_PITCH_DOWN_DEG
	_ray_yaw_right_deg = RAY_YAW_RIGHT_DEG
	_calibration_boost_sec = AIM_CALIBRATION_BOOST_SEC
	_save_settings()
	_update_ray_info()
	print("[ray] свой луч сброшен к настройкам как у Meta, калибровка направления заново")


func _on_ray_source_button() -> void:
	_use_runtime_aim = not _use_runtime_aim
	_save_settings()
	_update_ray_info()
	print("[ray] источник луча рук: ", "Meta (поза прицеливания среды)" if _use_runtime_aim else "свой (по суставам)")


func _on_ray_yaw_button(step_deg: float) -> void:
	_ray_yaw_right_deg = clampf(_ray_yaw_right_deg + step_deg, -45.0, 45.0)
	_save_settings()
	_update_ray_info()
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
		# The learned offset makes our ray agree with the runtime's; the manual trim comes on top.
		# SIDE_SIGNS mirrors the trim: what is "right" for the right hand is "left" for the left one.
		var yaw := _aim_offset[index].x + deg_to_rad(_ray_yaw_right_deg) * SIDE_SIGNS[index]
		var pitch := -_aim_offset[index].y + deg_to_rad(_ray_pitch_down_deg)
		var target := PointerMath.pitch_direction(PointerMath.yaw_direction(
				PointerMath.blend_ray_direction(shoulder_direction, pointer.rotation_forward, _hand_rotation_weight), yaw), pitch)
		# The same ray without the rotation filter and without offsets: for the tremor
		# measurement and for comparing with the runtime's ray.
		var unoffset_target := PointerMath.blend_ray_direction(shoulder_direction, hand_forward, _hand_rotation_weight)
		var unfiltered_target := PointerMath.pitch_direction(PointerMath.yaw_direction(unoffset_target, yaw), pitch)
		var wrist_world := to_world * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST)
		if controller.get_has_tracking_data():
			var aim_direction := -controller.global_basis.z.normalized()
			pointer.study.add(shoulder_direction, hand_forward, aim_direction,
					wrist_world.affine_inverse() * controller.global_position,
					wrist_world.basis.orthonormalized().inverse() * aim_direction, aim_direction.angle_to(unfiltered_target))
			var difference := AimStudy.step(AimStudy.angles(unoffset_target), AimStudy.angles(aim_direction))
			var calibration_time := AIM_CALIBRATION_FAST_SEC if _calibration_boost_sec > 0.0 else AIM_CALIBRATION_SEC
			_aim_offset[index] += (difference - _aim_offset[index]) * (1.0 - exp(-delta / calibration_time))
		var ray_origin := wrist_world * Vector3(AIM_ORIGIN_IN_WRIST.x * SIDE_SIGNS[index], AIM_ORIGIN_IN_WRIST.y, AIM_ORIGIN_IN_WRIST.z)
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
	_ray_source_button = _add_button("Луч: Meta", Vector3(0.13, 0.52, -1.2), 0.6)
	_ray_source_button.activated.connect(_on_ray_source_button)

	# Mix of our own ray: how much it follows the wrist rotation versus the hand position.
	var less_rotation_button := _add_button("Кисть −", Vector3(0.13, 0.36, -1.2), 0.3)
	less_rotation_button.activated.connect(_on_rotation_weight_button.bind(-ROTATION_WEIGHT_STEP))
	var more_rotation_button := _add_button("Кисть +", Vector3(0.45, 0.36, -1.2), 0.3)
	more_rotation_button.activated.connect(_on_rotation_weight_button.bind(ROTATION_WEIGHT_STEP))
	var ray_reset_button := _add_button("Как у Meta", Vector3(0.77, 0.36, -1.2), 1.0)
	ray_reset_button.activated.connect(_on_ray_reset_button)

	_ray_info = Label3D.new()
	_ray_info.position = Vector3(-0.31, 0.5, -1.2)
	_ray_info.pixel_size = 0.001
	_ray_info.font_size = 34
	_ray_info.outline_size = 8
	add_child(_ray_info)
	_update_ray_info()

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
