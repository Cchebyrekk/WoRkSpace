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
## The first seconds after start are logged finely ([startup]): some sessions began
## at half the frame rate for 10-17 s, and the cause is to be found.
const STARTUP_PROBE_SEC := 30.0
const STARTUP_PROBE_STEP_SEC := 0.5

# Tunables for the hand pointer; they move to a settings resource with the full gesture set.
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
## How many times the restarting PowerShell starts the app again if it crashes.
const XR_CRASH_RELAUNCHES := 10
const XR_RETRY_ENV := "WORKPLACE_XR_RETRY"
## How long the layout from before "Apply" waits for the helper's answer.
const RESTORE_WAIT_MAX_SEC := 180.0
## After a restart of Quest Link the runtime may come up without hand tracking at
## first; then the app restarts once more after this long.
const XR_HANDS_RETRY_DELAY_SEC := 8.0

## A row of monitors wider than this arc is shrunk to fit, so that panels never
## wrap around behind the user.
const PANEL_MAX_ARC_DEG := 300.0
const MONITOR_CHECK_SEC := 1.0
const EXIT_HOTKEY_VIRTUAL_KEY := 0x7B  # F12, together with Ctrl+Alt+Shift

## Controller stick: wheel units per second at full deflection, and the dead zone.
const CONTROLLER_SCROLL_SPEED := 1200.0
const CONTROLLER_STICK_DEADZONE := 0.2
## Controller radial menu (held B/Y): the stick picks an item once deflected this far;
## below that, moving the controller does, as with the hand.
const CONTROLLER_MENU_STICK := 0.5
## The press is placed where the pointer was this long before the fingers touched
## (the recognition window comes on top, see _update_cursor).
const CURSOR_LOOKBACK_SEC := 0.1
const CLICK_LABELS := {-1: "—", 0: "ЛКМ", 1: "ПКМ", 2: "СКМ"}
## When the disc pose forms, the cursor goes back to where it was this long before.
const DISC_RECALL_SEC := 0.3
## Cosine between the palm normal and the direction to the head for "palm turned to the user".
const MENU_PALM_FACING := 0.6
## Swipe shortcuts per swipe_mode: [left, right], as Windows virtual-key codes.
const SWIPE_KEYS := [
	[[0x12, 0x25], [0x12, 0x27]],  # Alt+Left / Alt+Right: back / forward
	[[0x11, 0x5A], [0x11, 0x10, 0x5A]],  # Ctrl+Z / Ctrl+Shift+Z: undo / redo
]
const VK_CONTROL := 0x11
const CALIBRATION_SEC := 8.0
const POSE_CALIBRATION_SEC := 6.0
## _calibrating value for recording the scroll pose rather than a contact.
const CALIBRATE_POSE := 3
const MENU_BACKGROUND_COLOR := Color(0.05, 0.06, 0.09, 0.75)

## Tunables on the settings panel: [section, property, label, display scale, unit, step, min, max].
## Values are stored in SI units (metres, seconds); the scale converts them for display.
const TUNABLES := [
	["gestures", "pinch_press", "Щипок: сжатие", 1000.0, "мм", 0.001, 0.008, 0.035],
	["gestures", "pinch_release", "Щипок: разжатие", 1000.0, "мм", 0.002, 0.02, 0.07],
	["gestures", "side_press", "Средняя: касание бока", 1000.0, "мм", 0.002, 0.008, 0.04],
	["gestures", "side_release", "Средняя: отпускание", 1000.0, "мм", 0.002, 0.02, 0.07],
	["gestures", "confirm_delay", "Окно распознавания", 1000.0, "мс", 0.02, 0.0, 0.4],
	["pause", "max_gap", "Пауза: ладони ближе чем", 100.0, "см", 0.02, 0.02, 0.8],
	["pause", "hold_sec", "Пауза: удерживать", 1000.0, "мс", 0.1, 0.2, 2.0],
	["pause", "facing", "Пауза: ладони друг к другу", 100.0, "%", 0.05, 0.3, 0.95],
	["gestures", "swipe_mode", "Смахивание", 1.0, "", 1.0, 0.0, 1.0],
	["gestures", "swipe_distance", "Смахивание: путь руки", 100.0, "см", 0.02, 0.08, 0.4],
	["gestures", "zoom_speed", "Масштаб: скорость", 1.0 / 120.0, "щелч/м", 120.0, 120.0, 6000.0],
	["gestures", "scroll_mode", "Прокрутка: способ", 1.0, "", 1.0, 0.0, 1.0],
	["gestures", "stick_speed", "Направление: скорость", 1.0 / 120.0, "щелч/с", 120.0, 120.0, 9600.0],
	["gestures", "invert_vertical", "Направление: инверсия вверх-вниз", 1.0, "", 1.0, 0.0, 1.0],
	["gestures", "invert_horizontal", "Направление: инверсия влево-вправо", 1.0, "", 1.0, 0.0, 1.0],
	["gestures", "disc_dwell", "Прокрутка: задержка позы", 1000.0, "мс", 0.05, 0.0, 0.6],
	["gestures", "disc_radius", "Диск: радиус", 1000.0, "мм", 0.01, 0.03, 0.15],
	["gestures", "disc_turn_units", "Диск: щелчков за оборот", 1.0 / 120.0, "", 120.0, 120.0, 4800.0],
	["gestures", "disc_align", "Диск: пальцы по линии кисти", 100.0, "%", 0.05, 0.3, 1.0],
	["gestures", "disc_together", "Диск: пальцы вместе", 1000.0, "мм", 0.002, 0.01, 0.05],
	["gestures", "approach", "Начало щипка", 1000.0, "мм", 0.005, 0.025, 0.08],
	["engagement", "drop", "Покой: рука ниже глаз на", 100.0, "см", 0.02, 0.2, 0.9],
	["engagement", "ray_down_deg", "Покой: луч ниже горизонта на", 1.0, "°", 5.0, 10.0, 80.0],
	["gestures", "disc_ring_curl", "Диск: безымянный согнут", 1000.0, "мм", 0.01, 0.0, 0.15],
	["cursor", "drag_threshold", "Перетаскивание: порог", 1.0, "px", 5.0, 5.0, 150.0],
	["cursor", "drag_delay_sec", "Перетаскивание: задержка", 1000.0, "мс", 0.05, 0.0, 1.0],
	["cursor", "double_click_sec", "Двойной щелчок: окно", 1000.0, "мс", 0.1, 0.3, 2.0],
	["gestures", "grab_mode", "Перенос панели", 1.0, "", 1.0, 0.0, 3.0],
	["gestures", "fist_curl", "Кулак: пальцы у ладони", 1000.0, "мм", 0.005, 0.04, 0.11],
	["panels", "move_mode", "Перенос меняет", 1.0, "", 1.0, 0.0, 1.0],
	["panels", "magnet", "Магнит в VR", 1.0, "", 1.0, 0.0, 1.0],
	["panels", "tilt_mode", "Наклон меняет", 1.0, "", 1.0, 0.0, 1.0],
	["panels", "monitor_menu", "Меню экранов", 1.0, "", 1.0, 0.0, 1.0],
	["world", "travel_mode", "Режим движения", 1.0, "", 1.0, 0.0, 1.0],
	["world", "move_speed", "Скорость движения", 1.0, "м/с", 0.5, 0.5, 10.0],
	["world", "hand_reach", "Ход руки до полной скорости", 100.0, "см", 0.01, 0.05, 0.4],
	["gestures", "ring_tilt_degrees", "Наклон кольца (движение и прокрутка)", 1.0, "°", 15.0, 0.0, 90.0],
	["world", "turn_mode", "Поворот", 1.0, "", 1.0, 0.0, 2.0],
	["world", "snap_degrees", "Поворот рывком на", 1.0, "°", 5.0, 10.0, 90.0],
	["world", "turn_speed_degrees", "Плавный поворот: скорость", 1.0, "°/с", 15.0, 15.0, 360.0],
	["world", "vignette", "Затемнение краёв при движении", 100.0, "%", 0.1, 0.0, 1.0],
	["world", "grid", "Сетка точками", 1.0, "", 1.0, 0.0, 1.0],
	["world", "grid_step", "Сетка: шаг", 1.0, "м", 0.25, 0.25, 5.0],
	["world", "render_radius", "Радиус отрисовки экранов", 1.0, "м", 1.0, 0.0, 100.0],
	["world", "interact_radius", "Радиус нажатий по экранам", 1.0, "м", 1.0, 0.0, 50.0],
	["world", "stick_mode", "Стик контроллера", 1.0, "", 1.0, 0.0, 2.0],
]

const EXIT_BUTTON_HOLD_SEC := 1.0
const TOPOLOGY_MESSAGES := {
	"detached": "экран отсоединён",
	"attached": "экран присоединён",
	"last_screen": "это последний экран, убирать нельзя",
	"no_free_screen": "свободных экранов нет — добавьте экземпляр на вкладке «Драйвер»",
	"arranged": "раскладка Windows изменена",
	"saved": "исходная раскладка запомнена",
	"restored": "исходная раскладка возвращена",
	"no_backup": "исходная раскладка не запомнена",
}
## Grabbing a screen panel: by the bar under it (move) or by its corner (resize in VR only).
const GRAB_MOVE := 1
const GRAB_RESIZE := 2
const PANEL_SCALE_MIN := 0.5
const PANEL_SCALE_MAX := 2.5
## A fist lets go only once the fingers open this much further than it took to close.
const FIST_RELEASE_MARGIN := 0.015
## A thumb this straight and this far from the palm is up, so the hand is no fist
## (logged 20.10.2026: thumb up 0.98 / 94 mm, thumb over a fist 0.84-0.89 / 64-69 mm).
const FIST_DWELL_SEC := 0.15
const FIST_THUMB_UP_STRAIGHT := 0.94
const FIST_THUMB_UP_DISTANCE := 0.082
## A monitor's menu floats this far in front of its panel (metres).
const MONITOR_MENU_FORWARD := 0.25
## Driver section of the settings panel: where it is, the instance limit (as in
## tools/vdd_helper.ps1) and how long "Применить" has to be held.
## Settings panel tabs, and which tab each tunable is on (the rest are on the first,
## "Жесты": everything about recognising the hands — touches, pause, swipe, zoom,
## rest, fist, the ring's tilt and the moving hand's reach; 20.10.2026 the user
## asked for every setting to sit on the tab it belongs to).
const SETTINGS_TABS := ["Жесты", "Прокрутка", "Курсор", "Луч", "Панели", "Раскладки", "Драйвер", "Назначения", "Мир", "Заготовки", "Меню"]
const TUNABLE_TABS := {
	"scroll_mode": 1, "stick_speed": 1, "invert_vertical": 1, "invert_horizontal": 1, "disc_dwell": 1,
	"disc_radius": 1, "disc_turn_units": 1, "disc_align": 1, "disc_together": 1, "disc_ring_curl": 1,
	"drag_threshold": 2, "drag_delay_sec": 2, "double_click_sec": 2,
	"grab_mode": 4, "move_mode": 4, "magnet": 4, "tilt_mode": 4, "monitor_menu": 4,
	"travel_mode": 8, "move_speed": 8, "turn_mode": 8, "snap_degrees": 8, "turn_speed_degrees": 8,
	"vignette": 8, "grid": 8, "grid_step": 8, "render_radius": 8, "interact_radius": 8, "stick_mode": 8,
}
## The sliders of the settings rows (see VrSlider).
var _sliders: Array[VrSlider] = []
## A tab with more rows than this lays them out in two columns.
const SETTINGS_ROWS_PER_COLUMN := 11
## Where the column of tab buttons stands, left of the content.
const SETTINGS_TAB_COLUMN_X := -1.25
## Saved arrangements on the "Раскладки" tab.
const LAYOUT_SLOTS := 4
const DRIVER_MAX_INSTANCES := 8
const DRIVER_APPLY_HOLD_SEC := 2.0
## Room between rows of panels for the handles under them (metres).
const ROW_GAP := 0.07
## A carried panel is let go only after the grip (fist, pinch, trigger) or the
## tracking has been lost this long: tracking drops out for a moment now and then.
const FIST_GRACE_SEC := 0.5
const GRAB_GRACE_SEC := 0.25
## Magnets in VR: placement within this angle, size within this share.
const MAGNET_REACH_DEG := 3.0
const SIZE_MAGNET_SHARE := 0.04
## Tilt grip: degrees of tilt per degree the hand moves up or down.
const TILT_GAIN := 2.0
## Curve grip: curvature (0..1) per radian the hand moves sideways, and its magnet.
const CURVE_GAIN := 3.0
const CURVE_MAGNET := 0.05


## Panel options on the settings panel (section [panels]).
class PanelOptions:
	## What moving a panel by its handle changes: 0 = the Windows layout (the panels
	## follow it), 1 = only where the panel is in VR.
	var move_mode := 0
	## Magnet for placing and sizing panels in VR: 1 = on.
	var magnet := 1
	## What the tilt grip changes: 0 = the panel's whole row, 1 = that panel only.
	var tilt_mode := 0
	## The grip that opens a monitor's menu (resolution, refresh rate, scale): 1 = shown.
	var monitor_menu := 0


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


## Quest Link can drop the session without a word (20.10.2026, after «Применить»:
## no session_stopping or instance_exiting, the state stayed "focused", the hand
## trackers stayed registered, and only xrWaitFrame answered XR_ERROR_SESSION_LOST,
## which Godot prints every frame). This logger watches the engine's output for it.
## A headset resting on the table does not lose the session, so it does not count.
## Called from any thread; it only sets a flag.
class SessionLossLogger extends Logger:
	var lost := false

	func _log_message(message: String, _error: bool) -> void:
		if not lost and message.contains("XR_ERROR_SESSION_LOST"):
			lost = true

	func _log_error(_function: String, _file: String, _line: int, code: String, rationale: String, _editor_notify: bool,
			_error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if not lost and (code.contains("XR_ERROR_SESSION_LOST") or rationale.contains("XR_ERROR_SESSION_LOST")):
			lost = true


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
	var gestures := HandGestures.new()
	## The mouse button this pointer holds (hand gesture or controller button), or NONE.
	var button := HandGestures.Click.NONE
	## A hand gesture is being recognised, or the wheel pose is on: keep the cursor still.
	var pending := false
	var scrolling := false
	## Wheel units produced this frame; positive scrolls up.
	var scroll := 0.0
	var disc := ScrollDisc.new()
	var stick := ScrollStick.new()
	## The scroll pose uses the stick (not the disc) this time.
	var using_stick := false
	var fingertips := Vector3.ZERO
	## Horizontal wheel units produced this frame; positive scrolls right.
	var hscroll := 0.0
	## Took part in a two-hand zoom: its pinch presses nothing until it opens (the
	## hand still pinching when the other let go clicked where the cursor was).
	var zoom_held := false
	var disc_shown := false
	var engagement := HandEngagement.new()
	## Hand data for the two-hand gestures, the menu and calibration (world space).
	var tracked_hand := false
	var palm_world := Vector3.ZERO
	var palm_normal := Vector3.ZERO
	var pinch_point := Vector3.ZERO
	## Thumb to index tip, to middle tip, to the side of the index (metres).
	var contact_distances := Vector3.ONE
	## The scroll pose's measurements, for calibrating it (see ExtraGestures.calibrate_pose).
	var pose_features := PackedFloat32Array()
	## The hand's joints this frame (tracker space) and its shape (HandPose
	## features); empty while the hand is not tracked.
	var hand_joints := PackedVector3Array()
	var hand_features := PackedFloat32Array()
	## A recogniser per pose action ("scroll", "grab", "move", "turn") and which of
	## those actions' poses this hand holds now (GestureCatalog bindings).
	var pose_matchers := {}
	var poses := {}
	## The hand is within range of one of the user's own bound poses (before its
	## dwell too): the built-in fist then stays off, the recorded pose wins.
	var near_own_pose := false
	## The built-in scroll pose gives way: a recorded pose fits this hand better.
	var scroll_yields := false
	## When the built-in fist started forming (NAN when it is not), for its dwell.
	var fist_since := NAN
	## The palm in the rig's own space (tracker space): moving the rig does not move
	## it, so the moving hand's offset stays the hand's own.
	var palm_local := Vector3.ZERO
	## Moving / turning: where the hand was when its pose formed (rig space), by action.
	var travel_anchors := {}
	var snap_turn := Locomotion.SnapTurn.new()
	## Dragging a sphere's radius handle: the sphere's id (-1 = not), its radius and
	## the hand's distance from its centre when taken, and how long the press was lost.
	var radius_fixture := -1
	var radius_start := 0.0
	var radius_start_distance := 0.0
	var radius_lost := 0.0
	## The settings slider this pointer is dragging, or null.
	var slider: VrSlider
	## The ring shown for moving or turning: which action ("" = none) and the hand's
	## offset in the plane facing the user (sideways, up), metres.
	var travel_ring := ""
	var travel_offset := Vector2.ZERO
	var menu := MenuSet.Navigator.new()
	## Which finger opened the menu (0 middle, 1 ring, 2 little): it holds it open.
	var menu_finger := 0
	var menu_open := false
	var menu_selected := ""
	## Pointer mode that opened the menu: if the hand and the controller swap while
	## it is open, it closes without running anything.
	var menu_mode := ""
	var swipe := ExtraGestures.Swipe.new()
	## For the log and the rest decision: palm below the eyes (m) and ray angle to the horizon (rad).
	var palm_drop := 0.0
	var ray_elevation := 0.0
	## When the gesture just decided began (see HandGestures.Output.anchor_time), else NAN.
	var anchor_time := NAN
	## The hand has just taken the disc pose (it may have dragged the cursor while forming it).
	var disc_pose_started := false
	var on_panel := false
	## The nearest screen panel the ray hits, and where: 0..1 from its top-left corner.
	var panel: ScreenPanel
	var panel_uv := Vector2.ZERO
	## Fist (all four fingertips at the palm), and the frame it closed; only in fist grab mode.
	var fist := false
	var fist_started := false
	## The farthest fingertip from the palm (mm), for the log: tuning the fist threshold.
	var fist_mm := 0.0
	## The panel this pointer moves or resizes, or null; GRAB_MOVE or GRAB_RESIZE.
	var grab_panel: ScreenPanel
	var grab_kind := 0
	## Held by a fist rather than by a pinch / trigger.
	var grab_by_fist := false
	## Where on the panel it was grabbed: (heading, elevation) from the panel's centre.
	var grab_offset := Vector2.ZERO
	## Resize: the scale and the angle from the panel's centre when grabbed.
	var grab_scale := 1.0
	var grab_angle := 1.0
	## Resize: where the panel's centre was when grabbed (heading, elevation).
	var grab_centre := Vector2.ZERO
	## How long the grip or the tracking has been lost while carrying.
	var grab_lost_sec := 0.0
	## Where the ray was when grabbed (heading, elevation), and the tilt or curvature then.
	var grab_start := Vector2.ZERO
	var grab_value := 0.0
	## Free placement: what the magnet held last frame (NAN = nothing).
	var snap_held := Vector2(NAN, NAN)


var _origin: XROrigin3D
var _camera: XRCamera3D
var _controllers: Array[XRController3D] = []
## Last interaction profile seen per side, for the log.
var _controller_profiles: Array[String] = ["", ""]
var _controller_visuals: Array[Node3D] = []
var _joint_meshes: Array[MultiMeshInstance3D] = []
var _pointers: Array[Pointer] = [Pointer.new(), Pointer.new()]
var _rays: Array[Node3D] = []
var _buttons: Array[VrButton] = []
var _topology: DisplayTopology
var _vdd: VddControl
var _vdd_message := ""
var _status: Label3D
## Whether the agent reports the secure desktop up (UAC, lock screen, Ctrl+Alt+Del).
var _secure_desktop := false
## The secure desktop's picture, captured by the agent and shown on a quad in VR.
var _secure := SecureDesktop.new()
var _secure_viewport: SubViewport
var _secure_rect: TextureRect
var _secure_layer: OpenXRCompositionLayerQuad
var _secure_shown := false
## The quad's world transform and size (m) while shown, for mapping the laser onto it.
var _secure_quad_xf := Transform3D.IDENTITY
var _secure_quad_size := Vector2.ZERO
## The captured monitor: top-left on the virtual desktop and size in pixels.
var _secure_origin := Vector2i.ZERO
var _secure_pixels := Vector2i.ZERO
## The mouse button the secure cursor holds, or NONE.
var _secure_button := HandGestures.Click.NONE
## Which pointer pressed `_secure_button`: it alone can let go of it.
var _secure_press_pointer := 0
## Which pointer drives the cursor on the secure desktop (-1: none yet).
var _secure_cursor_pointer := -1
## How tall the secure-desktop quad stands in VR, in metres.
const SECURE_QUAD_HEIGHT := 0.9
const SECURE_QUAD_DISTANCE := 1.3
var _log_timer := 0.0
var _xr_ready := false
var _xr: OpenXRInterface
## One live panel per Windows monitor, in the order of ScreenCapture.list_monitors().
var _panels: Array[ScreenPanel] = []
## What the monitor list looked like when the panels were built; a change rebuilds them.
var _monitor_signature := ""
## A changed list has to be seen twice in a row: during a topology change it flickers.
var _pending_monitor_signature := ""
## "Apply" in the driver section: the layout is being remembered before the restart.
var _driver_saving_layout := false
## Set after the restart "Apply" brought: the panels' first build puts the layout back.
var _restore_after_apply := false
## "Apply" was sent with the layout remembered: kept in the settings across the restart.
var _driver_restore_pending := false
## The helper request of that "Apply": the layout goes back once it is answered.
var _driver_restore_request := ""
var _restore_wait_started := 0.0
var _monitor_check_timer := 0.0
## Moving a panel: the layout when it was grabbed, which panel is primary, and
## the layout as it would be if let go now (the other panels already show it).
var _drag_rects: Array[Rect2i] = []
var _drag_primary := 0
var _drag_preview: Array[Rect2i] = []
## Sent to Windows and not yet seen back: the panels keep showing it meanwhile.
var _layout_pending: Array[Rect2i] = []
## VR-only panel size per monitor name.
var _panel_scales := {}
## Panels placed freely in VR (outside the layout): monitor name -> (heading, elevation).
var _panel_positions := {}
var _panel_options := PanelOptions.new()
## A layout to send to Windows once the one being applied is done.
var _queued_positions := {}
## Tilt per monitor name and per row (key: row from the primary's, as a string),
## in radians; neither = facing the eye. Curvature per monitor name, 0..1.
var _panel_pitches := {}
var _row_pitches := {}
var _panel_curvatures := {}
## The panel arrangement of each way of moving them: "windows" (the panels follow
## the Windows layout) and "vr" (placed freely); the active one is in the
## _panel_* variables. See _own_arrangement().
var _arrangements := {"windows": {}, "vr": {}}
## Saved arrangements ("1".."4"): see _on_slot_save().
var _layout_slots := {}
## A saved arrangement being loaded: screens are added or removed one by one first.
var _slot_loading := {}
var _slot_load_steps := 0
## The number of panels the step under way should lead to, or -1.
var _slot_waiting_count := -1
var _slot_labels: Array[Label3D] = []
var _layout_status: Label3D
## Settings panel tabs.
var _settings_tabs: Array[Node3D] = []
var _settings_tab_buttons: Array[VrButton] = []
## The menu of one monitor (resolution, refresh rate, scale), shown on demand.
var _monitor_menu: MonitorMenu
## The monitor whose mode was just changed from its menu: the layout is checked
## once Windows has it (a bigger monitor may overlap its neighbours).
var _mode_change_monitor := ""
## Driver section of the settings panel: working instances now and wanted, the
## resolutions in the driver's file now and wanted.
var _driver_count := -1
var _driver_target := -1
var _driver_resolutions: Array[Vector2i] = []
var _driver_selected: Array[Vector2i] = []
var _driver_count_label: Label3D
var _driver_status: Label3D
var _driver_apply: VrButton
var _driver_chips := {}
var _session_visible := false
var _frames_logged := 0
## The startup probe: frames, the longest frame and capture frames over the current step.
var _probe_step_sec := 0.0
var _probe_frames := 0
var _probe_max_frame_sec := 0.0
var _probe_capture_frames := 0
## Where the time of _process went, by part (µs), in this frame and in the last one.
const PROBE_PARTS: Array[String] = ["панели", "сессия", "руки", "жесты и перенос", "защищённый стол", "курсор и лучи", "строка состояния"]
var _probe_parts := PackedInt64Array()
var _probe_mark_usec := 0
## Pipeline compilation counters as last logged (see _probe_pipelines).
var _probe_pipelines_seen := PackedInt64Array()
## A frame longer than this during the probe is logged with its parts.
const PROBE_LONG_FRAME_SEC := 0.03
var _cursor_filter := CursorFilter.new()
## The button the Windows cursor currently holds, released with the same button.
var _cursor_button := HandGestures.Click.NONE
## Fractions of a wheel unit carried over between frames.
var _scroll_remainder := 0.0
var _hscroll_remainder := 0.0
## Two-hand gestures: pause toggle and Ctrl+wheel zoom.
var _pause := ExtraGestures.Pause.new()
var _hands_paused := false
var _zoom_active := false
var _zoom_last_gap := 0.0
var _zoom_remainder := 0.0
## Calibration: which contact is being recorded (0 = thumb-index tip, 2 = side), or -1.
var _calibrating := -1
var _calibration_end := 0.0
var _calibration_samples := PackedFloat32Array()
var _pose_samples: Array[PackedFloat32Array] = []
## Per hand: the radial menu's dark background disc.
var _menu_backgrounds: Array[MeshInstance3D] = []
var _calibration_status: Label3D
## Per hand: the radial menu's labels.
var _menu_labels: Array = [[], []]
## The radial menu's categories and how it opens (MenuSet; [menus] in settings).
var _menus: Array = MenuSet.default_menus()
var _menu_mode := MenuSet.MODE_TWO_LEVEL
var _menu_editor: MenuEditor
var _scroll_logged := 0.0
## Shared by both hands' recognisers; tuned on the settings panel.
var _gesture_settings := HandGestures.Settings.new()
## What each action is bound to (GestureCatalog), the poses the user recorded and
## the built-in locomotion sign. Saved in [bindings] and [poses].
var _bindings: Dictionary = GestureCatalog.DEFAULTS.duplicate()
var _custom_poses: Array[HandPose.Template] = []
var _next_custom_pose := 1
var _move_template := GestureCatalog.move_template()
## Which hand moves with the movement pose (0 left, 1 right); the other one turns.
var _move_hand := 0
## The world (slice i): its settings, the floor's height (gravity walks on it), the
## orientation dots, the floor, the comfort vignette and what moved last frame.
var _world := Locomotion.Options.new()
var _floor_height := 0.0
var _grid: MultiMeshInstance3D
var _grid_key := ""
var _floor: MeshInstance3D
var _vignette: MeshInstance3D
var _vignette_material: ShaderMaterial
var _floor_label: Label3D
## Per hand: [outer ring, dead-zone ring, marker] shown while moving or turning.
var _travel_rings: Array = []
## The world's fixtures (slice j: spheres) and the one the user sits in (its id, or -1).
var _fixtures: Array[WorldLayout.Fixture] = WorldLayout.default_fixtures(PackedStringArray())
var _seated := -1
## Smooth turning on now, and its top speed so far (degrees per second), for the log.
var _smooth_turning := false
var _smooth_turn_peak := 0.0
## "Сесть": floats before the user near a sphere they are not seated in.
var _sit_button: VrButton
var _sit_offer: WorldLayout.Fixture
## Beyond its radius plus this, a sphere no longer offers its seat (metres).
const SEAT_REACH := 1.0
## The "Заготовки" tab: a row per fixture and a row per monitor (pools, shown as needed).
const FIXTURE_ROWS := 6
const FIXTURE_MONITOR_ROWS := 8
const FIXTURE_RADIUS_STEP := 0.1
var _fixture_rows: Array[Node3D] = []
var _fixture_monitor_rows: Array[Node3D] = []
var _fixture_status: Label3D
## Each sphere's radius handle (one per sphere, pooled) and its label.
var _radius_handles: Array[MeshInstance3D] = []
var _radius_labels: Array[Label3D] = []
## A handle's hit area (metres around it): larger than drawn, a hand ray is not steady.
const RADIUS_HANDLE_HIT := 0.07
## Controller sticks turning in steps: a separate step logic per controller.
var _stick_snap: Array[Locomotion.SnapTurn] = []
## Stick values treated like a hand's offset (metres): full tilt = this far.
const STICK_AS_REACH := 0.15
## How far ahead of the fingertips (away from the user) the moving/turning ring floats.
const TRAVEL_RING_AHEAD := 0.04
const GRID_RADIUS_FLOOR := 12.0
const GRID_RADIUS_SPACE := 5.0
## The "Назначения" tab: a choice button and a preview per action, the open list
## of choices (one action at a time) and the user's own poses.
var _binding_buttons := {}
var _binding_previews := {}
var _binding_menu_action := ""
var _binding_menu_title: Label3D
var _binding_options: Array[VrButton] = []
var _binding_option_previews: Array[HandPreview] = []
var _binding_option_ids: Array[String] = []
var _move_hand_button: VrButton
var _pose_status: Label3D
var _pose_rows: Array[Node3D] = []
## Recording a pose: which hand (-1 = not recording), until when the countdown
## or the recording runs, and what was recorded.
var _pose_recording := -1
var _pose_recording_until := 0.0
var _pose_recording_started := false
var _pose_record_samples: Array[PackedFloat32Array] = []
var _pose_record_joints: Array[PackedVector3Array] = []
const POSE_COUNTDOWN_SEC := 3.0
const POSE_RECORD_SEC := 5.0
const BINDING_MENU_ROWS := 12
const POSE_ROWS := 6
var _engagement_settings := HandEngagement.Settings.new()
var _disc_rings: Array[MeshInstance3D] = []
var _disc_markers: Array[MeshInstance3D] = []
var _settings_root: Node3D
var _settings_values: Array[Label3D] = []
## Index of the pointer that drives the Windows cursor, or -1.
var _cursor_owner := -1
var _cursor_press_armed := false
var _recentered := false
## Temporary: log every hand's pose ([pose]) to design the locomotion gesture from
## the sign the user shows (20.10.2026). Turn off once the gesture is in.
const POSE_LOG := false
const POSE_LOG_STEP_SEC := 0.25
var _pose_log_next: Array[float] = [0.0, 0.0]
## Seconds since focus while waiting for a tracked head to align the scene; -1 when not waiting.
var _recenter_wait_sec := -1.0
## Align anyway after this long without a tracked head.
const RECENTER_MAX_WAIT_SEC := 0.5
## Shader warm-up: tiny copies of every kind of material in front of the eyes for
## the first visible frames. The D3D12 driver keeps no pipeline cache, so each run
## built shaders the first time something came into view: two ~110 ms frames
## (first frame, then the panels after aligning; 19.10.2026). Now all at once, in
## the first frame, while the runtime is still fading in.
var _shaders_warmed := false
var _warm_up_nodes: Array[Node3D] = []
var _warm_up_frames := 0
const WARM_UP_FRAMES := 4
const WARM_UP_DISTANCE := 0.5
## Small enough to cover no pixel; a draw is still issued, which is what builds the shader.
const WARM_UP_SCALE := 0.0005
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
var _session_loss := SessionLossLogger.new()


func _ready() -> void:
	OS.add_logger(_session_loss)
	_build_world()
	_build_rig()
	_build_world_visuals()
	# The status line goes with the user through the world (slice i).
	_status.reparent(_origin, false)
	for pointer in _pointers:
		pointer.gestures.settings = _gesture_settings
		pointer.engagement.settings = _engagement_settings
	_build_helpers()
	_build_seat_button()
	_build_radius_handles()
	_build_settings_panel()
	_load_settings()
	_refresh_floor_label()
	_sync_menu_editor()
	_update_ray_info()
	_refresh_layout_section()
	_refresh_settings_panel()
	# The layout as it was before this session, for the emergency exit. Not after a
	# self-restart: by then the layout may already have been changed here.
	if OS.get_environment(XR_RETRY_ENV) == "":
		_topology.save_layout()
	_take_restore_after_apply()
	_count_instances_when_free()

	_hotkey = GlobalHotkey.new()
	if _hotkey.start(true, true, true, EXIT_HOTKEY_VIRTUAL_KEY):
		print("[app] аварийный выход: Ctrl+Alt+Shift+F12")
	else:
		print("[app] не удалось занять Ctrl+Alt+Shift+F12 — сочетание уже используется")
	# The WoRkPlaceAgent service (tools/install_agent.ps1) carries the input to
	# elevated windows and the secure desktop; without it the app injects itself.
	print("[input] агент ввода: ", "подключён" if MouseInput.is_agent_connected() else "нет (окна администратора и UAC недоступны)")

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
	var retry_attempt := OS.get_environment(XR_RETRY_ENV).to_int()
	if retry_attempt > 0:
		print("[xr] сессия восстановлена после перезапуска, попытка ", retry_attempt)
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
		# Back too early after Quest Link restarted: the runtime is up but without
		# hand tracking for the whole session (18.10.2026). Try again a bit later.
		if retry_attempt > 0 and not openxr.is_hand_tracking_supported() and retry_attempt < XR_RESTART_MAX_ATTEMPTS:
			print("[xr] после перезапуска Link руки ещё недоступны, перезапускаюсь ещё раз")
			get_tree().create_timer(XR_HANDS_RETRY_DELAY_SEC).timeout.connect(_restart_app.bind(retry_attempt + 1))
		openxr.session_begun.connect(_on_session_begun.bind(openxr))
		# Holding the Meta button re-centres the headset's view; the scene follows.
		if openxr.has_signal(&"pose_recentered"):
			openxr.connect(&"pose_recentered", _on_pose_recentered)
		for event: StringName in [&"session_stopping", &"session_focussed", &"session_visible", &"session_loss_pending", &"instance_exiting"]:
			openxr.connect(event, _on_xr_event.bind(event))

	if not _diag.is_empty():
		print("[diag] ", _diag)
	_rebuild_panels()


func _process(delta: float) -> void:
	if _hotkey != null and _hotkey.consume_pressed():
		print("[app] нажато Ctrl+Alt+Shift+F12")
		_quit(true)
		return
	if not _xr_ready:
		return
	_update_startup_probe(delta)
	_update_first_recenter(delta)
	_update_shader_warm_up()
	_probe_mark(-1)
	# The rig moves first, so this frame's rays and panels start from where the user is.
	_update_locomotion(delta)
	_update_world_visuals()
	_update_panels(delta)
	_probe_mark(0)
	_calibration_boost_sec = maxf(_calibration_boost_sec - delta, 0.0)
	_update_xr_session(delta)
	_probe_mark(1)

	var lines: PackedStringArray = []
	for i in 2:
		var joints := _update_hand(i)
		_update_pointer(i, delta)
		var controller := _controllers[i]
		var pointer := _pointers[i]
		# With the hand interaction profile the controller node is tracked for bare hands too.
		_controller_visuals[i].visible = pointer.mode == "контроллер"
		if pointer.mode == "покой":
			_joint_meshes[i].visible = false
		lines.append("%s: суставов %d/%d (источник: %s) | контроллер: %s, триггер %.2f, grip %.2f, стик %s | луч: %s%s" % [
			SIDE_LABELS[i], joints, XRHandTracker.HAND_JOINT_MAX, _hand_source_label(i),
			"да" if controller.get_has_tracking_data() else "нет",
			controller.get_float(&"trigger"), controller.get_float(&"grip"),
			controller.get_vector2(&"primary"),
			pointer.mode, (", " + CLICK_LABELS[pointer.button]) if pointer.pressed else (", колесо" if pointer.scrolling else (", распознаю" if pointer.pending else "")),
		])
		if pointer.mode == "рука" or pointer.mode == "покой":
			lines[-1] += " | щипок %.0f мм, луч %s, ниже глаз %.0f см, луч %+.0f°, кулак %.0f мм" % [pointer.pinch_mm,
					"Meta" if pointer.runtime_aim else "свой", pointer.palm_drop * 100.0, rad_to_deg(pointer.ray_elevation), pointer.fist_mm]
		if pointer.grab_panel != null:
			lines[-1] += " | %s %s" % ["переношу" if pointer.grab_kind == GRAB_MOVE else "меняю размер", pointer.grab_panel.monitor_name]
		for action: String in ["move", "turn"]:
			if pointer.poses.get(action, false):
				lines[-1] += " | %s (%s)" % [GestureCatalog.label_of(action).to_upper(), GestureCatalog.name_of(_bindings[action], _custom_poses)]
	_probe_mark(2)

	_update_two_hand_gestures()
	_update_calibration()
	_update_pose_recording()
	_update_grabs(delta)
	_update_radius_handles(delta)
	_place_monitor_menu()
	_update_buttons(delta)
	_update_sliders()
	if _menu_editor != null:
		_menu_editor.update(_pointers)
	_probe_mark(3)
	# Before the cursor (which it replaces while shown) and the rays (which end on its quad).
	_update_secure_desktop()
	_probe_mark(4)
	_update_cursor()
	_update_rays()
	_probe_mark(5)

	if _secure_desktop:
		lines.append("ЗАЩИЩЁННЫЙ РАБОЧИЙ СТОЛ (запрос администратора / экран блокировки) — виден через агента")
	if _hands_paused:
		lines.append("УПРАВЛЕНИЕ НА ПАУЗЕ (руки и контроллеры) — ладони друг к другу, чтобы продолжить")
	lines.append("Экранов Windows: %d  |  наклон луча %.0f°, вбок %.1f°%s" % [DisplayServer.get_screen_count(), _ray_pitch_down_deg, _ray_yaw_right_deg, ("  |  " + _vdd_message) if _vdd_message != "" else ""])
	_status.text = "\n".join(lines)
	_probe_mark(6)

	_log_timer += delta
	if _log_timer >= LOG_INTERVAL_SEC:
		_log_timer = 0.0
		_log_tremor()
		var frames := 0
		for panel in _panels:
			frames += panel.capture.get_frame_count()
		lines.append("Панелей %d, кадров захвата за интервал %d, FPS %d" % [_panels.size(), frames - _frames_logged, Engine.get_frames_per_second()])
		if _scroll_logged != 0.0:
			lines.append("Колесо за интервал: %+d (%.1f щелчка)" % [int(_scroll_logged), _scroll_logged / 120.0])
			_scroll_logged = 0.0
		_frames_logged = frames
		for line in lines:
			print("[track] ", line)


## For the first STARTUP_PROBE_SEC after start, every STARTUP_PROBE_STEP_SEC: frames,
## the longest frame, the render time of the last frame on the CPU and the GPU,
## how many panels redraw and how many capture frames came. Tells a slow GPU (a
## shader compiling, many panels drawing) from a runtime that halved the rate.
func _update_startup_probe(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now > STARTUP_PROBE_SEC:
		_probe_parts.clear()
		return
	var viewport_rid := get_viewport().get_viewport_rid()
	if _probe_frames == 0 and _probe_step_sec == 0.0:
		RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	# A long frame: what the last _process spent by part, the render of the last
	# frame, and the rest (the engine outside _process, timers and signals, and the
	# wait for the OpenXR runtime's next frame).
	if delta > PROBE_LONG_FRAME_SEC and _probe_parts.size() == PROBE_PARTS.size():
		var described: PackedStringArray = []
		var spent := 0
		for i in PROBE_PARTS.size():
			spent += _probe_parts[i]
			if _probe_parts[i] >= 1000:
				described.append("%s %.0f" % [PROBE_PARTS[i], _probe_parts[i] / 1000.0])
		var render_cpu := RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		print("[startup] %.2f с: кадр %.0f мс — _process %.1f мс (%s), отрисовка ЦП %.1f / ГП %.1f мс, вне этого %.0f мс; %s" % [
				now, delta * 1000.0, spent / 1000.0, ", ".join(described) if not described.is_empty() else "всё меньше 1 мс",
				render_cpu, RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid),
				delta * 1000.0 - spent / 1000.0 - render_cpu, _probe_pipelines()])
	_probe_frames += 1
	_probe_max_frame_sec = maxf(_probe_max_frame_sec, delta)
	_probe_step_sec += delta
	if _probe_step_sec < STARTUP_PROBE_STEP_SEC:
		return
	var frames := 0
	var redrawing := 0
	for panel in _panels:
		frames += panel.capture.get_frame_count()
		if panel.is_redrawing():
			redrawing += 1
	print("[startup] %.1f с: кадров %d (%.0f/с), самый долгий %.0f мс, отрисовка ЦП %.1f / ГП %.1f мс, панелей %d (перерисовываются %d), кадров захвата %d, сессия %s; %s" % [
			now, _probe_frames, _probe_frames / _probe_step_sec, _probe_max_frame_sec * 1000.0,
			RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid),
			RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid),
			_panels.size(), redrawing, maxi(frames - _probe_capture_frames, 0), "видна" if _session_visible else "не видна", _probe_pipelines()])
	_probe_capture_frames = frames
	_probe_frames = 0
	_probe_max_frame_sec = 0.0
	_probe_step_sec = 0.0
	if now + STARTUP_PROBE_STEP_SEC > STARTUP_PROBE_SEC:
		RenderingServer.viewport_set_measure_render_time(viewport_rid, false)


## The first alignment after focus: on the first frame with a tracked head (or
## after RECENTER_MAX_WAIT_SEC), not a fixed half second later.
func _update_first_recenter(delta: float) -> void:
	if _recenter_wait_sec < 0.0:
		return
	_recenter_wait_sec += delta
	var head := XRServer.get_tracker(&"head") as XRPositionalTracker
	var pose: XRPose = head.get_pose(&"default") if head != null else null
	var tracked := pose != null and pose.has_tracking_data
	if tracked or _recenter_wait_sec >= RECENTER_MAX_WAIT_SEC:
		print("[xr] выравниваю сцену через %.2f с после фокуса (%s)" % [_recenter_wait_sec, "голова отслеживается" if tracked else "голова не отслеживается"])
		_recenter_wait_sec = -1.0
		_recenter()


## Puts a tiny copy of each distinct mesh/material and Label3D style in the scene
## right in front of the camera, so that their shaders are built in the first
## visible frames rather than whenever each first comes into view.
func _warm_up_shaders() -> void:
	_shaders_warmed = true
	var seen := {}
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		var key := _warm_up_key(node)
		if key == "" or seen.has(key):
			continue
		seen[key] = true
		var copy := node.duplicate(0) as GeometryInstance3D
		for child in copy.get_children():
			copy.remove_child(child)
			child.free()
		copy.visible = true
		_camera.add_child(copy)
		copy.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * WARM_UP_SCALE), Vector3(0.0, 0.0, -WARM_UP_DISTANCE))
		_warm_up_nodes.append(copy)
	_warm_up_frames = WARM_UP_FRAMES
	print("[startup] прогрев шейдеров: %d образцов" % _warm_up_nodes.size())


## What decides a node's shader, or "" for a node that draws nothing of its own.
func _warm_up_key(node: Node) -> String:
	if node is Label3D:
		var label := node as Label3D
		return "label|%s|%d|%s|%s|%s|%d|%d|%s" % [label.font, label.billboard, label.no_depth_test, label.shaded, label.double_sided,
				label.alpha_cut, label.render_priority, label.fixed_size]
	if node is MeshInstance3D:
		var instance := node as MeshInstance3D
		if instance.mesh == null:
			return ""
		var materials: PackedStringArray = [str(instance.material_override)]
		for i in instance.mesh.get_surface_count():
			materials.append(str(instance.get_active_material(i)))
		return "mesh|%s|%s|%s" % [instance.mesh.get_class(), instance.cast_shadow, "|".join(materials)]
	if node is MultiMeshInstance3D:
		# Hand previews and the like: by mesh kind and material settings (each
		# instance has its own material object, but the same shader).
		var multi := node as MultiMeshInstance3D
		if multi.multimesh == null or multi.multimesh.mesh == null or multi.multimesh.instance_count == 0:
			return ""
		var material := multi.material_override as BaseMaterial3D
		return "multimesh|%s|%s|%s|%s" % [multi.multimesh.mesh.get_class(), multi.multimesh.use_colors,
				material.shading_mode if material != null else -1, material.vertex_color_use_as_albedo if material != null else false]
	return ""


func _update_shader_warm_up() -> void:
	if _warm_up_frames <= 0:
		return
	_warm_up_frames -= 1
	if _warm_up_frames == 0:
		for copy in _warm_up_nodes:
			copy.queue_free()
		_warm_up_nodes.clear()


## Shader pipelines Godot built since the last call, by kind: one built while
## drawing stalls that frame (a material seen for the first time).
func _probe_pipelines() -> String:
	var kinds := [
		["холст", RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS],
		["меш", RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH],
		["поверхность", RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE],
		["при отрисовке", RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW],
		["специализация", RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION],
	]
	if _probe_pipelines_seen.size() != kinds.size():
		_probe_pipelines_seen.resize(kinds.size())
		_probe_pipelines_seen.fill(0)
	var described: PackedStringArray = []
	for i in kinds.size():
		var count := RenderingServer.get_rendering_info(kinds[i][1])
		if count != _probe_pipelines_seen[i]:
			described.append("%s %d" % [kinds[i][0], count - _probe_pipelines_seen[i]])
			_probe_pipelines_seen[i] = count
	return ("собрано шейдеров: " + ", ".join(described)) if not described.is_empty() else "шейдеры не собирались"


## Moving and turning the user (slice i). The hand holding the movement pose is
## a stick: its offset from where the pose formed sets the velocity (any way in
## space, level with gravity); the hand holding the turning pose turns by its
## sideways offset (in steps or smoothly) and in space also lifts and lowers.
## Controller sticks do the same when they move rather than scroll
## (stick_mode). The rig moves; then everything kept in the world by global
## placement under the rig (panel layers, the UAC quad) is put back in place.
func _update_locomotion(delta: float) -> void:
	var space := _world.travel_mode == 0
	var seated := _seated >= 0
	var to_world := _origin.global_transform.basis
	var head := _camera.transform
	var head_right := Vector3(head.basis.x.x, 0.0, head.basis.x.z).normalized()
	# Ahead: level with gravity, wherever the head looks in space.
	var ahead := -head.basis.z if space else Vector3(-head.basis.z.x, 0.0, -head.basis.z.z).normalized()
	# The hand's plane: upright, or tipped forward as far as the user set (ring_tilt_degrees).
	var hand_up := Locomotion.plane_up(-head.basis.z, _gesture_settings.ring_tilt_degrees)
	var now := Time.get_ticks_msec() / 1000.0
	var velocity := Vector3.ZERO
	var turn_rate := 0.0
	var turn_steps := 0
	for i in 2:
		var pointer := _pointers[i]
		pointer.travel_ring = ""
		for action: String in ["move", "turn"]:
			var held: bool = pointer.poses.get(action, false) and pointer.tracked_hand
			if not held:
				pointer.travel_anchors.erase(action)
				if action == "turn":
					pointer.snap_turn.reset()
				continue
			# The fingertips, as for scrolling: the ring and its dot sit where the
			# user looks at the hand, not at the palm (20.10.2026).
			var tip := pointer.hand_joints[HandPose.FINGERS[2][3]] if pointer.hand_joints.size() == HandPose.JOINT_COUNT else pointer.palm_local
			if not pointer.travel_anchors.has(action):
				pointer.travel_anchors[action] = tip
			# Only the hand's move in the plane facing the user counts: towards or
			# away from the body the tracking loses the sign (20.10.2026).
			var offset: Vector3 = tip - pointer.travel_anchors[action]
			var flat := Vector2(offset.dot(head_right), offset.dot(hand_up))
			pointer.travel_ring = action
			pointer.travel_offset = flat
			if action == "move":
				# Up = ahead, down = back, sideways = a step aside. Seated: no moving.
				if seated:
					pointer.travel_ring = ""
					continue
				var push := Locomotion.stick_velocity(Vector3(flat.x, flat.y, 0.0), _world.hand_reach, _world.move_speed, false)
				velocity += to_world * (head_right * push.x + ahead * push.y)
			else:
				turn_rate += _turn_from(flat.x)
				turn_steps += _snap_from(flat.x, pointer.snap_turn, now)
				if space and not seated:
					velocity += to_world * Locomotion.stick_velocity(Vector3(0.0, flat.y, 0.0), _world.hand_reach, _world.move_speed, false)
		# Controllers: the left stick moves (forward where the head looks), the right turns.
		if _stick_moves(i) and not pointer.menu_open:
			var stick := _controllers[i].get_vector2(&"primary")
			if i == 0:
				if not seated:
					var push := Locomotion.stick_velocity(Vector3(stick.x, stick.y, 0.0) * STICK_AS_REACH, STICK_AS_REACH, _world.move_speed, false)
					velocity += to_world * (head_right * push.x + ahead * push.y)
			else:
				turn_rate += _turn_from(stick.x * STICK_AS_REACH)
				turn_steps += _snap_from(stick.x * STICK_AS_REACH, _stick_snap[i], now)
				if space and not seated:
					velocity += to_world * Locomotion.stick_velocity(Vector3(0.0, stick.y * STICK_AS_REACH, 0.0), STICK_AS_REACH, _world.move_speed, false)

	var rig := _origin.global_transform
	var before := rig
	rig.origin += velocity * delta
	var angle := turn_rate * delta + turn_steps * deg_to_rad(_world.snap_degrees)
	if angle != 0.0:
		rig = Locomotion.turn_about(rig, _camera.global_position, angle)
	if not space and not seated:
		rig.origin.y = Locomotion.settle(rig.origin.y, _floor_height, delta)
	if rig != before:
		_origin.global_transform = rig
		_keep_world_in_place()
		if turn_steps != 0:
			print("[world] поворот рывком %+d°" % roundi(turn_steps * _world.snap_degrees))
	# Smooth turning in the log: when it starts and ends, and how fast it went.
	if turn_rate != 0.0:
		_smooth_turn_peak = maxf(_smooth_turn_peak, absf(rad_to_deg(turn_rate)))
		if not _smooth_turning:
			_smooth_turning = true
			print("[world] плавный поворот %s" % ("вправо" if turn_rate > 0.0 else "влево"))
	elif _smooth_turning:
		_smooth_turning = false
		print("[world] плавный поворот закончен, до %.0f°/с" % _smooth_turn_peak)
		_smooth_turn_peak = 0.0
	var speed := velocity.length()
	_set_vignette(Locomotion.vignette_strength(_world.vignette, speed, _world.move_speed,
			turn_rate if turn_steps == 0 else deg_to_rad(_world.turn_speed_degrees), deg_to_rad(_world.turn_speed_degrees)))


func _turn_from(sideways: float) -> float:
	return Locomotion.turn_rate(sideways, _world.hand_reach, _world.turn_speed_degrees) if _world.turn_mode == 1 else 0.0


func _snap_from(sideways: float, snap: Locomotion.SnapTurn, now: float) -> int:
	return snap.update(sideways, now) if _world.turn_mode == 0 else 0


## Whether controller `index`'s thumbstick moves the user (else it scrolls).
func _stick_moves(index: int) -> bool:
	if not _is_real_controller(index):
		return false
	match _world.stick_mode:
		1:
			return false
		2:
			return true
	return not _pointers[index].on_panel


## The rig moved: panel layers (they must hang under the rig, but stand in the
## world) and the UAC quad go back to their places in the world.
func _keep_world_in_place() -> void:
	for panel in _panels:
		panel.place(panel.placement)
	if _secure_shown:
		_secure_layer.global_transform = _secure_quad_xf


## The orientation dots and the floor follow the user: rebuilt when the user has
## moved half a step, the mode or the floor changed. The floor shows with gravity.
func _update_world_visuals() -> void:
	_update_travel_rings()
	_update_seat()
	var head := _camera.global_position
	var planar := _world.travel_mode == 1
	_floor.visible = planar
	_floor.global_position = Vector3(head.x, _floor_height - 0.002, head.z)
	_grid.visible = _world.grid == 1
	if not _grid.visible:
		return
	var step := _world.grid_step
	var cell := (head / step).round()
	var key := "%s|%s|%s|%s" % [planar, step, _floor_height, cell]
	if key == _grid_key:
		return
	_grid_key = key
	var points := Locomotion.grid_points(head, step, GRID_RADIUS_FLOOR if planar else GRID_RADIUS_SPACE, planar, _floor_height)
	var multimesh := _grid.multimesh
	multimesh.instance_count = points.size()
	for i in points.size():
		multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, points[i]))


## The ring of a hand moving or turning: centred where the pose formed, in the
## plane facing the user (the only plane the hand's offset counts in).
func _update_travel_rings() -> void:
	var rig := _origin.global_transform
	var right := rig.basis * Vector3(_camera.transform.basis.x.x, 0.0, _camera.transform.basis.x.z).normalized()
	var up := rig.basis * Locomotion.plane_up(-_camera.transform.basis.z, _gesture_settings.ring_tilt_degrees)
	var ahead := rig.basis * Vector3(-_camera.transform.basis.z.x, 0.0, -_camera.transform.basis.z.z).normalized()
	for i in 2:
		var pointer := _pointers[i]
		var parts: Array = _travel_rings[i]
		var shown := pointer.travel_ring != "" and pointer.travel_anchors.has(pointer.travel_ring)
		for part: MeshInstance3D in parts:
			part.visible = shown
		if not shown:
			continue
		var outer := (parts[0] as MeshInstance3D).mesh as TorusMesh
		if not is_equal_approx(outer.outer_radius, _world.hand_reach + 0.003):
			outer.inner_radius = _world.hand_reach - 0.003
			outer.outer_radius = _world.hand_reach + 0.003
		# A little ahead of the fingertips, so the ring does not cut through the fingers.
		var centre: Vector3 = rig * (pointer.travel_anchors[pointer.travel_ring] as Vector3) + ahead * TRAVEL_RING_AHEAD
		var facing := Transform3D(Basis(right, right.cross(up), -up), centre)
		(parts[0] as MeshInstance3D).global_transform = facing
		(parts[1] as MeshInstance3D).global_transform = facing
		var shown_offset := pointer.travel_offset.limit_length(_world.hand_reach * 1.15)
		if pointer.travel_ring == "turn" and _world.travel_mode == 1:
			shown_offset.y = 0.0  # with gravity the turning hand only turns
		(parts[2] as MeshInstance3D).global_position = centre + right * shown_offset.x + up * shown_offset.y


## Seats (slice j). Near a sphere the user does not sit in, "Сесть" floats in
## front of them; it takes them to the sphere's centre, facing its middle.
## Seated, the movement pose does not move them (turning still turns); "Встать"
## in the radial menu (in place of "Центр") stands them up where they are.
func _update_seat() -> void:
	var head := _camera.global_transform
	var offer := WorldLayout.nearby(_fixtures, head.origin, SEAT_REACH)
	if offer != null and offer.id == _seated:
		offer = null
	_sit_offer = offer
	_sit_button.visible = offer != null
	if offer == null:
		return
	_sit_button.set_text("Сесть: %s" % offer.name)
	var ahead := Vector3(-head.basis.z.x, 0.0, -head.basis.z.z).normalized()
	var at := head.origin + ahead * 0.55 + Vector3.DOWN * 0.3
	# Its face (+Z) towards the user.
	_sit_button.global_transform = Transform3D(Basis.looking_at(ahead, Vector3.UP), at)


func _sit() -> void:
	if _sit_offer == null:
		return
	var fixture := _sit_offer
	_seated = fixture.id
	_origin.global_transform = WorldLayout.seat_rig(fixture, _camera.transform)
	for pointer in _pointers:
		pointer.travel_anchors.clear()
	_keep_world_in_place()
	_save_settings()
	_refresh_fixture_section()
	print("[world] сел в центре «%s» (радиус %.2f м)" % [fixture.name, fixture.radius])


func _stand_up() -> void:
	var fixture := WorldLayout.find(_fixtures, _seated)
	_seated = -1
	_save_settings()
	_refresh_fixture_section()
	print("[world] встал%s" % ((" с места «%s»" % fixture.name) if fixture != null else ""))


## The "Заготовки" tab: left, the spheres (radius, move it here, delete) and
## "Добавить шар здесь"; right, each monitor and the sphere it hangs on (press to
## move it to the next sphere). Every change is saved at once.
func _build_fixture_section(tab: Node3D) -> void:
	_settings_label("Шары", Vector3(-0.5, 0.53, 0.0), 28, tab)
	for r in FIXTURE_ROWS:
		var row := Node3D.new()
		row.position = Vector3(0.0, 0.45 - r * 0.08, 0.0)
		tab.add_child(row)
		var name_label := _settings_label("", Vector3(-0.8, 0.0, 0.0), 24, row)
		name_label.name = "Name"
		_add_button_to(row, "−", Vector3(-0.6, 0.0, 0.0), Vector2(0.07, 0.052), 0.25).activated.connect(_on_fixture_radius.bind(r, -1.0))
		var radius_label := _settings_label("", Vector3(-0.5, 0.0, 0.0), 24, row)
		radius_label.name = "Radius"
		_add_button_to(row, "+", Vector3(-0.4, 0.0, 0.0), Vector2(0.07, 0.052), 0.25).activated.connect(_on_fixture_radius.bind(r, 1.0))
		_add_button_to(row, "Сюда", Vector3(-0.23, 0.0, 0.0), Vector2(0.16, 0.055), 0.6).activated.connect(_on_fixture_here.bind(r))
		_add_button_to(row, "Удалить", Vector3(-0.04, 0.0, 0.0), Vector2(0.17, 0.055), 1.0).activated.connect(_on_fixture_delete.bind(r))
		_fixture_rows.append(row)
	_add_button_to(tab, "Добавить шар здесь", Vector3(-0.45, -0.07, 0.0), Vector2(0.42, 0.07), 0.6).activated.connect(_on_fixture_add)
	_fixture_status = _settings_label("«Сюда» — центр шара в вашу голову, лицом туда, куда смотрите.\nРадиус меняет и шарик-ручка на сфере внизу перед местом.",
			Vector3(-0.45, -0.17, 0.0), 20, tab)

	_settings_label("Мониторы", Vector3(0.6, 0.53, 0.0), 28, tab)
	for m in FIXTURE_MONITOR_ROWS:
		var row := Node3D.new()
		row.position = Vector3(0.0, 0.45 - m * 0.07, 0.0)
		tab.add_child(row)
		var label := _settings_label("", Vector3(0.48, 0.0, 0.0), 22, row)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.name = "Monitor"
		var button := _add_button_to(row, "", Vector3(0.7, 0.0, 0.0), Vector2(0.3, 0.055), 0.25)
		button.name = "Fixture"
		button.activated.connect(_on_monitor_fixture.bind(m))
		_fixture_monitor_rows.append(row)
	_refresh_fixture_section()


func _refresh_fixture_section() -> void:
	if _fixture_rows.is_empty():
		return
	for r in FIXTURE_ROWS:
		var row := _fixture_rows[r]
		row.visible = r < _fixtures.size()
		if row.visible:
			var fixture := _fixtures[r]
			(row.get_node("Name") as Label3D).text = fixture.name + (" (сижу)" if fixture.id == _seated else "")
			(row.get_node("Radius") as Label3D).text = "%.1f м" % fixture.radius
	for m in FIXTURE_MONITOR_ROWS:
		var row := _fixture_monitor_rows[m]
		row.visible = m < _panels.size()
		if row.visible:
			var panel := _panels[m]
			(row.get_node("Monitor") as Label3D).text = "%s %d×%d" % [panel.monitor_name.trim_prefix("\\\\.\\"),
					panel.monitor_rect.size.x, panel.monitor_rect.size.y]
			(row.get_node("Fixture") as VrButton).set_text(_fixture_of(panel).name)


func _on_fixture_radius(row: int, direction: float) -> void:
	if row >= _fixtures.size():
		return
	var fixture := _fixtures[row]
	fixture.radius = clampf(snappedf(fixture.radius + direction * FIXTURE_RADIUS_STEP, FIXTURE_RADIUS_STEP),
			WorldLayout.MIN_RADIUS, WorldLayout.MAX_RADIUS)
	_fixture_changed("%s: радиус %.1f м" % [fixture.name, fixture.radius])


## The sphere's centre to the user's head, its middle where the user looks.
func _on_fixture_here(row: int) -> void:
	if row >= _fixtures.size():
		return
	var fixture := _fixtures[row]
	var head := _camera.global_transform
	fixture.centre = head.origin
	fixture.yaw = atan2(head.basis.z.x, head.basis.z.z)
	_fixture_changed("%s: центр здесь" % fixture.name)


func _on_fixture_delete(row: int) -> void:
	if row >= _fixtures.size():
		return
	var fixture := _fixtures[row]
	if not WorldLayout.remove(_fixtures, fixture.id):
		_fixture_status.text = "Последний шар удалить нельзя: мониторам надо где-то висеть."
		return
	if _seated == fixture.id:
		_seated = -1
	_fixture_changed("%s удалён, его мониторы — на «%s»" % [fixture.name, _fixtures[0].name])


func _on_fixture_add() -> void:
	if _fixtures.size() >= FIXTURE_ROWS:
		_fixture_status.text = "Шаров уже %d — больше на вкладке не поместится." % FIXTURE_ROWS
		return
	var head := _camera.global_transform
	var fixture := WorldLayout.new_fixture(_fixtures, "sphere", head.origin, atan2(head.basis.z.x, head.basis.z.z))
	_fixtures.append(fixture)
	_fixture_changed("%s добавлен здесь; назначьте ему мониторы справа" % fixture.name)


## The monitor in row `m` goes to the next sphere in the list.
func _on_monitor_fixture(m: int) -> void:
	if m >= _panels.size() or _fixtures.size() < 2:
		return
	var panel := _panels[m]
	var next := _fixtures[(_fixtures.find(_fixture_of(panel)) + 1) % _fixtures.size()]
	WorldLayout.assign(_fixtures, panel.monitor_key, next.id)
	_fixture_changed("%s — на «%s»" % [panel.monitor_name, next.name])


func _fixture_changed(message: String) -> void:
	_place_panels([], true)
	_save_settings()
	_refresh_fixture_section()
	_fixture_status.text = message
	print("[world] ", message)


## Each sphere's radius handle: a small ball on the sphere low in front of the
## seat. Pinch or trigger on it and pull away from the centre — bigger, towards
## it — smaller; the screens follow live, the radius is saved on letting go.
func _update_radius_handles(delta: float) -> void:
	for i in _radius_handles.size():
		var shown := i < _fixtures.size()
		_radius_handles[i].visible = shown
		_radius_labels[i].visible = false
		if shown:
			_radius_handles[i].global_position = WorldLayout.radius_handle(_fixtures[i])
			(_radius_handles[i].material_override as StandardMaterial3D).albedo_color = ScreenPanel.GRIP_COLOR
	for pointer in _pointers:
		if pointer.radius_fixture >= 0:
			var fixture := WorldLayout.find(_fixtures, pointer.radius_fixture)
			if fixture == null:
				pointer.radius_fixture = -1
				continue
			if pointer.active and pointer.pressed:
				pointer.radius_lost = 0.0
				var radius := WorldLayout.dragged_radius(pointer.radius_start, pointer.radius_start_distance,
						pointer.origin.distance_to(fixture.centre))
				if not is_equal_approx(radius, fixture.radius):
					fixture.radius = radius
					_place_panels()
				_show_radius_handle(fixture, ScreenPanel.GRIP_ACTIVE_COLOR)
				continue
			pointer.radius_lost += delta
			if pointer.radius_lost >= GRAB_GRACE_SEC:
				pointer.radius_fixture = -1
				_fixture_changed("%s: радиус %.2f м" % [fixture.name, fixture.radius])
			continue
		if not pointer.active or pointer.grab_panel != null:
			continue
		for fixture in _fixtures:
			var at := WorldLayout.radius_handle(fixture)
			var along := (at - pointer.origin).dot(pointer.direction)
			if along <= 0.0 or (pointer.origin + pointer.direction * along).distance_to(at) > RADIUS_HANDLE_HIT:
				continue
			pointer.hit_distance = minf(pointer.hit_distance, along)
			_show_radius_handle(fixture, ScreenPanel.GRIP_HOVER_COLOR)
			if pointer.just_pressed:
				pointer.radius_fixture = fixture.id
				pointer.radius_start = fixture.radius
				pointer.radius_start_distance = pointer.origin.distance_to(fixture.centre)
				pointer.radius_lost = 0.0
				print("[world] %s: радиус (%s)" % [fixture.name, pointer.mode])
			break


func _show_radius_handle(fixture: WorldLayout.Fixture, color: Color) -> void:
	var i := _fixtures.find(fixture)
	if i < 0 or i >= _radius_handles.size():
		return
	(_radius_handles[i].material_override as StandardMaterial3D).albedo_color = color
	var label := _radius_labels[i]
	label.visible = true
	label.text = "радиус шара %.2f м" % fixture.radius
	label.global_position = WorldLayout.radius_handle(fixture) + Vector3.UP * 0.07


func _build_radius_handles() -> void:
	var ball := SphereMesh.new()
	ball.radius = 0.025
	ball.height = 0.05
	for i in FIXTURE_ROWS:
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = ScreenPanel.GRIP_COLOR
		var handle := MeshInstance3D.new()
		handle.mesh = ball
		handle.material_override = material
		handle.visible = false
		add_child(handle)
		_radius_handles.append(handle)
		var label := Label3D.new()
		label.pixel_size = 0.001
		label.font_size = 26
		label.outline_size = 8
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.visible = false
		add_child(label)
		_radius_labels.append(label)


func _build_seat_button() -> void:
	_sit_button = _add_button_to(self, "Сесть", Vector3.ZERO, Vector2(0.36, 0.09), 0.4)
	_sit_button.visible = false
	_sit_button.activated.connect(_sit)


func _set_vignette(strength: float) -> void:
	_vignette.visible = strength > 0.005
	_vignette_material.set_shader_parameter(&"strength", strength)


## Builds the dots, the floor (replacing the old fixed square) and the vignette.
func _build_world_visuals() -> void:
	var dot := SphereMesh.new()
	dot.radius = 0.012
	dot.height = 0.024
	dot.radial_segments = 6
	dot.rings = 3
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = dot
	_grid = MultiMeshInstance3D.new()
	_grid.multimesh = multimesh
	_grid.material_override = _flat_material(Color(0.45, 0.52, 0.62))
	add_child(_grid)

	var vignette_shader := Shader.new()
	vignette_shader.code = """
shader_type spatial;
render_mode unshaded, depth_test_disabled, cull_disabled, blend_mix;
uniform float strength = 0.0;
void fragment() {
	// The angle off the middle of this eye's view: dark towards the edges.
	float off = acos(clamp(-normalize(VERTEX).z, -1.0, 1.0));
	ALBEDO = vec3(0.0);
	ALPHA = strength * smoothstep(0.3, 0.8, off);
}
"""
	_vignette_material = ShaderMaterial.new()
	_vignette_material.shader = vignette_shader
	_vignette_material.render_priority = 120
	var quad := QuadMesh.new()
	quad.size = Vector2(0.9, 0.9)
	_vignette = MeshInstance3D.new()
	_vignette.mesh = quad
	_vignette.material_override = _vignette_material
	_vignette.position = Vector3(0.0, 0.0, -0.12)
	_vignette.visible = false
	_camera.add_child(_vignette)
	# Rings for moving and turning, as for scrolling: the outer one is full speed,
	# the small inner one the dead zone, the dot where the hand is now.
	var side_colors: Array[Color] = [Color(0.3, 0.7, 1.0), Color(1.0, 0.6, 0.3)]
	for i in 2:
		var parts: Array[MeshInstance3D] = []
		for radius: float in [_world.hand_reach, Locomotion.DEADZONE]:
			var torus := TorusMesh.new()
			torus.inner_radius = radius - 0.003
			torus.outer_radius = radius + 0.003
			torus.rings = 48
			torus.ring_segments = 8
			var ring := MeshInstance3D.new()
			ring.mesh = torus
			ring.material_override = _flat_material(Color(0.85, 0.9, 1.0))
			ring.visible = false
			add_child(ring)
			parts.append(ring)
		var marker_mesh := SphereMesh.new()
		marker_mesh.radius = 0.01
		marker_mesh.height = 0.02
		var marker := MeshInstance3D.new()
		marker.mesh = marker_mesh
		marker.material_override = _flat_material(side_colors[i])
		marker.visible = false
		add_child(marker)
		parts.append(marker)
		_travel_rings.append(parts)
	_stick_snap = [Locomotion.SnapTurn.new(), Locomotion.SnapTurn.new()]
	for snap in _stick_snap:
		snap.trigger = 0.7 * STICK_AS_REACH
		snap.rearm = 0.35 * STICK_AS_REACH


## The "Мир" tab, below its tunables: the floor where the user stands now. (A
## "Домой" button did what "Центр" in the radial menu does; dropped 20.10.2026.)
func _build_world_section(tab: Node3D) -> void:
	var rows := 0
	for tunable: Array in TUNABLES:
		if TUNABLE_TABS.get(tunable[1], 0) == SETTINGS_TABS.find("Мир"):
			rows += 1
	var bottom := 0.52 - rows * 0.062 - 0.04
	_add_button_to(tab, "Пол здесь", Vector3(-0.1, bottom, 0.0), Vector2(0.3, 0.07), 0.6).activated.connect(_on_floor_here)
	_floor_label = _settings_label("", Vector3(0.0, bottom - 0.08, 0.0), 22, tab)
	_settings_label("Движение: рука со знаком в плоскости кольца — от центра туда, куда ехать; вбок — шаг в сторону.\nПоворот — вторая рука вбок. Наклон кольца и ход руки — на вкладке «Жесты». К экранам — «Центр» в круговом меню.",
			Vector3(0.0, bottom - 0.15, 0.0), 20, tab)
	_refresh_floor_label()


func _on_floor_here() -> void:
	_floor_height = _origin.global_position.y
	_save_settings()
	_refresh_floor_label()
	print("[world] пол на высоте %.2f м" % _floor_height)


func _refresh_floor_label() -> void:
	if _floor_label != null:
		_floor_label.text = "Пол: %.2f м (с гравитацией ходите по нему)" % _floor_height


## Pose actions: which bound poses this hand holds now; a hand at rest holds
## nothing. Moving and turning split the hands (`_move_hand` moves, the other
## turns) only when both have the same gesture; with different gestures either
## hand does either (20.10.2026: a pose recorded with the right hand and bound to
## moving waited for the left hand, and the user saw it as broken). The built-in
## fist and scroll pose are recognised elsewhere (main.gd, HandGestures).
func _update_bound_poses(index: int, pointer: Pointer, time: float, resting: bool) -> void:
	var held := {}
	var split: bool = _bindings.get("move") == _bindings.get("turn")
	var actions: Array[String] = []
	for action: String in ["scroll", "grab", "move", "turn"]:
		if split and ((action == "move" and index != _move_hand) or (action == "turn" and index == _move_hand)):
			continue
		if _pose_template(_bindings.get(action, GestureCatalog.OFF)) != null:
			actions.append(action)
	# The poses compete: each bound pose this hand may hold, and the built-in
	# scroll pose (as a template of its thresholds), by strict distance. Only the
	# nearest of those that fit may come on (20.10.2026: a recorded pose differing
	# from the scroll pose in the thumb came on with it, both ways round).
	var fits := {}
	var features := pointer.hand_features
	if not resting and features.size() == HandPose.FEATURE_COUNT:
		for action in actions:
			var id: String = _bindings[action]
			fits[id] = HandPose.distance(_pose_template(id), features, false)
		if _bindings.get("scroll") == "pose:scroll":
			fits["pose:scroll"] = HandPose.distance(GestureCatalog.scroll_template(_gesture_settings), features, false)
	var best := ""
	for id: String in fits:
		if fits[id] <= 1.0 and (best == "" or fits[id] < fits[best]):
			best = id
	pointer.near_own_pose = false
	pointer.scroll_yields = best != "" and best != "pose:scroll" and _bindings.get("scroll") == "pose:scroll"
	for action in actions:
		var id: String = _bindings[action]
		var template := _pose_template(id)
		if id.begins_with("custom:") and best == id:
			pointer.near_own_pose = true
		if not pointer.pose_matchers.has(action):
			pointer.pose_matchers[action] = HandPose.Matcher.new()
		var matcher: HandPose.Matcher = pointer.pose_matchers[action]
		# A pinch with the other fingers straight looks like the locomotion sign
		# (20.10.2026: a left click turned the user). The sign has the thumb out, so
		# it does not count while the thumb closes on the index or a click is on.
		var pinching := id == "pose:move" and (pointer.contact_distances.x < _gesture_settings.approach
				or pointer.pressed or pointer.pending)
		var allowed := not resting and not pinching
		if allowed and best != "" and best != id:
			# Another pose fits better: this one may not come on; one already on gives
			# way only to a clearly better fit.
			allowed = matcher.on and fits[best] >= 0.5 * float(fits.get(id, INF))
		held[action] = matcher.update(template, features if allowed else PackedFloat32Array(), time)
		if id.begins_with("custom:") and held[action]:
			pointer.near_own_pose = true
	_set_poses(index, pointer, held)


## Stores the poses held and logs each one that starts or ends; on an end, which
## feature left its range (for tuning the tolerances).
func _set_poses(index: int, pointer: Pointer, held: Dictionary) -> void:
	for action: String in ["scroll", "grab", "move", "turn"]:
		var now: bool = held.get(action, false)
		if now == bool(pointer.poses.get(action, false)) or action not in ["move", "turn"]:
			continue
		var why := ""
		var template := _pose_template(_bindings.get(action, GestureCatalog.OFF))
		if not now and template != null:
			why = " (%s)" % HandPose.describe_miss(template, pointer.hand_features) if not pointer.hand_features.is_empty() else " (рука не видна)"
		print("[gesture] %s: %s — %s%s" % [SIDE_LABELS[index], GestureCatalog.label_of(action).to_lower(),
				("«%s»" % GestureCatalog.name_of(_bindings[action], _custom_poses)) if now else "отпущено", why])
	pointer.poses = held


## The template for a pose id, or null for "off" and for the built-in poses that
## have their own recognisers.
func _pose_template(id: String) -> HandPose.Template:
	if id == "pose:move":
		return _move_template
	return GestureCatalog.find(id, _custom_poses)


## After the bindings change (or load): keeps them valid and hands the touches to
## the click recogniser.
func _apply_bindings() -> void:
	_bindings = GestureCatalog.sanitize(_bindings, _custom_poses)
	_gesture_settings.left_contact = GestureCatalog.contact_of(_bindings["left"])
	_gesture_settings.right_contact = GestureCatalog.contact_of(_bindings["right"])
	_gesture_settings.middle_contact = GestureCatalog.contact_of(_bindings["middle"])
	for pointer in _pointers:
		pointer.gestures.reset()
		for matcher: HandPose.Matcher in pointer.pose_matchers.values():
			matcher.reset()


## The "Назначения" tab. Left: each action, its gesture on a button (press it to
## choose another) and a small hand showing that gesture. Middle: the list of
## choices for one action, each with its own hand. Right: the user's own poses,
## recorded with either hand, each with its hand and a delete button.
func _build_bindings_section(tab: Node3D) -> void:
	var row := 0
	for entry: Array in GestureCatalog.ACTIONS:
		var action: String = entry[0]
		var y := 0.5 - row * 0.08
		row += 1
		var label := _settings_label(entry[1], Vector3(-0.55, y, 0.0), 26, tab)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		var button := _add_button_to(tab, "", Vector3(-0.33, y, 0.0), Vector2(0.4, 0.06), 0.2)
		button.activated.connect(_open_binding_menu.bind(action))
		_binding_buttons[action] = button
		var preview := HandPreview.new()
		preview.position = Vector3(-0.07, y, 0.01)
		tab.add_child(preview)
		_binding_previews[action] = preview
	var y_hand := 0.5 - row * 0.08
	var hand_label := _settings_label("Движение — рука", Vector3(-0.55, y_hand, 0.0), 26, tab)
	hand_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_move_hand_button = _add_button_to(tab, "", Vector3(-0.33, y_hand, 0.0), Vector2(0.4, 0.06), 0.2)
	_move_hand_button.activated.connect(_on_move_hand_button)
	_settings_label("Если у движения и поворота один жест: эта рука\nдвижется, другая поворачивает. Разные жесты — любой рукой",
			Vector3(-0.33, y_hand - 0.07, 0.0), 20, tab)

	# The list of choices; only the rows in use are shown.
	_binding_menu_title = _settings_label("", Vector3(0.28, 0.555, 0.0), 22, tab)
	for i in BINDING_MENU_ROWS:
		var y := 0.5 - i * 0.07
		var option := _add_button_to(tab, "", Vector3(0.2, y, 0.0), Vector2(0.36, 0.055), 0.2)
		option.activated.connect(_on_binding_option.bind(i))
		option.visible = false
		_binding_options.append(option)
		var preview := HandPreview.new(0.06)
		preview.position = Vector3(0.43, y, 0.01)
		preview.visible = false
		tab.add_child(preview)
		_binding_option_previews.append(preview)

	# Own poses.
	_settings_label("Свои позы", Vector3(0.75, 0.53, 0.0), 26, tab)
	_add_button_to(tab, "Записать левой", Vector3(0.63, 0.46, 0.0), Vector2(0.24, 0.06), 0.6).activated.connect(_start_pose_recording.bind(0))
	_add_button_to(tab, "Записать правой", Vector3(0.88, 0.46, 0.0), Vector2(0.24, 0.06), 0.6).activated.connect(_start_pose_recording.bind(1))
	_pose_status = _settings_label("Нажмите, покажите позу этой рукой\nи держите её 5 с, слегка двигая рукой", Vector3(0.75, 0.37, 0.0), 20, tab)
	for i in POSE_ROWS:
		var pose_row := Node3D.new()
		pose_row.position = Vector3(0.0, 0.24 - i * 0.085, 0.0)
		tab.add_child(pose_row)
		var name_label := _settings_label("", Vector3(0.62, 0.0, 0.0), 24, pose_row)
		name_label.name = "Name"
		var preview := HandPreview.new(0.065)
		preview.name = "Preview"
		preview.position = Vector3(0.77, 0.0, 0.01)
		pose_row.add_child(preview)
		_add_button_to(pose_row, "Удалить", Vector3(0.92, 0.0, 0.0), Vector2(0.14, 0.05), 1.0).activated.connect(_delete_custom_pose.bind(i))
		_pose_rows.append(pose_row)
	_refresh_bindings_section()


func _refresh_bindings_section() -> void:
	if _move_hand_button == null:
		return
	for action: String in _binding_buttons:
		var id: String = _bindings.get(action, GestureCatalog.OFF)
		(_binding_buttons[action] as VrButton).set_text(("» %s «" if action == _binding_menu_action else "%s")
				% GestureCatalog.name_of(id, _custom_poses))
		(_binding_previews[action] as HandPreview).set_joints(GestureCatalog.preview_joints(id, _custom_poses))
	_move_hand_button.set_text("левая" if _move_hand == 0 else "правая")
	for i in POSE_ROWS:
		var row := _pose_rows[i]
		row.visible = i < _custom_poses.size()
		if row.visible:
			(row.get_node("Name") as Label3D).text = _custom_poses[i].name
			(row.get_node("Preview") as HandPreview).set_joints(_custom_poses[i].joints)


func _open_binding_menu(action: String) -> void:
	if _binding_menu_action == action:
		_close_binding_menu()
		return
	_binding_menu_action = action
	var options := GestureCatalog.options(action, _custom_poses)
	_binding_option_ids.clear()
	for i in BINDING_MENU_ROWS:
		var shown := i < options.size()
		_binding_options[i].visible = shown
		if shown:
			var id: String = options[i][0]
			_binding_option_ids.append(id)
			var current: bool = _bindings.get(action) == id
			_binding_options[i].set_text(("» %s" if current else "%s") % options[i][1])
			_binding_option_previews[i].set_joints(GestureCatalog.preview_joints(id, _custom_poses))
		else:
			_binding_option_previews[i].visible = false
	_binding_menu_title.text = "%s:" % GestureCatalog.label_of(action)
	_refresh_bindings_section()


func _close_binding_menu() -> void:
	_binding_menu_action = ""
	for i in _binding_options.size():
		_binding_options[i].visible = false
		_binding_option_previews[i].visible = false
	if _binding_menu_title != null:
		_binding_menu_title.text = ""
	_refresh_bindings_section()


func _on_binding_option(row: int) -> void:
	if _binding_menu_action == "" or row >= _binding_option_ids.size():
		return
	var action := _binding_menu_action
	var before := _bindings.duplicate()
	_bindings = GestureCatalog.assign(_bindings, action, _binding_option_ids[row])
	_apply_bindings()
	_save_settings()
	for key: String in _bindings:
		if _bindings[key] != before.get(key):
			print("[bindings] %s: %s" % [GestureCatalog.label_of(key), GestureCatalog.name_of(_bindings[key], _custom_poses)])
	_close_binding_menu()


func _on_move_hand_button() -> void:
	_move_hand = 1 - _move_hand
	_apply_bindings()
	_save_settings()
	_refresh_bindings_section()
	print("[bindings] движение — %s рука, поворот — %s" % ["левая" if _move_hand == 0 else "правая", "правая" if _move_hand == 0 else "левая"])


func _start_pose_recording(hand: int) -> void:
	if _pose_recording >= 0 or _calibrating >= 0:
		return
	_close_binding_menu()
	_pose_recording = hand
	_pose_recording_started = false
	_pose_recording_until = Time.get_ticks_msec() / 1000.0 + POSE_COUNTDOWN_SEC
	_pose_record_samples.clear()
	_pose_record_joints.clear()
	print("[poses] запись позы %s рукой: отсчёт" % ["левой", "правой"][hand])


## Every frame while recording: a countdown to form the pose, then POSE_RECORD_SEC
## of the hand's shape; meanwhile the hands control nothing.
func _update_pose_recording() -> void:
	if _pose_recording < 0:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var hand := ["левой", "правой"][_pose_recording] as String
	if not _pose_recording_started:
		if now < _pose_recording_until:
			_pose_status.text = "Покажите позу %s рукой… %d" % [hand, ceili(_pose_recording_until - now)]
			return
		_pose_recording_started = true
		_pose_recording_until = now + POSE_RECORD_SEC
	var pointer := _pointers[_pose_recording]
	if not pointer.hand_features.is_empty():
		_pose_record_samples.append(pointer.hand_features)
		_pose_record_joints.append(HandPose.local_joints(pointer.hand_joints, SIDE_SIGNS[_pose_recording]))
	if now < _pose_recording_until:
		_pose_status.text = "Запись %s рукой: держите позу… %d\n(кадров %d)" % [hand, ceili(_pose_recording_until - now), _pose_record_samples.size()]
		return
	_finish_pose_recording()


func _finish_pose_recording() -> void:
	var hand := _pose_recording
	_pose_recording = -1
	var id := "custom:%d" % _next_custom_pose
	var joints := _pose_record_joints[_pose_record_joints.size() / 2] if not _pose_record_joints.is_empty() else PackedVector3Array()
	var template := HandPose.record(_pose_record_samples, id, "Своя поза %d" % _next_custom_pose, joints)
	if template == null:
		_pose_status.text = "Не записано: рука была видна только %d кадров.\nДержите её перед собой и повторите." % _pose_record_samples.size()
		print("[poses] не записано: %d кадров" % _pose_record_samples.size())
		return
	if _custom_poses.size() >= POSE_ROWS:
		_custom_poses.pop_front()
	_custom_poses.append(template)
	_next_custom_pose += 1
	var warnings := _pose_warnings(template)
	_apply_bindings()
	_save_settings()
	_refresh_bindings_section()
	_pose_status.text = "«%s» записана (%s рукой, %d кадров).%s" % [template.name, ["левой", "правой"][hand], _pose_record_samples.size(),
			("\nПохожа на: " + ", ".join(warnings)) if not warnings.is_empty() else "\nНазначьте её действию слева."]
	print("[poses] записана «%s»: %d кадров, похожа на: %s; середина %s, допуск %s" % [template.name, _pose_record_samples.size(),
			", ".join(warnings) if not warnings.is_empty() else "ничто", template.middle, template.tolerance])


## Which gestures already in use the recorded frames look like: the built-in
## fist and scroll pose (by their own rules), an open hand (swipes), the
## locomotion sign and the other own poses (by template).
func _pose_warnings(recorded: HandPose.Template) -> PackedStringArray:
	var warnings: PackedStringArray = []
	var counts := {"Кулак": 0, "Поза прокрутки": 0, "Раскрытая ладонь (смахивание)": 0}
	for sample in _pose_record_samples:
		var thumb_up := sample[0] > FIST_THUMB_UP_STRAIGHT and sample[5] > FIST_THUMB_UP_DISTANCE
		if maxf(maxf(sample[6], sample[7]), maxf(sample[8], sample[9])) < _gesture_settings.fist_curl and not thumb_up:
			counts["Кулак"] += 1
		if sample[1] >= _gesture_settings.disc_straightness and sample[2] >= _gesture_settings.disc_straightness \
				and sample[11] >= _gesture_settings.disc_align and sample[12] >= _gesture_settings.disc_align \
				and sample[15] < _gesture_settings.disc_together and sample[18] >= _gesture_settings.disc_thumb_spread:
			counts["Поза прокрутки"] += 1
		if sample[1] > 0.85 and sample[2] > 0.85 and sample[3] > 0.85:
			counts["Раскрытая ладонь (смахивание)"] += 1
	for name: String in counts:
		if counts[name] > _pose_record_samples.size() * 0.3:
			warnings.append(name)
	var others: Array[HandPose.Template] = [_move_template]
	for template in _custom_poses:
		if template != recorded:
			others.append(template)
	for template in others:
		if HandPose.overlap(template, _pose_record_samples) > 0.3:
			warnings.append("«%s»" % template.name)
	return warnings


func _delete_custom_pose(row: int) -> void:
	if row >= _custom_poses.size():
		return
	var template := _custom_poses[row]
	_custom_poses.remove_at(row)
	_apply_bindings()
	_save_settings()
	_close_binding_menu()
	_pose_status.text = "«%s» удалена; действия с ней выключены." % template.name
	print("[poses] удалена «%s»" % template.name)


## One line per hand describing its pose, for designing a new gesture from what
## the user shows (the locomotion sign, 20.10.2026). Per finger: straightness
## (1 = straight), tip to palm and tip to thumb tip (mm), and how far it points
## along the hand (1 = in line with wrist->knuckle, 0 = across, -1 = curled back).
## Then the palm: its normal against up and towards the head, the hand's axis
## against up, and the gaps between neighbouring fingertips (mm).
func _log_pose(index: int, tracker: XRHandTracker, to_world: Transform3D, pointer: Pointer) -> void:
	var j := func(joint: int) -> Vector3: return tracker.get_hand_joint_transform(joint).origin
	var fingers := [
		["большой", XRHandTracker.HAND_JOINT_THUMB_METACARPAL, XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL,
				XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_THUMB_TIP],
		["указ", XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE,
				XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP],
		["средн", XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE,
				XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP],
		["безым", XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE,
				XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_RING_FINGER_TIP],
		["мизин", XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE,
				XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP],
	]
	var palm: Vector3 = j.call(XRHandTracker.HAND_JOINT_PALM)
	var wrist: Vector3 = j.call(XRHandTracker.HAND_JOINT_WRIST)
	var thumb_tip: Vector3 = j.call(XRHandTracker.HAND_JOINT_THUMB_TIP)
	var axis: Vector3 = (j.call(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL) - wrist).normalized()
	var parts: PackedStringArray = []
	var tips: Array[Vector3] = []
	for finger: Array in fingers:
		var a: Vector3 = j.call(finger[1])
		var b: Vector3 = j.call(finger[2])
		var c: Vector3 = j.call(finger[3])
		var tip: Vector3 = j.call(finger[4])
		tips.append(tip)
		parts.append("%s прям %.2f, к ладони %.0f, к большому %.0f, вдоль %+.2f" % [finger[0], HandGestures.straightness(a, b, c, tip),
				tip.distance_to(palm) * 1000.0, tip.distance_to(thumb_tip) * 1000.0, (tip - a).normalized().dot(axis)])
	var gaps: PackedStringArray = []
	for k in range(1, tips.size() - 1):
		gaps.append("%.0f" % (tips[k].distance_to(tips[k + 1]) * 1000.0))
	var head := (_camera.global_position - pointer.palm_world).normalized()
	print("[pose] %s: %s | ладонь вверх %+.2f, к голове %+.2f, кисть вверх %+.2f | промежутки кончиков %s | щипок %.0f, кулак %.0f, ниже глаз %.0f см" % [
			SIDE_LABELS[index], "; ".join(parts), pointer.palm_normal.dot(Vector3.UP), pointer.palm_normal.dot(head),
			(to_world.basis * axis).normalized().dot(Vector3.UP), "/".join(gaps), pointer.pinch_mm, pointer.fist_mm,
			(_camera.global_position.y - pointer.palm_world.y) * 100.0])


## The startup probe's stopwatch inside _process: -1 starts the frame, `part`
## records the time since the previous mark. Does nothing after the probe.
func _probe_mark(part: int) -> void:
	if Time.get_ticks_msec() > STARTUP_PROBE_SEC * 1000.0:
		return
	var now := Time.get_ticks_usec()
	if part < 0:
		_probe_parts.resize(PROBE_PARTS.size())
		_probe_parts.fill(0)
	else:
		_probe_parts[part] = now - _probe_mark_usec
	_probe_mark_usec = now


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_ESCAPE:
		_quit()


## The emergency exit (`restore_layout`) also brings back the Windows layout and
## the set of attached screens from before this session; a normal exit keeps them.
func _quit(restore_layout := false) -> void:
	print("[app] выход")
	if restore_layout:
		print("[screens] возвращаю исходную раскладку: ", _topology.restore_layout_now())
	get_tree().quit()


func _on_pose_recentered() -> void:
	print("[xr] вид сброшен кнопкой Meta, выравниваю сцену")
	# A moment later, when the new head pose has arrived.
	get_tree().create_timer(0.3).timeout.connect(_recenter)


func _on_session_begun(openxr: OpenXRInterface) -> void:
	print("[xr] сессия начата, частота: ", openxr.display_refresh_rate, " Гц (%.1f с от старта)" % (Time.get_ticks_msec() / 1000.0))


func _exit_tree() -> void:
	OS.remove_logger(_session_loss)
	# Never leave Windows with a mouse button or Ctrl stuck down.
	_release_cursor_button()
	if _zoom_active:
		MouseInput.set_key(VK_CONTROL, false)
	for panel in _panels:
		panel.capture.stop()


## Adds where a ray meets the plane of a panel (inside it or not), in that panel's pixels.
func _add_plane_point(spread: Spread, panel: ScreenPanel, origin: Vector3, direction: Vector3) -> void:
	var panel_transform := panel.placement.transform
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
	# While the secure desktop is shown, _update_secure_cursor drives the cursor.
	if _secure_shown:
		return
	if _panels.is_empty():
		return
	for pointer in _pointers:
		pointer.on_panel = false
		pointer.panel = null
		# A pointer that carries a panel (or a sphere's radius) does not touch the
		# cursor; nor does one on a monitor's menu.
		if not pointer.active or pointer.grab_panel != null or pointer.radius_fixture >= 0 or pointer.slider != null:
			continue
		var on_menu := _monitor_menu.hit_distance(pointer.origin, pointer.direction)
		if on_menu >= 0.0:
			pointer.hit_distance = minf(pointer.hit_distance, on_menu)
			continue
		var nearest := INF
		for panel in _panels:
			# Hidden (beyond the render radius) or beyond the interaction radius: no clicks.
			if not panel.layer.visible:
				continue
			var distance := panel.hit_distance(pointer.origin, pointer.direction)
			if _world.interact_radius > 0.0 and distance > _world.interact_radius:
				continue
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
	# A hand press is only decided after the recognition window, so the press point
	# is looked up that much further back.
	_cursor_filter.lookback_sec = CURSOR_LOOKBACK_SEC + _gesture_settings.confirm_delay
	var result: CursorFilter.Result
	var owner_pointer: Pointer = null
	if _cursor_owner < 0:
		_cursor_press_armed = false
		result = _cursor_filter.update(Vector2.ZERO, false, false, now)
	else:
		owner_pointer = _pointers[_cursor_owner]
		# A press counts only if it began on the panel, not if a held pinch wandered onto it.
		if owner_pointer.on_panel and owner_pointer.just_pressed:
			_cursor_press_armed = true
		elif not owner_pointer.pressed:
			_cursor_press_armed = false
		var target := owner_pointer.panel.pixel_at(owner_pointer.panel_uv) if owner_pointer.on_panel else Vector2.ZERO
		result = _cursor_filter.update(target, owner_pointer.on_panel, owner_pointer.pressed and _cursor_press_armed, now,
				owner_pointer.pending or owner_pointer.scrolling, owner_pointer.anchor_time)

	var pixel := Vector2i(result.position.round())
	if result.move:
		MouseInput.move_to(pixel)
	if result.press:
		_cursor_button = owner_pointer.button
		var mouse_button := _cursor_button as MouseInput.Button
		if result.double_click and _cursor_button == HandGestures.Click.LEFT:
			# A full click first: the press that follows is then the second one of a
			# double click by Windows' own timing, however slow the hand was.
			MouseInput.set_button(mouse_button, true)
			MouseInput.set_button(mouse_button, false)
		MouseInput.set_button(mouse_button, true)
		print("[cursor] %s: %s в %s, луч в этот момент в %.0f px от точки%s" % [SIDE_LABELS[_cursor_owner],
				CLICK_LABELS[_cursor_button], pixel, _cursor_filter.last_press_offset,
				", двойной щелчок" if result.double_click and _cursor_button == HandGestures.Click.LEFT else ""])
	if result.release:
		_release_cursor_button()
		print("[cursor] отпускание в %s через %.2f с, за время удержания луч уходил на %.0f px" % [
				pixel, _cursor_filter.last_hold_sec, _cursor_filter.last_hold_excursion])

	# Raising the fingers into the disc pose moves the ray; put the cursor back where
	# it was just before, so that the wheel goes to the window the user meant.
	if owner_pointer != null and owner_pointer.disc_pose_started:
		var back: Variant = _cursor_filter.recall(now - DISC_RECALL_SEC)
		if back != null:
			MouseInput.move_to(Vector2i((back as Vector2).round()))

	# The wheel goes to the window under the cursor, from whichever pointer turns it:
	# with the disc up the ray usually points somewhere else entirely.
	var any_scrolling := false
	for pointer in _pointers:
		if pointer.scrolling:
			any_scrolling = true
			_scroll_remainder += pointer.scroll
			_hscroll_remainder += pointer.hscroll
	if any_scrolling:
		var whole := int(_scroll_remainder)
		if whole != 0:
			MouseInput.scroll(whole)
			_scroll_remainder -= whole
			_scroll_logged += whole
		var sideways := int(_hscroll_remainder)
		if sideways != 0:
			MouseInput.scroll_horizontal(sideways)
			_hscroll_remainder -= sideways
	else:
		_scroll_remainder = 0.0
		_hscroll_remainder = 0.0


## Pause (palms facing each other) and zoom (both hands holding a left pinch).
func _update_two_hand_gestures() -> void:
	var left := _pointers[0]
	var right := _pointers[1]
	var now := Time.get_ticks_usec() / 1000000.0
	if left.tracked_hand and right.tracked_hand:
		if _pause.update(now, left.palm_world, left.palm_normal, right.palm_world, right.palm_normal):
			_hands_paused = not _hands_paused
			print("[gesture] руки %s" % ("на паузе" if _hands_paused else "снова управляют"))
	else:
		_pause.reset()

	var zooming := left.mode == "рука" and right.mode == "рука" \
			and left.button == HandGestures.Click.LEFT and right.button == HandGestures.Click.LEFT \
			and left.grab_panel == null and right.grab_panel == null
	if zooming:
		var gap := left.pinch_point.distance_to(right.pinch_point)
		if not _zoom_active:
			# The first hand's click may already be down: let it go before zooming.
			_release_cursor_button()
			MouseInput.set_key(VK_CONTROL, true)
			_zoom_active = true
			_zoom_remainder = 0.0
			print("[gesture] масштаб двумя руками")
		else:
			_zoom_remainder += (gap - _zoom_last_gap) * _gesture_settings.zoom_speed
			var whole := int(_zoom_remainder)
			if whole != 0:
				MouseInput.scroll(whole)
				_zoom_remainder -= whole
		_zoom_last_gap = gap
		# Neither hand clicks or moves the cursor while zooming.
		for pointer in [left, right]:
			pointer.button = HandGestures.Click.NONE
			pointer.pressed = false
			pointer.just_pressed = false
			pointer.pending = true
			pointer.zoom_held = true
	elif _zoom_active:
		MouseInput.set_key(VK_CONTROL, false)
		_zoom_active = false


## Records one contact distance for CALIBRATION_SEC while the user touches and
## opens repeatedly, then derives the thresholds from it.
func _start_calibration(contact: int) -> void:
	_calibrating = contact
	_calibration_end = Time.get_ticks_msec() / 1000.0 + (POSE_CALIBRATION_SEC if contact == CALIBRATE_POSE else CALIBRATION_SEC)
	_calibration_samples = PackedFloat32Array()
	_pose_samples.clear()
	print("[calibration] запись: %s" % ("щипок" if contact == 0 else "касание бока"))


func _update_calibration() -> void:
	if _calibrating < 0:
		return
	var now := Time.get_ticks_msec() / 1000.0
	# The right hand if it is tracked, otherwise the left.
	var source: Pointer = _pointers[1] if _pointers[1].tracked_hand else _pointers[0]
	if _calibrating == CALIBRATE_POSE:
		if source.tracked_hand:
			_pose_samples.append(source.pose_features)
		if now < _calibration_end:
			_calibration_status.text = "Запись: держите позу прокрутки и водите рукой\nосталось %d с" % ceili(_calibration_end - now)
			return
		var pose := ExtraGestures.calibrate_pose(_pose_samples)
		if pose.is_empty():
			_calibration_status.text = "Не получилось: рука почти не отслеживалась.\nПовторите."
		else:
			for property: String in pose:
				_gesture_settings.set(property, pose[property])
			_calibration_status.text = "Поза прокрутки настроена:\nвместе < %d мм, безымянный < %d мм, по линии ≥ %d%%" % [
					roundi(pose["disc_together"] * 1000.0), roundi(pose["disc_ring_curl"] * 1000.0), roundi(pose["disc_align"] * 100.0)]
		print("[calibration] %s (%d кадров)" % [_calibration_status.text.replace("\n", " "), _pose_samples.size()])
		_calibrating = -1
		_save_settings()
		_refresh_settings_panel()
		return

	if source.tracked_hand:
		_calibration_samples.append(source.contact_distances[_calibrating])
	var what := "щипок большой + указательный" if _calibrating == 0 else "касание большим бока указательного"
	if now < _calibration_end:
		_calibration_status.text = "Запись: делайте %s 5–8 раз\nосталось %d с" % [what, ceili(_calibration_end - now)]
		return
	var thresholds := ExtraGestures.calibrate(_calibration_samples)
	if thresholds == Vector2.ZERO:
		_calibration_status.text = "Не получилось: касания плохо различимы.\nПовторите чётче."
	elif _calibrating == 0:
		_gesture_settings.pinch_press = snappedf(thresholds.x, 0.001)
		_gesture_settings.pinch_release = snappedf(thresholds.y, 0.001)
		_calibration_status.text = "Щипок: касание %d мм, отпускание %d мм" % [roundi(thresholds.x * 1000.0), roundi(thresholds.y * 1000.0)]
	else:
		_gesture_settings.side_press = snappedf(thresholds.x, 0.001)
		_gesture_settings.side_release = snappedf(thresholds.y, 0.001)
		_calibration_status.text = "Бок: касание %d мм, отпускание %d мм" % [roundi(thresholds.x * 1000.0), roundi(thresholds.y * 1000.0)]
	print("[calibration] %s (%d кадров)" % [_calibration_status.text.replace("\n", " "), _calibration_samples.size()])
	_calibrating = -1
	_save_settings()
	_refresh_settings_panel()


func _release_cursor_button() -> void:
	if _cursor_button != HandGestures.Click.NONE:
		MouseInput.set_button(_cursor_button as MouseInput.Button, false)
		_cursor_button = HandGestures.Click.NONE


## Every frame: keeps the panels' pictures current and, once a second, checks
## whether the Windows monitor layout changed (from outside or by our own buttons).
func _update_panels(delta: float) -> void:
	_monitor_check_timer += delta
	if _monitor_check_timer >= MONITOR_CHECK_SEC:
		_monitor_check_timer = 0.0
		var monitors := ScreenCapture.list_monitors()
		var signature := str(monitors)
		if signature == _monitor_signature:
			_pending_monitor_signature = ""
		elif signature == _pending_monitor_signature:
			if _move_panels(monitors):
				print("[capture] мониторы переставлены, панели те же")
			else:
				print("[capture] раскладка мониторов изменилась, перестраиваю панели")
				_rebuild_panels()
		else:
			_pending_monitor_signature = signature

	var copy_frames := not _diag.has("nocopy")
	var now := Time.get_ticks_msec() / 1000.0
	var head := _camera.global_position
	for panel in _panels:
		# Beyond the render radius a panel is neither drawn nor fed new pictures;
		# the monitor stays in Windows as it is.
		var in_range := _world.render_radius <= 0.0 or panel.placement.transform.origin.distance_to(head) <= _world.render_radius
		if panel.layer.visible != in_range:
			panel.layer.visible = in_range
			print("[world] %s: %s радиуса отрисовки" % [panel.monitor_name, "в пределах" if in_range else "за пределами"])
		panel.refresh(_session_visible and in_range, copy_frames and in_range, now)
		panel.update_back(head, in_range)
	_order_layers(head)


## Composition layers are drawn by sort_order, not by depth: with every panel at
## the same order, one behind another could show over it from some angles
## (20.10.2026). The nearest panel gets -2, each farther one a step lower; the
## UAC quad stays above them all at -1.
func _order_layers(head: Vector3) -> void:
	var by_distance := _panels.duplicate()
	by_distance.sort_custom(func(a: ScreenPanel, b: ScreenPanel) -> bool:
		return a.placement.transform.origin.distance_squared_to(head) < b.placement.transform.origin.distance_squared_to(head))
	for rank in by_distance.size():
		var layer := (by_distance[rank] as ScreenPanel).layer
		if layer != null and layer.sort_order != -2 - rank:
			layer.sort_order = -2 - rank


## The same monitors, only moved around (or another one made primary): the
## captures keep working (checked with tests/move_probe.gd), so the panels just
## take the new places instead of being built anew, which made the headset stutter.
## False if monitors came, went or changed size.
func _move_panels(monitors: Array[Dictionary]) -> bool:
	if monitors.size() != _panels.size():
		return false
	var by_name := {}
	for monitor in monitors:
		by_name[monitor["name"]] = monitor
	for panel in _panels:
		if not by_name.has(panel.monitor_name) or by_name[panel.monitor_name]["size"] != panel.monitor_rect.size:
			return false
		# A new primary monitor froze its capture (17.10.2026): build the panels anew then.
		if by_name[panel.monitor_name]["primary"] != panel.primary:
			return false
	for panel in _panels:
		var monitor: Dictionary = by_name[panel.monitor_name]
		panel.monitor_rect = Rect2i(monitor["position"], panel.monitor_rect.size)
		panel.primary = monitor["primary"]
	_monitor_signature = str(monitors)
	_pending_monitor_signature = ""
	# What was sent has arrived, unless more is still on its way.
	if not _topology.busy and _queued_positions.is_empty():
		_layout_pending.clear()
	var carrying := false
	for pointer in _pointers:
		carrying = carrying or pointer.grab_panel != null
	if not carrying:
		_place_panels([], true)
	return true


## One live panel per Windows monitor, arranged like the monitors are in Windows.
func _rebuild_panels() -> void:
	# The cursor may be mid-drag on a panel that is about to disappear.
	_release_cursor_button()
	# A fresh filter, but with the tuned values of the old one.
	var tuned := _cursor_filter
	_cursor_filter = CursorFilter.new()
	for tunable: Array in TUNABLES:
		if tunable[0] == "cursor":
			_cursor_filter.set(tunable[1], tuned.get(tunable[1]))
	_cursor_owner = -1
	for pointer in _pointers:
		pointer.panel = null
		pointer.on_panel = false
		pointer.grab_panel = null
	# Whatever was sent to Windows has arrived (or failed): show what is there now.
	_layout_pending.clear()
	_queued_positions.clear()
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
	print("[capture] мониторов %d, панелей %d (%.1f с от старта)" % [monitors.size(), _panels.size(), Time.get_ticks_msec() / 1000.0])
	if _mode_change_monitor != "":
		_repair_layout()
	_resume_slot_load()
	_continue_slot_load()
	# Every monitor on one fixture; new ones on the first (slice j).
	var keys := PackedStringArray()
	for panel in _panels:
		keys.append(panel.monitor_key)
	WorldLayout.settle(_fixtures, keys)
	_refresh_fixture_section()
	_place_panels([], true)


## Puts the panels on an arc around the user, mirroring the Windows layout, or
## `layout` instead (one rectangle per panel: a move being previewed). A layout
## sent to Windows and not seen back yet is shown meanwhile. VR sizes push the
## neighbours aside; panels placed freely in VR stay where they were put; tilt
## and curvature come from the user's settings. `log_it` writes the result to the
## log (not while something is being dragged: that is every frame).
func _place_panels(layout: Array[Rect2i] = [], log_it := false) -> void:
	var rects: Array[Rect2i] = []
	if not layout.is_empty():
		rects = layout
	elif _layout_pending.size() == _panels.size():
		rects = _layout_pending
	else:
		rects = _current_rects()
	var primary_index := _primary_index()
	var row_offsets := _row_offsets(rects, primary_index)
	var scales: Array[float] = []
	var pitches: Array[float] = []
	var curvatures: Array[float] = []
	for i in _panels.size():
		var panel := _panels[i]
		panel.vr_scale = _panel_scales.get(panel.monitor_key, 1.0)
		scales.append(panel.vr_scale)
		pitches.append(_pitch_of(panel.monitor_key, row_offsets[i]))
		curvatures.append(_panel_curvatures.get(panel.monitor_key, 0.0))
	# Each fixture lays out its own monitors in its own space (centre at the origin,
	# its middle along -Z), then the panels go where the fixture is (slice j).
	var placements: Array[PanelLayout.Placement] = []
	placements.resize(_panels.size())
	for fixture in _fixtures:
		var members: Array[int] = []
		for i in _panels.size():
			if _fixture_of(_panels[i]) == fixture:
				members.append(i)
		if members.is_empty():
			continue
		var sub_rects: Array[Rect2i] = []
		var sub_scales: Array[float] = []
		var sub_pitches: Array[float] = []
		var sub_curvatures: Array[float] = []
		var sub_primary := maxi(members.find(primary_index), 0)
		for i in members:
			sub_rects.append(rects[i])
			sub_scales.append(scales[i])
			sub_pitches.append(pitches[i])
			sub_curvatures.append(curvatures[i])
		var arranged := PanelLayout.arrange(sub_rects, sub_primary, Vector3.ZERO, fixture.radius,
				WorldLayout.degrees_per_1920(fixture.radius), PANEL_MAX_ARC_DEG, sub_scales, ROW_GAP, sub_pitches, sub_curvatures)
		for k in members.size():
			var i := members[k]
			var free_at: Variant = _panel_positions.get(_panels[i].monitor_key)
			var placement := arranged[k]
			if free_at is Vector2:
				placement = PanelLayout.placement_at(free_at.x, free_at.y, placement.size, Vector3.ZERO, fixture.radius,
						_panel_pitches.get(_panels[i].monitor_key, NAN), curvatures[i])
			placement.transform = fixture.frame() * placement.transform
			placements[i] = placement
			_panels[i].distance = fixture.radius
	for i in _panels.size():
		var free_at: Variant = _panel_positions.get(_panels[i].monitor_key)
		_panels[i].place(placements[i])
		if log_it:
			print("[layout] %s%s %s в %s -> курс %+.0f°, возвышение %+.0f°, наклон %+.0f°, изгиб %.2f, %.2f x %.2f м%s" % [
					_panels[i].monitor_name, " (основной)" if _panels[i].primary else "", rects[i].size, rects[i].position,
					rad_to_deg(placements[i].heading), rad_to_deg(placements[i].elevation), rad_to_deg(placements[i].pitch),
					placements[i].curvature, placements[i].size.x, placements[i].size.y, ", свободно в VR" if free_at is Vector2 else ""])


## Each monitor's row, counted from the primary's (-1 = the row above it).
func _row_offsets(rects: Array[Rect2i], primary_index: int) -> Array[int]:
	var offsets: Array[int] = []
	offsets.resize(rects.size())
	var rows := LayoutEdit.rows(rects)
	var primary_row := 0
	for r in rows.size():
		if rows[r].has(primary_index):
			primary_row = r
	for r in rows.size():
		for i in rows[r]:
			offsets[i] = r - primary_row
	return offsets


## A monitor's own tilt, else its row's, else NAN (facing the eye).
## In the Windows layout panels stand upright unless tilted; in VR they face the
## eye (the user's choice on 18.10.2026).
func _pitch_of(monitor_key: String, row_offset: int) -> float:
	if _panel_pitches.has(monitor_key):
		return _panel_pitches[monitor_key]
	return _row_pitches.get(str(row_offset), 0.0 if _panel_options.move_mode == 0 else NAN)


func _current_rects() -> Array[Rect2i]:
	var rects: Array[Rect2i] = []
	for panel in _panels:
		rects.append(panel.monitor_rect)
	return rects


func _primary_index() -> int:
	for i in _panels.size():
		if _panels[i].primary:
			return i
	return 0


## Which grips a panel offers with the current settings: none at all when moving
## is by fist only or off (the user's choice on 17.10.2026: those modes are for
## not having anything under the panels). "Make primary" only on the others.
## The menu grip is there whenever the menu is switched on in the settings.
func _allowed_grips(panel: ScreenPanel) -> Array:
	var grips := []
	if _gesture_settings.grab_mode <= 1:
		grips = [ScreenPanel.Grip.MOVE, ScreenPanel.Grip.RESIZE, ScreenPanel.Grip.TILT, ScreenPanel.Grip.CURVE]
		if not panel.primary:
			grips.append(ScreenPanel.Grip.PRIMARY)
	if _panel_options.monitor_menu != 0:
		grips.append(ScreenPanel.Grip.MENU)
	return grips


## Moving, resizing, tilting and curving screen panels by the grips under them
## (pinch or trigger); in the fist modes a fist on a panel moves it too. Moving
## changes the Windows layout (the others make room the way Windows will, see
## LayoutEdit) or, if so set, only the place in VR.
func _update_grabs(delta: float) -> void:
	var carrying := false
	for pointer in _pointers:
		carrying = carrying or pointer.grab_panel != null
	for pointer in _pointers:
		if pointer.grab_panel != null:
			if not is_instance_valid(pointer.grab_panel):
				pointer.grab_panel = null
				continue
			var held := pointer.fist if pointer.grab_by_fist else pointer.pressed
			if pointer.active and held:
				pointer.grab_lost_sec = 0.0
				_drag(pointer)
			else:
				# Tracking or the grip may drop out for a moment: wait before letting go.
				pointer.grab_lost_sec += delta
				if pointer.grab_lost_sec >= (FIST_GRACE_SEC if pointer.grab_by_fist else GRAB_GRACE_SEC):
					_end_grab(pointer)
			continue
		if carrying or not pointer.active:
			continue
		var target: ScreenPanel = null
		var kind := 0
		if pointer.just_pressed and pointer.button == HandGestures.Click.LEFT:
			var nearest := INF
			for panel in _panels:
				var hit := panel.grip_at(pointer.origin, pointer.direction, _allowed_grips(panel))
				if int(hit.x) != ScreenPanel.Grip.NONE and hit.y < nearest:
					nearest = hit.y
					target = panel
					kind = int(hit.x)
		var by_fist := false
		# pointer.panel is still last frame's: the cursor is updated after this.
		var fist_moves := _gesture_settings.grab_mode == 1 or _gesture_settings.grab_mode == 2
		if target == null and fist_moves and pointer.fist_started and pointer.panel != null:
			target = pointer.panel
			kind = ScreenPanel.Grip.MOVE
			by_fist = true
		if target != null and kind == ScreenPanel.Grip.PRIMARY:
			# A button, not a grip: nothing to carry.
			_make_primary(target)
		elif target != null and kind == ScreenPanel.Grip.MENU:
			_toggle_monitor_menu(target)
		elif target != null and _start_grab(pointer, target, kind, by_fist):
			carrying = true

	# The grips show up when a ray comes near the panel.
	for panel in _panels:
		var allowed := _allowed_grips(panel)
		var near := false
		var hovered := ScreenPanel.Grip.NONE
		var held := ScreenPanel.Grip.NONE
		for pointer in _pointers:
			if pointer.grab_panel == panel:
				near = true
				held = pointer.grab_kind
			elif pointer.active and pointer.grab_panel == null and panel.is_near(pointer.origin, pointer.direction):
				near = true
				var hit := panel.grip_at(pointer.origin, pointer.direction, allowed)
				if int(hit.x) != ScreenPanel.Grip.NONE:
					hovered = int(hit.x)
					pointer.hit_distance = minf(pointer.hit_distance, hit.y)
		panel.show_grips(near, allowed, hovered, held)


## Windows makes primary the monitor at (0, 0): the whole layout shifts so that
## this one is there. Its taskbar moves with it; windows stay where they are.
func _make_primary(panel: ScreenPanel) -> void:
	var rects: Array[Rect2i] = _layout_pending.duplicate() if _layout_pending.size() == _panels.size() else _current_rects()
	var shift: Vector2i = -rects[_panels.find(panel)].position
	var positions := {}
	for i in _panels.size():
		rects[i] = Rect2i(rects[i].position + shift, rects[i].size)
		positions[_panels[i].monitor_name] = rects[i].position
	_layout_pending = rects
	print("[panels] %s: делаю основным" % panel.monitor_name)
	if _topology.busy:
		_queued_positions = positions
		_vdd_message = "основной экран: жду предыдущее изменение…"
	else:
		_vdd_message = "делаю %s основным…" % panel.monitor_name
		_topology.arrange(positions)


## The fixture a panel hangs on.
func _fixture_of(panel: ScreenPanel) -> WorldLayout.Fixture:
	return WorldLayout.fixture_of(_fixtures, panel.monitor_key)


## Where the pointer's ray leaves the sphere of `fixture`, as heading and
## elevation in the fixture's own space (NAN if it misses).
func _fixture_angles(pointer: Pointer, fixture: WorldLayout.Fixture) -> Vector2:
	var to_local := fixture.frame().affine_inverse()
	return PanelLayout.sphere_angles(to_local * pointer.origin, to_local.basis * pointer.direction, Vector3.ZERO, fixture.radius)


## Whether carrying a panel rearranges the Windows layout: the setting says so and
## all monitors hang on one fixture (with several, panels move in VR only until
## the Windows layout follows the seat the user is on).
func _windows_moves() -> bool:
	return _panel_options.move_mode == 0 and _fixtures.size() == 1


func _start_grab(pointer: Pointer, panel: ScreenPanel, kind: int, by_fist: bool) -> bool:
	var fixture := _fixture_of(panel)
	var angles := _fixture_angles(pointer, fixture)
	if is_nan(angles.x):
		return false
	pointer.grab_panel = panel
	pointer.grab_kind = kind
	pointer.grab_by_fist = by_fist
	pointer.grab_lost_sec = 0.0
	pointer.grab_start = angles
	pointer.snap_held = Vector2(NAN, NAN)
	pointer.grab_centre = Vector2(panel.placement.heading, panel.placement.elevation)
	pointer.grab_offset = angles - pointer.grab_centre
	pointer.grab_scale = panel.vr_scale
	pointer.grab_angle = maxf(PanelLayout.direction_of(pointer.grab_centre.x, pointer.grab_centre.y).angle_to(
			PanelLayout.direction_of(angles.x, angles.y)), 0.01)
	pointer.grab_value = panel.placement.pitch if kind == ScreenPanel.Grip.TILT else panel.placement.curvature
	if kind == ScreenPanel.Grip.MOVE:
		# From the layout as it will be: a change may still be on its way to Windows.
		_drag_rects = _layout_pending.duplicate() if _layout_pending.size() == _panels.size() else _current_rects()
		_drag_primary = _primary_index()
		_drag_preview = _drag_rects.duplicate()
		if _windows_moves() and _panel_positions.erase(panel.monitor_key):
			# Moved in the layout: it is part of the layout again at once.
			_save_settings()
			_place_panels(_drag_rects)
	print("[panels] %s: %s (%s%s)" % [panel.monitor_name, ScreenPanel.GRIP_NAMES[kind], "кулак" if by_fist else pointer.mode,
			", только VR" if kind == ScreenPanel.Grip.MOVE and not _windows_moves() else ""])
	return true


func _drag(pointer: Pointer) -> void:
	var panel := pointer.grab_panel
	var fixture := _fixture_of(panel)
	var angles := _fixture_angles(pointer, fixture)
	if is_nan(angles.x):
		return
	var magnet := _panel_options.magnet != 0
	match pointer.grab_kind:
		ScreenPanel.Grip.RESIZE:
			var centre := PanelLayout.direction_of(pointer.grab_centre.x, pointer.grab_centre.y)
			var ratio := centre.angle_to(PanelLayout.direction_of(angles.x, angles.y)) / pointer.grab_angle
			var scale := clampf(pointer.grab_scale * ratio, PANEL_SCALE_MIN, PANEL_SCALE_MAX)
			if magnet:
				# As wide or as tall as another panel, or the original size.
				var others: Array[Vector2] = []
				for other in _panels:
					if other != panel:
						others.append(other.placement.size)
				scale = PanelLayout.snap_scale(scale, panel.placement.size / panel.vr_scale, others, SIZE_MAGNET_SHARE)
			# Live, so that the neighbours move aside while the size changes.
			_panel_scales[panel.monitor_key] = scale
			_place_panels()
			return
		ScreenPanel.Grip.TILT:
			# Up and down tilts: the panel follows the hand, faster.
			var pitch := clampf(pointer.grab_value + (angles.y - pointer.grab_start.y) * TILT_GAIN,
					-deg_to_rad(75.0), deg_to_rad(75.0))
			if magnet:
				# Upright, or facing the eye.
				for candidate: float in [0.0, panel.placement.elevation]:
					if absf(pitch - candidate) < deg_to_rad(MAGNET_REACH_DEG):
						pitch = candidate
			_set_pitch(panel, pitch)
			_place_panels()
			return
		ScreenPanel.Grip.CURVE:
			# Sideways bends: to the right more, to the left less.
			var curvature := clampf(pointer.grab_value + (angles.x - pointer.grab_start.x) * CURVE_GAIN, 0.0, 1.0)
			if magnet:
				# Flat, around the eye, or like another panel.
				var candidates: Array[float] = [0.0, 1.0]
				for other in _panels:
					if other != panel and other.placement.curvature > 0.0:
						candidates.append(other.placement.curvature)
				for candidate in candidates:
					if absf(curvature - candidate) < CURVE_MAGNET:
						curvature = candidate
			if curvature > 0.0:
				_panel_curvatures[panel.monitor_key] = curvature
			else:
				_panel_curvatures.erase(panel.monitor_key)
			_place_panels()
			return
	var at := angles - pointer.grab_offset
	at.y = clampf(at.y, -1.2, 1.2)
	if not _windows_moves():
		# Only in VR: wherever it is put on its sphere, with the magnet to the other
		# panels of the same sphere.
		if magnet:
			var raw := at
			var others: Array[Vector4] = []
			var own_widths: Array[float] = []
			for other in _panels:
				if other != panel and _fixture_of(other) == fixture:
					var other_half := _visible_half(other.placement, fixture.radius)
					others.append(Vector4(other.placement.heading, other.placement.elevation, other_half.x, other_half.y))
					# This panel's width as if it stood at the other one's height.
					own_widths.append(PanelLayout.visible_half(panel.placement.size, other.placement.elevation,
							panel.placement.curvature, fixture.radius).x)
			var own_half := PanelLayout.visible_half(panel.placement.size, 0.0, panel.placement.curvature, fixture.radius)
			at = PanelLayout.snap_angles(at.x, at.y, own_half, others,
					deg_to_rad(MAGNET_REACH_DEG), pointer.snap_held, own_widths)
			pointer.snap_held = Vector2(at.x if at.x != raw.x else NAN, at.y if at.y != raw.y else NAN)
		var placed := PanelLayout.placement_at(at.x, at.y, panel.placement.size, Vector3.ZERO, fixture.radius,
				_panel_pitches.get(panel.monitor_key, NAN), panel.placement.curvature)
		placed.transform = fixture.frame() * placed.transform
		panel.place(placed)
		return
	var drop := PanelLayout.to_desktop(_drag_rects, _drag_primary, fixture.radius, WorldLayout.degrees_per_1920(fixture.radius),
			PANEL_MAX_ARC_DEG, at.x, at.y)
	var preview := LayoutEdit.move(_drag_rects, _drag_primary, _panels.find(panel), drop)
	# The carried panel stands where it will land (with the magnet to edges and
	# seams), not freely under the hand: otherwise the magnet was not seen and the
	# panel jumped when let go (18.10.2026).
	if preview != _drag_preview:
		_drag_preview = preview
		_place_panels(preview)


## Tilt: of the panel's whole row, or of this panel only (settings); a panel placed
## freely in VR is not in a row.
func _set_pitch(panel: ScreenPanel, pitch: float) -> void:
	if _panel_options.tilt_mode == 1 or _panel_positions.has(panel.monitor_key):
		_panel_pitches[panel.monitor_key] = pitch
		return
	var offsets := _row_offsets(_current_rects(), _primary_index())
	var row := offsets[_panels.find(panel)]
	_row_pitches[str(row)] = pitch
	# The whole row moves together: no panel of it keeps a tilt of its own.
	for i in _panels.size():
		if offsets[i] == row and not _panel_positions.has(_panels[i].monitor_key):
			_panel_pitches.erase(_panels[i].monitor_key)


## Half-width and half-height of a placed panel as the eye sees them (curved
## panels look narrower than flat ones), for the magnet.
func _visible_half(placement: PanelLayout.Placement, radius: float) -> Vector2:
	return PanelLayout.visible_half(placement.size, placement.elevation, placement.curvature, radius)


func _end_grab(pointer: Pointer) -> void:
	var panel := pointer.grab_panel
	pointer.grab_panel = null
	if not is_instance_valid(panel):
		return
	match pointer.grab_kind:
		ScreenPanel.Grip.RESIZE, ScreenPanel.Grip.TILT, ScreenPanel.Grip.CURVE:
			_save_settings()
			_place_panels([], true)
			print("[panels] %s: размер %.2f, наклон %+.0f°, изгиб %.2f" % [panel.monitor_name, panel.vr_scale,
					rad_to_deg(panel.placement.pitch), panel.placement.curvature])
			return
	if not _windows_moves():
		_panel_positions[panel.monitor_key] = Vector2(panel.placement.heading, panel.placement.elevation)
		_save_settings()
		print("[panels] %s: свободно в VR, курс %+.1f°, возвышение %+.1f°" % [panel.monitor_name,
				rad_to_deg(panel.placement.heading), rad_to_deg(panel.placement.elevation)])
		return
	# Moved in the layout: it is part of the layout again, wherever it was put in VR before.
	if _panel_positions.erase(panel.monitor_key):
		_save_settings()
	if _drag_preview == _drag_rects:
		_place_panels()
		print("[panels] %s: на прежнем месте" % panel.monitor_name)
		return
	var positions := {}
	var described: PackedStringArray = []
	for i in _panels.size():
		positions[_panels[i].monitor_name] = _drag_preview[i].position
		described.append("%s %s" % [_panels[i].monitor_name, _drag_preview[i].position])
	_layout_pending = _drag_preview
	_place_panels()
	print("[panels] новая раскладка: ", ", ".join(described))
	if _topology.busy:
		# One change at a time; the latest waits for the one being applied.
		_queued_positions = positions
		_vdd_message = "раскладка Windows: жду предыдущее изменение…"
	else:
		_vdd_message = "меняю раскладку Windows…"
		_topology.arrange(positions)


## Turns and shifts the play space so that the user stands at the world origin
## looking along -Z, where the panels and buttons are. The headset's own "forward"
## comes from the room setup and can point anywhere.
func _recenter() -> void:
	var recenter_start_usec := Time.get_ticks_usec()
	var head := _camera.transform
	var forward := -head.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.01:
		return
	var yaw := PI - atan2(forward.x, forward.z)
	var turn := Basis(Vector3.UP, yaw)
	_origin.transform = Transform3D(turn, -(turn * Vector3(head.origin.x, 0.0, head.origin.z)))
	_place_panels([], true)
	# The settings behind the user and the status line ahead, where they always
	# stood after aligning; they hang under the rig and go along from here.
	if _settings_root != null:
		_settings_root.global_transform = Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, 1.25, 0.9))
	_status.global_position = Vector3(0.0, 2.05, -1.2)
	# Seated (also after a restart): back to the seat, facing its sphere's middle.
	var seat := WorldLayout.find(_fixtures, _seated)
	if seat != null:
		_origin.global_transform = WorldLayout.seat_rig(seat, _camera.transform)
		_keep_world_in_place()
	elif _seated >= 0:
		_seated = -1
	# A prompt on show follows too ("Центр" or the Meta button), in front of the new view.
	if _secure_shown:
		_release_secure_button()
		_place_secure_quad()
	_recentered = true
	print("[xr] сцена выровнена по взгляду, поворот %.0f° (%.2f с от старта, заняло %.1f мс)" % [rad_to_deg(yaw),
			Time.get_ticks_msec() / 1000.0, (Time.get_ticks_usec() - recenter_start_usec) / 1000.0])


func _on_xr_event(event: StringName) -> void:
	print("[xr] событие: %s (%.1f с от старта)" % [event, Time.get_ticks_msec() / 1000.0])
	# As soon as the head is tracked (see _update_first_recenter): then the panels
	# are in view in the very first frames, together with the shader warm-up.
	if event == &"session_focussed" and not _recentered:
		_recenter_wait_sec = 0.0
	if event == &"session_visible" or event == &"session_focussed":
		if not _session_visible and not _shaders_warmed:
			_warm_up_shaders()
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
	# The PowerShell also waits for the new process: one that ends with a non-zero
	# code crashed (20.10.2026: while Link restarted, D3D12 ran out of video memory,
	# Godot fell back to Vulkan and crashed in the driver), so it is started again.
	# The app itself always quits with 0, so a normal exit or restart ends the loop.
	var command := ("Start-Sleep -Seconds 2; for ($i = 0; $i -le %d; $i++) { " +
			"$p = Start-Process -FilePath '%s' -ArgumentList '--path','%s' -PassThru; $null = $p.Handle; $p.WaitForExit(); " +
			"if ($p.ExitCode -eq 0) { break }; Start-Sleep -Seconds %d }") % [
		XR_CRASH_RELAUNCHES, OS.get_executable_path(), ProjectSettings.globalize_path("res://").trim_suffix("/"),
		int(XR_RESTART_DELAY_SEC),
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

	if _session_loss.lost and _reconnect_timer < 0.0:
		print("[xr] среда ответила XR_ERROR_SESSION_LOST — сессия потеряна")
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
	for tunable: Array in TUNABLES:
		var target := _tunable_target(tunable[0])
		target.set(tunable[1], config.get_value(tunable[0], tunable[1], target.get(tunable[1])))
	var arrangements: Variant = config.get_value("panels", "arrangements", {})
	if arrangements is Dictionary:
		var identity := {}
		for mode: String in arrangements:
			for part: String in ["positions", "scales", "pitches", "curvatures"]:
				for key: String in (arrangements[mode] as Dictionary).get(part, {}):
					identity[ScreenPanel.key_of(key)] = ScreenPanel.key_of(key)
		for mode: String in arrangements:
			_arrangements[mode] = _remapped_arrangement(arrangements[mode], identity)
	_apply_arrangement(_arrangements.get(_mode_key(), {}))
	var slots: Variant = config.get_value("layouts", "slots", {})
	if slots is Dictionary:
		_layout_slots = slots
	_custom_poses.clear()
	var poses: Variant = config.get_value("poses", "custom", [])
	if poses is Array:
		for data: Variant in poses:
			var template := HandPose.Template.from_dictionary(data) if data is Dictionary else null
			if template != null and template.is_valid():
				template.widen_to_minimum()
				_custom_poses.append(template)
	_next_custom_pose = int(config.get_value("poses", "next", _next_custom_pose))
	var bindings: Variant = config.get_value("bindings", "actions", {})
	if bindings is Dictionary:
		_bindings.merge(bindings, true)
	_move_hand = clampi(int(config.get_value("bindings", "move_hand", _move_hand)), 0, 1)
	_floor_height = float(config.get_value("world", "floor_height", _floor_height))
	_menu_mode = clampi(int(config.get_value("menus", "mode", _menu_mode)), 0, 1)
	var menus: Variant = config.get_value("menus", "list", [])
	if menus is Array and not (menus as Array).is_empty() and (menus as Array).size() <= MenuSet.MAX_CATEGORIES:
		_menus = menus
	var own: Variant = config.get_value("menus", "custom", {})
	if own is Dictionary:
		MenuSet.custom = own
	var fixtures: Variant = config.get_value("world", "fixtures", [])
	if fixtures is Array and not (fixtures as Array).is_empty():
		_fixtures.clear()
		for data: Variant in fixtures:
			if data is Dictionary:
				_fixtures.append(WorldLayout.Fixture.from_dictionary(data))
	_seated = int(config.get_value("world", "seated", -1))
	_apply_bindings()
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
	for tunable: Array in TUNABLES:
		config.set_value(tunable[0], tunable[1], _tunable_target(tunable[0]).get(tunable[1]))
	_arrangements[_mode_key()] = _own_arrangement()
	config.set_value("panels", "arrangements", _arrangements)
	config.set_value("layouts", "slots", _layout_slots)
	config.set_value("poses", "custom", _custom_poses.map(func(t: HandPose.Template) -> Dictionary: return t.to_dictionary()))
	config.set_value("poses", "next", _next_custom_pose)
	config.set_value("bindings", "actions", _bindings)
	config.set_value("bindings", "move_hand", _move_hand)
	config.set_value("world", "floor_height", _floor_height)
	config.set_value("menus", "mode", _menu_mode)
	config.set_value("menus", "list", _menus)
	config.set_value("menus", "custom", MenuSet.custom)
	config.set_value("world", "fixtures", _fixtures.map(func(f: WorldLayout.Fixture) -> Dictionary: return f.to_dictionary()))
	config.set_value("world", "seated", _seated)
	if not _slot_loading.is_empty():
		config.set_value("layouts", "pending", _slot_loading)
	if _driver_restore_pending:
		config.set_value("driver", "restore_layout", true)
		config.set_value("driver", "restore_request", _driver_restore_request)
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


func _on_topology_finished(ok: bool, code: String, detail: String) -> void:
	if _driver_saving_layout and code in ["saved", "failed"]:
		_start_driver_apply(ok)
	var text: String = TOPOLOGY_MESSAGES.get(code, code)
	_vdd_message = ("готово: " if ok else "ошибка: ") + text + ((" (" + detail + ")") if detail != "" else "")
	print("[screens] ", _vdd_message)
	if not _slot_loading.is_empty() and not ok:
		if code == "no_free_screen":
			# Not enough driver instances: create more (Quest Link reconnects; the
			# load goes on after the app has restarted, see _resume_slot_load).
			# Never fewer than there are: "apply" removes the ones above its number.
			var want := maxi(int(_slot_loading.get("count", 0)), _driver_count)
			_layout_status.text = "создаю экземпляры драйвера до %d, Link переподключится…" % want
			_save_settings()
			_vdd.apply(want)
		else:
			_layout_status.text = "не удалось: " + text
			_finish_slot_load()
	elif not _slot_loading.is_empty():
		_continue_slot_load()
	if code == "mode_set" or (not ok and _mode_change_monitor != ""):
		_repair_layout()
		_mode_change_monitor = ""
		if _monitor_menu.visible:
			_monitor_menu.show_loading(_monitor_menu.monitor_name)
			_topology.list_modes()
	if not _queued_positions.is_empty() and not _topology.busy:
		var positions := _queued_positions
		_queued_positions = {}
		_vdd_message = "меняю раскладку Windows…"
		_topology.arrange(positions)
	elif not ok and not _layout_pending.is_empty():
		# Windows refused the new layout: the panels go back to what it really is.
		_layout_pending.clear()
		_place_panels()


func _own_arrangement() -> Dictionary:
	return {"positions": _panel_positions.duplicate(), "scales": _panel_scales.duplicate(),
			"pitches": _panel_pitches.duplicate(), "row_pitches": _row_pitches.duplicate(),
			"curvatures": _panel_curvatures.duplicate()}


func _apply_arrangement(own: Dictionary) -> void:
	_panel_positions = own.get("positions", {}).duplicate()
	_panel_scales = own.get("scales", {}).duplicate()
	_panel_pitches = own.get("pitches", {}).duplicate()
	_row_pitches = own.get("row_pitches", {}).duplicate()
	_panel_curvatures = own.get("curvatures", {}).duplicate()


## Opens the menu of `panel` in front of the lower part of it, or closes it if it
## is already open there.
## A radial menu item: a keyboard shortcut, or one of the app's own actions.
## The "Меню" tab (MenuEditor): bins of functions, categories, recording shortcuts.
func _build_menu_section(tab: Node3D) -> void:
	_menu_editor = MenuEditor.new()
	tab.add_child(_menu_editor)
	_menu_editor.build(_add_button_to)
	_menu_editor.changed.connect(_on_menus_changed)
	_sync_menu_editor()


## After loading: the editor works on the loaded lists.
func _sync_menu_editor() -> void:
	if _menu_editor == null:
		return
	_menu_editor.menus = _menus
	_menu_editor.mode = _menu_mode
	_menu_editor.refresh()


func _on_menus_changed() -> void:
	_menu_mode = _menu_editor.mode
	_save_settings()
	print("[menus] %s; категорий %d, своих функций %d" % ["два уровня" if _menu_mode == MenuSet.MODE_TWO_LEVEL else "по пальцу",
			_menus.size(), MenuSet.custom.size()])


## The radial menu closed: runs the item the hand was on, if any.
func _finish_menu(index: int, how: String) -> void:
	var pointer := _pointers[index]
	var id := pointer.menu_selected
	pointer.menu_selected = ""
	if id == "":
		return
	_run_menu_action(id)
	print("[gesture] %s: меню — %s%s" % [SIDE_LABELS[index], _menu_label(id), how])


func _run_menu_action(id: String) -> void:
	var keys: Array = MenuSet.action(id)[1]
	if not keys.is_empty():
		MouseInput.press_keys(PackedInt32Array(keys))
	elif id == "center":
		# Seated, the same item stands the user up (slice j); the label says so.
		if _seated >= 0:
			_stand_up()
		else:
			_recenter()


func _menu_label(id: String) -> String:
	if id == "center" and _seated >= 0:
		return "Встать"
	return MenuSet.action(id)[0]


func _toggle_monitor_menu(panel: ScreenPanel) -> void:
	if _monitor_menu.visible and _monitor_menu.monitor_name == panel.monitor_name:
		_close_monitor_menu()
		return
	_monitor_menu.show_loading(panel.monitor_name)
	_monitor_menu.visible = true
	print("[screens] меню экрана %s" % panel.monitor_name)
	_place_monitor_menu()
	_list_modes_when_free()


func _close_monitor_menu() -> void:
	_monitor_menu.visible = false


## The topology script runs one thing at a time: ask again a little later if busy.
func _list_modes_when_free() -> void:
	if not _monitor_menu.visible:
		return
	if _topology.busy:
		get_tree().create_timer(1.0).timeout.connect(_list_modes_when_free)
	else:
		_topology.list_modes()


## Keeps the open menu with its panel (panels move when the layout changes).
func _place_monitor_menu() -> void:
	if not _monitor_menu.visible:
		return
	for panel in _panels:
		if panel.monitor_name == _monitor_menu.monitor_name:
			var lift := -panel.placement.size.y * 0.5 + MonitorMenu.SIZE.y * 0.5 + 0.03
			_monitor_menu.global_transform = panel.placement.transform * Transform3D(Basis.IDENTITY, Vector3(0.0, lift, MONITOR_MENU_FORWARD))
			return
	_monitor_menu.visible = false


func _on_modes_listed(monitors: Array) -> void:
	for entry: Dictionary in monitors:
		if str(entry.get("name", "")) == _monitor_menu.monitor_name:
			_monitor_menu.set_modes(entry)
			print("[screens] %s: %dx%d, %d Гц, масштаб %d %%" % [entry["name"], int(entry["width"]), int(entry["height"]),
					int(entry["refresh"]), int(entry["scale"])])


func _on_monitor_menu_apply(monitor_name: String, mode: String, scale: int) -> void:
	if _topology.busy:
		_vdd_message = "экраны заняты, повторите через несколько секунд"
		_monitor_menu.show_loading(monitor_name)
		_list_modes_when_free()
		return
	_mode_change_monitor = monitor_name if mode != "" else ""
	_vdd_message = "%s: %s%s…" % [monitor_name, (mode.replace("@", ", ") + " Гц") if mode != "" else "",
			(", масштаб %d %%" % scale) if scale > 0 else ""]
	print("[screens] ", _vdd_message)
	_topology.set_mode(monitor_name, mode, scale)


## After a monitor changed its resolution: if the layout overlaps or falls
## apart, that monitor is put back in its row (LayoutEdit.repair) and the fixed
## layout is sent to Windows.
func _repair_layout() -> void:
	var rects := _current_rects()
	var primary_index := _primary_index()
	if rects.is_empty() or LayoutEdit.is_valid(rects, primary_index):
		return
	var index := 0
	for i in _panels.size():
		if _panels[i].monitor_name == _mode_change_monitor:
			index = i
	var fixed := LayoutEdit.repair(rects, primary_index, index)
	var positions := {}
	for i in _panels.size():
		positions[_panels[i].monitor_name] = fixed[i].position
	print("[screens] раскладка после смены разрешения поправлена: ", positions)
	_layout_pending = fixed
	if _topology.busy:
		_queued_positions = positions
	else:
		_topology.arrange(positions)


## Settings panel, to the side of the gesture settings: how many driver instances
## (each one virtual screen) and which resolutions the driver offers. Changes are
## only collected; "Применить" writes the driver's file and restarts the driver
## once (Quest Link reconnects, the app comes back by itself).
func _build_driver_section(tab: Node3D) -> void:
	var x := 0.0
	_settings_label("Экземпляров", Vector3(x - 0.2, 0.51, 0.0), 26, tab)
	var small := Vector2(0.07, 0.052)
	_add_button_to(tab, "−", Vector3(x + 0.0, 0.51, 0.0), small, 0.25).activated.connect(_on_driver_count.bind(-1))
	_driver_count_label = _settings_label("", Vector3(x + 0.13, 0.51, 0.0), 26, tab)
	_add_button_to(tab, "+", Vector3(x + 0.26, 0.51, 0.0), small, 0.25).activated.connect(_on_driver_count.bind(1))
	_settings_label("Разрешения драйвера", Vector3(x, 0.44, 0.0), 26, tab)
	var options: Array[Vector2i] = VddConfig.PRESETS.duplicate()
	for size in VddConfig.read():
		if not options.has(size):
			options.append(size)
	options.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x * a.y < b.x * b.y)
	var per_column := ceili(options.size() / 2.0)
	for i in options.size():
		var at := Vector3(x - 0.15 + (i / per_column) * 0.3, 0.38 - (i % per_column) * 0.058, 0.0)
		var chip := _add_button_to(tab, "", at, Vector2(0.28, 0.05), 0.25)
		chip.activated.connect(_on_driver_chip.bind(options[i]))
		_driver_chips[options[i]] = chip
	var bottom := 0.38 - per_column * 0.058 - 0.03
	_driver_status = _settings_label("", Vector3(x, bottom, 0.0), 22, tab)
	_driver_apply = _add_button_to(tab, "Применить", Vector3(x, bottom - 0.08, 0.0), Vector2(0.3, 0.07), DRIVER_APPLY_HOLD_SEC)
	_driver_apply.activated.connect(_on_driver_apply)


## `reload` reads what the driver has now (when the settings panel opens).
func _refresh_driver_section(reload := false) -> void:
	if reload:
		_driver_resolutions = VddConfig.read()
		_driver_selected = _driver_resolutions.duplicate()
		_driver_count = -1
		_count_instances_when_free()
	for size: Vector2i in _driver_chips:
		var on := _driver_selected.has(size)
		var mark := "[x]" if on else "[ ]"
		var differs := on != _driver_resolutions.has(size)
		(_driver_chips[size] as VrButton).set_text("%s %d×%d%s" % [mark, size.x, size.y, " *" if differs else ""])
	if _driver_count < 0:
		_driver_count_label.text = "…"
	elif _driver_target != _driver_count:
		_driver_count_label.text = "%d → %d" % [_driver_count, _driver_target]
	else:
		_driver_count_label.text = str(_driver_count)
	var changed := _driver_count >= 0 and (_driver_target != _driver_count or _driver_selected != _driver_resolutions)
	_driver_apply.enabled = changed and not _vdd.busy and not _driver_saving_layout
	if _vdd.busy:
		_driver_status.text = "применяю: драйвер перезапускается, Link переподключится"
	elif changed:
		_driver_status.text = "* изменится после «Применить» (драйвер перезапустится,\nLink переподключится, приложение вернётся само)"
	else:
		_driver_status.text = ""


func _count_instances_when_free() -> void:
	if _topology.busy:
		get_tree().create_timer(1.0).timeout.connect(_count_instances_when_free)
	else:
		_topology.count_instances()


func _on_instances_counted(working: int, _total: int) -> void:
	_driver_count = working
	_driver_target = working
	_refresh_driver_section()


func _on_driver_count(step: int) -> void:
	if _driver_count < 0:
		return
	_driver_target = clampi(_driver_target + step, 1, DRIVER_MAX_INSTANCES)
	_refresh_driver_section()


func _on_driver_chip(size: Vector2i) -> void:
	if _driver_selected.has(size):
		# The driver needs at least one resolution.
		if _driver_selected.size() > 1:
			_driver_selected.erase(size)
	else:
		_driver_selected.append(size)
		_driver_selected.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x * a.y < b.x * b.y)
	_refresh_driver_section()


func _on_driver_apply() -> void:
	# Also while the layout is being saved for an apply already started (a second
	# press then restarted the driver twice).
	if _vdd.busy or _driver_saving_layout or _driver_count < 0:
		return
	if _driver_selected != _driver_resolutions:
		var problem := VddConfig.write(_driver_selected)
		if problem != "":
			_driver_status.text = "ошибка: " + problem
			print("[vdd] ", problem)
			return
	print("[vdd] применяю: экземпляров %d, разрешения %s" % [_driver_target, _driver_selected])
	# The driver restart attaches every instance to the desktop (18.10.2026): the
	# layout is remembered first and put back after the app has restarted.
	_driver_saving_layout = true
	_save_layout_for_apply()
	_refresh_driver_section()


func _save_layout_for_apply() -> void:
	if _topology.busy:
		get_tree().create_timer(0.5).timeout.connect(_save_layout_for_apply)
	else:
		_topology.save_layout("apply")


## After the layout is remembered (or could not be): the driver restart itself.
func _start_driver_apply(saved: bool) -> void:
	_driver_saving_layout = false
	_vdd_message = "драйвер перезапускается, Link переподключится…"
	_vdd.apply(_driver_target)
	_driver_restore_pending = saved and _vdd.busy
	_driver_restore_request = _vdd.last_request_id()
	_save_settings()
	_refresh_driver_section()


## After the restart "Apply" brings: the layout from before it, once, and only
## after the helper has finished. On 18.10.2026 the app was back while the helper
## still restarted the driver, and its last step attached every screen again.
func _restore_layout_after_apply() -> void:
	if not _restore_after_apply:
		return
	var waited := Time.get_ticks_msec() / 1000.0 - _restore_wait_started
	if _driver_restore_request != "" and not _vdd.has_answered(_driver_restore_request) and waited < RESTORE_WAIT_MAX_SEC:
		get_tree().create_timer(1.0).timeout.connect(_restore_layout_after_apply)
		return
	if not _slot_loading.is_empty():
		_restore_after_apply = false
		_driver_restore_pending = false
		_save_settings()
		return
	if _topology.busy:
		get_tree().create_timer(0.5).timeout.connect(_restore_layout_after_apply)
		return
	_restore_after_apply = false
	_driver_restore_pending = false
	_save_settings()
	print("[screens] возвращаю раскладку и окна, бывшие до «Применить»")
	_topology.restore_layout("apply")


func _on_vdd_finished(ok: bool, message: String) -> void:
	_vdd_message = ("готово: " if ok else "ошибка: ") + message
	print("[vdd] ", _vdd_message)
	if _driver_restore_pending:
		# The answer came while this process still runs: put the layout back now.
		# Also after a failure: the driver may have been restarted half way.
		_driver_restore_pending = false
		_save_settings()
		_restore_after_apply = true
		_restore_layout_after_apply()
	_refresh_driver_section(true)


## Builds the quad that shows the secure desktop (once, hidden).
func _build_secure_desktop() -> void:
	_secure_rect = TextureRect.new()
	_secure_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_secure_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_secure_viewport = SubViewport.new()
	_secure_viewport.disable_3d = true
	_secure_viewport.transparent_bg = false
	_secure_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_secure_viewport.add_child(_secure_rect)
	add_child(_secure_viewport)
	_secure_layer = OpenXRCompositionLayerQuad.new()
	_secure_layer.layer_viewport = _secure_viewport
	# Above the screen panels (sort_order -2) but behind the scene with a hole
	# punched through it, so hands, rays and menus draw over the prompt (at 100 it
	# covered them).
	_secure_layer.sort_order = -1
	_secure_layer.enable_hole_punch = true
	_secure_layer.visible = false
	_origin.add_child(_secure_layer)


## Polls the agent for the secure desktop (UAC, lock screen, Ctrl+Alt+Del). Shows
## its picture on a quad in front of the user and sends the laser's clicks to it
## (they reach the secure desktop through the agent).
func _update_secure_desktop() -> void:
	var active := MouseInput.is_secure_desktop_active()
	if active != _secure_desktop:
		_secure_desktop = active
		print("[secure] защищённый рабочий стол: ", "да" if active else "нет")
	if _secure_layer == null:
		_build_secure_desktop()

	if _secure_desktop and _secure.update():
		_secure_pixels = _secure.get_frame_size()
		_secure_origin = _secure.get_frame_origin()
		if _secure_viewport.size != _secure_pixels:
			_secure_viewport.size = _secure_pixels
		_secure_rect.texture = _secure.get_texture()

	var want := _secure_desktop and _secure_pixels.x > 0
	if want and not _secure_shown:
		_place_secure_quad()
		# The panel cursor stops for the while: it must not leave a button held.
		_release_cursor_button()
	if want != _secure_shown:
		_secure_shown = want
		_secure_layer.visible = want
		_secure_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if want else SubViewport.UPDATE_DISABLED
		if not want:
			_release_secure_button()
			# The next prompt shows only once its own first frame is in, not this one's.
			_secure_pixels = Vector2i.ZERO

	if _secure_shown:
		_update_secure_cursor()


## Puts the quad in front of the user's current view, facing them, keeping the
## captured monitor's aspect. Fixed while shown, so clicking it is steady.
func _place_secure_quad() -> void:
	var aspect := float(_secure_pixels.x) / float(maxi(_secure_pixels.y, 1))
	_secure_quad_size = Vector2(SECURE_QUAD_HEIGHT * aspect, SECURE_QUAD_HEIGHT)
	var head := _camera.global_transform
	var forward := -head.basis.z
	forward.y = 0.0
	if forward.length() < 0.01:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var center := head.origin + forward * SECURE_QUAD_DISTANCE
	center.y = head.origin.y
	var basis := Basis.looking_at(center - head.origin, Vector3.UP)
	_secure_quad_xf = Transform3D(basis, center)
	_secure_layer.global_transform = _secure_quad_xf
	_secure_layer.quad_size = _secure_quad_size


## Where the pointer's ray meets the quad: distance (or -1), and the 0..1 spot.
func _secure_hit(pointer: Pointer) -> Array:
	var normal := _secure_quad_xf.basis.z.normalized()
	var denom := pointer.direction.dot(normal)
	if absf(denom) < 1e-6:
		return [-1.0, Vector2.ZERO]
	var distance := (_secure_quad_xf.origin - pointer.origin).dot(normal) / denom
	if distance <= 0.0:
		return [-1.0, Vector2.ZERO]
	var local := _secure_quad_xf.affine_inverse() * (pointer.origin + pointer.direction * distance)
	var u := local.x / _secure_quad_size.x + 0.5
	var v := 0.5 - local.y / _secure_quad_size.y
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return [-1.0, Vector2.ZERO]
	return [distance, Vector2(u, v)]


## Drives the Windows cursor on the secure desktop from the laser and pinch. Runs
## instead of the normal panel cursor while the secure quad is shown.
func _update_secure_cursor() -> void:
	var hits: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
	var owner := -1
	var nearest := INF
	for i: int in [1, 0]: # right hand first
		var pointer := _pointers[i]
		# The panel cursor is off, so nothing else clears these this frame.
		pointer.on_panel = false
		pointer.panel = null
		if not pointer.active:
			continue
		var hit := _secure_hit(pointer)
		var distance: float = hit[0]
		if distance < 0.0:
			continue
		hits[i] = hit[1]
		pointer.on_panel = true
		pointer.hit_distance = minf(pointer.hit_distance, distance)
		if distance < nearest:
			nearest = distance
			owner = i
	# While a button is held, the pointer that pressed it keeps the cursor: the
	# other hand drifting onto the quad must not let go of it.
	if _secure_button != HandGestures.Click.NONE:
		var holder := _pointers[_secure_press_pointer]
		if not holder.active or not holder.on_panel or not holder.pressed:
			_release_secure_button()
		else:
			owner = _secure_press_pointer
	if _secure_button == HandGestures.Click.NONE:
		# Otherwise, as with the panel cursor: a press on the quad takes the cursor
		# (the other hand can always take over with a pinch), and between presses it
		# stays with whoever had it while that one still aims at the quad.
		var pressing := -1
		for i: int in [1, 0]:
			var p := _pointers[i]
			if p.on_panel and p.just_pressed and p.button != HandGestures.Click.NONE:
				pressing = i
				break
		if pressing >= 0:
			owner = pressing
		elif _secure_cursor_pointer >= 0 and _pointers[_secure_cursor_pointer].on_panel:
			owner = _secure_cursor_pointer
	_secure_cursor_pointer = owner
	if owner < 0:
		return
	var pointer := _pointers[owner]
	var spot := (hits[owner] * Vector2(_secure_pixels)).floor()
	var pixel := _secure_origin + Vector2i(clampi(int(spot.x), 0, _secure_pixels.x - 1), clampi(int(spot.y), 0, _secure_pixels.y - 1))
	MouseInput.move_to(pixel)
	if _secure_button == HandGestures.Click.NONE and pointer.just_pressed and pointer.button != HandGestures.Click.NONE:
		_secure_button = pointer.button
		_secure_press_pointer = owner
		MouseInput.set_button(_secure_button as MouseInput.Button, true)
		print("[secure] %s в %s на защищённом столе" % [CLICK_LABELS[_secure_button], pixel])


func _release_secure_button() -> void:
	if _secure_button != HandGestures.Click.NONE:
		MouseInput.set_button(_secure_button as MouseInput.Button, false)
		_secure_button = HandGestures.Click.NONE


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


## A controller in the hand, not the controller node that the hand interaction
## profile (XR_EXT_hand_interaction) drives for a bare hand: when the hand drops
## out of view, that one keeps its last pose and its last pinch or grip, and was
## taken for a controller that clicks (748 presses in one session on 16.10.2026).
func _is_real_controller(index: int) -> bool:
	var tracker := XRServer.get_tracker(CONTROLLER_TRACKER_NAMES[index]) as XRPositionalTracker
	var profile := "" if tracker == null else String(tracker.profile)
	if profile != _controller_profiles[index]:
		_controller_profiles[index] = profile
		print("[input] %s: профиль ввода %s" % [SIDE_LABELS[index], profile if profile != "" else "нет"])
	return _controllers[index].get_has_tracking_data() and profile != "" and not profile.contains("hand_interaction")


## A real hand wins over a controller; hand joints synthesised from a held
## controller do not count as a hand.
func _update_pointer(index: int, delta: float) -> void:
	var pointer := _pointers[index]
	var was_pressed := pointer.pressed
	var was_scrolling := pointer.scrolling
	pointer.tracked_hand = false
	pointer.disc_shown = false
	pointer.disc_pose_started = false
	var was_fist := pointer.fist
	pointer.fist = false
	pointer.fist_started = false
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
		var middle_tip := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP).origin
		# Any finger closing on the thumb freezes the rotation part of the ray: the
		# touches bound to a button (GestureCatalog), the index and middle without bindings.
		var tip_distance := INF
		for contact: int in [_gesture_settings.left_contact, _gesture_settings.right_contact, _gesture_settings.middle_contact]:
			if contact >= 0 and contact < HandGestures.Contact.SIDE:
				tip_distance = minf(tip_distance, thumb_tip.distance_to(
						tracker.get_hand_joint_transform(HandPose.FINGERS[contact + 1][3]).origin))
		if is_inf(tip_distance):
			tip_distance = minf(thumb_tip.distance_to(index_tip), thumb_tip.distance_to(middle_tip))
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

		var index_knuckle := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL).origin
		var index_joint := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE).origin
		var frame := HandGestures.Frame.new()
		frame.time = Time.get_ticks_usec() / 1000000.0
		frame.thumb_index = thumb_tip.distance_to(index_tip)
		frame.thumb_middle = thumb_tip.distance_to(middle_tip)
		# The side of the index finger is its first segment, knuckle to middle joint.
		frame.thumb_side = HandGestures.distance_to_segment(thumb_tip, index_knuckle, index_joint)
		frame.index_straightness = HandGestures.straightness(index_knuckle, index_joint,
				tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL).origin, index_tip)
		frame.middle_straightness = HandGestures.straightness(middle_knuckle,
				tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE).origin,
				tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL).origin, middle_tip)
		# Disc pose: fingers in line with the hand (whatever way the hand is turned) and together.
		var hand_axis := (middle_knuckle - wrist).normalized()
		frame.index_align = (index_tip - index_knuckle).normalized().dot(hand_axis)
		frame.middle_align = (middle_tip - middle_knuckle).normalized().dot(hand_axis)
		frame.index_middle = index_tip.distance_to(middle_tip)
		frame.thumb_spread = thumb_tip.distance_to(index_knuckle)
		frame.ring_to_palm = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_RING_FINGER_TIP).origin.distance_to(
				tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM).origin)
		# Palm and contact data for the two-hand gestures, the menu, swipes and calibration.
		var little_knuckle := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL).origin
		pointer.tracked_hand = true
		pointer.palm_world = palm
		pointer.palm_local = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM).origin
		pointer.palm_normal = (to_world.basis * ExtraGestures.palm_normal(wrist, index_knuckle, little_knuckle, SIDE_SIGNS[index])).normalized()
		pointer.pinch_point = to_world * thumb_tip
		pointer.contact_distances = Vector3(frame.thumb_index, frame.thumb_middle, frame.thumb_side)
		pointer.pose_features = PackedFloat32Array([frame.index_straightness, frame.middle_straightness,
				frame.index_align, frame.middle_align, frame.index_middle, frame.thumb_spread, frame.ring_to_palm])
		var ring_straightness := HandGestures.straightness(
				tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL).origin,
				tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE).origin,
				tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL).origin,
				tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_RING_FINGER_TIP).origin)
		var open_hand := frame.index_straightness > 0.85 and frame.middle_straightness > 0.85 and ring_straightness > 0.85 \
				and frame.thumb_index > _gesture_settings.pinch_release
		var joints := PackedVector3Array()
		joints.resize(HandPose.JOINT_COUNT)
		for joint in HandPose.JOINT_COUNT:
			joints[joint] = tracker.get_hand_joint_transform(joint).origin
		pointer.hand_joints = joints
		pointer.hand_features = HandPose.features(joints, SIDE_SIGNS[index], _camera.transform.origin)
		frame.thumb_ring = thumb_tip.distance_to(joints[HandPose.FINGERS[3][3]])
		frame.thumb_pinky = thumb_tip.distance_to(joints[HandPose.FINGERS[4][3]])
		if POSE_LOG and frame.time >= _pose_log_next[index]:
			_pose_log_next[index] = frame.time + POSE_LOG_STEP_SEC
			_log_pose(index, tracker, to_world, pointer)

		# A hand on the keyboard or the lap is at rest: hidden, no ray, no gestures.
		pointer.palm_drop = _camera.global_position.y - palm.y
		pointer.ray_elevation = asin(clampf(pointer.direction.y, -1.0, 1.0))
		var was_engaged := pointer.engagement.engaged
		# Paused hands and hands being recorded for calibration control nothing either.
		var resting := not pointer.engagement.update(frame.time, pointer.palm_drop, pointer.ray_elevation) \
				or _hands_paused or _calibrating >= 0 or _pose_recording >= 0
		if resting != not was_engaged:
			print("[hand] %s: %s (ниже глаз %.0f см, луч %+.0f°)" % [SIDE_LABELS[index], "в покое" if resting else "в работе",
					pointer.palm_drop * 100.0, rad_to_deg(pointer.ray_elevation)])
		# Fist (fist grab mode only): every fingertip at the palm. It carries a panel,
		# so it clicks nothing.
		var palm_local := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM).origin
		var curl := maxf(maxf(index_tip.distance_to(palm_local), middle_tip.distance_to(palm_local)),
				maxf(frame.ring_to_palm, tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP).origin.distance_to(palm_local)))
		pointer.fist_mm = curl * 1000.0
		# The poses bound to held actions (GestureCatalog): the built-in fist and
		# scroll pose keep their own recognisers, the rest go by template.
		_update_bound_poses(index, pointer, frame.time, resting)
		# The built-in fist: four fingertips at the palm, and not a thumb up (a
		# "like" has the fingers curled just the same: 20.10.2026 it was taken for a
		# fist), nor while the hand comes close to one of the user's own poses.
		var thumb_up := pointer.hand_features.size() == HandPose.FEATURE_COUNT \
				and pointer.hand_features[0] > FIST_THUMB_UP_STRAIGHT and pointer.hand_features[5] > FIST_THUMB_UP_DISTANCE
		var builtin_fist := curl < _gesture_settings.fist_curl + (FIST_RELEASE_MARGIN if was_fist else 0.0) \
				and not thumb_up and not pointer.near_own_pose
		# It has to hold FIST_DWELL_SEC to start: a hand folding into a thumb up
		# passes through a fist first (20.10.2026, once right before the "like").
		if not builtin_fist:
			pointer.fist_since = NAN
		elif not was_fist and is_nan(pointer.fist_since):
			pointer.fist_since = frame.time
		builtin_fist = builtin_fist and (was_fist or frame.time - pointer.fist_since >= FIST_DWELL_SEC)
		var grab_pose: bool = builtin_fist if _bindings["grab"] == "pose:fist" else pointer.poses.get("grab", false)
		pointer.fist = not resting and (_gesture_settings.grab_mode == 1 or _gesture_settings.grab_mode == 2) and grab_pose
		pointer.fist_started = pointer.fist and not was_fist
		if pointer.fist_started:
			print("[gesture] %s: %s (пальцы у ладони до %.0f мм)" % [SIDE_LABELS[index],
					GestureCatalog.name_of(_bindings["grab"], _custom_poses).to_lower(), curl * 1000.0])
		match _bindings["scroll"]:
			"pose:scroll":
				# Built-in, unless a recorded pose fits the hand better (it wins).
				frame.scroll_pose = 0 if pointer.scroll_yields else -1
			GestureCatalog.OFF:
				frame.scroll_pose = 0
			_:
				frame.scroll_pose = 1 if pointer.poses.get("scroll", false) else 0
		# Moving or turning with a pose: no clicks meanwhile, as with the fist.
		var travelling: bool = pointer.poses.get("move", false) or pointer.poses.get("turn", false)
		if resting or pointer.fist or travelling:
			pointer.gestures.reset()
		var gesture := HandGestures.Output.new() if resting or pointer.fist or travelling else pointer.gestures.update(frame)
		pointer.button = gesture.button
		pointer.pending = gesture.pending
		pointer.anchor_time = gesture.anchor_time
		pointer.scrolling = gesture.disc_pending or gesture.disc
		pointer.scroll = 0.0
		var fingertips := to_world * ((index_tip + middle_tip) * 0.5)
		pointer.fingertips = fingertips
		pointer.hscroll = 0.0
		if gesture.disc_started:
			pointer.using_stick = _gesture_settings.scroll_mode == 0
			if pointer.using_stick:
				pointer.stick.max_speed = _gesture_settings.stick_speed
				pointer.stick.invert_vertical = _gesture_settings.invert_vertical != 0
				pointer.stick.invert_horizontal = _gesture_settings.invert_horizontal != 0
				pointer.stick.start(fingertips, _camera.global_position, _gesture_settings.ring_tilt_degrees)
			else:
				pointer.disc.radius = _gesture_settings.disc_radius
				pointer.disc.turn_units = _gesture_settings.disc_turn_units
				pointer.disc.start(fingertips, _camera.global_position)
			print("[gesture] %s: прокрутка (%s)" % [SIDE_LABELS[index], "направление" if pointer.using_stick else "диск"])
		if gesture.disc:
			if pointer.using_stick:
				var wheel := pointer.stick.scroll(fingertips, delta)
				pointer.scroll = wheel.y
				pointer.hscroll = wheel.x
			else:
				pointer.scroll = pointer.disc.turn(fingertips)
		pointer.disc_shown = gesture.disc
		pointer.disc_pose_started = pointer.scrolling and not was_scrolling

		# Radial menu: with the palm turned to the user, the thumb on the middle, ring
		# or little fingertip opens it instead of a click (by finger, that finger picks
		# the category); keep touching, move to an item, let go to run it.
		var facing_user := pointer.palm_normal.dot((_camera.global_position - palm).normalized()) > MENU_PALM_FACING
		var menu_touches := [frame.thumb_middle, frame.thumb_ring, frame.thumb_pinky]
		if not pointer.menu_open and facing_user and not resting:
			for finger in 3:
				if menu_touches[finger] < _gesture_settings.pinch_press:
					pointer.menu_open = true
					pointer.menu_finger = finger
					pointer.menu_mode = "рука"
					pointer.menu.menus = _menus
					pointer.menu.mode = _menu_mode
					pointer.menu.open(pointer.pinch_point, _camera.global_position, finger if _menu_mode == MenuSet.MODE_FINGER else -1)
					pointer.gestures.reset()
					print("[gesture] %s: круговое меню%s" % [SIDE_LABELS[index],
							(" «%s»" % _menus[finger]["name"]) if _menu_mode == MenuSet.MODE_FINGER and finger < _menus.size() else ""])
					break
		if pointer.menu_open and pointer.menu_mode == pointer.mode:
			if float(menu_touches[pointer.menu_finger]) < _gesture_settings.pinch_release:
				pointer.menu_selected = pointer.menu.update(pointer.pinch_point)
			else:
				pointer.menu_open = false
				_finish_menu(index, "")
			pointer.gestures.reset()
			pointer.button = HandGestures.Click.NONE
			pointer.pending = pointer.menu_open

		# Swipe of the open hand sideways (as the user sees it).
		var head_right := Vector3(_camera.global_basis.x.x, 0.0, _camera.global_basis.x.z).normalized()
		pointer.swipe.distance = _gesture_settings.swipe_distance
		var swipe := pointer.swipe.update(frame.time, palm.dot(head_right),
				# Only while the hand's ray is on a screen (last frame): turning round with
				# an open hand swings it sideways too, but points it away from the screens.
				open_hand and not resting and not pointer.scrolling and not pointer.menu_open and pointer.on_panel)
		if swipe != 0:
			var keys := SWIPE_KEYS[_gesture_settings.swipe_mode][0 if swipe < 0 else 1] as Array
			MouseInput.press_keys(PackedInt32Array(keys))
			print("[gesture] %s: смахивание %s" % [SIDE_LABELS[index], "влево" if swipe < 0 else "вправо"])
		if resting:
			pointer.active = false
			pointer.mode = "покой"
	elif _is_real_controller(index) and not _hands_paused:
		pointer.active = true
		pointer.mode = "контроллер"
		pointer.origin = controller.global_position
		pointer.direction = -controller.global_basis.z.normalized()
		pointer.pending = false
		if controller.is_button_pressed(&"trigger_click"):
			pointer.button = HandGestures.Click.LEFT
		elif controller.is_button_pressed(&"grip_click"):
			pointer.button = HandGestures.Click.RIGHT
		else:
			pointer.button = HandGestures.Click.NONE
		pointer.anchor_time = NAN
		var stick_vector := controller.get_vector2(&"primary")
		# A stick that moves the user (Locomotion.Options.stick_mode) does not scroll.
		var stick := 0.0 if _stick_moves(index) else stick_vector.y
		pointer.scrolling = absf(stick) > CONTROLLER_STICK_DEADZONE
		pointer.scroll = stick * CONTROLLER_SCROLL_SPEED * delta if pointer.scrolling else 0.0
		pointer.hscroll = 0.0

		# Radial menu: hold B/Y, pick an item with the stick or by moving the
		# controller, let go to run it.
		var menu_held := controller.is_button_pressed(&"by_button")
		if not pointer.menu_open and menu_held and not was_pressed:
			pointer.menu_open = true
			pointer.menu_mode = pointer.mode
			# A controller has no fingers to pick by: always two levels.
			pointer.menu.menus = _menus
			pointer.menu.mode = MenuSet.MODE_TWO_LEVEL
			pointer.menu.open(controller.global_position, _camera.global_position)
			print("[gesture] %s: круговое меню (контроллер)" % SIDE_LABELS[index])
		if pointer.menu_open and pointer.menu_mode == pointer.mode:
			if menu_held:
				var point := controller.global_position
				if stick_vector.length() > CONTROLLER_MENU_STICK:
					# The stick points from the ring shown now: categories or items.
					var nav := pointer.menu
					var ring_centre := nav.item_centre if nav.level == 1 else nav.centre
					var reach := nav.item_radius if nav.level == 1 else nav.radius
					point = ring_centre + (nav.right * stick_vector.x + nav.up * stick_vector.y).normalized() * reach
				pointer.menu_selected = pointer.menu.update(point)
			else:
				pointer.menu_open = false
				_finish_menu(index, " (контроллер)")
			pointer.button = HandGestures.Click.NONE
			pointer.pending = pointer.menu_open
			pointer.scrolling = false
			pointer.scroll = 0.0
	else:
		pointer.active = false
		pointer.mode = "нет"
		pointer.button = HandGestures.Click.NONE
		pointer.pending = false
		pointer.scrolling = false
		pointer.scroll = 0.0
		pointer.hscroll = 0.0
		pointer.zoom_held = false
	if not pointer.tracked_hand:
		# No hand, no pose: a hand coming back starts from scratch.
		pointer.hand_joints = PackedVector3Array()
		pointer.hand_features = PackedFloat32Array()
		for matcher: HandPose.Matcher in pointer.pose_matchers.values():
			matcher.reset()
		_set_poses(index, pointer, {})
	if pointer.menu_open and pointer.menu_mode != pointer.mode:
		# Switched between hand and controller (or lost tracking): close without running.
		pointer.menu_open = false
		pointer.menu_selected = ""
	if pointer.zoom_held and pointer.button == HandGestures.Click.NONE:
		pointer.zoom_held = false
	pointer.pressed = pointer.button != HandGestures.Click.NONE and not pointer.zoom_held
	pointer.just_pressed = pointer.pressed and not was_pressed
	if pointer.pressed != was_pressed:
		print("[gesture] %s (%s): %s" % [SIDE_LABELS[index], pointer.mode,
				("нажата " + CLICK_LABELS[pointer.button]) if pointer.pressed else "отпущено"])


func _update_buttons(delta: float) -> void:
	for button in _buttons:
		# Buttons of a hidden panel cannot be pressed.
		if not button.is_visible_in_tree():
			button.update(false, false, false, delta)
			continue
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
	# The radial menu: the selected item is bright and larger.
	for i in 2:
		var pointer := _pointers[i]
		_menu_backgrounds[i].visible = pointer.menu_open
		if pointer.menu_open:
			var toward_viewer := pointer.menu.right.cross(pointer.menu.up)
			# The cylinder's axis (local Y) faces the user; set a few centimetres behind the
			# labels so that they float clearly in front of it.
			_menu_backgrounds[i].global_transform = Transform3D(Basis(pointer.menu.right, toward_viewer, -pointer.menu.up),
					pointer.menu.centre - toward_viewer * 0.035)
		# What the ring shows: the categories, or the chosen one's items with its name
		# in the middle.
		var nav := pointer.menu
		var shown: Array = []  # [text, position, highlighted]
		if pointer.menu_open:
			if nav.level == 0:
				for c in nav.menus.size():
					shown.append([nav.menus[c]["name"], nav.category_position(c), false])
			else:
				var items := MenuSet.items_of(nav.menus[nav.category])
				for k in items.size():
					shown.append([_menu_label(items[k]), nav.item_position(k, items.size()), items[k] == pointer.menu_selected])
				shown.append([nav.menus[nav.category]["name"], nav.item_centre, false])
			_menu_backgrounds[i].global_position = (nav.item_centre if nav.level == 1 else nav.centre) \
					- nav.right.cross(nav.up) * 0.035
			# The dark disc as wide as the ring shown (a ring of many items is wider).
			var across := ((nav.item_radius if nav.level == 1 else nav.radius) + 0.07) / 0.18
			_menu_backgrounds[i].scale = Vector3(across, 1.0, across)
		for k in _menu_labels[i].size():
			var label: Label3D = _menu_labels[i][k]
			label.visible = k < shown.size()
			if label.visible:
				label.text = shown[k][0]
				label.global_position = shown[k][1]
				var category_title: bool = nav.level == 1 and k == shown.size() - 1
				label.modulate = Color(1.0, 0.85, 0.3) if shown[k][2] else (Color(0.6, 0.7, 0.85) if category_title else Color(0.85, 0.9, 1.0))
				label.font_size = 34 if shown[k][2] else (22 if category_title else 26)

	# The scroll disc and the marker of where the fingertips are on it.
	for i in 2:
		var pointer := _pointers[i]
		_disc_rings[i].visible = pointer.disc_shown
		_disc_markers[i].visible = pointer.disc_shown
		if not pointer.disc_shown:
			continue
		var torus := _disc_rings[i].mesh as TorusMesh
		# The stick's ring marks full speed; the disc's ring is the track to follow.
		var radius := pointer.stick.full_offset if pointer.using_stick else pointer.disc.radius
		if not is_equal_approx(torus.outer_radius, radius + 0.003):
			torus.inner_radius = radius - 0.003
			torus.outer_radius = radius + 0.003
		if pointer.using_stick:
			_disc_rings[i].global_transform = Transform3D(pointer.stick.basis(), pointer.stick.origin)
			_disc_markers[i].global_position = pointer.stick.marker(pointer.fingertips)
		else:
			_disc_rings[i].global_transform = Transform3D(pointer.disc.basis(), pointer.disc.center)
			_disc_markers[i].global_position = pointer.disc.marker()

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

	# The floor of gravity mode: it follows the user (see _update_world_visuals).
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(40.0, 40.0)
	_floor = MeshInstance3D.new()
	_floor.mesh = floor_mesh
	_floor.material_override = _flat_material(Color(0.12, 0.14, 0.17))
	add_child(_floor)

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

		# Scroll disc: a thin ring and a marker, placed in world space each frame.
		var torus := TorusMesh.new()
		torus.inner_radius = 0.057
		torus.outer_radius = 0.063
		torus.rings = 48
		torus.ring_segments = 8
		var ring := MeshInstance3D.new()
		ring.mesh = torus
		ring.material_override = _flat_material(Color(0.85, 0.9, 1.0))
		ring.visible = false
		add_child(ring)
		_disc_rings.append(ring)
		var marker_mesh := SphereMesh.new()
		marker_mesh.radius = 0.008
		marker_mesh.height = 0.016
		var marker := MeshInstance3D.new()
		marker.mesh = marker_mesh
		marker.material_override = _flat_material(side_colors[i])
		marker.visible = false
		add_child(marker)
		_disc_markers.append(marker)

		# Radial menu labels (a pool: categories, or a category's items and its name).
		for item in MenuSet.MAX_ITEMS + 4:
			var label := Label3D.new()
			label.pixel_size = 0.0007
			label.font_size = 28
			label.outline_size = 8
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			# Over the background disc: transparent things are otherwise sorted by distance.
			label.render_priority = 2
			label.outline_render_priority = 1
			label.visible = false
			add_child(label)
			_menu_labels[i].append(label)
		# A dark disc behind the menu, so the items read against the screens.
		var background_mesh := CylinderMesh.new()
		background_mesh.top_radius = 0.18
		background_mesh.bottom_radius = 0.18
		background_mesh.height = 0.002
		background_mesh.radial_segments = 48
		var background_material := _flat_material(MENU_BACKGROUND_COLOR)
		background_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		background_material.render_priority = -1
		var background := MeshInstance3D.new()
		background.mesh = background_mesh
		background.material_override = background_material
		background.visible = false
		add_child(background)
		_menu_backgrounds.append(background)

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


func _build_helpers() -> void:
	_vdd = VddControl.new()
	_vdd.finished.connect(_on_vdd_finished)
	add_child(_vdd)
	_topology = DisplayTopology.new()
	_topology.finished.connect(_on_topology_finished)
	_topology.modes_listed.connect(_on_modes_listed)
	_topology.instances_counted.connect(_on_instances_counted)
	add_child(_topology)
	_monitor_menu = MonitorMenu.new()
	_monitor_menu.visible = false
	_monitor_menu.apply_requested.connect(_on_monitor_menu_apply)
	_monitor_menu.close_requested.connect(_close_monitor_menu)
	add_child(_monitor_menu)
	_buttons.append_array(_monitor_menu.buttons)


func _add_button_to(parent: Node3D, text: String, at: Vector3, size: Vector2, hold_time: float) -> VrButton:
	var button := VrButton.new(text, size, hold_time)
	button.position = at
	parent.add_child(button)
	_buttons.append(button)
	return button


## Settings panel behind the user, where no screen panel reaches (the screens span
## at most 300 degrees in front), in tabs so that it stays small: each tunable
## with − / + buttons, the hand ray, saved arrangements, the display driver.
## Shown and hidden with the "Настройки" button; saved on each change.
func _build_settings_panel() -> void:
	_settings_root = Node3D.new()
	_settings_root.position = Vector3(0.0, 1.25, 0.9)
	# Turned to face the user when they turn round.
	_settings_root.rotation = Vector3(0.0, PI, 0.0)
	# Always there behind the user (18.10.2026: nothing stays in front of the screens);
	# under the rig, so it goes along when the user moves through the world (slice i).
	_origin.add_child(_settings_root)

	for t in SETTINGS_TABS.size():
		var tab := Node3D.new()
		tab.visible = t == 0
		_settings_root.add_child(tab)
		_settings_tabs.append(tab)
		# The tabs in a column on the left (the user's choice, 20.10.2026), clear of
		# every tab's content, which stays right of x = -1.
		var button := _add_button_to(_settings_root, SETTINGS_TABS[t], Vector3(SETTINGS_TAB_COLUMN_X, 0.56 - t * 0.075, 0.0),
				Vector2(0.24, 0.065), 0.2)
		button.activated.connect(_show_settings_tab.bind(t))
		_settings_tab_buttons.append(button)
	_show_settings_tab(0)

	var small := Vector2(0.07, 0.052)
	var rows: Array[int] = []
	rows.resize(SETTINGS_TABS.size())
	# How many rows each tab has: a long one gets two columns.
	var totals: Array[int] = []
	totals.resize(SETTINGS_TABS.size())
	for tunable: Array in TUNABLES:
		totals[TUNABLE_TABS.get(tunable[1], 0)] += 1
	for i in TUNABLES.size():
		var t: int = TUNABLE_TABS.get(TUNABLES[i][1], 0)
		var tab := _settings_tabs[t]
		var per_column := ceili(totals[t] / 2.0) if totals[t] > SETTINGS_ROWS_PER_COLUMN else totals[t]
		var column := rows[t] / per_column
		var y := 0.52 - (rows[t] % per_column) * 0.062
		rows[t] += 1
		var x: float = [-0.5, 0.62][column] if totals[t] > SETTINGS_ROWS_PER_COLUMN else 0.15
		var name_label := _settings_label(TUNABLES[i][2], Vector3(x - 0.06, y, 0.0), 26, tab)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_add_button_to(tab, "−", Vector3(x, y, 0.0), small, 0.25).activated.connect(_on_tunable_button.bind(i, -1.0))
		if _is_slider_tunable(TUNABLES[i]):
			# A slider between − and + (20.10.2026: quicker than many presses; the
			# buttons stay for fine steps), the value after +.
			var slider := VrSlider.new()
			slider.tunable = i
			slider.position = Vector3(x + 0.165, y, 0.0)
			slider.set_range(TUNABLES[i][6], TUNABLES[i][7], TUNABLES[i][5])
			tab.add_child(slider)
			_sliders.append(slider)
			_add_button_to(tab, "+", Vector3(x + 0.33, y, 0.0), small, 0.25).activated.connect(_on_tunable_button.bind(i, 1.0))
			_settings_values.append(_settings_label("", Vector3(x + 0.46, y, 0.0), 24, tab))
		else:
			_settings_values.append(_settings_label("", Vector3(x + 0.13, y, 0.0), 26, tab))
			_add_button_to(tab, "+", Vector3(x + 0.26, y, 0.0), small, 0.25).activated.connect(_on_tunable_button.bind(i, 1.0))

	var gestures := _settings_tabs[0]
	var column_rows := ceili(rows[0] / 2.0) if rows[0] > SETTINGS_ROWS_PER_COLUMN else rows[0]
	var bottom := 0.52 - column_rows * 0.062 - 0.03
	_add_button_to(gestures, "По умолчанию", Vector3(-0.55, bottom, 0.0), Vector2(0.26, 0.08), 1.0).activated.connect(_on_tunables_default)
	# Self-tuning: record a few touches and derive the thresholds from them.
	_add_button_to(gestures, "Настроить щипок", Vector3(-0.2, bottom, 0.0), Vector2(0.3, 0.08), 0.6).activated.connect(_start_calibration.bind(0))
	_add_button_to(gestures, "Настроить бок (СКМ)", Vector3(0.17, bottom, 0.0), Vector2(0.34, 0.08), 0.6).activated.connect(_start_calibration.bind(2))
	_add_button_to(gestures, "Настроить прокрутку", Vector3(0.54, bottom, 0.0), Vector2(0.32, 0.08), 0.6).activated.connect(_start_calibration.bind(CALIBRATE_POSE))
	_calibration_status = _settings_label("Настройка: нажмите кнопку и повторяйте жест 5–8 раз", Vector3(0.0, bottom - 0.09, 0.0), 26, gestures)

	_build_ray_section(_settings_tabs[SETTINGS_TABS.find("Луч")])
	_build_layout_section(_settings_tabs[SETTINGS_TABS.find("Раскладки")])
	_build_driver_section(_settings_tabs[SETTINGS_TABS.find("Драйвер")])
	_build_bindings_section(_settings_tabs[SETTINGS_TABS.find("Назначения")])
	_build_world_section(_settings_tabs[SETTINGS_TABS.find("Мир")])
	_build_fixture_section(_settings_tabs[SETTINGS_TABS.find("Заготовки")])
	_build_menu_section(_settings_tabs[SETTINGS_TABS.find("Меню")])

	# Kept apart from the tabs so that it is not hit by accident.
	_add_button_to(_settings_root, "Выход", Vector3(1.1, 0.62, 0.0), Vector2(0.18, 0.06), EXIT_BUTTON_HOLD_SEC).activated.connect(_quit)


func _settings_label(text: String, at: Vector3, font_size: int, parent: Node3D = null) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.position = at + Vector3(0.0, 0.0, 0.002)
	label.pixel_size = 0.001
	label.font_size = font_size
	label.outline_size = 8
	(parent if parent != null else _settings_root).add_child(label)
	return label


func _show_settings_tab(index: int) -> void:
	for t in _settings_tabs.size():
		_settings_tabs[t].visible = t == index
		_settings_tab_buttons[t].set_text(("» %s «" if t == index else "%s") % SETTINGS_TABS[t])
	if SETTINGS_TABS[index] == "Драйвер" and _driver_count_label != null:
		_refresh_driver_section(true)
	_close_binding_menu()


## The hand ray: Meta's or our own, and our own ray's mix and trim (they used to
## stand in front of the user; moved here on 18.10.2026).
func _build_ray_section(tab: Node3D) -> void:
	_ray_info = _settings_label("", Vector3(0.0, 0.47, 0.0), 30, tab)
	var size := Vector2(0.3, 0.08)
	_ray_source_button = _add_button_to(tab, "Луч: Meta", Vector3(-0.33, 0.3, 0.0), size, 0.6)
	_ray_source_button.activated.connect(_on_ray_source_button)
	# Mix of our own ray: how much it follows the wrist rotation versus the hand position.
	_add_button_to(tab, "Кисть −", Vector3(0.0, 0.3, 0.0), size, 0.3).activated.connect(_on_rotation_weight_button.bind(-ROTATION_WEIGHT_STEP))
	_add_button_to(tab, "Кисть +", Vector3(0.33, 0.3, 0.0), size, 0.3).activated.connect(_on_rotation_weight_button.bind(ROTATION_WEIGHT_STEP))
	_add_button_to(tab, "Луч выше", Vector3(-0.33, 0.19, 0.0), size, 0.3).activated.connect(_on_ray_pitch_button.bind(-RAY_PITCH_STEP_DEG))
	_add_button_to(tab, "Луч ниже", Vector3(0.0, 0.19, 0.0), size, 0.3).activated.connect(_on_ray_pitch_button.bind(RAY_PITCH_STEP_DEG))
	_add_button_to(tab, "Как у Meta", Vector3(0.33, 0.19, 0.0), size, 1.0).activated.connect(_on_ray_reset_button)
	_add_button_to(tab, "Луч влево", Vector3(-0.33, 0.08, 0.0), size, 0.3).activated.connect(_on_ray_yaw_button.bind(-RAY_YAW_STEP_DEG))
	_add_button_to(tab, "Луч вправо", Vector3(0.0, 0.08, 0.0), size, 0.3).activated.connect(_on_ray_yaw_button.bind(RAY_YAW_STEP_DEG))
	_update_ray_info()


## Arrangements: back to the default of the current way of moving, and saved ones.
func _build_layout_section(tab: Node3D) -> void:
	_settings_label("Положение панелей", Vector3(0.0, 0.52, 0.0), 28, tab)
	_add_button_to(tab, "Сбросить положение", Vector3(0.0, 0.43, 0.0), Vector2(0.42, 0.07), 1.0).activated.connect(_on_layout_reset)
	for slot in LAYOUT_SLOTS:
		var y := 0.31 - slot * 0.09
		var label := _settings_label("", Vector3(-0.42, y, 0.0), 24, tab)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_slot_labels.append(label)
		_add_button_to(tab, "Сохранить", Vector3(0.22, y, 0.0), Vector2(0.22, 0.07), 1.0).activated.connect(_on_slot_save.bind(slot + 1))
		_add_button_to(tab, "Загрузить", Vector3(0.46, y, 0.0), Vector2(0.22, 0.07), 1.0).activated.connect(_on_slot_load.bind(slot + 1))
	_layout_status = _settings_label("", Vector3(0.0, 0.31 - LAYOUT_SLOTS * 0.09, 0.0), 22, tab)
	_refresh_layout_section()


func _refresh_layout_section() -> void:
	for slot in _slot_labels.size():
		var data: Dictionary = _layout_slots.get(str(slot + 1), {})
		if data.is_empty():
			_slot_labels[slot].text = "%d: пусто" % (slot + 1)
		else:
			_slot_labels[slot].text = "%d: %d экр., %s, %s" % [slot + 1, int(data.get("count", 0)),
					"VR" if int(data.get("mode", 0)) == 1 else "Windows", str(data.get("time", "")).substr(5, 11).replace("T", " ")]


func _mode_key() -> String:
	return "vr" if _panel_options.move_mode == 1 else "windows"


func _on_layout_reset() -> void:
	_apply_arrangement({})
	_save_settings()
	_place_panels([], true)
	print("[panels] положение сброшено (%s)" % _mode_key())


## A saved arrangement: the way of moving, both VR arrangements, how many screens
## and where each was in the Windows layout (by device path: stays the same when
## the driver restarts, unlike the \\.\DISPLAYnn names).
func _on_slot_save(slot: int) -> void:
	var positions := {}
	for panel in _panels:
		positions[panel.monitor_key] = panel.monitor_rect.position
	_arrangements[_mode_key()] = _own_arrangement()
	_layout_slots[str(slot)] = {"mode": _panel_options.move_mode, "count": _panels.size(), "positions": positions,
			"arrangements": _arrangements.duplicate(true), "time": Time.get_datetime_string_from_system(false, true)}
	_save_settings()
	_refresh_layout_section()
	_layout_status.text = "сохранено в ячейку %d" % slot
	print("[layouts] сохранено в ячейку %d: %d экранов, %s" % [slot, _panels.size(), _mode_key()])


## Loads a saved arrangement. If it had more or fewer screens, screens are added
## or removed one by one first (and driver instances created if there are not
## enough: then Quest Link reconnects and the load goes on after the restart).
func _on_slot_load(slot: int) -> void:
	var data: Dictionary = _layout_slots.get(str(slot), {})
	if data.is_empty():
		_layout_status.text = "ячейка %d пуста" % slot
		return
	# The arrangements are taken over once the number of screens matches.
	_arrangements[_mode_key()] = _own_arrangement()
	_panel_options.move_mode = int(data.get("mode", 0))
	_apply_arrangement(_arrangements.get(_mode_key(), {}))
	_slot_loading = data.duplicate(true)
	_slot_load_steps = 0
	_slot_waiting_count = -1
	_save_settings()
	_refresh_settings_panel()
	_place_panels([], true)
	print("[layouts] загружаю ячейку %d: %d экранов, %s" % [slot, int(data.get("count", 0)), _mode_key()])
	_continue_slot_load()


## One step of loading: a screen added or removed, or, once the number matches,
## the saved Windows layout applied. Called again when the panels are rebuilt.
##
## Called both when the panels have been rebuilt and when the topology script is
## done (it keeps watching windows for several seconds after a change): the next
## step waits until the panels show the screen added or removed and the script is
## free. Without that the load stopped half-way (18.10.2026: 3 wanted, 4 left).
func _continue_slot_load() -> void:
	if _slot_loading.is_empty() or _topology.busy or _vdd.busy:
		return
	if _slot_waiting_count >= 0 and _panels.size() != _slot_waiting_count:
		return
	_slot_waiting_count = -1
	_slot_load_steps += 1
	var want := int(_slot_loading.get("count", _panels.size()))
	if _slot_load_steps > 20:
		_layout_status.text = "не удалось подобрать число экранов (%d)" % want
		_finish_slot_load()
		return
	# The saved monitors themselves where possible: detach those not in the save,
	# attach those in it (the primary was a different one after a load, 18.10.2026).
	var saved_keys: Array = _normalized_keys(_slot_loading.get("positions", {})).keys()
	if _panels.size() < want:
		var missing := ""
		var present: Array = _panels.map(func(panel: ScreenPanel) -> String: return panel.monitor_key)
		for key: String in saved_keys:
			if not present.has(key):
				missing = key
				break
		_layout_status.text = "добавляю экран (%d из %d)…" % [_panels.size() + 1, want]
		_slot_waiting_count = _panels.size() + 1
		_topology.add_screen(missing)
		return
	if _panels.size() > want:
		var extra := ""
		for panel in _panels:
			if not panel.primary and not saved_keys.has(panel.monitor_key):
				extra = panel.monitor_key
				break
		_layout_status.text = "убираю экран (%d → %d)…" % [_panels.size(), want]
		_slot_waiting_count = _panels.size() - 1
		_topology.remove_screen(extra)
		return
	# The number matches: saved monitors to the ones there are now, then the VR
	# arrangements and the Windows layout under the current monitors' keys.
	var saved_positions: Dictionary = _normalized_keys(_slot_loading.get("positions", {}))
	var mapping := _slot_mapping(saved_positions.keys())
	var arrangements: Dictionary = _slot_loading.get("arrangements", {})
	for mode: String in ["windows", "vr"]:
		_arrangements[mode] = _remapped_arrangement(arrangements.get(mode, {}), mapping)
	_apply_arrangement(_arrangements[_mode_key()])
	var positions := _slot_positions(saved_positions, mapping)
	_finish_slot_load()
	_save_settings()
	_place_panels([], true)
	if positions.is_empty():
		_layout_status.text = "экраны на месте; сохранённая раскладка Windows к ним не подходит"
		print("[layouts] сохранённая раскладка Windows к нынешним экранам не подходит")
		return
	_layout_status.text = "раскладка загружена"
	print("[layouts] загружено: ", positions)
	_layout_pending.clear()
	_topology.arrange(positions)


## Whether "Apply" left a layout to put back ([driver] restore_layout). The flag
## stays in the settings until the restore is sent: the self-restart after Link
## may take several processes that never get a session (attempt 7 on 18.10.2026).
func _take_restore_after_apply() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK or not bool(config.get_value("driver", "restore_layout", false)):
		return
	_restore_after_apply = true
	_driver_restore_pending = true
	_driver_restore_request = str(config.get_value("driver", "restore_request", ""))
	_restore_wait_started = Time.get_ticks_msec() / 1000.0
	print("[screens] верну раскладку, бывшую до «Применить», когда помощник закончит")
	_restore_layout_after_apply()


## After the restart that new driver instances bring: a load that was under way goes on, once.
func _resume_slot_load() -> void:
	if not _slot_loading.is_empty():
		return
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK or not config.has_section_key("layouts", "pending"):
		return
	var pending: Variant = config.get_value("layouts", "pending")
	config.erase_section_key("layouts", "pending")
	config.save(SETTINGS_PATH)
	if pending is Dictionary:
		_slot_loading = pending
		_slot_load_steps = 10
		print("[layouts] продолжаю загрузку после перезапуска драйвера")


func _finish_slot_load() -> void:
	_slot_loading = {}
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK and config.has_section_key("layouts", "pending"):
		config.erase_section_key("layouts", "pending")
		config.save(SETTINGS_PATH)


## Saved monitor keys -> the current monitors' keys: the same monitor where it is
## still there, the rest in order of their keys.
func _slot_mapping(saved_keys: Array) -> Dictionary:
	var mapping := {}
	var left: Array = saved_keys.duplicate()
	left.sort()
	var free_keys: Array[String] = []
	for panel in _panels:
		if left.has(panel.monitor_key):
			mapping[panel.monitor_key] = panel.monitor_key
			left.erase(panel.monitor_key)
		else:
			free_keys.append(panel.monitor_key)
	free_keys.sort()
	for i in mini(free_keys.size(), left.size()):
		mapping[left[i]] = free_keys[i]
	return mapping


## Monitor keys made stable (see ScreenPanel.key_of): older saves used whole paths.
func _normalized_keys(by_monitor: Dictionary) -> Dictionary:
	var result := {}
	for key: String in by_monitor:
		result[ScreenPanel.key_of(key)] = by_monitor[key]
	return result


func _remapped_arrangement(arrangement: Dictionary, mapping: Dictionary) -> Dictionary:
	var result := {"row_pitches": (arrangement.get("row_pitches", {}) as Dictionary).duplicate()}
	for part: String in ["positions", "scales", "pitches", "curvatures"]:
		var remapped := {}
		var saved: Dictionary = _normalized_keys(arrangement.get(part, {}))
		for key: String in saved:
			if mapping.has(key):
				remapped[mapping[key]] = saved[key]
		result[part] = remapped
	return result


## Saved positions for the screens there are now (through `mapping`). Empty if
## that is not a valid layout, e.g. the sizes are different now.
func _slot_positions(saved: Dictionary, mapping: Dictionary) -> Dictionary:
	var by_key := {}
	for key: String in saved:
		if mapping.has(key):
			by_key[mapping[key]] = saved[key]
	var rects: Array[Rect2i] = []
	var primary := -1
	for i in _panels.size():
		var at: Vector2i = by_key.get(_panels[i].monitor_key, _panels[i].monitor_rect.position)
		rects.append(Rect2i(at, _panels[i].monitor_rect.size))
		if at == Vector2i.ZERO:
			primary = i
	if primary < 0 or not LayoutEdit.is_valid(rects, primary):
		return {}
	var positions := {}
	for i in _panels.size():
		positions[_panels[i].monitor_name] = rects[i].position
	return positions


func _tunable_target(section: String) -> Object:
	match section:
		"gestures":
			return _gesture_settings
		"engagement":
			return _engagement_settings
		"panels":
			return _panel_options
		"pause":
			return _pause
		"world":
			return _world
	return _cursor_filter


func _on_tunable_button(index: int, direction: float) -> void:
	var tunable: Array = TUNABLES[index]
	_set_tunable(index, float(_tunable_target(tunable[0]).get(tunable[1])) + direction * float(tunable[5]), true)


## Whether a setting gets a slider: a number with at least a few steps between
## its ends (a choice of two or three stays on − / +).
func _is_slider_tunable(tunable: Array) -> bool:
	return (float(tunable[7]) - float(tunable[6])) / float(tunable[5]) >= 5.0


## Sets setting `index` to `raw` (clamped and stepped as its row says); `save`
## writes the settings and logs it (a slider saves only on letting go).
func _set_tunable(index: int, raw: float, save: bool) -> void:
	var tunable: Array = TUNABLES[index]
	var target := _tunable_target(tunable[0])
	var value := snappedf(clampf(raw, tunable[6], tunable[7]), tunable[5])
	# Keep each hysteresis pair ordered: a finger has to let go further out than it touches.
	match tunable[1]:
		"pinch_press":
			value = minf(value, _gesture_settings.pinch_release - 0.005)
		"pinch_release":
			value = maxf(value, _gesture_settings.pinch_press + 0.005)
		"side_press":
			value = minf(value, _gesture_settings.side_release - 0.005)
		"side_release":
			value = maxf(value, _gesture_settings.side_press + 0.005)
	var switching: bool = tunable[1] == "move_mode" and int(value) != _panel_options.move_mode
	if switching:
		_arrangements[_mode_key()] = _own_arrangement()
	target.set(tunable[1], value)
	if switching:
		_apply_arrangement(_arrangements.get(_mode_key(), {}))
		_place_panels([], true)
	_refresh_settings_panel()
	if save:
		_save_settings()
		print("[settings] %s: %s" % [tunable[2], _settings_values[index].text])


## The settings sliders: a pinch (or trigger) that starts on one takes it; while
## held, the ray sets the value; letting go saves it.
func _update_sliders() -> void:
	for slider in _sliders:
		var hovered := false
		var visible := slider.is_visible_in_tree()
		for pointer in _pointers:
			if visible and pointer.active and pointer.slider == null and pointer.grab_panel == null:
				var distance := slider.hit_distance(pointer.origin, pointer.direction)
				if distance >= 0.0:
					hovered = true
					pointer.hit_distance = minf(pointer.hit_distance, distance)
					if pointer.just_pressed:
						pointer.slider = slider
		var held := false
		for pointer in _pointers:
			held = held or pointer.slider == slider
		slider.set_active(held, hovered)
	for pointer in _pointers:
		var slider := pointer.slider
		if slider == null:
			continue
		if pointer.active and pointer.pressed and slider.is_visible_in_tree():
			var value := slider.value_from_ray(pointer.origin, pointer.direction)
			if not is_nan(value):
				_set_tunable(slider.tunable, value, false)
			continue
		pointer.slider = null
		slider.set_active(false, false)
		_save_settings()
		print("[settings] %s: %s" % [TUNABLES[slider.tunable][2], _settings_values[slider.tunable].text])


func _on_tunables_default() -> void:
	var defaults := {"gestures": HandGestures.Settings.new(), "cursor": CursorFilter.new(), "engagement": HandEngagement.Settings.new(),
			"pause": ExtraGestures.Pause.new(), "panels": PanelOptions.new(), "world": Locomotion.Options.new()}
	var mode_before := _mode_key()
	_arrangements[mode_before] = _own_arrangement()
	for tunable: Array in TUNABLES:
		_tunable_target(tunable[0]).set(tunable[1], (defaults[tunable[0]] as Object).get(tunable[1]))
	if _mode_key() != mode_before:
		_apply_arrangement(_arrangements.get(_mode_key(), {}))
		_place_panels([], true)
	_save_settings()
	_refresh_settings_panel()
	print("[settings] жесты и курсор — значения по умолчанию")


func _refresh_settings_panel() -> void:
	for slider in _sliders:
		var tunable: Array = TUNABLES[slider.tunable]
		slider.set_value(float(_tunable_target(tunable[0]).get(tunable[1])))
	for i in mini(TUNABLES.size(), _settings_values.size()):
		var tunable: Array = TUNABLES[i]
		var value := float(_tunable_target(tunable[0]).get(tunable[1]))
		if tunable[1] == "disc_ring_curl" and value <= 0.0:
			_settings_values[i].text = "не нужно"
		elif tunable[1] == "swipe_mode":
			_settings_values[i].text = "отмена/повтор" if value >= 0.5 else "назад/вперёд"
		elif tunable[1] == "scroll_mode":
			_settings_values[i].text = "диск" if value >= 0.5 else "направление"
		elif tunable[1] == "grab_mode":
			_settings_values[i].text = ["ручка", "ручка и кулак", "только кулак", "выключен"][clampi(roundi(value), 0, 3)]
		elif tunable[1] == "monitor_menu":
			_settings_values[i].text = "показано" if value >= 0.5 else "скрыто"
		elif tunable[1] == "tilt_mode":
			_settings_values[i].text = "монитор" if value >= 0.5 else "ряд"
		elif tunable[1] == "move_mode":
			_settings_values[i].text = "только VR" if value >= 0.5 else "раскладку Windows"
		elif tunable[1] == "magnet":
			_settings_values[i].text = "да" if value >= 0.5 else "нет"
		elif tunable[1] in ["invert_vertical", "invert_horizontal"]:
			_settings_values[i].text = "да" if value >= 0.5 else "нет"
		elif tunable[1] == "travel_mode":
			_settings_values[i].text = "гравитация" if value >= 0.5 else "космос"
		elif tunable[1] == "turn_mode":
			_settings_values[i].text = ["рывками", "плавно", "выключен"][clampi(roundi(value), 0, 2)]
		elif tunable[1] == "stick_mode":
			_settings_values[i].text = ["по лучу", "прокрутка", "движение"][clampi(roundi(value), 0, 2)]
		elif tunable[1] == "grid":
			_settings_values[i].text = "да" if value >= 0.5 else "нет"
		elif tunable[1] == "vignette" and value <= 0.0:
			_settings_values[i].text = "выключено"
		elif tunable[1] in ["render_radius", "interact_radius"] and value <= 0.0:
			_settings_values[i].text = "без ограничения"
		elif tunable[1] in ["move_speed", "grid_step"]:
			_settings_values[i].text = "%.2f %s" % [value, tunable[4]] if tunable[1] == "grid_step" else "%.1f %s" % [value, tunable[4]]
		else:
			_settings_values[i].text = "%d %s" % [roundi(value * float(tunable[3])), tunable[4]]


func _flat_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material
