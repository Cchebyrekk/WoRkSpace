extends SceneTree
## Headless tests for pure functions:
##   godot --headless --xr-mode off --path . -s tests/run_tests.gd

var _failures := 0
var _checks := 0


func _init() -> void:
	_test_ray_rect()
	_test_pinch_hysteresis()
	_test_hand_ray()
	_test_recenter_math()
	_test_rect_uv()
	_test_ray_arc()
	_test_vdd_config()
	_test_monitor_key()
	_test_cursor_filter()
	_test_aim_study()
	_test_panel_layout()
	_test_layout_edit()
	_test_hand_gestures()
	_test_hand_pose()
	_test_gesture_catalog()
	_test_locomotion()
	_test_world_layout()
	_test_slider()
	_test_panel_back()
	_test_menu_set()
	_test_lookups_and_helpers()
	_test_wall_layout()
	_test_wall_split()
	_test_column_and_lean()
	_test_place_network()
	_test_desktop_groups()
	_test_world_edit()
	_test_link_protocol()
	print("%d проверок, %d провалов" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, what: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("ПРОВАЛ: ", what)


func _test_ray_rect() -> void:
	var rect := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, -2.0))
	var size := Vector2(0.4, 0.2)
	var eye := Vector3(0.0, 1.0, 0.0)
	_check(is_equal_approx(PointerMath.ray_rect_distance(eye, Vector3.FORWARD, rect, size), 2.0), "прямое попадание на 2 м")
	_check(PointerMath.ray_rect_distance(eye, Vector3.BACK, rect, size) < 0.0, "луч от прямоугольника — промах")
	_check(PointerMath.ray_rect_distance(eye, Vector3.RIGHT, rect, size) < 0.0, "параллельный луч — промах")
	_check(PointerMath.ray_rect_distance(eye + Vector3(0.19, 0.0, 0.0), Vector3.FORWARD, rect, size) > 0.0, "внутри края по X")
	_check(PointerMath.ray_rect_distance(eye + Vector3(0.21, 0.0, 0.0), Vector3.FORWARD, rect, size) < 0.0, "за краем по X")
	_check(PointerMath.ray_rect_distance(eye + Vector3(0.0, 0.11, 0.0), Vector3.FORWARD, rect, size) < 0.0, "за краем по Y")

	var turned := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(-2.0, 1.0, 0.0))
	_check(is_equal_approx(PointerMath.ray_rect_distance(eye, Vector3.LEFT, turned, size), 2.0), "повёрнутый прямоугольник слева")
	_check(PointerMath.ray_rect_distance(eye, Vector3.FORWARD, turned, size) < 0.0, "повёрнутый: луч вперёд — промах")


func _test_monitor_key() -> void:
	# The same monitor before and after the driver was reinstalled (18.10.2026).
	var before := ScreenPanel.key_of("\\\\?\\DISPLAY#MTT1337#1&2240405a&1&UID256#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}")
	var after := ScreenPanel.key_of("\\\\?\\DISPLAY#MTT1337#1&2240405a&2&UID256#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}")
	_check(before == "MTT1337#1&2240405a&UID256" and after == before, "ключ монитора не меняется при переустановке драйвера (%s, %s)" % [before, after])
	_check(ScreenPanel.key_of("\\\\.\\DISPLAY3") == "\\\\.\\DISPLAY3", "ключ без пути — как есть")
	_check(ScreenPanel.key_of(before) == before, "ключ от ключа — тот же")


func _test_vdd_config() -> void:
	var text := "<vdd_settings>\n    <monitors><count>1</count></monitors>\n    <resolutions>\n        <resolution>\n" \
			+ "            <width>1920</width>\n            <height>1080</height>\n            <refresh_rate>120</refresh_rate>\n" \
			+ "        </resolution>\n        <resolution><width>2560</width><height>1440</height><refresh_rate>60</refresh_rate></resolution>\n" \
			+ "    </resolutions>\n    <options><logging>false</logging></options>\n</vdd_settings>"
	var parsed := VddConfig.parse_resolutions(text)
	var expected: Array[Vector2i] = [Vector2i(1920, 1080), Vector2i(2560, 1440)]
	_check(parsed == expected, "настройки VDD: разрешения прочитаны")
	var wanted: Array[Vector2i] = [Vector2i(3440, 1440), Vector2i(1920, 1080)]
	var changed := VddConfig.with_resolutions(text, wanted)
	_check(VddConfig.parse_resolutions(changed) == wanted, "настройки VDD: новый список записан")
	# The layer's picture: Link refused a 5120×2160 one (22.10.2026), 3840×2160 always worked.
	_check(ScreenPanel.layer_size(Vector2i(3840, 2160)) == Vector2i(3840, 2160) and ScreenPanel.layer_size(Vector2i(5120, 2160)) == Vector2i(4096, 1728)
			and ScreenPanel.layer_size(Vector2i(1920, 8640)) == Vector2i(910, 4096), "картинка слоя — не больше 4096 по большей стороне, форма та же")
	# Too big or too thin: the most the limits allow, the shape kept (22.10.2026).
	var big_fit := VddConfig.fitted(Vector2i(5944, 4600))
	_check(VddConfig.supported(big_fit) and big_fit.x % 8 == 0 and absf(float(big_fit.x) / big_fit.y - 5944.0 / 4600.0) < 0.01
			and big_fit.x * big_fit.y > 15360 * 1080 * 0.95, "разрешение: место за пределами — наибольшее допустимое той же формы: %s" % big_fit)
	_check(VddConfig.fitted(Vector2i(1920, 1080)) == Vector2i(1920, 1080) and VddConfig.fitted(Vector2i(1920, 304)).y >= 360
			and VddConfig.fitted(Vector2i(20000, 100)) == Vector2i.ZERO, "разрешение: допустимое не меняется, тонкое поднимается, невозможное — нет")
	# Limits found on 22.10.2026 (tests/vdd_limit_probe.ps1; a taller mode crashed Windows).
	_check(VddConfig.supported(Vector2i(15360, 1080)) and VddConfig.supported(Vector2i(3840, 2160)) and VddConfig.supported(Vector2i(912, 1080))
			and VddConfig.supported(Vector2i(1920, 4320)) and VddConfig.supported(Vector2i(1920, 8640)),
			"настройки VDD: ширина до 15360, высота до 8640, 4K и полклетки допустимы")
	_check(not VddConfig.supported(Vector2i(1920, 8648)) and not VddConfig.supported(Vector2i(15992, 8104))
			and not VddConfig.supported(Vector2i(1920, 200)) and not VddConfig.supported(Vector2i(9600, 2160)),
			"настройки VDD: выше 8640, больше 15360×1080 пикселей и уже 360 — нет")
	_check(changed.contains("<count>1</count>") and changed.contains("<logging>false</logging>"), "настройки VDD: остальное не тронуто")
	_check(VddConfig.parse_resolutions("<vdd_settings/>").is_empty(), "настройки VDD: без списка — пусто")


func _test_ray_arc() -> void:
	# A curved panel 1.2 m of arc on a 1.1 m cylinder around the viewer at the origin.
	var panel := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -1.1))
	var hit := PointerMath.ray_arc(Vector3.ZERO, Vector3.FORWARD, panel, Vector2(1.2, 0.6), 1.1)
	_check(is_equal_approx(hit.x, 1.1) and is_equal_approx(hit.y, 0.5) and is_equal_approx(hit.z, 0.5), "изогнутая панель: луч в середину")
	# Around the cylinder axis every point of the arc is 1.1 m away.
	var angle := 0.4
	hit = PointerMath.ray_arc(Vector3.ZERO, Vector3(sin(angle), 0.0, -cos(angle)), panel, Vector2(1.2, 0.6), 1.1)
	_check(is_equal_approx(hit.x, 1.1) and is_equal_approx(hit.y, angle / (1.2 / 1.1) + 0.5), "изогнутая панель: u растёт по дуге")
	hit = PointerMath.ray_arc(Vector3.ZERO, Vector3(sin(0.7), 0.0, -cos(0.7)), panel, Vector2(1.2, 0.6), 1.1)
	_check(hit.x < 0.0, "изогнутая панель: мимо края — промах")
	hit = PointerMath.ray_arc(Vector3.ZERO, Vector3.BACK, panel, Vector2(1.2, 0.6), 1.1)
	_check(hit.x < 0.0, "изогнутая панель: сзади — промах")


func _test_rect_uv() -> void:
	var rect := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, -1.0))
	var size := Vector2(2.0, 1.0)
	_check(PointerMath.rect_uv(Vector3(0.0, 1.5, -1.0), rect, size).is_equal_approx(Vector2(0.5, 0.5)), "центр панели — середина экрана")
	_check(PointerMath.rect_uv(Vector3(-1.0, 2.0, -1.0), rect, size).is_equal_approx(Vector2(0.0, 0.0)), "левый верхний угол — пиксель (0, 0)")
	_check(PointerMath.rect_uv(Vector3(1.0, 1.0, -1.0), rect, size).is_equal_approx(Vector2(1.0, 1.0)), "правый нижний угол")
	var turned := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(-2.0, 1.5, 0.0))
	_check(PointerMath.rect_uv(Vector3(-2.0, 2.0, 1.0), turned, size).is_equal_approx(Vector2(0.0, 0.0)), "повёрнутая панель: левый верхний угол")


func _test_cursor_filter() -> void:
	var filter := CursorFilter.new()
	filter.lookback_sec = 0.1
	filter.drag_threshold = 25.0

	var result := filter.update(Vector2(100.0, 100.0), true, false, 0.0)
	_check(result.move and result.position == Vector2(100.0, 100.0) and not result.press, "без нажатия курсор следует за лучом")
	_check(not filter.update(Vector2(100.0, 100.0), true, false, 0.01).move, "та же точка — без лишнего перемещения")

	# The hand drifts while the fingers close: 0.05 s .. 0.19 s, then the pinch registers at 0.2 s.
	filter.update(Vector2(200.0, 200.0), true, false, 0.05)
	filter.update(Vector2(200.0, 200.0), true, false, 0.1)
	filter.update(Vector2(206.0, 204.0), true, false, 0.15)
	filter.update(Vector2(212.0, 209.0), true, false, 0.19)
	result = filter.update(Vector2(215.0, 212.0), true, true, 0.2)
	_check(result.press and result.position == Vector2(200.0, 200.0), "нажатие уходит туда, где луч был до щипка")
	_check(result.move, "перед нажатием курсор возвращается в эту точку")
	_check(filter.is_held(), "кнопка считается зажатой")

	result = filter.update(Vector2(218.0, 214.0), true, true, 0.25)
	_check(not result.move and not result.press and result.position == Vector2(200.0, 200.0), "дрожание в пределах порога курсор не двигает")
	result = filter.update(Vector2(260.0, 200.0), true, true, 0.3)
	_check(not result.move, "рывок в первые доли секунды после нажатия — ещё не перетаскивание")
	result = filter.update(Vector2(240.0, 200.0), true, true, 0.5)
	_check(result.move and result.position == Vector2(240.0, 200.0), "после задержки и за порогом начинается перетаскивание")
	result = filter.update(Vector2(242.0, 201.0), true, true, 0.55)
	_check(result.move and result.position == Vector2(242.0, 201.0), "при перетаскивании курсор следует точно")
	result = filter.update(Vector2(242.0, 201.0), true, false, 0.6)
	_check(result.release and not result.move and not filter.is_held(), "разведение пальцев отпускает кнопку на месте")

	# A quick click with a jumpy ray stays a click: pressed and released at the same pixel.
	filter = CursorFilter.new()
	filter.update(Vector2(300.0, 300.0), true, false, 0.0)
	filter.update(Vector2(300.0, 300.0), true, false, 0.1)
	result = filter.update(Vector2(330.0, 340.0), true, true, 0.2)
	_check(result.press and result.position == Vector2(300.0, 300.0), "щелчок: нажатие в точке до щипка")
	filter.update(Vector2(350.0, 280.0), true, true, 0.25)
	result = filter.update(Vector2(350.0, 280.0), true, false, 0.3)
	_check(result.release and result.position == Vector2(300.0, 300.0), "щелчок: отпускание в той же точке, несмотря на прыжок луча")

	# The second press of a double click lands exactly on the first one.
	filter.update(Vector2(320.0, 310.0), true, false, 0.35)
	filter.update(Vector2(320.0, 310.0), true, false, 0.45)
	result = filter.update(Vector2(325.0, 300.0), true, true, 0.5)
	_check(result.press and result.double_click and result.position == Vector2(300.0, 300.0), "двойной щелчок: второе нажатие прилипает к первому")
	filter.update(Vector2(325.0, 300.0), true, false, 0.55)
	# A third quick press does not chain into another double click.
	filter.update(Vector2(302.0, 301.0), true, false, 0.6)
	filter.update(Vector2(302.0, 301.0), true, false, 0.7)
	result = filter.update(Vector2(302.0, 301.0), true, true, 0.8)
	_check(result.press and not result.double_click, "третье быстрое нажатие — обычный щелчок")
	filter.update(Vector2(302.0, 301.0), true, false, 0.85)
	# Too late or too far away is a separate click.
	filter.update(Vector2(310.0, 305.0), true, false, 2.3)
	filter.update(Vector2(310.0, 305.0), true, false, 2.4)
	result = filter.update(Vector2(310.0, 305.0), true, true, 2.5)
	_check(result.position == Vector2(310.0, 305.0) and not result.double_click, "нажатие через полторы секунды — отдельный щелчок")
	filter.update(Vector2(310.0, 305.0), true, false, 2.55)
	filter.update(Vector2(900.0, 500.0), true, false, 2.6)
	filter.update(Vector2(900.0, 500.0), true, false, 2.7)
	result = filter.update(Vector2(900.0, 500.0), true, true, 2.8)
	_check(result.position == Vector2(900.0, 500.0) and not result.double_click, "нажатие далеко от предыдущего — отдельный щелчок")
	# Switched off (radius 0): a quick press near the last one stays where it is.
	filter.update(Vector2(900.0, 500.0), true, false, 2.85)
	filter.double_click_radius = 0.0
	filter.update(Vector2(905.0, 503.0), true, false, 2.9)
	filter.update(Vector2(905.0, 503.0), true, false, 3.0)
	result = filter.update(Vector2(905.0, 503.0), true, true, 3.1)
	_check(result.position == Vector2(905.0, 503.0) and not result.double_click, "двойной щелчок выключен — нажатие там, где луч")

	_check(is_equal_approx(PointerMath.adaptive_smoothing(0.0, 0.2, 0.03, 0.1, 1.0), 0.2), "неподвижный луч — сильное сглаживание")
	_check(is_equal_approx(PointerMath.adaptive_smoothing(5.0, 0.2, 0.03, 0.1, 1.0), 0.03), "быстрый поворот — почти без сглаживания")
	_check(is_equal_approx(PointerMath.adaptive_smoothing(0.55, 0.2, 0.03, 0.1, 1.0), 0.115), "посередине — среднее")

	# A press that starts off the screen is not a click, even if it wanders onto it.
	filter = CursorFilter.new()
	filter.update(Vector2(50.0, 50.0), true, false, 0.0)
	result = filter.update(Vector2.ZERO, false, true, 0.1)
	_check(not result.press and not filter.is_held(), "нажатие мимо экрана не считается")
	result = filter.update(Vector2(60.0, 60.0), true, true, 0.2)
	_check(not result.press and not result.move, "зажатый щипок, затянутый на экран, ничего не делает")

	# Leaving the screen while holding keeps the button down; opening the fingers releases it.
	filter = CursorFilter.new()
	filter.update(Vector2(10.0, 10.0), true, false, 0.0)
	filter.update(Vector2(10.0, 10.0), true, true, 0.2)
	result = filter.update(Vector2.ZERO, false, true, 0.3)
	_check(filter.is_held() and not result.release and not result.move, "луч ушёл с экрана — кнопка остаётся зажатой")
	_check(filter.update(Vector2.ZERO, false, false, 0.4).release, "и отпускается, когда пальцы разведены")


func _direction(heading: float, elevation: float) -> Vector3:
	return Vector3(sin(heading) * cos(elevation), sin(elevation), -cos(heading) * cos(elevation))


func _test_aim_study() -> void:
	# A ray built as 0.7 x shoulder line + 0.3 x hand direction, tilted down by a
	# constant angle, must be recognised as exactly that mix.
	var study: RefCounted = preload("res://src/main.gd").AimStudy.new()
	for i in 400:
		var shoulder := Vector2(0.3 * sin(i * 0.05), 0.1 + 0.2 * cos(i * 0.031))
		var forward := Vector2(0.5 * sin(i * 0.083 + 1.0), -0.2 + 0.3 * sin(i * 0.047))
		var aim := shoulder * 0.7 + forward * 0.3 + Vector2(0.0, -0.4)
		study.add(_direction(shoulder.x, shoulder.y), _direction(forward.x, forward.y), _direction(aim.x, aim.y),
				Vector3(0.01, 0.02, 0.03), Vector3.FORWARD, 0.25)
	var weights: Vector2 = study.weights()
	_check(absf(weights.x - 0.7) < 0.01 and absf(weights.y - 0.3) < 0.01, "состав луча восстанавливается: %.3f и %.3f" % [weights.x, weights.y])
	_check(study.mean_origin_in_wrist().is_equal_approx(Vector3(0.01, 0.02, 0.03)), "среднее начало луча")
	_check(is_equal_approx(study.mean_angle_to_own(), 0.25), "средний угол до своего луча")


func _test_panel_layout() -> void:
	var eye := Vector3(0.0, 1.45, 0.0)
	var distance := 1.1

	# One 1920x1080 monitor: straight ahead, 60 degrees wide, facing the user.
	var single: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080)]
	var placed := PanelLayout.arrange(single, 0, eye, distance, 60.0, 300.0)
	_check(placed.size() == 1, "одна панель на один монитор")
	_check(placed[0].transform.origin.is_equal_approx(eye + Vector3(0.0, 0.0, -distance)), "единственный монитор прямо перед глазами")
	_check(is_equal_approx(placed[0].size.x, 2.0 * distance * tan(deg_to_rad(30.0))), "1920 пикселей занимают 60 градусов")
	_check(is_equal_approx(placed[0].size.y / placed[0].size.x, 1080.0 / 1920.0), "пропорции экрана сохранены")
	_check(placed[0].transform.basis.z.is_equal_approx(Vector3.BACK), "панель лицом к пользователю")

	# Three in a row with the primary in the middle: left is left, right is right, edges meet.
	var row: Array[Rect2i] = [Rect2i(1920, 0, 1920, 1080), Rect2i(-1920, 0, 1920, 1080), Rect2i(0, 0, 1920, 1080)]
	placed = PanelLayout.arrange(row, 2, eye, distance, 60.0, 300.0)
	_check(is_zero_approx(placed[2].heading), "основной монитор по центру")
	_check(is_equal_approx(placed[0].heading, deg_to_rad(60.0)) and placed[0].transform.origin.x > 0.0, "правый монитор справа на 60 градусов")
	_check(is_equal_approx(placed[1].heading, deg_to_rad(-60.0)) and placed[1].transform.origin.x < 0.0, "левый монитор слева")
	var centre_right_edge := placed[2].transform * Vector3(placed[2].size.x * 0.5, 0.0, 0.0)
	var right_left_edge := placed[0].transform * Vector3(-placed[0].size.x * 0.5, 0.0, 0.0)
	_check(centre_right_edge.is_equal_approx(right_left_edge), "соседние панели стыкуются краями")
	_check((placed[0].transform.basis.z).dot(eye - placed[0].transform.origin) > 0.0, "боковая панель повёрнута к пользователю")
	_check(is_equal_approx(placed[0].transform.origin.distance_to(eye), distance), "все панели на одном расстоянии")

	# Two rows: the upper monitor is above, a half-shifted one sits half-way sideways.
	var rows: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(960, -1080, 1920, 1080)]
	placed = PanelLayout.arrange(rows, 0, eye, distance, 60.0, 300.0)
	_check(placed[1].elevation > 0.0 and placed[1].transform.origin.y > eye.y, "монитор выше в Windows — выше в VR")
	_check(is_equal_approx(placed[1].heading - placed[0].heading, deg_to_rad(30.0)), "сдвиг на пол-экрана — сдвиг на половину угла")
	_check(is_zero_approx(placed[0].elevation), "ряд основного монитора — на уровне глаз")
	var lower_top := placed[0].transform.origin.y + placed[0].size.y * 0.5
	var upper_bottom := (placed[1].transform * Vector3(0.0, -placed[1].size.y * 0.5, 0.0)).y
	_check(absf(upper_bottom - lower_top) < 0.03, "ряды стыкуются по вертикали")

	# A smaller monitor keeps its relative size.
	var mixed: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 1280, 720)]
	placed = PanelLayout.arrange(mixed, 0, eye, distance, 60.0, 300.0)
	_check(placed[1].size.x < placed[0].size.x and is_equal_approx(placed[1].size.y / placed[1].size.x, 720.0 / 1280.0), "маленький монитор — маленькая панель")

	# Eight in a row would be 480 degrees: shrunk to the allowed arc, order kept, nothing behind.
	var wide: Array[Rect2i] = []
	for i in 8:
		wide.append(Rect2i(i * 1920, 0, 1920, 1080))
	placed = PanelLayout.arrange(wide, 0, eye, distance, 60.0, 300.0)
	var ordered := true
	for i in range(1, 8):
		ordered = ordered and placed[i].heading > placed[i - 1].heading
	_check(ordered, "восемь в ряд: порядок слева направо сохранён")
	_check(is_equal_approx(placed[7].heading - placed[0].heading, deg_to_rad(300.0 * 7.0 / 8.0)), "восемь в ряд: ряд ужат до 300 градусов")
	_check(is_equal_approx(placed[0].heading, -placed[7].heading), "восемь в ряд: дуга симметрична")
	_check(placed[0].size.x < 2.0 * distance * tan(deg_to_rad(30.0)), "восемь в ряд: панели стали меньше")

	# The group is centred, not the primary: three in a row with the primary on the
	# left still put the middle one straight ahead (reported by the user on 15.10.2026).
	var three: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 1920, 1080), Rect2i(3840, 0, 1920, 1080)]
	placed = PanelLayout.arrange(three, 0, eye, distance, 60.0, 300.0)
	_check(is_zero_approx(placed[1].heading), "три в ряд, основной слева: средний прямо перед глазами")
	_check(is_equal_approx(placed[0].heading, deg_to_rad(-60.0)), "три в ряд: основной слева на 60 градусов")

	# A centred group in a row that fits keeps the full scale.
	var five: Array[Rect2i] = []
	for i in 5:
		five.append(Rect2i(i * 1920, 0, 1920, 1080))
	placed = PanelLayout.arrange(five, 2, eye, distance, 60.0, 300.0)
	_check(is_zero_approx(placed[2].heading) and is_equal_approx(placed[4].heading, deg_to_rad(120.0)), "пять в ряд: основной по центру, масштаб не меняется")
	_check(PanelLayout.arrange([] as Array[Rect2i], 0, eye, distance, 60.0, 300.0).is_empty(), "нет мониторов — нет панелей")

	# Back from VR to the desktop: the centre of each panel maps to the centre of its monitor.
	placed = PanelLayout.arrange(rows, 0, eye, distance, 60.0, 300.0)
	var back := PanelLayout.to_desktop(rows, 0, distance, 60.0, 300.0, placed[1].heading, placed[1].elevation)
	_check(back.is_equal_approx(Vector2(rows[1].get_center())), "из VR обратно в пиксели: центр панели — центр монитора")

	# A panel enlarged in VR pushes its neighbours aside: they still meet edge to edge.
	var trio: Array[Rect2i] = [Rect2i(-1920, 0, 1920, 1080), Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 1920, 1080)]
	placed = PanelLayout.arrange(trio, 1, eye, distance, 60.0, 300.0, [1.0, 1.5, 1.0] as Array[float])
	var middle_right := placed[1].transform * Vector3(placed[1].size.x * 0.5, 0.0, 0.0)
	var right_left := placed[2].transform * Vector3(-placed[2].size.x * 0.5, 0.0, 0.0)
	_check(is_zero_approx(placed[1].heading), "увеличенная средняя панель осталась прямо перед глазами")
	# Flat panels of different sizes meet at different depths; from the eye the edges line up.
	_check((middle_right - eye).normalized().angle_to((right_left - eye).normalized()) < 0.002, "увеличенная панель: соседи стыкуются гранью к грани")
	_check(is_equal_approx(placed[1].size.x, 1.5 * 2.0 * distance * tan(deg_to_rad(30.0))), "увеличенная панель в полтора раза шире")
	_check(is_equal_approx(placed[0].heading, -placed[2].heading), "увеличенная панель: соседи раздвинулись поровну")

	# Below (and above) eye level panels facing the eye used to cut into each other
	# (reported on 16.10.2026). Seen from above, the right-most corner of the left
	# panel must not pass the left-most corner of the right one, leaning or curved.
	var two_below: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(-960, 1080, 1920, 1080), Rect2i(960, 1080, 1920, 1080)]
	for variant in [[[] as Array[float], [] as Array[float], "к глазу"],
			[[NAN, 0.0, 0.0] as Array[float], [] as Array[float], "стоят прямо"],
			[[] as Array[float], [0.0, 0.8, 0.8] as Array[float], "изогнуты"]]:
		placed = PanelLayout.arrange(two_below, 0, eye, distance, 60.0, 300.0, [] as Array[float], 0.07, variant[0], variant[1])
		var left_edge := -INF
		var right_edge := INF
		for corner in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
			var left_point := _panel_point(placed[1], corner, distance)
			var right_point := _panel_point(placed[2], corner, distance)
			left_edge = maxf(left_edge, atan2(left_point.x - eye.x, -(left_point.z - eye.z)))
			right_edge = minf(right_edge, atan2(right_point.x - eye.x, -(right_point.z - eye.z)))
		_check(left_edge <= right_edge + 0.002, "ряд ниже глаз (%s): панели не заходят друг в друга" % variant[2])
		_check(right_edge - left_edge < deg_to_rad(4.0), "ряд ниже глаз (%s): и не расходятся заметно" % variant[2])

	# Two leaning panels over the seams of three: their seam stays over the middle
	# of the middle panel below (it was off-centre, 18.10.2026).
	var two_over_three: Array[Rect2i] = [Rect2i(-1920, 0, 1920, 1080), Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 1920, 1080),
			Rect2i(-960, -1080, 1920, 1080), Rect2i(960, -1080, 1920, 1080)]
	placed = PanelLayout.arrange(two_over_three, 1, eye, distance, 60.0, 300.0, [] as Array[float], 0.07)
	var seam_left := _panel_point(placed[3], Vector2(1, 0), distance)
	var seam_right := _panel_point(placed[4], Vector2(-1, 0), distance)
	var seam_heading := (atan2(seam_left.x - eye.x, -(seam_left.z - eye.z)) + atan2(seam_right.x - eye.x, -(seam_right.z - eye.z))) * 0.5
	_check(absf(seam_heading - placed[1].heading) < deg_to_rad(0.5), "два наклонённых над тремя: стык по центру среднего")

	# A gap between rows, for the handles.
	placed = PanelLayout.arrange(rows, 0, eye, distance, 60.0, 300.0, [] as Array[float], 0.07)
	lower_top = placed[0].transform.origin.y + placed[0].size.y * 0.5
	upper_bottom = (placed[1].transform * Vector3(0.0, -placed[1].size.y * 0.5, 0.0)).y
	_check(upper_bottom - lower_top > 0.05 and upper_bottom - lower_top < 0.08, "между рядами зазор под ручку")
	_check(is_zero_approx(placed[0].elevation), "с зазором ряд основного по-прежнему на уровне глаз")

	# Magnets for panels placed in VR.
	var other := Vector4(0.0, 0.0, 0.5, 0.3)
	var snapped := PanelLayout.snap_angles(1.03, 0.02, Vector2(0.5, 0.3), [other] as Array[Vector4], deg_to_rad(3.0))
	_check(snapped.is_equal_approx(Vector2(1.0, 0.0)), "магнит: панель прилипает грань к грани и по высоте")
	snapped = PanelLayout.snap_angles(1.3, 0.4, Vector2(0.5, 0.3), [other] as Array[Vector4], deg_to_rad(3.0))
	_check(snapped.is_equal_approx(Vector2(1.3, 0.4)), "магнит: вдали панель не трогает")
	# Held at one place (1.0, edge to edge with `other`), pulled near another (1.03,
	# in line with a second panel): the nearer one wins (it stayed a little off, 17.10.2026).
	var two_others := [other, Vector4(1.03, 0.0, 0.5, 0.3)] as Array[Vector4]
	snapped = PanelLayout.snap_angles(1.04, 0.0, Vector2(0.5, 0.3), two_others, deg_to_rad(3.0), Vector2(1.0, NAN))
	_check(is_equal_approx(snapped.x, 1.03), "магнит: удержание не мешает точной точке рядом")
	# Moving the panel up and down along an edge must not make it creep sideways (17.10.2026).
	var neighbour := Vector4(0.0, 0.2, 0.5, 0.3)
	var widths := [PanelLayout.visible_half(Vector2(1.27, 0.71), 0.2, 0.0, distance).x] as Array[float]
	var low := PanelLayout.snap_angles(1.05, -0.1, Vector2(0.5, 0.3), [neighbour] as Array[Vector4], deg_to_rad(3.0), Vector2(NAN, NAN), widths)
	var high := PanelLayout.snap_angles(1.05, 0.35, Vector2(0.5, 0.3), [neighbour] as Array[Vector4], deg_to_rad(3.0), Vector2(NAN, NAN), widths)
	_check(is_equal_approx(low.x, high.x) and not is_equal_approx(low.x, 1.05), "магнит: вдоль края вверх-вниз панель не ползёт вбок")

	# Just past the reach it still holds; well past it lets go.
	snapped = PanelLayout.snap_angles(1.0 + deg_to_rad(4.0), 0.3, Vector2(0.5, 0.3), [other] as Array[Vector4], deg_to_rad(3.0), Vector2(1.0, NAN))
	_check(is_equal_approx(snapped.x, 1.0), "магнит: у границы держит")
	snapped = PanelLayout.snap_angles(1.0 + deg_to_rad(6.0), 0.3, Vector2(0.5, 0.3), [other] as Array[Vector4], deg_to_rad(3.0), Vector2(1.0, NAN))
	_check(is_equal_approx(snapped.x, 1.0 + deg_to_rad(6.0)), "магнит: дальше отпускает")
	_check(is_equal_approx(PanelLayout.snap_scale(1.02, Vector2(0.5, 0.3), [] as Array[Vector2], 0.04), 1.0), "магнит размера: к исходному")
	var bigger := Vector2(0.5, 0.3) * 1.5
	_check(is_equal_approx(PanelLayout.snap_scale(1.47, Vector2(0.5, 0.3), [bigger] as Array[Vector2], 0.04), 1.5), "магнит размера: как у соседа")
	_check(is_equal_approx(PanelLayout.snap_scale(1.3, Vector2(0.5, 0.3), [bigger] as Array[Vector2], 0.04), 1.3), "магнит размера: вдали не трогает")

	# A curved panel looks narrower than a flat one: the magnet has to see that.
	var flat_half := PanelLayout.visible_half(Vector2(1.27, 0.71), 0.0, 0.0, distance)
	var curved_half := PanelLayout.visible_half(Vector2(1.27, 0.71), 0.0, 1.0, distance)
	_check(is_equal_approx(flat_half.x, atan(0.635 / distance)), "видимая ширина плоской панели")
	_check(is_equal_approx(curved_half.x, 1.27 * 0.5 / distance), "изогнутая вокруг глаза: видимая половина — половина дуги")

	# Where a ray from the hand leaves the sphere of panels.
	var angles := PanelLayout.sphere_angles(eye, PanelLayout.direction_of(0.5, 0.2), eye, distance)
	_check(angles.is_equal_approx(Vector2(0.5, 0.2)), "луч из глаза: курс и возвышение совпадают с направлением")
	angles = PanelLayout.sphere_angles(eye + Vector3(0.2, -0.3, -0.3), Vector3.FORWARD, eye, distance)
	_check(angles.x > 0.0 and angles.y < 0.0 and angles.x < 0.3, "луч от руки справа снизу выходит справа снизу")


## A corner (±1, ±1) of a placed panel in world space; curved panels bend towards the eye.
func _panel_point(placement: PanelLayout.Placement, corner: Vector2, distance: float) -> Vector3:
	var local := Vector3(corner.x * placement.size.x * 0.5, corner.y * placement.size.y * 0.5, 0.0)
	if placement.curvature > 0.0:
		var radius := PanelLayout.curve_radius(placement.curvature, distance)
		var angle := corner.x * placement.size.x * 0.5 / radius
		local = Vector3(radius * sin(angle), local.y, radius * (1.0 - cos(angle)))
	return placement.transform * local


func _layout_is_valid(rects: Array[Rect2i], primary: int) -> bool:
	if rects[primary].position != Vector2i.ZERO:
		return false
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if rects[i].intersects(rects[j]):
				return false
	# Connected: a monitor touches another along an edge (not just a corner).
	var reached := {0: true}
	var changed := true
	while changed:
		changed = false
		for i in rects.size():
			if reached.has(i):
				continue
			for j: int in reached.keys():
				var a := rects[i]
				var b := rects[j]
				var side := (a.end.x == b.position.x or b.end.x == a.position.x) and mini(a.end.y, b.end.y) > maxi(a.position.y, b.position.y)
				var stacked := (a.end.y == b.position.y or b.end.y == a.position.y) and mini(a.end.x, b.end.x) > maxi(a.position.x, b.position.x)
				if side or stacked:
					reached[i] = true
					changed = true
					break
	return reached.size() == rects.size()


func _test_layout_edit() -> void:
	var three: Array[Rect2i] = [Rect2i(-1920, 0, 1920, 1080), Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 1920, 1080)]
	var rows := LayoutEdit.rows(three)
	_check(rows.size() == 1 and rows[0] == PackedInt32Array([0, 1, 2]), "три в ряд — один ряд слева направо")

	# The left monitor dropped to the right of the right one: order becomes 1, 2, 0.
	var moved := LayoutEdit.move(three, 1, 0, Vector2(4000.0, 540.0))
	_check(_layout_is_valid(moved, 1), "перенос вправо: раскладка допустима")
	_check(moved[1].position.x < moved[2].position.x and moved[2].position.x < moved[0].position.x, "перенос вправо: порядок 1, 2, 0")
	_check(moved[0].position.y == 0 and moved[2].position.y == 0, "перенос вправо: все в одном ряду")

	# Dropped between two neighbours: goes in between.
	moved = LayoutEdit.move(three, 1, 2, Vector2(-900.0, 540.0))
	_check(_layout_is_valid(moved, 1), "вставка между соседями: раскладка допустима")
	_check(moved[0].position.x < moved[2].position.x and moved[2].position.x < moved[1].position.x, "вставка между соседями: порядок 0, 2, 1")

	# Dropped well above: a new row on top, touching the row below.
	moved = LayoutEdit.move(three, 1, 2, Vector2(960.0, -1200.0))
	_check(_layout_is_valid(moved, 1), "новый ряд сверху: раскладка допустима")
	_check(moved[2].end.y == 0, "новый ряд сверху: стоит на ряду ниже")
	_check(moved[0].position.y == 0 and moved[1].position.y == 0, "новый ряд сверху: нижний ряд на месте")

	# The middle one moved up: left and right close the gap.
	moved = LayoutEdit.move(three, 0, 1, Vector2(0.0, -1200.0))
	_check(_layout_is_valid(moved, 0), "средний наверх: раскладка допустима")
	_check(moved[0].end.x == moved[2].position.x, "средний наверх: соседи сомкнулись")

	# Back down from a second row into the first.
	var two_rows: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 1920, 1080), Rect2i(960, -1080, 1920, 1080)]
	_check(LayoutEdit.rows(two_rows).size() == 2, "два ряда распознаны")
	moved = LayoutEdit.move(two_rows, 0, 2, Vector2(5000.0, 500.0))
	_check(_layout_is_valid(moved, 0), "из верхнего ряда в нижний: раскладка допустима")
	_check(LayoutEdit.rows(moved).size() == 1 and moved[2].position.x == moved[1].end.x, "из верхнего ряда в нижний: встал справа")

	# A new row far to the side still overlaps the row it sits on.
	moved = LayoutEdit.move(three, 1, 0, Vector2(20000.0, 3000.0))
	_check(_layout_is_valid(moved, 1), "новый ряд далеко сбоку: раскладка допустима")

	# Moving the primary keeps it at (0, 0) and the layout valid; mixed sizes too.
	var mixed: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 2560, 1440), Rect2i(-1280, 0, 1280, 720)]
	moved = LayoutEdit.move(mixed, 0, 0, Vector2(6000.0, 700.0))
	_check(_layout_is_valid(moved, 0), "перенос основного и разные размеры: раскладка допустима")
	_check(moved[1].size == Vector2i(2560, 1440), "размеры мониторов не меняются")

	# Two over the seams of three ("45 degrees", asked for on 16.10.2026): the magnet
	# puts the middle of an upper monitor on the edge between two lower ones.
	var five: Array[Rect2i] = [Rect2i(-1920, 0, 1920, 1080), Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 1920, 1080),
			Rect2i(-1920, -1080, 1920, 1080), Rect2i(0, -1080, 1920, 1080)]
	moved = LayoutEdit.move(five, 1, 4, Vector2(1900.0, -500.0))
	_check(_layout_is_valid(moved, 1), "над стыком: раскладка допустима")
	_check(moved[4].position == Vector2i(960, -1080), "над стыком: середина верхнего на стыке нижних")
	_check(moved[3].position == Vector2i(-1920, -1080), "над стыком: второй верхний не сдвинулся")
	moved = LayoutEdit.move(moved, 1, 3, Vector2(30.0, -560.0))
	_check(moved[3].position == Vector2i(-960, -1080) and moved[4].position == Vector2i(960, -1080), "два над стыками трёх")

	# An upper row on the right, away from the existing upper monitor (reported on 16.10.2026).
	var with_top_left: Array[Rect2i] = [Rect2i(-1920, 0, 1920, 1080), Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 1920, 1080),
			Rect2i(-1920, -1080, 1920, 1080)]
	moved = LayoutEdit.move(with_top_left, 1, 0, Vector2(2900.0, -560.0))
	_check(_layout_is_valid(moved, 1), "второй ряд справа: раскладка допустима")
	_check(moved[0].position.y == -1080 and moved[0].position.x > moved[3].position.x, "второй ряд справа: встал наверх справа")

	# A monitor switched to a bigger resolution overlaps its neighbour: repaired.
	var grown: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 1920, 1080), Rect2i(-1920, 0, 1920, 1080)]
	grown[2] = Rect2i(-1920, 0, 2560, 1440)
	_check(not LayoutEdit.is_valid(grown, 0), "проверка раскладки: наложение замечено")
	var repaired := LayoutEdit.repair(grown, 0, 2)
	_check(LayoutEdit.is_valid(repaired, 0) and _layout_is_valid(repaired, 0), "выросший монитор: раскладка исправлена")
	_check(repaired[2].end.x == 0 and repaired[1].position.x == 1920, "выросший монитор: встал слева вплотную, остальные на месте")
	_check(LayoutEdit.is_valid(three, 1), "проверка раскладки: нормальная раскладка допустима")
	var apart: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(2000, 0, 1920, 1080)]
	_check(not LayoutEdit.is_valid(apart, 0), "проверка раскладки: разрыв замечен")

	# Dropping where it already is changes nothing.
	moved = LayoutEdit.move(three, 1, 2, Vector2(2880.0, 540.0))
	_check(moved == three, "отпустили на том же месте — раскладка та же")


## A hand with fingers pointing forward (not the disc pose) and the given contact distances.
func _hand(time: float, thumb_index: float, thumb_middle := 0.06, thumb_side := 0.05) -> HandGestures.Frame:
	var frame := HandGestures.Frame.new()
	frame.time = time
	frame.thumb_index = thumb_index
	frame.thumb_middle = thumb_middle
	frame.thumb_side = thumb_side
	frame.index_straightness = 0.95
	frame.middle_straightness = 0.95
	frame.index_align = 0.95
	frame.middle_align = 0.95
	frame.index_middle = 0.03
	frame.thumb_spread = 0.04
	frame.ring_to_palm = 0.05
	return frame


## The disc pose: index and middle straight, in line with the hand and together,
## thumb out, ring curled.
func _disc_pose(time: float, ring_to_palm := 0.05, align := 0.95, together := 0.015) -> HandGestures.Frame:
	var frame := _hand(time, 0.09, 0.09, 0.07)
	frame.index_align = align
	frame.middle_align = align
	frame.index_middle = together
	frame.thumb_spread = 0.08
	frame.ring_to_palm = ring_to_palm
	return frame


## Joints of a synthesized hand moved and turned somewhere in the room, the way the
## tracker would report them.
func _placed(joints: PackedVector3Array, where: Transform3D) -> PackedVector3Array:
	var result := PackedVector3Array()
	for joint in joints:
		result.append(where * joint)
	return result


func _test_hand_pose() -> void:
	var open := HandPose.synthesize([0.0, 0.0, 0.0, 0.0, 0.0], 0.6)
	var fist := HandPose.synthesize([0.7, 1.0, 1.0, 1.0, 1.0], 0.1)
	var open_features := HandPose.features(open)
	var fist_features := HandPose.features(fist)
	_check(open_features.size() == HandPose.FEATURE_COUNT, "признаков столько, сколько объявлено")
	_check(open_features[1] > 0.95 and fist_features[1] < 0.8, "прямота указательного: раскрытая %.2f, кулак %.2f" % [open_features[1], fist_features[1]])
	_check(fist_features[6] < open_features[6] - 0.03, "согнутый палец ближе к ладони (%.3f против %.3f)" % [fist_features[6], open_features[6]])
	_check(open_features[11] > 0.9 and fist_features[11] < 0.5, "палец вдоль кисти: %.2f / %.2f" % [open_features[11], fist_features[11]])

	# Where the hand is and how it is turned does not matter.
	var moved := HandPose.features(_placed(open, Transform3D(Basis(Vector3(0.3, 1.0, 0.2).normalized(), 1.1), Vector3(0.4, 1.3, -0.5))))
	var same := true
	for f in HandPose.FEATURE_COUNT:
		same = same and absf(moved[f] - open_features[f]) < 0.001
	_check(same, "признаки не зависят от положения и поворота руки")
	_check(HandPose.features(PackedVector3Array()).is_empty(), "без суставов — нет признаков")
	# The hand's turn: the same shape with the palm towards the head or away.
	var head := Vector3(0.0, 0.1, 0.5)  # in front of the palm (+Z) of a right hand
	var toward := HandPose.features(open, 1.0, head)
	var away := HandPose.features(open, 1.0, Vector3(0.0, 0.1, -0.5))
	_check(toward[19] > 0.7 and away[19] < -0.7, "ладонь к себе и от себя различаются (%.2f / %.2f)" % [toward[19], away[19]])
	_check(toward[20] > 0.9, "кисть пальцами вверх")
	var mirrored := HandPose.features(_placed(open, Transform3D(Basis.FLIP_X, Vector3.ZERO)), -1.0, head)
	_check(absf(mirrored[19] - toward[19]) < 0.01, "левая рука — так же, как правая")
	var turned_record: Array[PackedFloat32Array] = []
	for k in 50:
		turned_record.append(toward)
	var palm_in := HandPose.record(turned_record, "custom:9", "к себе")
	_check(HandPose.distance(palm_in, toward, false) <= 1.0 and HandPose.distance(palm_in, away, false) > 1.0,
			"поза, записанная ладонью к себе, не узнаётся ладонью от себя")
	var older := palm_in.to_dictionary()
	older["middle"] = (older["middle"] as PackedFloat32Array).slice(0, HandPose.SHAPE_FEATURES)
	older["tolerance"] = (older["tolerance"] as PackedFloat32Array).slice(0, HandPose.SHAPE_FEATURES)
	var upgraded := HandPose.Template.from_dictionary(older)
	_check(upgraded.is_valid() and HandPose.distance(upgraded, away, false) <= 1.0, "старая поза (без поворота) — поворот любой")

	# Recording: frames around one pose make a template that takes it and refuses others.
	var samples: Array[PackedFloat32Array] = []
	for k in 60:
		var curls: Array[float] = [0.1, 0.5 + 0.1 * sin(k * 0.7), 0.0, 0.0, 0.0]
		samples.append(HandPose.features(HandPose.synthesize(curls, 0.85)))
	_check(HandPose.record(samples.slice(0, 20), "custom:1", "x") == null, "слишком короткая запись — нет шаблона")
	var template := HandPose.record(samples, "custom:1", "Своя поза 1")
	_check(template != null and template.is_valid(), "шаблон из записи")
	_check(HandPose.distance(template, samples[7]) <= 1.0, "записанная поза узнаётся (%.2f)" % HandPose.distance(template, samples[7]))
	_check(HandPose.distance(template, open_features) > 1.0, "раскрытая рука — не эта поза (%.2f)" % HandPose.distance(template, open_features))
	_check(HandPose.distance(template, fist_features) > 1.0, "кулак — не эта поза")
	var narrowest := INF
	for f in HandPose.FEATURE_COUNT:
		narrowest = minf(narrowest, template.tolerance[f] / HandPose.MIN_TOLERANCE[f])
	_check(narrowest >= 0.999, "допуск не уже минимального")
	var stored := HandPose.Template.from_dictionary(template.to_dictionary())
	_check(stored.id == "custom:1" and stored.name == "Своя поза 1" and stored.is_valid()
			and is_equal_approx(HandPose.distance(stored, samples[3]), HandPose.distance(template, samples[3])), "шаблон переживает сохранение")
	_check(HandPose.overlap(template, samples) > 0.9, "своя запись почти вся в своём шаблоне")
	var fists: Array[PackedFloat32Array] = [fist_features, fist_features]
	_check(HandPose.overlap(template, fists) == 0.0, "кулак шаблону чужой")

	# The matcher: dwell to come on, grace over a short loss, off after a longer one.
	var matcher := HandPose.Matcher.new()
	var hit := samples[0]
	_check(not matcher.update(template, hit, 0.0), "сразу не включается")
	_check(not matcher.update(template, hit, 0.05), "до выдержки — нет")
	_check(matcher.update(template, hit, 0.15), "после выдержки — поза")
	_check(matcher.update(template, open_features, 0.3), "короткий провал позу не снимает")
	_check(matcher.update(template, PackedFloat32Array(), 0.45), "короткая потеря слежения — тоже")
	_check(not matcher.update(template, open_features, 0.7), "долгий провал снимает позу")
	_check(not matcher.update(template, hit, 0.75), "после снятия снова нужна выдержка")

	# Built-in locomotion sign: the values the user showed are it; an open hand, a fist and the scroll pose are not.
	var sign := GestureCatalog.move_template()
	var shown := PackedFloat32Array([0.98, 0.66, 1.0, 1.0, 0.99, 0.08, 0.069, 0.118, 0.11, 0.093,
			0.92, 0.25, 0.97, 0.99, 0.98, 0.087, 0.018, 0.034, 0.05, -0.6, 0.8])
	_check(HandPose.distance(sign, shown) <= 1.0, "знак движения из журнала узнаётся (%.2f)" % HandPose.distance(sign, shown))
	var shown_right := PackedFloat32Array([0.99, 0.64, 1.0, 1.0, 0.99, 0.101, 0.073, 0.12, 0.114, 0.099,
			0.54, 0.43, 0.94, 0.94, 0.94, 0.096, 0.021, 0.038, 0.06, -0.7, 0.75])
	_check(HandPose.distance(sign, shown_right) <= 1.0, "и правой рукой (%.2f)" % HandPose.distance(sign, shown_right))
	var open_logged := PackedFloat32Array([0.99, 1.0, 1.0, 1.0, 0.99, 0.099, 0.112, 0.12, 0.112, 0.1,
			0.8, 0.99, 1.0, 0.99, 0.99, 0.032, 0.023, 0.04, 0.06, -0.6, 0.8])
	_check(HandPose.distance(sign, open_logged) > 1.35, "раскрытая рука — не знак, даже с запасом удержания (%.2f)" % HandPose.distance(sign, open_logged))
	_check(HandPose.distance(sign, fist_features) > 1.35, "кулак — не знак")
	# One misread finger is forgiven, a clearly different hand is not.
	var one_off := shown.duplicate()
	one_off[13] = 0.95 - 0.2 * 1.8  # ring "along" out by 1.8 tolerances
	_check(HandPose.distance(sign, one_off) <= 1.0, "один сбойный палец не снимает позу (%.2f)" % HandPose.distance(sign, one_off))
	var two_off := one_off.duplicate()
	two_off[12] = 0.95 - 0.2 * 1.8
	_check(HandPose.distance(sign, two_off) > 1.35, "два сбойных — уже не поза")
	var far_off := shown.duplicate()
	far_off[13] = 0.95 - 0.2 * 3.0
	_check(HandPose.distance(sign, far_off) > 1.35, "один, но далеко за допуском — не поза")
	_check(HandPose.distance(sign, one_off, false) > 1.0, "строго (для входа) сбойный палец не прощается")
	# Entering is strict, holding forgives one finger.
	var strict := HandPose.Matcher.new()
	_check(not strict.update(sign, one_off, 0.0) and not strict.update(sign, one_off, 0.3), "с одним пальцем за допуском поза не включается")
	strict.update(sign, shown, 1.0)
	_check(strict.update(sign, shown, 1.2) and strict.update(sign, one_off, 1.3), "включённая — держится и с одним сбойным пальцем")

	# The built-in scroll pose as a template of its thresholds.
	var scroll_box := GestureCatalog.scroll_template(HandGestures.Settings.new())
	var scroll_hand := open_features.duplicate()
	scroll_hand[1] = 0.97
	scroll_hand[2] = 0.97
	scroll_hand[11] = 0.95
	scroll_hand[12] = 0.95
	scroll_hand[15] = 0.015
	scroll_hand[18] = 0.09
	scroll_hand[8] = 0.05
	_check(HandPose.distance(scroll_box, scroll_hand, false) <= 1.0, "поза прокрутки укладывается в свои пороги (%.2f)" % HandPose.distance(scroll_box, scroll_hand, false))
	var thumb_in := scroll_hand.duplicate()
	thumb_in[18] = 0.04
	_check(HandPose.distance(scroll_box, thumb_in, false) > 1.0, "большой прижат — уже не прокрутка")
	_check(HandPose.distance(scroll_box, open_features, false) > 1.0 and HandPose.distance(scroll_box, fist_features, false) > 1.0,
			"раскрытая рука и кулак — не прокрутка")
	var old := HandPose.Template.from_dictionary(template.to_dictionary())
	old.tolerance[12] = 0.05
	old.widen_to_minimum()
	_check(is_equal_approx(old.tolerance[12], HandPose.MIN_TOLERANCE[12]) and is_inf(sign.tolerance[10]), "старые позы расширяются до минимума, «любое» остаётся")
	var miss := HandPose.describe_miss(sign, open_logged)
	_check(miss.begins_with("промежуток указательный-средний") or miss.begins_with("указательный"), "в журнал — признак, вышедший за допуск: " + miss)
	_check(HandPose.describe_miss(sign, shown).begins_with("в пределах"), "поза в допуске — так и сказано")
	_check(HandPose.distance(sign, HandPose.features(GestureCatalog.preview_joints("pose:scroll", []))) > 1.35, "поза прокрутки — не знак")

	# Previews: every built-in gesture has a whole hand; a left hand is mirrored to look like a right one.
	for id: String in GestureCatalog.TOUCHES.keys() + GestureCatalog.POSES.keys():
		_check(GestureCatalog.preview_joints(id, []).size() == HandPose.JOINT_COUNT, "превью для " + id)
	var right_local := HandPose.local_joints(_placed(open, Transform3D(Basis(Vector3.UP, 0.8), Vector3(0.2, 1.2, -0.3))), 1.0)
	_check(right_local[HandPose.WRIST].length() < 0.0001 and right_local[HandPose.MIDDLE_KNUCKLE].y > 0.08
			and absf(right_local[HandPose.MIDDLE_KNUCKLE].x) < 0.001, "превью: запястье в нуле, пальцы вверх")
	_check(right_local[HandPose.INDEX_KNUCKLE].x > 0.0, "превью: большой палец со стороны +X")
	var mirror := Basis.FLIP_X
	var left_local := HandPose.local_joints(_placed(open, Transform3D(mirror, Vector3.ZERO)), -1.0)
	_check(left_local[HandPose.INDEX_KNUCKLE].x > 0.0 and absf(left_local[HandPose.INDEX_KNUCKLE].x - right_local[HandPose.INDEX_KNUCKLE].x) < 0.001,
			"левая рука в превью выглядит как правая")
	# A touch preview really touches.
	var touch := GestureCatalog.preview_joints("touch:ring", [])
	_check(touch[HandPose.FINGERS[0][3]].distance_to(touch[HandPose.FINGERS[3][3]]) < 0.001, "превью касания: большой у безымянного")


func _test_menu_set() -> void:
	var menus := MenuSet.default_menus()
	_check(menus.size() == 3 and MenuSet.items_of(menus[0]).has("copy"), "три категории по умолчанию")
	for menu: Dictionary in menus:
		_check(MenuSet.items_of(menu).size() <= MenuSet.MAX_ITEMS, "не больше %d пунктов в «%s»" % [MenuSet.MAX_ITEMS, menu["name"]])
	_check(MenuSet.next_action("") == MenuSet.ACTIONS.keys()[0] and MenuSet.next_action(MenuSet.ACTIONS.keys().back()) == "",
			"перебор действий: с пустого — первое, после последнего — пусто")

	# Two levels: categories first, then the chosen one's items beyond it; back to the middle — categories again.
	var nav := MenuSet.Navigator.new()
	nav.menus = menus
	var viewer := Vector3(0.0, 1.6, 0.5)
	var at := Vector3(0.0, 1.2, 0.0)
	nav.open(at, viewer)
	_check(nav.level == 0 and nav.update(at) == "", "открылось — кольцо категорий, ничего не выбрано")
	var top := nav.category_position(0)
	nav.update(top)
	_check(nav.level == 1 and nav.category == 0, "довёл до категории — раскрылись её пункты")
	var first_item := nav.item_position(0, MenuSet.items_of(menus[0]).size())
	_check(nav.update(first_item) == "copy", "дальше — пункт (%s)" % nav.update(first_item))
	nav.update(at)
	_check(nav.level == 0, "назад к середине — снова категории")
	# By finger: the category's items open at once, around the hand.
	var finger := MenuSet.Navigator.new()
	finger.menus = menus
	finger.mode = MenuSet.MODE_FINGER
	finger.open(at, viewer, 1)
	_check(finger.level == 1 and finger.update(finger.item_position(0, 7)) == "alt_tab", "по пальцу — сразу пункты своей категории")
	_check(finger.update(at) == "" and finger.level == 1, "по пальцу середина — ничего, без возврата к категориям")
	_check(MenuSet.shortcut_label([0x11, 0x10, 0x54]) == "Ctrl+Shift+T" and MenuSet.shortcut_label([0x12, 0x73]) == "Alt+F4",
			"имя сочетания: «%s»" % MenuSet.shortcut_label([0x11, 0x10, 0x54]))
	_check(MenuSet.moved(["a", "b", "c"], "a", 2) == ["b", "c", "a"] and MenuSet.moved(["a", "b", "c"], "c", 0) == ["c", "a", "b"] \
			and MenuSet.moved(["a", "b"], "x", 1) == ["a", "x", "b"] and MenuSet.moved(["a"], "x", 9) == ["a", "x"], "перестановка пунктов меню")
	MenuSet.custom["custom:1"] = ["Ctrl+Shift+T", [0x11, 0x10, 0x54]]
	var with_own := {"name": "Своё", "items": ["custom:1", "nope", "copy"]}
	_check(MenuSet.items_of(with_own) == PackedStringArray(["custom:1", "copy"]) and MenuSet.action("custom:1")[0] == "Ctrl+Shift+T",
			"своя функция — в категории наравне с готовыми, неизвестные пропускаются")
	MenuSet.custom.clear()
	# Items open around the chosen category, a gap towards the middle: no item is nearer the middle than the back zone.
	nav.open(at, viewer)
	nav.update(nav.category_position(1))
	var count := MenuSet.items_of(menus[1]).size()
	var nearest := INF
	for k in count:
		nearest = minf(nearest, nav.item_position(k, count).distance_to(at))
	# Neighbouring labels apart: at least ~11 cm between items, so 12-character labels do not overlap.
	var gap := nav.item_position(0, count).distance_to(nav.item_position(1, count))
	_check(gap > 0.1, "соседние пункты подменю не накладываются (%.3f м)" % gap)
	_check(nav.item_centre.is_equal_approx(nav.category_position(1)) and nearest > nav.radius * 0.25,
			"подменю — с центром на категории, пункты не в зоне возврата (%.3f)" % nearest)


func _test_panel_back() -> void:
	var flat := ScreenPanel.back_mesh(Vector2(1.2, 0.7), 0.0, 1.1)
	var flat_aabb := flat.get_aabb()
	_check(Vector2(flat_aabb.size.x, flat_aabb.size.y).is_equal_approx(Vector2(1.2, 0.7)) and flat_aabb.size.z < 0.001
			and is_equal_approx(flat_aabb.position.z, -ScreenPanel.BACK_GAP),
			"задняя крышка плоского экрана — его размера, чуть позади (%s)" % flat_aabb)
	var curved := ScreenPanel.back_mesh(Vector2(1.2, 0.7), 1.0, 1.1)
	var curved_aabb := curved.get_aabb()
	_check(curved_aabb.position.z < 0.0 and curved_aabb.end.z > 0.1 and curved_aabb.size.x < 1.2,
			"у изогнутого — по дуге, края к зрителю (%s)" % curved_aabb)


func _test_slider() -> void:
	var marks := VrSlider.notches_for(0.0, 1.0, 0.05)
	_check(marks.size() == 11 and is_equal_approx(marks[1], 0.1) and is_equal_approx(marks[10], 1.0), "насечки: не больше 10 промежутков, по шагам, с концами")
	var odd := VrSlider.notches_for(10.0, 80.0, 5.0)
	_check(is_equal_approx(odd[0], 10.0) and is_equal_approx(odd[odd.size() - 1], 80.0), "насечки с обоих концов при неровном делении")
	_check(is_equal_approx(VrSlider.value_at(0.51, 0.0, 1.0, 0.05, marks), 0.5), "у насечки — прилипает к ней")
	_check(is_equal_approx(VrSlider.value_at(0.56, 0.0, 1.0, 0.05, marks), 0.55), "между насечками — по шагу")
	_check(VrSlider.value_at(1.4, 0.0, 1.0, 0.05, marks) == 1.0 and VrSlider.value_at(-0.2, 0.0, 1.0, 0.05, marks) == 0.0, "за концами — конец")


func _test_world_layout() -> void:
	var keys := PackedStringArray(["A", "B", "C"])
	var fixtures := WorldLayout.default_fixtures(keys)
	_check(fixtures.size() == 1 and fixtures[0].monitors == keys and fixtures[0].centre == Vector3(0.0, 1.45, 0.0),
			"без мира — один шар там, где была сфера, со всеми мониторами")
	_check(is_equal_approx(WorldLayout.degrees_per_1920(1.1), 60.0) or absf(WorldLayout.degrees_per_1920(1.1) - 60.0) < 0.1,
			"на прежнем радиусе панель прежнего размера (%.2f°)" % WorldLayout.degrees_per_1920(1.1))
	_check(absf(WorldLayout.degrees_per_1920(2.2) - 32.2) < 0.2, "шар вдвое больше — панель меньше по углу (та же в метрах)")

	var second := WorldLayout.new_fixture(fixtures, "sphere", Vector3(5.0, 1.5, 0.0), 0.5)
	fixtures.append(second)
	_check(second.id == 2 and second.name == "Шар 2", "новый шар: следующий номер и имя")
	WorldLayout.assign(fixtures, "B", 2)
	_check(not fixtures[0].monitors.has("B") and second.monitors == PackedStringArray(["B"]), "монитор переносится на другой шар")
	_check(WorldLayout.fixture_of(fixtures, "B") == second and WorldLayout.fixture_of(fixtures, "Z") == fixtures[0],
			"чей монитор; неизвестный — на первом")
	fixtures[0].monitors.append("B")
	WorldLayout.settle(fixtures, PackedStringArray(["A", "B", "C", "D"]))
	_check(fixtures[0].monitors.count("B") == 1 and fixtures[0].monitors.has("D"), "монитор на двух шарах остаётся на одном, новый — на первом")
	_check(not second.monitors.has("B"), "второй раз монитор не числится")
	# Driver screens made anew come back under new names (22.10.2026).
	var anew := WorldLayout.Fixture.new()
	anew.kind = "wall"
	anew.monitors = PackedStringArray(["MTT1337#a", "MTT1337#b", "PHL"])
	anew.cells = {"MTT1337#a": Rect2i(0, 0, 1, 1), "PHL": Rect2i(1, 0, 1, 1)}
	anew.parts = {"MTT1337#b": "2,0:1"}
	var renamed := WorldLayout.adopt([anew] as Array[WorldLayout.Fixture], PackedStringArray(["MTT1337#x", "MTT1337#y", "PHL"]))
	_check(renamed == {"MTT1337#a": "MTT1337#x", "MTT1337#b": "MTT1337#y"} and anew.cells.get("MTT1337#x") == Rect2i(0, 0, 1, 1)
			and anew.parts.get("MTT1337#y") == "2,0:1" and anew.monitors.has("MTT1337#x") and not anew.cells.has("MTT1337#a"),
			"экраны драйвера с новыми именами занимают места пропавших")
	_check(WorldLayout.adopt([anew] as Array[WorldLayout.Fixture], PackedStringArray(["MTT1337#x", "MTT1337#y", "PHL"])).is_empty(),
			"без новых экранов ничего не переименовывается")

	var near := WorldLayout.nearby(fixtures, Vector3(5.5, 1.6, 0.4), 1.0)
	_check(near == second and WorldLayout.nearby(fixtures, Vector3(20.0, 1.6, 0.0), 1.0) == null, "рядом с шаром — его место, вдали — ничего")

	# The seat: the head at the centre, looking at the sphere's middle.
	var head_local := Transform3D(Basis(Vector3.UP, 0.7), Vector3(0.3, 1.6, -0.2))
	var rig := WorldLayout.seat_rig(second, head_local)
	var head_world := rig * head_local
	_check(head_world.origin.is_equal_approx(second.centre), "сел: голова в центре шара")
	_check((-head_world.basis.z).is_equal_approx(second.frame().basis * Vector3.FORWARD), "сел: лицом к середине шара")

	var handle := WorldLayout.radius_handle(second)
	_check(is_equal_approx(handle.distance_to(second.centre), second.radius) and handle.y < second.centre.y - 0.9 * second.radius,
			"ручка радиуса — на шаре, низко")
	var handle_ahead := second.frame().affine_inverse() * handle
	_check(handle_ahead.z < 0.0 and absf(handle_ahead.x) < 0.001, "ручка — спереди по середине шара")

	var stored := WorldLayout.Fixture.from_dictionary(second.to_dictionary())
	_check(stored.id == 2 and stored.centre == second.centre and stored.monitors == second.monitors and is_equal_approx(stored.yaw, 0.5),
			"шар переживает сохранение")
	_check(WorldLayout.remove(fixtures, 2) and fixtures.size() == 1 and fixtures[0].monitors.has("C"), "удалённый шар отдаёт мониторы первому")
	_check(not WorldLayout.remove(fixtures, fixtures[0].id), "последний шар не удаляется")


func _test_locomotion() -> void:
	# The hand as a stick: dead zone, full speed at the reach, direction kept.
	_check(Locomotion.stick_velocity(Vector3(0.01, 0.0, 0.0), 0.15, 2.0, false) == Vector3.ZERO, "в мёртвой зоне — стоим")
	var full := Locomotion.stick_velocity(Vector3(0.0, 0.0, -0.3), 0.15, 2.0, false)
	_check(full.is_equal_approx(Vector3(0.0, 0.0, -2.0)), "дальше хода руки — полная скорость вперёд (%s)" % full)
	var half := Locomotion.stick_velocity(Vector3(0.085, 0.0, 0.0), 0.15, 2.0, false)
	_check(half.x > 0.0 and half.x < 0.6, "на середине хода — медленнее половины (%.2f)" % half.x)
	var up := Locomotion.stick_velocity(Vector3(0.0, 0.2, 0.0), 0.15, 2.0, true)
	_check(up == Vector3.ZERO, "с гравитацией рука вверх никуда не ведёт")
	var flat := Locomotion.stick_velocity(Vector3(0.1, 0.1, 0.1), 0.15, 2.0, true)
	_check(is_zero_approx(flat.y) and flat.x > 0.0, "с гравитацией — только по горизонтали")
	_check(Locomotion.stick_velocity(Vector3(0.0, 0.2, 0.0), 0.15, 2.0, false).y > 1.9, "в космосе — и вверх")

	_check(Locomotion.plane_up(Vector3.FORWARD, 0.0).is_equal_approx(Vector3.UP), "кольцо стоя: «вверх» — вверх")
	_check(Locomotion.plane_up(Vector3(0.0, 0.3, -1.0), 90.0).is_equal_approx(Vector3.FORWARD), "кольцо лёжа: «вверх» — вперёд, по горизонтали")
	var tipped := Locomotion.plane_up(Vector3.FORWARD, 45.0)
	_check(is_equal_approx(tipped.y, -tipped.z) and tipped.y > 0.0, "наклон 45° — между ними")
	_check(Locomotion.turn_rate(0.01, 0.15, 90.0) == 0.0, "поворот: мёртвая зона")
	_check(is_equal_approx(Locomotion.turn_rate(-0.2, 0.15, 90.0), -deg_to_rad(90.0)), "поворот влево на полной скорости")

	var snap := Locomotion.SnapTurn.new()
	_check(snap.update(0.03, 0.0) == 0 and snap.update(0.08, 0.1) == 1, "рывок вправо, когда рука ушла за порог")
	_check(snap.update(0.1, 0.3) == 0, "держишь руку — до паузы второго рывка нет")
	_check(snap.update(0.1, 0.6) == 1 and snap.update(0.1, 0.7) == 0 and snap.update(0.1, 1.06) == 1, "держишь дальше — рывки повторяются через паузу")
	_check(snap.update(0.02, 1.1) == 0 and snap.update(-0.09, 1.15) == -1, "вернул руку — следующий рывок сразу, влево")

	# Turning on the spot: the head stays where it is.
	var rig := Transform3D(Basis.IDENTITY, Vector3(1.0, 0.0, 2.0))
	var head := Vector3(1.3, 1.6, 1.7)
	var turned := Locomotion.turn_about(rig, head, deg_to_rad(90.0))
	var head_local := rig.affine_inverse() * head
	var head_after := turned * head_local
	_check(Vector2(head_after.x, head_after.z).is_equal_approx(Vector2(head.x, head.z)), "поворот вокруг головы: голова на месте")
	var forward_after := turned.basis * Vector3.FORWARD
	_check(forward_after.is_equal_approx(Vector3.RIGHT), "поворот вправо: «вперёд» смотрит вправо (%s)" % forward_after)

	_check(Locomotion.settle(2.0, 0.0, 0.1) < 2.0 and Locomotion.settle(2.0, 0.0, 0.1) > 1.5, "гравитация опускает плавно")
	_check(Locomotion.settle(0.05, 0.0, 0.1) == 0.0, "у пола — ровно на пол")

	var floor_dots := Locomotion.grid_points(Vector3(0.4, 1.6, -0.2), 1.0, 3.0, true, 0.5)
	var all_on_floor := true
	for point in floor_dots:
		all_on_floor = all_on_floor and is_equal_approx(point.y, 0.5) and is_equal_approx(point.x, roundf(point.x))
	_check(floor_dots.size() > 20 and all_on_floor, "сетка пола: точки на полу и по шагу (%d)" % floor_dots.size())
	var space_dots := Locomotion.grid_points(Vector3(10.2, 3.0, 0.0), 1.0, 2.0, false)
	var heights := {}
	for point in space_dots:
		heights[point.y] = true
	_check(heights.size() >= 3 and space_dots.has(Vector3(10.0, 3.0, 0.0)), "сетка в космосе — объёмная, вокруг пользователя (%d высот)" % heights.size())
	_check(Locomotion.grid_points(Vector3.ZERO, 0.0, 3.0, true).is_empty(), "без шага — без точек")

	_check(Locomotion.vignette_strength(0.0, 2.0, 2.0, 0.0, 1.0) == 0.0, "затемнение выключено")
	_check(is_equal_approx(Locomotion.vignette_strength(0.6, 2.0, 2.0, 0.0, 1.0), 0.6), "на полной скорости — сколько задано")
	_check(Locomotion.vignette_strength(0.6, 0.2, 2.0, 0.0, 1.0) < 0.1, "медленно — почти без затемнения")


func _test_gesture_catalog() -> void:
	var bindings := GestureCatalog.sanitize({}, [])
	_check(bindings == GestureCatalog.DEFAULTS, "без настроек — назначения по умолчанию")
	# Taking a touch another button has: the two swap.
	var swapped := GestureCatalog.assign(bindings, "left", "touch:middle")
	_check(swapped["left"] == "touch:middle" and swapped["right"] == "touch:index", "занятое касание: кнопки меняются (%s)" % swapped)
	_check(swapped["middle"] == "touch:side", "третья кнопка не тронута")
	var off := GestureCatalog.assign(bindings, "middle", GestureCatalog.OFF)
	_check(off["middle"] == GestureCatalog.OFF and off["left"] == "touch:index", "выключение ни у кого ничего не забирает")
	var shared := GestureCatalog.assign(bindings, "scroll", "pose:move")
	_check(shared["scroll"] == "pose:move" and shared["move"] == "pose:move", "позу могут делить несколько действий")

	var custom := HandPose.Template.new()
	custom.id = "custom:3"
	custom.name = "Ладонь"
	var customs: Array[HandPose.Template] = [custom]
	var with_custom := GestureCatalog.assign(bindings, "turn", "custom:3")
	_check(GestureCatalog.sanitize(with_custom, customs)["turn"] == "custom:3", "своя поза остаётся, пока она есть")
	_check(GestureCatalog.sanitize(with_custom, [])["turn"] == GestureCatalog.OFF, "удалённая поза — действие выключено")
	_check(GestureCatalog.sanitize({"left": "pose:fist"}, [])["left"] == GestureCatalog.OFF, "поза на щелчке недопустима")
	var touch_names: Array = GestureCatalog.options("left", customs).map(func(o: Array) -> String: return o[0])
	_check(touch_names.has("touch:pinky") and not touch_names.has("custom:3") and touch_names.back() == GestureCatalog.OFF,
			"для щелчка — касания и «выключено»")
	var pose_names: Array = GestureCatalog.options("move", customs).map(func(o: Array) -> String: return o[0])
	_check(pose_names.has("custom:3") and pose_names.has("pose:fist") and not pose_names.has("touch:index"), "для движения — позы и свои")
	_check(GestureCatalog.name_of("custom:3", customs) == "Ладонь" and GestureCatalog.contact_of("touch:side") == HandGestures.Contact.SIDE,
			"имена и касания")

	# HandGestures with other bindings: the ring finger clicks left, the index does nothing.
	var gestures := HandGestures.new()
	gestures.settings.left_contact = HandGestures.Contact.RING
	gestures.settings.right_contact = -1
	var frame := _hand(0.0, 0.012)
	var out := gestures.update(frame)
	_check(out.button == HandGestures.Click.NONE and not out.pending, "неназначенное касание ничего не делает")
	frame = _hand(0.5, 0.06)
	frame.thumb_ring = 0.012
	gestures.update(frame)
	frame = _hand(0.7, 0.06)
	frame.thumb_ring = 0.012
	out = gestures.update(frame)
	_check(out.button == HandGestures.Click.LEFT, "безымянный назначен на левую — левая")
	frame = _hand(0.9, 0.06, 0.012)
	frame.thumb_ring = 0.06
	gestures.update(frame)
	out = gestures.update(_hand(1.1, 0.06, 0.012))
	_check(out.button == HandGestures.Click.NONE, "правая выключена — средний не щёлкает")
	# The scroll pose decided by the caller.
	var scrolling := HandGestures.new()
	var plain := _hand(2.0, 0.09, 0.09, 0.07)
	plain.scroll_pose = 1
	scrolling.update(plain)
	plain = _hand(2.3, 0.09, 0.09, 0.07)
	plain.scroll_pose = 1
	_check(scrolling.update(plain).disc, "своя поза прокрутки включает прокрутку")
	var refused := _disc_pose(3.0)
	refused.scroll_pose = 0
	_check(not HandGestures.new().update(refused).disc_pending, "прокрутка выключена — встроенная поза не действует")


func _test_hand_gestures() -> void:
	const NONE := HandGestures.Click.NONE
	const LEFT := HandGestures.Click.LEFT
	const RIGHT := HandGestures.Click.RIGHT
	const MIDDLE := HandGestures.Click.MIDDLE

	var gestures := HandGestures.new()
	var out := gestures.update(_hand(0.0, 0.06))
	_check(out.button == NONE and not out.pending and not out.disc and not out.disc_pending, "открытая рука — ничего")
	out = gestures.update(_hand(0.10, 0.012))
	_check(out.pending and out.button == NONE, "касание: сначала ожидание, кнопки ещё нет")
	out = gestures.update(_hand(0.20, 0.012))
	_check(out.pending and out.button == NONE, "до конца окна кнопка не нажимается")
	out = gestures.update(_hand(0.23, 0.012))
	_check(out.button == LEFT and not out.pending, "большой + указательный — левая кнопка")
	out = gestures.update(_hand(0.50, 0.025))
	_check(out.button == LEFT, "между порогами сжатия и разжатия кнопка держится")
	out = gestures.update(_hand(0.60, 0.04))
	_check(out.button == NONE, "пальцы разведены — кнопка отпущена")

	gestures = HandGestures.new()
	gestures.update(_hand(0.0, 0.06, 0.012))
	out = gestures.update(_hand(0.13, 0.06, 0.012))
	_check(out.button == RIGHT, "большой + средний — правая кнопка")

	# Middle button: the thumb tip against the side of the index finger.
	gestures = HandGestures.new()
	gestures.update(_hand(0.0, 0.04, 0.06, 0.012))
	out = gestures.update(_hand(0.13, 0.04, 0.06, 0.012))
	_check(out.button == MIDDLE, "большой к боку указательного — средняя кнопка")
	out = gestures.update(_hand(0.30, 0.04, 0.06, 0.03))
	_check(out.button == MIDDLE, "средняя держится между порогами касания бока")
	out = gestures.update(_hand(0.35, 0.04, 0.06, 0.04))
	_check(out.button == NONE, "средняя отпущена")

	# Two contacts within the window: the deeper one (relative to its threshold) decides.
	gestures = HandGestures.new()
	gestures.update(_hand(0.0, 0.017, 0.06, 0.06))
	gestures.update(_hand(0.05, 0.017, 0.06, 0.008))
	out = gestures.update(_hand(0.13, 0.017, 0.06, 0.008))
	_check(out.button == MIDDLE, "задел кончик, но прижал бок — средняя")
	gestures = HandGestures.new()
	gestures.update(_hand(0.0, 0.006, 0.06, 0.021))
	out = gestures.update(_hand(0.13, 0.006, 0.06, 0.021))
	_check(out.button == LEFT, "плотный щипок кончиков рядом с боком — левая")

	# A finger joining after the window does not change the button.
	gestures = HandGestures.new()
	gestures.update(_hand(0.0, 0.012, 0.06))
	out = gestures.update(_hand(0.13, 0.012, 0.06))
	_check(out.button == LEFT, "левая нажата")
	out = gestures.update(_hand(0.20, 0.012, 0.012))
	_check(out.button == LEFT, "средний палец после окна — всё ещё левая")

	# A pinch shorter than the window is still a click: pressed for one frame, then released.
	gestures = HandGestures.new()
	gestures.update(_hand(0.0, 0.012))
	out = gestures.update(_hand(0.05, 0.05))
	_check(out.button == LEFT, "быстрое касание — щелчок")
	out = gestures.update(_hand(0.07, 0.05))
	_check(out.button == NONE and not out.pending, "и сразу отпускание")

	# Fingers hovering between the two thresholds never start a press.
	gestures = HandGestures.new()
	var touched := false
	for i in 10:
		out = gestures.update(_hand(i * 0.05, 0.025))
		touched = touched or out.pending or out.button != NONE
	_check(not touched, "пальцы между порогами без касания — нажатия нет")

	# Disc: the pose has to be held for the dwell before the disc appears.
	gestures = HandGestures.new()
	out = gestures.update(_disc_pose(0.0))
	_check(out.disc_pending and not out.disc, "поза диска: курсор стоит, диска ещё нет")
	out = gestures.update(_disc_pose(0.10))
	_check(out.disc_pending and not out.disc_started, "до конца задержки диска нет")
	out = gestures.update(_disc_pose(0.16))
	_check(out.disc and out.disc_started, "через задержку диск появляется")
	out = gestures.update(_disc_pose(0.20))
	_check(out.disc and not out.disc_started, "диск держится, «появился» только один кадр")
	out = gestures.update(_disc_pose(0.25, 0.05, 0.75, 0.03))
	_check(out.disc, "небольшой изгиб и разведение пальцев не сбрасывают диск (гистерезис)")
	out = gestures.update(_hand(0.30, 0.06))
	_check(not out.disc and not out.disc_pending, "пальцы опущены — диск исчез")

	# Fingers up but the ring finger straight (an open hand held up) is not the pose.
	gestures = HandGestures.new()
	var any_disc := false
	for i in 10:
		out = gestures.update(_disc_pose(i * 0.05, 0.12))
		any_disc = any_disc or out.disc or out.disc_pending
	_check(not any_disc, "поднятая открытая ладонь диск не вызывает")
	# Fingers bent at the knuckle (not in line with the hand) are not the pose.
	gestures = HandGestures.new()
	any_disc = false
	for i in 10:
		out = gestures.update(_disc_pose(i * 0.05, 0.05, 0.3))
		any_disc = any_disc or out.disc or out.disc_pending
	_check(not any_disc, "пальцы согнуты в костяшках — диска нет")
	# Index and middle apart (a V) are not the pose.
	gestures = HandGestures.new()
	any_disc = false
	for i in 10:
		out = gestures.update(_disc_pose(i * 0.05, 0.05, 0.95, 0.05))
		any_disc = any_disc or out.disc or out.disc_pending
	_check(not any_disc, "пальцы врозь — диска нет")

	# The press is anchored to when the finger started closing, however slowly it closed.
	gestures = HandGestures.new()
	gestures.update(_hand(0.00, 0.06, 0.06))
	gestures.update(_hand(0.10, 0.06, 0.05))
	gestures.update(_hand(0.20, 0.06, 0.04))
	gestures.update(_hand(0.30, 0.06, 0.03))
	gestures.update(_hand(0.40, 0.06, 0.012))
	out = gestures.update(_hand(0.53, 0.06, 0.012))
	_check(out.button == RIGHT and is_equal_approx(out.anchor_time, 0.10), "нажатие привязано к началу сведения пальцев")
	out = gestures.update(_hand(0.60, 0.06, 0.012))
	_check(is_nan(out.anchor_time), "время начала выдаётся только в кадр решения")
	gestures.reset()
	out = gestures.update(_hand(0.70, 0.06, 0.012))
	_check(out.button == NONE and out.pending, "после сброса касание распознаётся заново")

	# A hand at rest (low, or ray pointing down) stops controlling; it takes a moment either way.
	var engagement := HandEngagement.new()
	_check(not engagement.update(0.0, 0.3, 0.0), "в начале рука не управляет")
	_check(not engagement.update(0.2, 0.3, 0.0), "в работу не сразу")
	_check(engagement.update(0.35, 0.3, 0.0), "поднятая рука с лучом вперёд — в работе")
	_check(engagement.update(0.45, 0.6, 0.0), "опустилась — ещё не сразу")
	_check(not engagement.update(0.7, 0.6, 0.0), "рука ниже глаз на 60 см — в покое")
	engagement.update(0.8, 0.3, 0.0)
	_check(engagement.update(1.2, 0.3, 0.0), "снова поднята — в работе")
	engagement.update(1.3, 0.3, deg_to_rad(-60.0))
	_check(not engagement.update(1.6, 0.3, deg_to_rad(-60.0)), "луч круто вниз (рука на клавиатуре) — в покое")
	engagement.update(1.7, 0.3, 0.0)
	_check(not engagement.update(1.75, 0.6, 0.0) and not engagement.update(1.9, 0.3, 0.0), "короткий подъём не возвращает в работу")

	# The cursor filter places a press at an explicit anchor time.
	var anchored := CursorFilter.new()
	anchored.update(Vector2(10.0, 10.0), true, false, 0.0)
	anchored.update(Vector2(10.0, 10.0), true, false, 0.1)
	anchored.update(Vector2(90.0, 10.0), true, false, 0.3)
	var press := anchored.update(Vector2(95.0, 10.0), true, true, 0.4, false, 0.1)
	_check(press.press and press.position == Vector2(10.0, 10.0), "нажатие ставится на момент начала жеста")

	# Scroll stick: direction and speed from the offset to where the pose formed.
	var stick := ScrollStick.new()
	stick.start(Vector3(0.0, 1.3, -0.4), Vector3(0.0, 1.6, 0.0))
	_check(stick.scroll(Vector3(0.0, 1.31, -0.4), 1.0) == Vector2.ZERO, "в мёртвой зоне прокрутки нет")
	var up_wheel := stick.scroll(Vector3(0.0, 1.3 + stick.full_offset, -0.4), 0.5)
	_check(up_wheel.x == 0.0 and is_equal_approx(up_wheel.y, stick.max_speed * 0.5), "рука вверх до упора — полная скорость вверх")
	var half := stick.scroll(Vector3(0.0, 1.3 - (stick.dead_zone + stick.full_offset) * 0.5, -0.4), 1.0)
	_check(is_equal_approx(half.y, -stick.max_speed * 0.5), "вниз наполовину — половина скорости вниз")
	var sideways := stick.scroll(Vector3(0.05, 1.32, -0.4), 1.0)
	_check(sideways.y == 0.0 and sideways.x > 0.0, "вправо сильнее, чем вверх — только вправо")
	stick.invert_vertical = true
	_check(stick.scroll(Vector3(0.0, 1.38, -0.4), 1.0).y < 0.0, "инверсия вертикали")
	stick.invert_horizontal = true
	_check(stick.scroll(Vector3(0.06, 1.3, -0.4), 1.0).x < 0.0, "инверсия горизонтали")
	_check(stick.marker(Vector3(0.0, 1.6, -0.4)).distance_to(stick.origin) <= stick.full_offset + 0.0001, "отметка не выходит за круг")

	# Extra gestures. Right hand held up with its back to a viewer at +Z: the palm faces away (-Z).
	var normal := ExtraGestures.palm_normal(Vector3.ZERO, Vector3(-0.02, 0.09, 0.0), Vector3(0.04, 0.08, 0.0), 1.0)
	_check(normal.z < -0.9, "нормаль ладони правой руки")
	_check(ExtraGestures.palm_normal(Vector3.ZERO, Vector3(0.02, 0.09, 0.0), Vector3(-0.04, 0.08, 0.0), -1.0).z < -0.9, "нормаль ладони левой руки (зеркально)")

	_check(ExtraGestures.Radial.item_at(Vector2(0.0, 0.05), 0.03, 8) == 0, "меню: вверх — первый пункт")
	_check(ExtraGestures.Radial.item_at(Vector2(0.05, 0.0), 0.03, 8) == 2, "меню: вправо — третий пункт (по часовой)")
	_check(ExtraGestures.Radial.item_at(Vector2(-0.04, 0.04), 0.03, 8) == 7, "меню: вверх-влево — последний пункт")
	_check(ExtraGestures.Radial.item_at(Vector2(0.0, 0.01), 0.03, 8) == -1, "меню: у центра ничего не выбрано")
	var menu := ExtraGestures.Radial.new()
	menu.open(Vector3(0.0, 1.3, -0.4), Vector3(0.0, 1.6, 0.0))
	_check(menu.selection(menu.item_position(5)) == 5, "меню: рука у пункта выбирает его")

	var swipe := ExtraGestures.Swipe.new()
	var fired := 0
	for i in 8:
		fired += swipe.update(i * 0.03, i * 0.03, true)
	_check(fired == 1, "быстрое смахивание вправо срабатывает один раз")
	fired = 0
	for i in 8:
		fired += swipe.update(1.0 + i * 0.03, 0.3 - i * 0.03, true)
	_check(fired == -1, "смахивание влево")
	fired = 0
	for i in 40:
		fired += swipe.update(3.0 + i * 0.03, i * 0.005, true)
	_check(fired == 0, "медленное движение — не смахивание")
	fired = 0
	for i in 8:
		fired += swipe.update(5.0 + i * 0.03, i * 0.03, false)
	_check(fired == 0, "сжатая рука не смахивает")

	var pause := ExtraGestures.Pause.new()
	var toggles := 0
	for i in 30:
		if pause.update(i * 0.05, Vector3(-0.1, 1.2, -0.3), Vector3.RIGHT, Vector3(0.1, 1.2, -0.3), Vector3.LEFT):
			toggles += 1
	_check(toggles == 1, "ладони друг к другу — пауза переключается один раз")
	_check(not pause.update(2.0, Vector3(-0.1, 1.2, -0.3), Vector3.FORWARD, Vector3(0.1, 1.2, -0.3), Vector3.FORWARD), "ладони не друг к другу — паузы нет")

	var recording := PackedFloat32Array()
	for touch in 5:
		for i in 10:
			recording.append(0.06 + 0.005 * sin(i))
		for i in 8:
			recording.append(0.009 + 0.002 * sin(i))
	var thresholds := ExtraGestures.calibrate(recording)
	_check(thresholds.x > 0.012 and thresholds.x < thresholds.y and thresholds.y < 0.055, "калибровка: пороги между касанием и раскрытием")
	_check(ExtraGestures.calibrate(PackedFloat32Array([0.05, 0.05, 0.05])) == Vector2.ZERO, "калибровка: мало данных — отказ")

	# Pose calibration: thresholds a margin outside what the recorded pose showed.
	var pose_samples: Array[PackedFloat32Array] = []
	for i in 60:
		var wobble := 0.01 * sin(i * 0.5)
		pose_samples.append(PackedFloat32Array([0.9 + wobble, 0.88 + wobble, 0.85 + wobble, 0.86 + wobble,
				0.018 + wobble * 0.3, 0.07 + wobble, 0.05 + wobble]))
	var pose := ExtraGestures.calibrate_pose(pose_samples)
	_check(pose["disc_straightness"] < 0.88 and pose["disc_straightness"] > 0.75, "калибровка позы: прямота пальцев с запасом")
	_check(pose["disc_together"] > 0.018 and pose["disc_together"] < 0.03, "калибровка позы: «вместе» с запасом")
	_check(pose["disc_ring_curl"] > 0.05 and pose["disc_thumb_spread"] < 0.07, "калибровка позы: безымянный и большой с запасом")
	_check(ExtraGestures.calibrate_pose([] as Array[PackedFloat32Array]).is_empty(), "калибровка позы: нет данных — отказ")

	# The thumb coming in while the disc is up must not click.
	gestures = HandGestures.new()
	gestures.update(_disc_pose(0.0))
	gestures.update(_disc_pose(0.2))
	var clicked := false
	for i in 6:
		out = gestures.update(_hand(0.25 + i * 0.05, 0.012))
		clicked = clicked or out.button != NONE or out.pending
	_check(not clicked, "касание пальцев во время диска — щелчка нет")
	gestures.update(_hand(0.6, 0.06))
	gestures.update(_hand(0.7, 0.012))
	out = gestures.update(_hand(0.83, 0.012))
	_check(out.button == LEFT, "после разведения пальцев щелчки снова работают")

	_check(is_equal_approx(HandGestures.straightness(Vector3.ZERO, Vector3(0, 0.04, 0), Vector3(0, 0.07, 0), Vector3(0, 0.09, 0)), 1.0), "прямой палец — 1")
	_check(HandGestures.straightness(Vector3.ZERO, Vector3(0, 0.04, 0), Vector3(0, 0.04, 0.03), Vector3(0, 0.02, 0.03)) < 0.6, "согнутый палец — заметно меньше 1")
	_check(is_equal_approx(HandGestures.distance_to_segment(Vector3(0.01, 0.02, 0.0), Vector3.ZERO, Vector3(0, 0.04, 0)), 0.01), "расстояние до бока фаланги")
	_check(is_equal_approx(HandGestures.distance_to_segment(Vector3(0, 0.07, 0), Vector3.ZERO, Vector3(0, 0.04, 0)), 0.03), "расстояние за концом фаланги — до конца")

	# Scroll disc: the fingertip starts at the top; counter-clockwise (as seen by the user) scrolls up.
	var disc := ScrollDisc.new()
	var viewer := Vector3(0.0, 1.6, 0.0)
	disc.start(Vector3(0.0, 1.3, -0.4), viewer)
	_check(disc.center.is_equal_approx(Vector3(0.0, 1.3 - disc.radius, -0.4)), "диск появляется под кончиками пальцев")
	_check(disc.marker().is_equal_approx(Vector3(0.0, 1.3, -0.4)), "пальцы на верхней точке диска")
	_check(disc.basis().y.is_equal_approx(Vector3.BACK), "диск повёрнут к пользователю")
	var turned := 0.0
	for i in range(0, 73):
		var angle := PI * 0.5 + i * TAU / 72.0
		turned += disc.turn(disc.center + (disc.right * cos(angle) + disc.up * sin(angle)) * disc.radius)
	_check(is_equal_approx(turned, disc.turn_units), "оборот против часовой — колесо вверх на оборот")
	var back := 0.0
	for i in range(0, 37):
		var angle := PI * 0.5 - i * TAU / 72.0
		back += disc.turn(disc.center + (disc.right * cos(angle) + disc.up * sin(angle)) * disc.radius)
	_check(is_equal_approx(back, -disc.turn_units * 0.5), "полоборота по часовой — колесо вниз")
	_check(disc.right.is_equal_approx(Vector3.RIGHT), "«право» диска — право пользователя")
	_check(is_zero_approx(disc.turn(disc.center + Vector3(0.005, 0.0, 0.0))), "у самого центра колесо не крутится")
	_check(is_zero_approx(disc.turn(disc.center + disc.up * disc.radius)), "после центра первый кадр только запоминает угол")

	# Recalling where the cursor was before a pose froze it.
	var filter := CursorFilter.new()
	filter.update(Vector2(100.0, 100.0), true, false, 0.0)
	filter.update(Vector2(100.0, 100.0), true, false, 0.2)
	filter.update(Vector2(160.0, 90.0), true, false, 0.4)
	_check(filter.recall(0.15) == Vector2(100.0, 100.0), "курсор возвращается туда, где был до позы")
	_check(filter.recall(-5.0) == null, "слишком давно — возвращать некуда")


func _test_recenter_math() -> void:
	# The formula used by main.gd::_recenter: after the turn the head must look along -Z.
	for degrees: float in [0.0, 90.0, 180.0, -45.0, 137.0]:
		var head_basis := Basis(Vector3.UP, deg_to_rad(degrees))
		var forward := -head_basis.z
		var turn := Basis(Vector3.UP, PI - atan2(forward.x, forward.z))
		_check((turn * forward).is_equal_approx(Vector3.FORWARD), "выравнивание при повороте головы %d°" % int(degrees))


func _test_pinch_hysteresis() -> void:
	var press := 0.018
	var release := 0.035
	_check(not PointerMath.pinch_state(false, 0.05, press, release), "разведены — не нажато")
	_check(not PointerMath.pinch_state(false, 0.025, press, release), "в зоне гистерезиса из открытого — не нажато")
	_check(PointerMath.pinch_state(false, 0.01, press, release), "сведены — нажато")
	_check(PointerMath.pinch_state(true, 0.025, press, release), "в зоне гистерезиса из нажатого — держится")
	_check(not PointerMath.pinch_state(true, 0.04, press, release), "разведены дальше порога — отпущено")


func _test_hand_ray() -> void:
	var head := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.6, 0.0))
	# Palm straight in front of the right shoulder: the ray goes straight forward.
	var direction := PointerMath.hand_ray_direction(head, Vector3(0.18, 1.4, -0.4), 1.0, 0.2, 0.18)
	_check(direction.is_equal_approx(Vector3.FORWARD), "ладонь перед плечом — луч вперёд")
	var raised := PointerMath.hand_ray_direction(head, Vector3(0.18, 1.6, -0.4), 1.0, 0.2, 0.18)
	_check(raised.y > 0.0 and raised.z < 0.0, "ладонь выше плеча — луч вверх и вперёд")
	var left := PointerMath.hand_ray_direction(head, Vector3(-0.18, 1.4, -0.4), -1.0, 0.2, 0.18)
	_check(left.is_equal_approx(Vector3.FORWARD), "левая ладонь перед левым плечом — луч вперёд")
	# Head tilted down must not drag the shoulder estimate with it.
	var tilted := Transform3D(Basis(Vector3.RIGHT, -0.6), Vector3(0.0, 1.6, 0.0))
	_check(PointerMath.hand_ray_direction(tilted, Vector3(0.18, 1.4, -0.4), 1.0, 0.2, 0.18).is_equal_approx(Vector3.FORWARD), "наклон головы не меняет луч")
	_check(is_equal_approx(PointerMath.hand_ray_direction(head, Vector3(0.5, 1.2, -0.3), 1.0, 0.2, 0.18).length(), 1.0), "направление нормировано")

	# Blend: the rotation of the hand dominates, the shoulder line only steadies it.
	var hand_up := Vector3(0.0, 2.0, 0.0)
	_check(PointerMath.blend_ray_direction(Vector3.FORWARD, hand_up, 0.0).is_equal_approx(Vector3.FORWARD), "вес 0 — только плечо")
	_check(PointerMath.blend_ray_direction(Vector3.FORWARD, hand_up, 1.0).is_equal_approx(Vector3.UP), "вес 1 — только кисть")
	var blended := PointerMath.blend_ray_direction(Vector3.FORWARD, hand_up, 0.8)
	_check(blended.y > absf(blended.z) and blended.z < 0.0, "вес 0.8 — ближе к кисти")
	_check(is_equal_approx(blended.length(), 1.0), "смешанное направление нормировано")
	_check(PointerMath.blend_ray_direction(Vector3.FORWARD, Vector3.ZERO, 0.8).is_equal_approx(Vector3.FORWARD), "нет данных кисти — плечо")

	var pitched := PointerMath.pitch_direction(Vector3.FORWARD, deg_to_rad(30.0))
	_check(is_equal_approx(pitched.y, -0.5) and pitched.z < 0.0 and is_zero_approx(pitched.x), "наклон 30° вниз от горизонта")
	_check(PointerMath.pitch_direction(Vector3.FORWARD, deg_to_rad(-30.0)).y > 0.0, "отрицательный наклон — вверх")
	var side := PointerMath.pitch_direction(Vector3(1.0, 0.0, -1.0).normalized(), deg_to_rad(20.0))
	_check(side.y < 0.0 and is_equal_approx(side.x, -side.z) and is_equal_approx(side.length(), 1.0), "наклон сохраняет курс и длину")
	_check(PointerMath.pitch_direction(Vector3.UP, 0.5).is_equal_approx(Vector3.UP), "вертикальный луч не меняется")
	_check(PointerMath.pitch_direction(Vector3.FORWARD, 0.0).is_equal_approx(Vector3.FORWARD), "нулевой наклон")

	var turned_right := PointerMath.yaw_direction(Vector3.FORWARD, deg_to_rad(30.0))
	_check(is_equal_approx(turned_right.x, 0.5) and turned_right.z < 0.0 and is_zero_approx(turned_right.y), "поворот 30° вправо")
	var turned_left := PointerMath.yaw_direction(Vector3.FORWARD, deg_to_rad(-30.0))
	_check(is_equal_approx(turned_left.x, -turned_right.x) and is_equal_approx(turned_left.z, turned_right.z), "зеркальный поворот для другой руки")
	_check(is_equal_approx(PointerMath.yaw_direction(Vector3(0.0, -0.6, -0.8), 0.4).y, -0.6), "поворот не меняет наклон")

	# Dead zone: 0.01 rad here.
	var near := Vector3.FORWARD.rotated(Vector3.UP, 0.006)
	_check(PointerMath.deadband_direction(Vector3.FORWARD, near, 0.01).is_equal_approx(Vector3.FORWARD), "в мёртвой зоне луч стоит")
	var far := Vector3.FORWARD.rotated(Vector3.UP, 0.05)
	var trailing := PointerMath.deadband_direction(Vector3.FORWARD, far, 0.01)
	_check(is_equal_approx(trailing.angle_to(far), 0.01), "вне зоны луч отстаёт ровно на её радиус")
	_check(is_equal_approx(trailing.angle_to(Vector3.FORWARD), 0.04), "и сдвигается на остаток")
	_check(PointerMath.deadband_direction(Vector3.ZERO, far, 0.01).is_equal_approx(far), "первый кадр — без мёртвой зоны")
	_check(PointerMath.deadband_direction(Vector3.FORWARD, far, 0.0).is_equal_approx(far), "нулевой радиус отключает зону")
	var held := Vector3.FORWARD
	for i in 100:
		held = PointerMath.deadband_direction(held, Vector3.FORWARD.rotated(Vector3.UP, 0.004 * sin(i * 0.7)), 0.01)
	_check(held.is_equal_approx(Vector3.FORWARD), "дрожание меньше радиуса не сдвигает луч вовсе")

	_check(PointerMath.smooth_direction(Vector3.ZERO, Vector3.UP, 0.01, 0.05).is_equal_approx(Vector3.UP), "первый кадр — без сглаживания")
	_check(PointerMath.smooth_direction(Vector3.FORWARD, Vector3.UP, 0.01, 0.0).is_equal_approx(Vector3.UP), "сглаживание выключено")
	var smoothed := PointerMath.smooth_direction(Vector3.FORWARD, Vector3.UP, 0.01, 0.05)
	_check(smoothed.y > 0.0 and smoothed.z < 0.0 and smoothed.y < absf(smoothed.z), "один кадр — небольшой шаг к цели")
	var settled := Vector3.FORWARD
	for i in 60:
		settled = PointerMath.smooth_direction(settled, Vector3.UP, 0.011, 0.05)
	_check(settled.distance_to(Vector3.UP) < 0.001, "за 60 кадров сходится к цели")


## Small lookups and helpers the bigger tests use only indirectly.
func _test_lookups_and_helpers() -> void:
	# GestureCatalog: names and kinds of actions, recorded poses by id.
	_check(GestureCatalog.kind_of("left") == "touch" and GestureCatalog.kind_of("move") == "pose" and GestureCatalog.kind_of("nope") == "",
			"вид действия: касание, поза, неизвестное — пусто")
	_check(GestureCatalog.label_of("turn") == "Поворот" and GestureCatalog.label_of("nope") == "nope", "название действия, неизвестное — как есть")
	var pose := HandPose.Template.new()
	pose.id = "custom:3"
	var customs: Array[HandPose.Template] = [pose]
	_check(GestureCatalog.find("custom:3", customs) == pose and GestureCatalog.find("custom:9", customs) == null, "своя поза по id")

	# MenuSet: built-in and own functions, ring size.
	MenuSet.custom = {"custom:1": ["Ctrl+K", [0x11, 0x4B]]}
	_check(MenuSet.has_action("copy") and MenuSet.has_action("custom:1") and not MenuSet.has_action("nope"), "есть ли функция")
	_check(MenuSet.all_ids().has("paste") and MenuSet.all_ids().has("custom:1") and MenuSet.all_ids().size() == MenuSet.ACTIONS.size() + 1,
			"все функции — готовые и свои")
	MenuSet.custom = {}
	_check(is_equal_approx(MenuSet.ring_radius_for(2), 0.1) and MenuSet.ring_radius_for(8) > MenuSet.ring_radius_for(5),
			"кольцо: не меньше 10 см и растёт с числом пунктов")
	var navigator := MenuSet.Navigator.new()
	navigator.open(Vector3(0.0, 1.4, -0.4), Vector3(0.0, 1.6, 0.0))
	_check(navigator.offset(navigator.centre, navigator.centre + Vector3(0.05, 0.02, 0.0)).is_equal_approx(Vector2(0.05, 0.02)),
			"меню: смещение руки в плоскости кольца")

	# ScrollStick: offset in the ring's plane; towards the viewer does not count.
	var stick := ScrollStick.new()
	stick.start(Vector3(0.0, 1.3, -0.4), Vector3(0.0, 1.6, 0.0))
	_check(stick.offset(Vector3(0.03, 1.32, -0.4)).is_equal_approx(Vector2(0.03, 0.02)), "прокрутка: смещение вправо и вверх")
	_check(stick.offset(Vector3(0.0, 1.3, -0.3)).is_zero_approx(), "прокрутка: к себе — не смещение")

	# PanelLayout: half-angle a panel takes, and a placement by angles.
	var size := Vector2(1.0, 0.6)
	var flat := PanelLayout.half_azimuth(size, 0.0, 0.0, 0.0, 2.0)
	_check(is_equal_approx(flat, atan(0.5 / 2.0)), "половина угла плоской панели перед глазом")
	_check(PanelLayout.half_azimuth(size, deg_to_rad(30.0), deg_to_rad(30.0), 0.0, 2.0) > flat, "наклонённая выше глаз ближе и шире на вид")
	_check(PanelLayout.half_azimuth(size, 0.0, 0.0, 1.0, 2.0) > flat, "изогнутая на вид шире: края загибаются к глазу")
	var eye := Vector3(0.0, 1.6, 0.0)
	var placed := PanelLayout.placement_at(deg_to_rad(30.0), deg_to_rad(10.0), size, eye, 2.0)
	_check(placed.transform.origin.is_equal_approx(eye + PanelLayout.direction_of(deg_to_rad(30.0), deg_to_rad(10.0)) * 2.0),
			"панель стоит на сфере по курсу и возвышению")
	_check(is_equal_approx(placed.pitch, deg_to_rad(10.0)) and placed.transform.basis.z.normalized().dot((eye - placed.transform.origin).normalized()) > 0.999,
			"без наклона — смотрит на глаз")
	_check(is_equal_approx(PanelLayout.placement_at(0.0, deg_to_rad(10.0), size, eye, 2.0, 0.0).pitch, 0.0), "наклон «прямо» задаётся явно")

	# HandPose.box_template: a range is the pose, out of it is not; the rest is "any".
	var box := HandPose.box_template("pose:test", "Проба", {0: [0.2, 0.4]})
	var values := PackedFloat32Array()
	values.resize(HandPose.FEATURE_COUNT)
	values.fill(5.0)
	values[0] = 0.3
	_check(HandPose.distance(box, values, false) <= 1.0, "коробка: внутри диапазона — поза, остальные признаки любые")
	values[0] = 0.9
	_check(HandPose.distance(box, values, false) > 1.0 and is_inf(box.tolerance[1]), "коробка: вне диапазона — не поза")

	# WorldLayout.find
	var spheres := WorldLayout.default_fixtures(PackedStringArray(["a"]))
	_check(WorldLayout.find(spheres, spheres[0].id) == spheres[0] and WorldLayout.find(spheres, 999) == null, "заготовка по id")

	# VddConfig.write refuses an empty list before touching the driver's file.
	_check(VddConfig.write([] as Array[Vector2i]) != "", "драйвер: пустой список разрешений не пишется")

	# Edge cases found in the review (21.10.2026).
	var broken: Array[PackedFloat32Array] = []
	for k in 50:
		broken.append(PackedFloat32Array([1.0, 2.0]))
	_check(HandPose.record(broken, "custom:x", "x") == null, "запись позы из кадров не того размера — не поза, без падения")
	_check(is_equal_approx(PanelLayout.snap_scale(0.0, Vector2(1.0, 0.6), [Vector2(1.0, 0.6)] as Array[Vector2], 0.04), 0.0)
			and is_equal_approx(PanelLayout.snap_scale(1.0, Vector2.ZERO, [Vector2(1.0, 0.6)] as Array[Vector2], 0.04), 1.0),
			"магнит размера: нулевой масштаб или размер — без деления на ноль")


func _test_wall_layout() -> void:
	var one := Rect2i(0, 0, 1, 1)
	var pitch := WallLayout.pitch()
	_check(WallLayout.cell_centre(one).is_zero_approx() and WallLayout.cell_centre(Rect2i(1, 0, 1, 1)).is_equal_approx(Vector2(pitch.x, 0.0))
			and WallLayout.cell_centre(Rect2i(0, 0, 2, 2)).is_equal_approx(Vector2(pitch.x * 0.5, -pitch.y * 0.5)),
			"стена: середины клеток (столбцы вправо, ряды вниз)")
	_check(WallLayout.cell_size(Rect2i(0, 0, 2, 2)).is_equal_approx(WallLayout.CELL * 2.0 + Vector2.ONE * WallLayout.DEFAULT_GAP), "стена: 2×2 клетки с зазором")
	_check(WallLayout.panel_size(one, Vector2i(1920, 1080)).is_equal_approx(WallLayout.CELL), "стена: экран 16:9 заполняет клетку")
	var wide := WallLayout.panel_size(Rect2i(0, 0, 2, 1), Vector2i(3440, 1440))
	_check(is_equal_approx(wide.y, WallLayout.CELL.y) and is_equal_approx(wide.x / wide.y, 3440.0 / 1440.0), "стена: широкий экран вписан по высоте")
	_check(WallLayout.span_for(Vector2i(3840, 2160)) == Vector2i(2, 2) and WallLayout.span_for(Vector2i(2560, 1440)) == Vector2i(1, 1)
			and WallLayout.span_for(Vector2i(3440, 1440)) == Vector2i(2, 1), "стена: сколько клеток занимает экран")
	var far := Rect2i(-2, 1, 2, 2)
	var far_centre := WallLayout.cell_centre(far)
	_check(WallLayout.cell_at(0.1, -0.05, Vector2i.ONE) == one and WallLayout.cell_at(far_centre.x, far_centre.y, far.size) == far,
			"стена: клетка по точке — обратное к середине")

	var taken: Array[Rect2i] = [one]
	var free := WallLayout.nearest_free(one, taken)
	_check(not free.intersects(one) and absi(free.position.x) + absi(free.position.y) == 1, "стена: занято — ближайшая свободная рядом")

	var row: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 1920, 1080), Rect2i(-1920, 0, 1920, 1080), Rect2i(-1920, 1080, 3840, 2160)]
	var cells := WallLayout.from_desktop(row, 0)
	_check(cells[0] == one and cells[1] == Rect2i(1, 0, 1, 1) and cells[2] == Rect2i(-1, 0, 1, 1) and cells[3] == Rect2i(-1, 1, 2, 2),
			"стена: из раскладки Windows — основной в (0, 0), 4K на 2×2 снизу: %s" % [cells])
	var clash: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(900, 0, 1920, 1080)]
	var apart := WallLayout.from_desktop(clash, 0)
	_check(apart[0] == one and not apart[1].intersects(apart[0]), "стена: два экрана на одну клетку — второй рядом")

	var placed := {"a": one}
	var settled := WallLayout.settle(placed, PackedStringArray(["a", "b"]), [Rect2i(5000, 0, 1920, 1080), Rect2i(0, 0, 1920, 1080)] as Array[Rect2i], 1)
	_check(settled["a"] == one and not (settled["b"] as Rect2i).intersects(one) and placed.size() == 1,
			"стена: свои клетки остаются, новый — в свободную, исходник не тронут")
	var swapped := WallLayout.moved({"a": one, "b": Rect2i(1, 0, 1, 1)}, "a", Rect2i(1, 0, 1, 1))
	_check(swapped["a"] == Rect2i(1, 0, 1, 1) and not (swapped["b"] as Rect2i).intersects(swapped["a"]), "стена: перенос на соседа — сосед отходит")
	var grown := WallLayout.moved({"a": one, "b": Rect2i(1, 0, 1, 1), "c": Rect2i(0, 1, 1, 1)}, "a", Rect2i(0, 0, 2, 2))
	_check(not (grown["b"] as Rect2i).intersects(grown["a"]) and not (grown["c"] as Rect2i).intersects(grown["a"])
			and not (grown["b"] as Rect2i).intersects(grown["c"]), "стена: увеличенный экран раздвигает соседей")

	var flat_shape := WallLayout.shape_of(one, 0.06, 1.5, 0.0)
	var flat := WallLayout.surface(0.4, 0.2, 0.0, flat_shape)
	_check(flat.origin.is_equal_approx(Vector3(0.4, 0.2, -1.5)) and flat.basis.z.is_equal_approx(Vector3.BACK), "стена плоская: точка и лицо к месту")
	_check(WallLayout.hit(Vector3.ZERO, Vector3(0.3, 0.2, -1.0).normalized(), flat_shape).is_equal_approx(Vector2(0.45, 0.3)), "стена плоская: попадание луча")
	_check(is_nan(WallLayout.hit(Vector3.ZERO, Vector3.BACK, flat_shape).x), "стена плоская: луч назад — мимо")
	_check(WallLayout.eye(Vector2(1.0, 0.5), flat_shape).origin.is_equal_approx(Vector3(1.0, 0.5, 0.0)), "стена: место скользит вдоль")
	# Bent round its middle; 1 = a closed cylinder (the user's wish, 21.10.2026).
	var row_of_five := Rect2i(-2, 0, 5, 1)
	var cylinder := WallLayout.shape_of(row_of_five, 0.06, 1.5, 1.0)
	_check(is_equal_approx(cylinder.middle, 0.0) and is_equal_approx(cylinder.radius() * TAU, cylinder.length), "стена-цилиндр: длина стены — окружность")
	_check(WallLayout.surface(0.0, 0.0, 0.0, cylinder).origin.is_equal_approx(Vector3(0.0, 0.0, -1.5))
			and WallLayout.surface(-cylinder.length * 0.5, 0.0, 0.0, cylinder).origin.is_equal_approx(WallLayout.surface(cylinder.length * 0.5, 0.0, 0.0, cylinder).origin),
			"стена-цилиндр: середина на месте, концы сходятся")
	var inside := WallLayout.shape_of(row_of_five, 0.06, 0.6, 1.0)
	var seat_a := WallLayout.eye(Vector2.ZERO, inside)
	var seat_b := WallLayout.eye(Vector2(1.0, 0.0), inside)
	var faced := WallLayout.surface(1.0, 0.0, 0.0, inside).origin
	_check(seat_a.origin.distance_to(seat_b.origin) > 0.2 and is_equal_approx(seat_b.origin.distance_to(faced), 0.6)
			and (faced - seat_b.origin).normalized().is_equal_approx(-seat_b.basis.z), "изогнутая стена: место едет по дуге, смотрит ровно на экран перед собой")
	var target := WallLayout.surface(1.3, 0.1, 0.0, inside).origin
	_check(WallLayout.hit(seat_b.origin, (target - seat_b.origin).normalized(), inside).is_equal_approx(Vector2(1.3, 0.1)), "стена-цилиндр: луч изнутри попадает в свою точку")
	var quarter := WallLayout.shape_of(row_of_five, 0.06, 1.5, 0.25)
	var bent := WallLayout.surface(0.8, 0.1, 0.0, quarter)
	_check(WallLayout.hit(Vector3.ZERO, bent.origin.normalized(), quarter).is_equal_approx(Vector2(0.8, 0.1)), "стена в четверть круга: луч в точку стены даёт ту же точку")
	_check(bent.basis.z.dot(-bent.origin) > 0.0, "стена изогнутая: экран смотрит к месту")
	var corner := WallLayout.size_handle_point(one)
	_check(corner.x > WallLayout.CELL.x * 0.5 and corner.y < -WallLayout.CELL.y * 0.5, "стена: ручка размера за правым нижним углом")

	var wall := WorldLayout.new_fixture(WorldLayout.default_fixtures(PackedStringArray()), "wall", Vector3(1.0, 1.5, 2.0), 0.5)
	wall.bend = 0.3
	wall.cells = {"m": Rect2i(-1, 2, 2, 2)}
	var restored := WorldLayout.Fixture.from_dictionary(wall.to_dictionary())
	_check(wall.name == "Стена 1" and is_equal_approx(wall.radius, WallLayout.DEFAULT_DISTANCE) and is_equal_approx(restored.bend, 0.3)
			and restored.cells.get("m") == Rect2i(-1, 2, 2, 2), "стена: имя, расстояние, сохранение изгиба и клеток")
	var head := Transform3D(Basis(Vector3.UP, 0.7), Vector3(0.2, 1.6, -0.1))
	var eyes := Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP), Vector3(3.0, 1.5, 2.0))
	var rig := WorldLayout.rig_for(eyes, head)
	_check((rig * head).origin.is_equal_approx(eyes.origin) and (rig.basis * -head.basis.z).is_equal_approx(Vector3.RIGHT), "место: голова в точку, взгляд вдоль")
	var left := WallLayout.bend_handle_point(one)
	_check(is_equal_approx(left.x, WallLayout.area(one).get_center().x) and left.y < corner.y, "стена: ручка изгиба под серединой")
	_check(WallLayout.size_handle_point(one, 0.06, Vector2i(-1, -1)).x < 0.0 and WallLayout.size_handle_point(one, 0.06, Vector2i(-1, -1)).y > 0.0,
			"стена: ручка размера у левого верхнего угла")
	_check(is_equal_approx(WallLayout.bend_from_degrees(36.0, 3.0), 0.1) and is_equal_approx(WallLayout.bend_from_degrees(46.8, 3.0), 45.0 / 360.0)
			and WallLayout.bend_from_degrees(1.4, 3.0) == 0.0 and WallLayout.bend_from_degrees(500.0, 3.0) == 1.0,
			"стена: изгиб ручкой — магнит каждые 15° дуги, от плоской до цилиндра")

	# The wall's own size and gap (21.10.2026).
	var screens: Array[Rect2i] = [one, Rect2i(1, 0, 2, 2)]
	_check(WallLayout.settle_grid(Rect2i(), screens) == Rect2i(0, 0, 3, 2) and WallLayout.settle_grid(Rect2i(), [] as Array[Rect2i]) == one
			and WallLayout.settle_grid(Rect2i(-1, -1, 2, 2), screens) == Rect2i(-1, -1, 4, 3), "стена: размер — не меньше экранов")
	_check(is_equal_approx(WallLayout.cell_centre(Rect2i(1, 0, 1, 1), 0.2).x, WallLayout.CELL.x + 0.2)
			and is_equal_approx(WallLayout.cell_size(Rect2i(0, 0, 2, 1), 0.0).x, WallLayout.CELL.x * 2.0), "стена: зазор между клетками настраивается")
	var lines := WallLayout.outline(Rect2i(0, 0, 3, 2), 0.06, WallLayout.shape_of(Rect2i(0, 0, 3, 2), 0.06, 1.5, 0.0))
	_check(lines.size() == 6 * 4 * 2 and is_equal_approx(lines[0].z, -1.5 + WallLayout.OUTLINE_DEPTH), "стена: контур — вокруг каждой клетки, за стеной")
	var bent_lines := WallLayout.outline(Rect2i(0, 0, 3, 2), 0.06, WallLayout.shape_of(Rect2i(0, 0, 3, 2), 0.06, 1.5, 0.5))
	_check(bent_lines.size() > lines.size() * 2, "стена изогнутая: линии поперёк по дуге")
	var joined_wall := WallLayout.Wall.new()
	joined_wall.blocks = {"B1": "0,0+1,0"}
	var joined_lines := WallLayout.outline(Rect2i(0, 0, 3, 2), 0.06, WallLayout.shape_of(Rect2i(0, 0, 3, 2), 0.06, 1.5, 0.0), joined_wall)
	_check(joined_lines.size() == lines.size() - 4 * 2, "стена: соединённые клетки — одна клетка в контуре")
	var ball := WallLayout.sphere_outline(1.1, 16)
	_check(ball.size() == 3 * 16 * 2 and is_equal_approx(ball[5].length(), 1.1 - WallLayout.OUTLINE_DEPTH), "шар: контур — три окружности за экранами")
	var slab := WallLayout.backing(Rect2i(0, 0, 3, 2), 0.06, WallLayout.shape_of(Rect2i(0, 0, 3, 2), 0.06, 1.5, 0.0))
	var behind := true
	for point in slab:
		behind = behind and point.z <= -1.5 + WallLayout.BACKING_FRONT + 0.0001 and point.z >= -1.5 + WallLayout.BACKING_BACK - 0.0001
	_check(slab.size() == 36 and behind, "стена: подложка — плита за экранами")
	# A bent wall: the seat goes back at most to the axis (21.10.2026).
	var far_seat := WallLayout.shape_of(row_of_five, 0.06, 5.0, 1.0)
	_check(is_equal_approx(WallLayout.seat_depth(far_seat), far_seat.radius()) and WallLayout.eye(Vector2(1.0, 0.0), far_seat).origin.is_equal_approx(far_seat.axis())
			and is_equal_approx(WallLayout.max_distance(far_seat, 6.0), far_seat.radius()) and WallLayout.max_distance(flat_shape, 6.0) == 6.0,
			"изогнутая стена: дальше оси место не уходит")
	var near_seat := WallLayout.shape_of(row_of_five, 0.06, 0.6, 1.0)
	var slid := WallLayout.eye(Vector2(0.5, 0.0), near_seat).origin.x - WallLayout.eye(Vector2.ZERO, near_seat).origin.x
	_check(slid > 0.0, "изогнутая стена: вправо — значит вправо")
	# Seat offer and sitting at a wall (21.10.2026).
	_check(WallLayout.project(Vector3(0.4, 0.2, -0.5), flat_shape).is_equal_approx(Vector3(0.4, 0.2, 1.0))
			and WallLayout.project(Vector3(0.0, 0.0, -2.0), flat_shape).z < 0.0, "стена плоская: проекция точки и сколько до стены")
	var standing := WallLayout.eye(Vector2(0.9, 0.3), quarter).origin
	var seen := WallLayout.project(standing, quarter)
	_check(is_equal_approx(seen.x, 0.9) and is_equal_approx(seen.y, 0.3) and is_equal_approx(seen.z, WallLayout.seat_depth(quarter)),
			"стена изогнутая: проекция места — точка скольжения и расстояние")
	var screens_at: Array[Rect2i] = [one, Rect2i(0, 2, 1, 1)]
	_check(WallLayout.nearest_screen(screens_at, 0.1, -2.4).is_equal_approx(WallLayout.cell_centre(Rect2i(0, 2, 1, 1)))
			and WallLayout.nearest_screen([] as Array[Rect2i], 0.3, 0.4) == Vector2(0.3, 0.4), "стена: сесть — к ближайшему экрану")


static func _split_wall(splits: Dictionary) -> WallLayout.Wall:
	var wall := WallLayout.Wall.new()
	wall.splits = splits
	return wall


func _test_wall_split() -> void:
	# Saved before joined cells were cells of their own: groups become "B<n>".
	var old := WorldLayout.Fixture.from_dictionary({"kind": "wall", "joins": ["0,0+1,0"], "parts": {"m": "0,0+1,0", "n": "2,0:1"}, "splits": {"2,0": "c2"}})
	_check(old.blocks == {"B1": "0,0+1,0"} and old.parts.get("m") == "B1" and old.parts.get("n") == "2,0:1",
			"старое сохранение: соединённое место стало клеткой B1")
	var saved := WorldLayout.Fixture.from_dictionary(old.to_dictionary())
	_check(saved.blocks == old.blocks and saved.parts == old.parts, "соединённые клетки сохраняются")
	# Split cells (slice k2, 22.10.2026).
	var driver: Array[Vector2i] = [Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160), Vector2i(1080, 1920)]
	_check(WallLayout.best_resolution(WallLayout.CELL * 2.0, driver) == Vector2i(3840, 2160),
			"разрешение по клетке: 2×2 клетки — 4K")
	_check(WallLayout.best_resolution(WallLayout.CELL, driver) == Vector2i(1920, 1080),
			"разрешение по клетке: одна клетка — 1920×1080")
	_check(WallLayout.best_resolution(Vector2(WallLayout.CELL.y, WallLayout.CELL.x), driver) == Vector2i(1080, 1920),
			"разрешение по клетке: стоячая часть — стоячее разрешение")
	_check(WallLayout.best_resolution(Vector2(WallLayout.CELL.x / 3.0, WallLayout.CELL.y), driver) == Vector2i.ZERO,
			"разрешение по клетке: нет подходящего по форме — ничего")
	_check(WallLayout.wanted_resolution(WallLayout.CELL) == Vector2i(1920, 1080), "нужное разрешение: клетка — 1920×1080")
	var half_cell := WallLayout.wanted_resolution(Vector2((WallLayout.CELL.x - 0.06) * 0.5, WallLayout.CELL.y))
	_check(half_cell.x % 8 == 0 and half_cell.y == 1080 and absi(half_cell.x - 912) <= 8, "нужное разрешение: полклетки — около 912×1080")
	var with_half: Array[Vector2i] = driver.duplicate()
	with_half.append(half_cell)
	_check(WallLayout.best_resolution(Vector2((WallLayout.CELL.x - 0.06) * 0.5, WallLayout.CELL.y), with_half) == half_cell,
			"разрешение по клетке: добавленное в драйвер подходит")

	# Staggered rows: a screen on the line between two cells (22.10.2026).
	var row := WallLayout.Wall.new()
	row.cells = {"a": Rect2i(0, 0, 1, 1), "b": Rect2i(1, 0, 1, 1), "c": Rect2i(0, 1, 1, 1)}
	var step := WallLayout.pitch(0.06)
	var stagger := WallLayout.dropped(row, "c", 0.5 * step.x, 0.0, 0.06)
	_check(stagger.parts.get("c") == "B1" and stagger.blocks.get("B1") == "0,0:1+1,0:0" and stagger.splits.get("0,0") == "c2" and stagger.splits.get("1,0") == "c2",
			"шахматный порядок: экран на стыке — на двух половинах, клетки поделены")
	_check(stagger.parts.get("a") == "0,0:0" and stagger.parts.get("b") == "1,0:1", "шахматный порядок: соседи — во внешних половинах")
	var stagger_area := WallLayout.screen_area(stagger, "c", 0.06)
	_check(is_equal_approx(stagger_area.size.x, WallLayout.CELL.x) and is_equal_approx(stagger_area.get_center().x, 0.5 * step.x),
			"шахматный порядок: экран шириной в клетку, посередине стыка")
	_check(WallLayout.screen_cells(stagger, "c") == Rect2i(0, 0, 2, 1), "шахматный порядок: экран стоит на двух клетках")
	_check(WallLayout.dropped(row, "c", 0.3 * step.x, 0.0, 0.06).parts.is_empty(), "не у стыка — обычный перенос")
	var thirds := row.copy()
	thirds.splits = {"1,0": "c3"}
	_check(WallLayout.straddled(thirds, "c", Vector2i(0, 0)) == null, "на стык с клеткой на три — нельзя")


	# The grip: split in two, delete, join four ways (22.10.2026).
	var grid := Rect2i(0, 0, 2, 2)
	var whole_split := WallLayout.split_step(row, "0,0", "c")
	_check(whole_split.splits.get("0,0") == "c2" and whole_split.parts.get("a") == "0,0:0", "деление: целая — 2 столбца")
	var nested := WallLayout.split_step(whole_split, "0,0:1", "c")
	_check(nested.splits.get("0,0:1") == "c2" and nested.splits.get("0,0") == "c2", "деление: часть делится ещё раз пополам")
	var many := row
	var deepest := "0,0"
	for k in 6:
		many = WallLayout.split_step(many, deepest, "c")
		deepest += ":1"
	_check(many.splits.has("0,0:1:1") and not many.splits.has("0,0:1:1:1"), "деление: не мельче 8 см (столбцы 60, 27, 11 см — да, 2 см — нет)")
	# Into N equal parts in one go (22.10.2026).
	var fifths := WallLayout.split_step(row, "1,0", "c", 0.06, 5)
	_check(fifths.splits.get("1,0") == "c5" and is_equal_approx(WallLayout.slot_area("1,0:4", fifths.splits, 0.06).size.x, (WallLayout.CELL.x - 0.24) / 5.0)
			and WallLayout.split_step(row, "1,0", "c", 0.06, 10).splits.is_empty(), "деление на 5 равных столбцов; на 10 — уже мельче 8 см")
	_check(WallLayout.split_step(row, "1,0", "c", 0.06, 1) == row, "деление на 1 — ничего")
	# A joined cell is a cell of its own (22.10.2026, «соедини в настоящую»): split
	# into N equal parts like any cell, what it covers untouched.
	var pair := WallLayout.Wall.new()
	pair.blocks = {"B1": "0,0+1,0"}
	for n: int in [3, 5]:
		var cut_n := WallLayout.split_step(pair, "B1", "c", 0.06, n)
		var equal := cut_n.splits == {"B1": "c%d" % n} and cut_n.blocks == pair.blocks
		for k in n:
			equal = equal and is_equal_approx(cut_n.area_of("B1:%d" % k, 0.06).size.x, (2 * WallLayout.CELL.x + 0.06 - (n - 1) * 0.06) / n)
		_check(equal, "соединённое из двух клеток — на %d равных частей: %s" % [n, cut_n.splits])
	_check(WallLayout.split_step(pair, "B1", "c", 0.06, 20) == pair, "соединённое — не мельче 8 см")
	_check(not WallLayout.is_leaf(pair, "0,0") and WallLayout.is_leaf(pair, "B1") and not WallLayout.is_leaf(pair, "B2")
			and WallLayout.all_leaves(pair, Rect2i(0, 0, 2, 2)) == PackedStringArray(["0,1", "1,1", "B1"]),
			"соединённое: клетки под ним спрятаны, само — место")
	var pair_cut := WallLayout.split_step(pair, "B1", "r", 0.06)
	_check(WallLayout.leaf_at(pair_cut, Vector2i(1, 0), WallLayout.CELL.x * 1.5, -0.3, 0.06) == "B1:1",
			"соединённое: точка на второй клетке — его нижняя часть")
	var uneven := {"0,0": "cw0.25,0.75"}
	_check(is_equal_approx(WallLayout.slot_area("0,0:0", uneven, 0.06).size.x, (WallLayout.CELL.x - 0.06) * 0.25)
			and WallLayout.leaf_at(_split_wall(uneven), Vector2i(0, 0), WallLayout.slot_area("0,0:1", uneven, 0.06).get_center().x, 0.0, 0.06) == "0,0:1",
			"неравное деление: доли и часть под точкой")
	var three_uneven := WallLayout.Wall.new()
	three_uneven.splits = {"0,0": "cw1,2,1"}
	_check(WallLayout.deleted(three_uneven, "0,0:1", Rect2i(0, 0, 1, 1), 0.06).splits.get("0,0") == "c2", "удаление из неравного деления: остальные по своим долям")
	_check(WallLayout.slot_area("0,0:3", {"0,0": "c9"}, 0.3).size.x >= 0.0, "часть не уходит в минус при большом зазоре")
	# Selecting several cells (22.10.2026).
	var empty_wall := WallLayout.Wall.new()
	var four_cells := WallLayout.selection(empty_wall, Rect2i(0, 0, 3, 3), WallLayout.cell_centre(Rect2i(0, 0, 1, 1)), WallLayout.cell_centre(Rect2i(1, 1, 1, 1)))
	_check(four_cells.size() == 4 and four_cells.has("1,1") and not four_cells.has("2,0"), "выделение: прямоугольник из четырёх клеток")
	var joined_pick := WallLayout.split_many(pair, PackedStringArray(["B1"]), "c", 3, 0.06)
	_check(joined_pick.splits == {"B1": "c3"}, "выделение соединённого места: на 3 части целиком: %s" % [joined_pick.splits])
	var grid_made := WallLayout.split_many(empty_wall, four_cells, "c", 2)
	_check(grid_made.splits.size() == 4 and grid_made.splits.get("0,1") == "c2", "выделение: каждая клетка поделена")
	var one_place := WallLayout.joined_many(empty_wall, four_cells, Rect2i(0, 0, 3, 3))
	_check(one_place.blocks.size() == 1 and (one_place.blocks["B1"] as String).split("+").size() == 4, "выделение: соединено в одно место")
	var corner_pick := PackedStringArray(["0,0", "1,1"])
	_check((WallLayout.joined_many(empty_wall, corner_pick, Rect2i(0, 0, 3, 3)).blocks["B1"] as String).split("+").size() == 4,
			"выделение по диагонали достраивается до прямоугольника")
	var with_screen := WallLayout.Wall.new()
	with_screen.cells = {"big": Rect2i(1, 0, 2, 1)}
	_check(WallLayout.joined_many(with_screen, PackedStringArray(["0,0", "1,0"]), Rect2i(0, 0, 3, 3)) == with_screen,
			"выделение: экран, выходящий за выделенное, не даёт соединить")
	var four := WallLayout.split_step(nested, "0,0:0", "c")
	_check(four.splits == {"0,0": "c4"} and four.parts.get("a") == "0,0:0", "деление: две половины пополам — четыре равных столбца")
	var three := WallLayout.deleted(four, "0,0:3", grid, 0.06)
	_check(three.splits == {"0,0": "c3"} and is_equal_approx(WallLayout.slot_area("0,0:2", three.splits, 0.06).size.x, (WallLayout.CELL.x - 0.12) / 3.0),
			"удаление: оставшиеся три делят место поровну")
	var halves_gone := WallLayout.deleted(whole_split, "0,0:1", grid, 0.06)
	_check(halves_gone.splits.is_empty() and halves_gone.cells.get("a") == Rect2i(0, 0, 1, 1), "удаление одной из двух половин — вторая на всю клетку")
	var gone := WallLayout.deleted(row, "0,0", grid, 0.06)
	_check(gone.parts.get("b") == "B1" and gone.blocks.get("B1") == "0,0+1,0" and gone.cells.has("a") and not WallLayout.overlaps(gone.cells["a"], gone.taken("a")),
			"удаление клетки: её место занимает сосед справа, экран — в свободную клетку")
	var right_split := row.copy()
	right_split.splits = {"1,0": "c2"}
	right_split.cells.erase("b")
	_check(WallLayout.deleted(right_split, "0,0", grid, 0.06).blocks.values().has("0,0+0,1"), "удаление: справа другой размер — место занимает нижний")
	var alone := WallLayout.Wall.new()
	_check(WallLayout.deleted(alone, "0,0", Rect2i(0, 0, 1, 1), 0.06) == alone, "единственная клетка не удаляется")
	# 22.10.2026: the grip kept a part that a join had removed; deleting it stopped the frame.
	_check(not WallLayout.is_leaf(whole_split, "0,0:1:0") and WallLayout.is_leaf(whole_split, "0,0:1")
			and not WallLayout.is_leaf(whole_split, "0,0"), "часть стены: существует ли она сейчас")
	_check(WallLayout.deleted(whole_split, "0,0:1:0", grid, 0.06) == whole_split, "удаление несуществующей части ничего не делает")
	var triple := WallLayout.Wall.new()
	triple.blocks = {"B1": "0,0+1,0+2,0"}
	var cut := WallLayout.split_step(triple, "B1", "c", 0.06)
	_check(is_equal_approx(cut.area_of("B1:0", 0.06).size.x, cut.area_of("B1:1", 0.06).size.x), "деление соединённого из трёх клеток — две равные половины")
	var half_gone := WallLayout.deleted(cut, "B1:1", Rect2i(0, 0, 3, 1), 0.06)
	_check(half_gone.splits.is_empty() and half_gone.blocks == triple.blocks, "удаление половины соединённого — вторая на всё место")
	var with_tenant := triple.copy()
	with_tenant.parts = {"t": "B1"}
	var tenant_cut := WallLayout.split_step(with_tenant, "B1", "r", 0.06)
	_check(tenant_cut.parts.get("t") == "B1:0", "деление соединённого: экран — в первую часть")
	var regrown := WallLayout.joined(tenant_cut, "B1:0", Vector2i(0, 1), Rect2i(0, 0, 3, 1), 0.06)
	_check(regrown.blocks == triple.blocks and regrown.splits.is_empty() and regrown.parts.get("t") == "B1",
			"соединение двух частей соединённого — оно снова целое")
	var two := WallLayout.joined(whole_split, "0,0:0", Vector2i(1, 0), grid, 0.06)
	_check(two.blocks.is_empty() and not two.splits.has("0,0") and two.cells.get("a") == Rect2i(0, 0, 1, 1),
			"соединение двух половин — клетка снова целая")
	var cells_joined := WallLayout.joined(row, "0,0", Vector2i(1, 0), grid, 0.06)
	_check(cells_joined.parts.get("a") == "B1" and cells_joined.has("b") and not cells_joined.parts.has("b")
			and is_equal_approx(WallLayout.screen_area(cells_joined, "a", 0.06).size.x, WallLayout.CELL.x * 2.0 + 0.06),
			"соединение двух клеток: экран на обеих, второй — в свободную клетку")
	_check(WallLayout.join_target(row, "0,0", Vector2i(0, 1), grid, 0.06) == "0,1", "соединение вниз — с клеткой ниже")
	_check(WallLayout.join_target(row, "0,1", Vector2i(0, -1), grid, 0.06) == "0,0", "соединение вверх — с клеткой выше")
	_check(WallLayout.join_target(row, "1,0", Vector2i(-1, 0), grid, 0.06) == "0,0", "соединение влево — с клеткой слева")
	var rows_split := WallLayout.split_step(row, "0,0", "r")
	_check(WallLayout.join_target(rows_split, "0,0:0", Vector2i(1, 0), grid, 0.06) == "", "соединение: стороны разной длины — нельзя")
	_check(WallLayout.join_target(whole_split, "0,0:1", Vector2i(1, 0), grid, 0.06) == "1,0", "соединение: половина с клеткой справа — сторона одна")
	_check(WallLayout.join_target(WallLayout.split_step(whole_split, "0,0:1", "r"), "0,0:0", Vector2i(1, 0), grid, 0.06) == "",
			"соединение: справа две части — нельзя")
	var all_one := WallLayout.joined(WallLayout.joined(WallLayout.joined(WallLayout.Wall.new(), "0,0", Vector2i(1, 0), grid, 0.06),
			"0,1", Vector2i(1, 0), grid, 0.06), "B1", Vector2i(0, 1), grid, 0.06)
	_check(all_one.blocks.size() == 1 and (all_one.blocks["B1"] as String).split("+").size() == 4
			and WallLayout.all_leaves(all_one, grid) == PackedStringArray(["B1"]), "всю стену можно соединить в одно место")
	# Nothing inside a joined cell is remembered («зачем вообще помнить», 22.10.2026).
	var chopped := WallLayout.split_many(WallLayout.Wall.new(), PackedStringArray(["0,0", "1,0"]), "c", 3, 0.06)
	chopped = WallLayout.split_many(chopped, WallLayout.all_leaves(chopped, Rect2i(0, 0, 2, 1)), "r", 2, 0.06)
	var merged_all := WallLayout.joined_many(chopped, WallLayout.all_leaves(chopped, Rect2i(0, 0, 2, 1)), Rect2i(0, 0, 2, 1), 0.06)
	var kept_members := (merged_all.blocks.get("B1", "") as String).split("+")
	kept_members.sort()
	_check(kept_members == PackedStringArray(["0,0", "1,0"]) and merged_all.splits.is_empty(),
			"соединение 12 частей двух клеток — помнит только две клетки: %s %s" % [merged_all.blocks, merged_all.splits])
	var edge := WallLayout.joined_many(chopped, PackedStringArray(["0,0:2:0", "0,0:2:1", "1,0:0:0", "1,0:0:1"]), Rect2i(0, 0, 2, 1), 0.06)
	var edge_members := (edge.blocks.get("B1", "") as String).split("+")
	edge_members.sort()
	_check(edge_members == PackedStringArray(["0,0:2", "1,0:0"]) and not edge.splits.has("0,0:2") and edge.splits.get("0,0") == "c3",
			"соединение по краю клеток — помнит только два куска: %s" % [edge.blocks])
	_check(WallLayout.joined(whole_split, "0,0:0", Vector2i(1, 0), grid, 0.06).blocks.is_empty(), "две половины одной клетки — просто клетка")
	# A wall only read remembers its answers; the same answers, and a copy edits afresh.
	var frozen := tenant_cut.copy()
	frozen.frozen = true
	var alike := WallLayout.all_leaves(frozen, Rect2i(0, 0, 3, 1)) == WallLayout.all_leaves(tenant_cut, Rect2i(0, 0, 3, 1))
	for leaf in WallLayout.all_leaves(tenant_cut, Rect2i(0, 0, 3, 1)):
		alike = alike and frozen.area_of(leaf, 0.06) == tenant_cut.area_of(leaf, 0.06) and frozen.area_of(leaf, 0.06) == tenant_cut.area_of(leaf, 0.06)
	alike = alike and frozen.area_of("B1:0", 0.1) == tenant_cut.area_of("B1:0", 0.1) and WallLayout.screen_cells(frozen, "t") == WallLayout.screen_cells(tenant_cut, "t")
	_check(alike and not frozen.copy().frozen and WallLayout.joined(frozen, "B1:0", Vector2i(0, 1), Rect2i(0, 0, 3, 1), 0.06).blocks == triple.blocks,
			"стена только для чтения: те же ответы, правка идёт по копии")
	var unjoined := WallLayout.split_step(stagger, "B1", "c")
	_check(unjoined.splits.get("B1") == "c2" and unjoined.parts.get("c") == "B1:0"
			and WallLayout.split_step(stagger, "0,0:1", "c") == stagger, "место на стыке делится как своя клетка, спрятанная половина — нет")

	# Swipe is bound like the others (22.10.2026).
	var swipe_options: Array = GestureCatalog.options("swipe", []).map(func(o: Array) -> String: return o[0])
	_check(swipe_options.front() == GestureCatalog.PALM and swipe_options.has("pose:move") and not swipe_options.has("pose:fist"),
			"смахивание: ладонь, знак движения и свои позы, без кулака")
	_check(GestureCatalog.sanitize({"swipe": "pose:fist"}, [])["swipe"] == GestureCatalog.OFF
			and GestureCatalog.sanitize({}, [])["swipe"] == GestureCatalog.PALM, "смахивание: по умолчанию ладонь, кулак недопустим")
	var wall := WallLayout.Wall.new()
	wall.cells = {"a": Rect2i(0, 0, 1, 1), "b": Rect2i(1, 0, 1, 1)}
	var halves := WallLayout.cycled(wall, "0,0")
	_check(halves.splits.get("0,0") == "c2" and halves.parts.get("a") == "0,0:0" and not halves.cells.has("a"),
			"деление: клетка пополам, экран — в первую часть")
	var whole := WallLayout.slot_area("0,0", halves.splits)
	var left := WallLayout.slot_area("0,0:0", halves.splits)
	var right := WallLayout.slot_area("0,0:1", halves.splits)
	_check(is_equal_approx(left.position.x, whole.position.x) and is_equal_approx(right.end.x, whole.end.x)
			and is_equal_approx(right.position.x - left.end.x, WallLayout.DEFAULT_GAP) and is_equal_approx(left.size.y, whole.size.y),
			"деление: две части по ширине с зазором между ними")
	var rows := WallLayout.cycled(WallLayout.cycled(halves, "0,0"), "0,0")
	_check(rows.splits.get("0,0") == "r2" and rows.parts.get("a") == "0,0:0", "деление: перебор — столбцы, потом ряды")
	var top := WallLayout.slot_area("0,0:0", rows.splits)
	_check(is_equal_approx(top.end.y, whole.end.y) and top.size.y < whole.size.y * 0.5, "деление на ряды: первая часть сверху")
	var back := WallLayout.cycled(WallLayout.cycled(rows, "0,0"), "0,0")
	_check(not back.splits.has("0,0") and back.cells.get("a") == Rect2i(0, 0, 1, 1) and back.parts.is_empty(), "деление: по кругу — снова целая")
	var deep := WallLayout.cycled(halves, "0,0:1")
	_check(deep.splits.get("0,0:1") == "c2" and WallLayout.leaves("0,0", deep.splits) == PackedStringArray(["0,0:0", "0,0:1:0", "0,0:1:1"]),
			"деление: часть делится дальше")
	var under_point := WallLayout.leaf_at(deep, Vector2i.ZERO, right.get_center().x, right.get_center().y)
	_check(under_point == "0,0:1:1" or under_point == "0,0:1:0", "деление: часть под точкой")
	var into_part := WallLayout.dropped(halves, "b", right.get_center().x, right.get_center().y)
	_check(into_part.parts.get("b") == "0,0:1" and not into_part.cells.has("b"), "перенос: экран в свободную часть")
	var swapped := WallLayout.dropped(into_part, "b", left.get_center().x, left.get_center().y)
	_check(swapped.parts.get("b") == "0,0:0" and swapped.parts.get("a") == "0,0:1", "перенос: на занятую часть — меняются местами")
	var out := WallLayout.dropped(into_part, "b", WallLayout.cell_centre(Rect2i(3, 0, 1, 1)).x, 0.0)
	_check(out.cells.get("b") == Rect2i(3, 0, 1, 1) and not out.parts.has("b"), "перенос: из части на целую клетку")
	var big := WallLayout.Wall.new()
	big.cells = {"k": Rect2i(0, 0, 2, 2)}
	big.splits = {"3,0": "c2"}
	_check(not WallLayout.cycled(big, "1,1").splits.has("1,1"), "деление: клетку под экраном на нескольких клетках не делят")
	var pushed := WallLayout.onto_cells(big, "k", Rect2i(2, 0, 2, 2))
	_check(not (pushed.cells["k"] as Rect2i).has_point(Vector2i(3, 0)), "перенос: широкий экран обходит разделённую клетку")

	# The Windows layout from the wall (22.10.2026).
	var four_k := Vector2i(3840, 2160)
	var hd := Vector2i(1920, 1080)
	var split_left := WallLayout.cycled(WallLayout.cycled(WallLayout.cycled(WallLayout.Wall.new(), "-1,0"), "-1,0"), "-1,0")
	var big_area := WallLayout.area(Rect2i(0, 0, 2, 2))
	var small_top := WallLayout.slot_area("-1,0:0", split_left.splits)
	var small_bottom := WallLayout.slot_area("-1,0:1", split_left.splits)
	var layout := WallLayout.desktop([big_area, small_top, small_bottom] as Array[Rect2], [four_k, hd, hd] as Array[Vector2i], 0, 0.1)
	_check(layout[0] == Rect2i(Vector2i.ZERO, four_k) and layout[1].position.x == -1920 and layout[2].position.x == -1920
			and layout[1].position.y < layout[2].position.y and LayoutEdit.is_valid(layout, 0),
			"Windows по стене: два маленьких слева от 4K — сбоку, друг над другом: %s" % [layout])
	var row_layout := WallLayout.desktop([WallLayout.area(Rect2i(0, 0, 1, 1)), WallLayout.area(Rect2i(1, 0, 1, 1)), WallLayout.area(Rect2i(0, 1, 1, 1))] as Array[Rect2],
			[hd, hd, hd] as Array[Vector2i], 0, 0.1)
	_check(row_layout[1] == Rect2i(1920, 0, 1920, 1080) and row_layout[2] == Rect2i(0, 1080, 1920, 1080), "Windows по стене: справа и снизу")
	var apart := WallLayout.desktop([WallLayout.area(Rect2i(0, 0, 1, 1)), WallLayout.area(Rect2i(4, 0, 1, 1))] as Array[Rect2], [hd, hd] as Array[Vector2i], 0, 0.1)
	_check(LayoutEdit.is_valid(apart, 0) and apart[1].position.x == 1920, "Windows по стене: далёкий экран всё равно рядом")
	var settled := WallLayout.settle({}, PackedStringArray(["p", "n"]), [Rect2i(0, 0, 1920, 1080), Rect2i(0, 0, 1920, 1080)] as Array[Rect2i], 0,
			{"p": "0,0:0"}, [Rect2i(0, 0, 1, 1)] as Array[Rect2i])
	_check(not settled.has("p") and settled.has("n") and not (settled["n"] as Rect2i).intersects(Rect2i(0, 0, 1, 1)),
			"новые мониторы: в частях не трогаются, разделённые клетки обходятся")
	var fitted := WallLayout.fit(Vector2(0.6, 0.714), Vector2i(1920, 1080))
	_check(is_equal_approx(fitted.x, 0.6) and is_equal_approx(fitted.x / fitted.y, 16.0 / 9.0), "экран в узкой части вписан по ширине")
	# Two 1080p beside a 1080p shown as 2x2 (22.10.2026): both still touch it.
	var same := WallLayout.desktop([big_area, small_top, small_bottom] as Array[Rect2], [hd, hd, hd] as Array[Vector2i], 0, 0.1)
	var big_rect := same[0]
	_check(LayoutEdit.is_valid(same, 0) and same[1].end.x == 0 and same[2].end.x == 0
			and same[1].position.y < big_rect.end.y and same[1].end.y > 0 and same[2].position.y < big_rect.end.y and same[2].end.y > 0,
			"Windows по стене: оба маленьких касаются большого и при равных разрешениях: %s" % [same])
	# A screen whose pixels do not match its place (22.10.2026: 960×1080 on a joined
	# place of 2×2 cells) keeps the others in the wall's order.
	var small_px := Vector2i(960, 1080)
	var mixed := WallLayout.desktop([WallLayout.area(Rect2i(0, 0, 1, 1)), WallLayout.area(Rect2i(0, 1, 1, 1)), WallLayout.area(Rect2i(1, 0, 2, 2)),
			WallLayout.area(Rect2i(3, 0, 1, 1))] as Array[Rect2], [hd, hd, small_px, hd] as Array[Vector2i], 0, 0.1)
	_check(mixed[1] == Rect2i(0, 1080, 1920, 1080) and mixed[2].position.x == 1920 and mixed[3].position.x == 1920 + 960
			and LayoutEdit.is_valid(mixed, 0), "Windows по стене: экран не по размеру не сбивает соседей, порядок как на стене: %s" % [mixed])
	var under := WallLayout.desktop([WallLayout.area(Rect2i(0, 0, 1, 1)), WallLayout.area(Rect2i(1, 0, 1, 1)), WallLayout.area(Rect2i(2, 0, 1, 1)),
			WallLayout.area(Rect2i(0, 1, 3, 1))] as Array[Rect2], [hd, hd, hd, small_px] as Array[Vector2i], 1, 0.1)
	_check(under[0].end.x == 0 and under[2].position.x == 1920 and under[3].position.y == 1080 and LayoutEdit.is_valid(under, 1),
			"Windows по стене: ряд из трёх и под ним широкое место — ряд вплотную, место снизу: %s" % [under])
	var split_lines := WallLayout.outline(Rect2i(0, 0, 1, 1), 0.06, WallLayout.shape_of(Rect2i(0, 0, 1, 1), 0.06, 1.5, 0.0), _split_wall({"0,0": "c3"}))
	_check(split_lines.size() == WallLayout.outline(Rect2i(0, 0, 1, 1), 0.06, WallLayout.shape_of(Rect2i(0, 0, 1, 1), 0.06, 1.5, 0.0)).size() * 3,
			"контур: линии вокруг каждой части разделённой клетки")


## Slice l: a column is a wall bent outwards; walls and columns lean (a cone);
## screens on them bend either way.
func _test_column_and_lean() -> void:
	var grid := Rect2i(0, 0, 3, 1)
	var gap := 0.06
	var column := WallLayout.shape_of(grid, gap, 1.5, 1.0, true)
	var length := WallLayout.area(grid, gap).size.x + gap
	_check(is_equal_approx(column.radius(), length / TAU), "столб: радиус — длина по кругу (со швом в зазор)")
	_check(column.axis().is_equal_approx(Vector3(column.middle, 0.0, -1.5 - column.radius())), "столб: ось за стеной")
	var front := WallLayout.surface(column.middle, 0.0, 0.0, column)
	_check(front.origin.is_equal_approx(Vector3(column.middle, 0.0, -1.5)), "столб: середина на расстоянии")
	_check(front.basis.z.is_equal_approx(Vector3.BACK), "столб: смотрит на место")
	var right := WallLayout.surface(column.middle + column.radius() * PI * 0.5, 0.0, 0.0, column)
	_check(right.origin.is_equal_approx(column.axis() + Vector3.RIGHT * column.radius()), "столб: четверть круга вправо — справа от оси")
	_check(right.basis.z.is_equal_approx(Vector3.RIGHT), "столб: и смотрит наружу")
	# Hits from outside, the near side; from inside none.
	var seen := WallLayout.hit(Vector3(column.middle + 0.2, 0.3, 0.0), Vector3.FORWARD, column)
	var back := WallLayout.surface(seen.x, seen.y, 0.0, column).origin
	_check(absf(seen.y - 0.3) < 0.0001 and back.z > column.axis().z, "столб: луч спереди — ближняя сторона")
	_check(is_nan(WallLayout.hit(column.axis(), Vector3.FORWARD, column).x), "столб: изнутри — промах")
	var eye := WallLayout.eye(Vector2(seen.x, 0.0), column)
	_check(is_equal_approx(WallLayout.project(eye.origin, column).z, 1.5), "столб: место на расстоянии, не упирается в ось")
	_check(WallLayout.max_distance(column, 6.0) == 6.0, "столб: отходить можно сколько угодно")
	var wrapped := WallLayout.wrapped(column.middle + length * 0.75, column.middle, column)
	_check(is_equal_approx(wrapped, column.middle - length * 0.25), "столб: по кругу — ближним путём")
	_check(WallLayout.wrapped(9.0, 0.0, WallLayout.shape_of(grid, gap, 1.5, 0.5)) == 9.0, "незамкнутая — без перехода")

	# A lean: upright walls are as before; leaning, the face looks up and v goes up the slope.
	var flat := WallLayout.shape_of(grid, gap, 1.5, 0.0, false, deg_to_rad(30.0))
	var top := WallLayout.surface(0.5, 1.0, 0.0, flat)
	_check(top.origin.is_equal_approx(Vector3(0.5, cos(deg_to_rad(30.0)), -1.5 - sin(deg_to_rad(30.0)))), "наклон: верх уходит от места")
	_check(top.basis.z.y > 0.4, "наклон: смотрит вверх")
	var on_flat := WallLayout.hit(Vector3(0.5, 0.2, 0.0), (top.origin - Vector3(0.5, 0.2, 0.0)).normalized(), flat)
	_check(on_flat.distance_to(Vector2(0.5, 1.0)) < 0.0001, "наклон: луч в точку — та же точка")
	for outside: bool in [false, true]:
		for lean: float in [-0.4, 0.4]:
			var cone := WallLayout.shape_of(grid, gap, 1.5, 0.6, outside, lean)
			var point := WallLayout.surface(cone.middle + 0.3, 0.5, 0.0, cone).origin
			var from := Vector3(cone.middle, 0.0, 0.0) if not outside else Vector3(cone.middle + 0.1, 0.1, 0.5)
			var found := WallLayout.hit(from, (point - from).normalized(), cone)
			_check(found.distance_to(Vector2(cone.middle + 0.3, 0.5)) < 0.001, "конус %s %+.1f: луч в точку — та же точка (%s)" % ["столб" if outside else "стена", lean, found])
			_check(absf(WallLayout.project(point, cone).z) < 0.001, "конус %s %+.1f: точка на поверхности" % ["столб" if outside else "стена", lean])
	var upright := WallLayout.shape_of(grid, gap, 1.5, 0.6)
	var narrowing := WallLayout.shape_of(grid, gap, 1.5, 0.6, true, 0.4)
	var high := WallLayout.surface(narrowing.middle, 1.0, 0.0, narrowing).origin
	_check(Vector2(high.x - narrowing.axis().x, high.z - narrowing.axis().z).length() < narrowing.radius(), "столб, лицом вверх: сужается кверху")
	_check(WallLayout.surface(upright.middle, 0.7, 0.0, upright).origin.is_equal_approx(Vector3(upright.middle, 0.7, -1.5)), "без наклона — как раньше")
	_check(is_equal_approx(WallLayout.tilt_from_degrees(31.0, 3.0), deg_to_rad(30.0)) and is_equal_approx(WallLayout.tilt_from_degrees(-99.0, 3.0), -WallLayout.MAX_TILT), "наклон: магнит и предел")

	# Convex panels: hit from outside, u left to right.
	_check(PanelLayout.curve_radius(-0.5, 1.0) == -2.0, "выпуклый: радиус отрицательный")
	var panel := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -1.0))
	var size := Vector2(1.0, 0.5)
	var middle := PointerMath.ray_arc(Vector3.ZERO, Vector3.FORWARD, panel, size, -1.0)
	_check(is_equal_approx(middle.x, 1.0) and is_equal_approx(middle.y, 0.5), "выпуклый: середина ближе всего")
	var edge := PointerMath.ray_arc(Vector3(0.4, 0.0, 0.0), Vector3.FORWARD, panel, size, -1.0)
	_check(edge.x > 1.0 and edge.y > 0.5, "выпуклый: правее — дальше и правее по u")
	var concave := PointerMath.ray_arc(Vector3(0.4, 0.0, 0.0), Vector3.FORWARD, panel, size, 1.0)
	_check(concave.x > 0.0 and concave.x < 1.0 and concave.y > 0.5, "вогнутый — как раньше")

	# Screens never into the wall: lifted by what would go behind it.
	var cell := WallLayout.CELL
	var on_column := WallLayout.shape_of(grid, gap, 1.5, 1.0, true)
	var reach := on_column.radius()
	_check(WallLayout.lift(on_column, reach, cell, 0.0, 0.0, 0.0) == 0.0, "на столбе плоский — края уходят от столба, не поднимать")
	_check(is_zero_approx(WallLayout.lift(on_column, reach, cell, -1.0, 0.0, 0.0)), "на столбе выпуклый как столб — по поверхности")
	var concave_wall := WallLayout.shape_of(grid, gap, 1.5, 0.5)
	var wall_reach := concave_wall.radius()
	_check(WallLayout.lift(concave_wall, wall_reach, cell, 0.0, 0.0, 0.0) > 0.01, "в вогнутой стене плоский — края вошли бы в стену")
	_check(is_zero_approx(WallLayout.lift(concave_wall, wall_reach, cell, 1.0, 0.0, 0.0)), "вогнутый как стена — по поверхности")
	var leaning := WallLayout.lift(flat, 1.5, cell, 0.0, deg_to_rad(30.0), 0.0)
	_check(is_equal_approx(leaning, cell.y * 0.25), "наклон 30° — поднят на полвысоты · sin")
	_check(is_equal_approx(WallLayout.lift(flat, 1.5, cell, 0.0, 0.0, deg_to_rad(-30.0)), cell.x * 0.25), "поворот 30° — на полширины · sin")
	_check(WallLayout.lift(flat, 1.5, cell, -1.0, 0.0, 0.0) > 0.0, "на плоской выпуклый — середина вперёд")

	# Free placement on a wall: the magnet.
	var others: Array[Rect2] = [Rect2(0.0, 0.0, 1.0, 0.5)]
	var beside := WallLayout.snap_free(Vector2(1.58, 0.27), Rect2(-0.5, -0.25, 1.0, 0.5), others, 0.06, 0.05)
	_check(beside.is_equal_approx(Vector2(1.56, 0.25)), "свободно: вплотную через зазор и в линию (%s)" % beside)
	var above := WallLayout.snap_free(Vector2(0.52, 0.83), Rect2(-0.5, -0.25, 1.0, 0.5), others, 0.06, 0.05)
	_check(above.is_equal_approx(Vector2(0.5, 0.81)), "свободно: над соседом, середины в линию (%s)" % above)
	var far := WallLayout.snap_free(Vector2(3.3, 2.2), Rect2(-0.5, -0.25, 1.0, 0.5), others, 0.06, 0.05)
	_check(far == Vector2(3.3, 2.2), "свободно: далеко — без магнита")
	var cells := WallLayout.snap_free(Vector2(2.68, -0.75), Rect2(-0.5, -0.25, 1.0, 0.5), [] as Array[Rect2], 0.06, 0.05, WallLayout.pitch(0.06))
	_check(cells.is_equal_approx(Vector2(2.0 * WallLayout.pitch(0.06).x, -WallLayout.pitch(0.06).y)), "свободно: к середине клетки (%s)" % cells)

	# What a screen covers of the wall, for the magnet.
	var flat_on_column := WallLayout.footprint(on_column, reach, cell, 0.0, 0.0, 0.0)
	_check(flat_on_column.size.x < cell.x and is_equal_approx(flat_on_column.size.x, 2.0 * reach * atan(cell.x * 0.5 / reach)),
			"столб: плоский занимает дугу меньше ширины")
	_check(is_equal_approx(WallLayout.footprint(on_column, reach, cell, -1.0, 0.0, 0.0).size.x, cell.x), "столб: выпуклый как столб — во всю ширину")
	_check(WallLayout.footprint(upright, 1.5, cell, 0.0, 0.0, 0.0).size.x < cell.x + 0.0001, "вогнутая: плоский не шире себя")
	var on_flat_wall := WallLayout.footprint(flat, 1.5, cell, 0.0, 0.0, 0.0)
	_check(on_flat_wall.is_equal_approx(Rect2(-cell.x * 0.5, -cell.y * 0.5, cell.x, cell.y)), "плоская: во всю ширину и высоту")
	var turned := WallLayout.footprint(flat, 1.5, cell, 0.0, deg_to_rad(60.0), deg_to_rad(60.0))
	_check(is_equal_approx(turned.size.x, cell.x * 0.5) and is_equal_approx(turned.size.y, cell.y * 0.5), "повёрнутый и наклонённый — уже и ниже")
	# Edge to edge by what they cover: a flat one on a column snaps closer than its width.
	var neighbour := Rect2(flat_on_column.position, flat_on_column.size)
	var touching := WallLayout.snap_free(Vector2(flat_on_column.size.x + 0.05, 0.0), flat_on_column, [neighbour] as Array[Rect2], 0.06, 0.05)
	_check(is_equal_approx(touching.x, flat_on_column.size.x + 0.06), "столб: вплотную по занятой дуге")

	# Thinner than its cells: the same angles, a smaller circle.
	var thin := WallLayout.shape_of(grid, gap, 1.5, 1.0, true, 0.0, 0.5)
	_check(is_equal_approx(thin.radius(), column.radius() * 0.5) and is_equal_approx(thin.arc_radius(), column.arc_radius()), "тонкий столб: радиус меньше, клетки по тем же углам")
	var quarter := thin.middle + thin.arc_radius() * PI * 0.5
	_check(WallLayout.surface(quarter, 0.0, 0.0, thin).basis.z.is_equal_approx(Vector3.RIGHT), "тонкий столб: четверть круга — так же справа")
	var seen_thin := WallLayout.hit(Vector3(thin.middle + 0.1, 0.2, 0.0), Vector3.FORWARD, thin)
	var back_thin := WallLayout.project(WallLayout.surface(seen_thin.x, seen_thin.y, 0.0, thin).origin, thin)
	_check(absf(back_thin.x - seen_thin.x) < 0.0001 and absf(back_thin.z) < 0.0001, "тонкий столб: луч и точка сходятся")
	_check(WallLayout.shape_of(grid, gap, 1.5, 1.0, true, 0.0, 0.01).squeeze == WallLayout.MIN_SQUEEZE, "тонкий столб: не тоньше предела")

	# Cells taken away are forgotten.
	var remembered := WallLayout.Wall.new()
	remembered.splits = {"0,0": "c2", "0,3": "r2", "0,3:1": "c2", "B1": "c2"}
	remembered.blocks = {"B1": "1,3+2,3", "B2": "1,0+2,0"}
	remembered.parts = {"a": "0,3:0", "b": "0,0:1", "c": "B1:0"}
	var cut := WallLayout.pruned(remembered, Rect2i(0, 0, 3, 2))
	_check(cut.splits.keys() == ["0,0"] and cut.blocks.keys() == ["B2"] and cut.parts.keys() == ["b"], "убранные клетки забыты (%s, %s, %s)" % [cut.splits, cut.blocks, cut.parts])

	# The driver's list: 1920×1080 first (Windows takes the first when it sets up afresh).
	var listed: Array[Vector2i] = [Vector2i(960, 1080), Vector2i(1920, 544), Vector2i(1920, 1080), Vector2i(2560, 1440)]
	_check(VddConfig.ordered(listed) == ([Vector2i(1920, 1080), Vector2i(960, 1080), Vector2i(1920, 544), Vector2i(2560, 1440)] as Array[Vector2i]),
			"драйвер: 1920×1080 первым")

	# The pad: both values from one point.
	var both := VrPad.values_at(Vector2(0.5, 1.0), Vector2(-75.0, -75.0), Vector2(75.0, 75.0), Vector2(1.0, 1.0),
			VrSlider.notches_for(-75.0, 75.0, 15.0), VrSlider.notches_for(-75.0, 75.0, 15.0))
	_check(both == Vector2(0.0, 75.0), "площадка: середина по ширине, верх по высоте")

	# The fixture keeps its kind and tilt.
	var fixture := WorldLayout.new_fixture(WorldLayout.default_fixtures(PackedStringArray()), "column", Vector3.ZERO, 0.0)
	_check(fixture.name == "Столб 1" and fixture.bend == 1.0 and fixture.radius == WallLayout.DEFAULT_DISTANCE, "столб: новая заготовка — замкнутая")
	fixture.tilt = 0.3
	fixture.squeeze = 0.6
	var restored := WorldLayout.Fixture.from_dictionary(fixture.to_dictionary())
	_check(restored.kind == "column" and is_equal_approx(restored.tilt, 0.3) and is_equal_approx(restored.squeeze, 0.6), "столб: наклон и толщина сохраняются")


## Slice m: the network of places.
func _test_place_network() -> void:
	var points := {1: Vector3(0, 0, 0), 2: Vector3(1, 0, 0), 3: Vector3(5, 0, 0), 4: Vector3(5, 0, 1)}
	var auto := PlaceNetwork.auto_links(points, 1)
	_check(auto.has(Vector2i(1, 2)) and auto.has(Vector2i(3, 4)) and auto.size() == 2, "сеть: каждое место с ближайшим (%s)" % [auto])
	_check(PlaceNetwork.auto_links(points, 2).has(Vector2i(2, 3)), "сеть: по два ближайших — мостик между кучками")
	_check(PlaceNetwork.auto_links(points, 0).is_empty(), "сеть: связи с ближайшими выключены")
	var none: Array[Vector2i] = []
	var drawn := PlaceNetwork.toggled(1, 3, points, 1, none, none)
	_check((drawn["added"] as Array).has(Vector2i(1, 3)), "сеть: своя связь добавлена")
	var undrawn := PlaceNetwork.toggled(3, 1, points, 1, drawn["added"], drawn["removed"])
	_check((undrawn["added"] as Array).is_empty(), "сеть: своя связь убрана тем же жестом")
	var cut := PlaceNetwork.toggled(2, 1, points, 1, none, none)
	_check((cut["removed"] as Array).has(Vector2i(1, 2)), "сеть: автосвязь убрана")
	var all := PlaceNetwork.links(points, 1, drawn["added"], cut["removed"])
	_check(all.has(Vector2i(1, 3)) and all.has(Vector2i(3, 4)) and not all.has(Vector2i(1, 2)), "сеть: связи — авто без убранных и свои")
	var gone: Array[Vector2i] = [Vector2i(1, 9)]
	_check(not PlaceNetwork.links(points, 1, gone, none).has(Vector2i(1, 9)), "сеть: связь с пропавшим местом не считается")
	var frame := PlaceNetwork.map_frame([Vector3(-5, 0, 0), Vector3(5, 2, 0)], 0.6)
	_check((frame[0] as Vector3).is_equal_approx(Vector3(0, 1, 0)) and is_equal_approx(frame[1], 0.06), "сеть: карта вмещает мир")
	_check(is_equal_approx(PlaceNetwork.map_frame([Vector3.ZERO, Vector3(0.1, 0, 0)], 0.6)[1], 0.6), "сеть: маленький мир не раздувается")
	var bubble := PlaceNetwork.cloud([Vector3(0, 0, 0), Vector3(2, 0, 0)], 0.1)
	_check((bubble[0] as Vector3).is_equal_approx(Vector3(1, 0, 0)) and is_equal_approx(bubble[1], 1.1), "сеть: облако группы")
	var from := Transform3D(Basis.IDENTITY, Vector3.ZERO)
	var to := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(4, 0, 0))
	_check(PlaceNetwork.flight(from, to, 0.0).is_equal_approx(from) and PlaceNetwork.flight(from, to, 1.0).is_equal_approx(to), "сеть: перелёт — от и до")
	_check(PlaceNetwork.flight(from, to, 0.5).origin.is_equal_approx(Vector3(2, 0, 0)), "сеть: середина пути — посередине")
	_check(PlaceNetwork.links_from(PlaceNetwork.links_to([Vector2i(2, 5)] as Array[Vector2i])) == ([Vector2i(2, 5)] as Array[Vector2i]), "сеть: связи сохраняются")
	var fixture := WorldLayout.Fixture.new()
	fixture.group = 3
	fixture.placement = 2
	var stored := WorldLayout.Fixture.from_dictionary(fixture.to_dictionary())
	_check(stored.group == 3 and stored.placement == 2, "сеть: группа и расстановка заготовки сохраняются")


## The Windows layout by groups (one fixture = one group, slice n).
func _test_desktop_groups() -> void:
	var a: Array[Rect2i] = [Rect2i(100, 50, 1920, 1080), Rect2i(2020, 50, 1920, 1080)]
	var b: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080)]
	var na := DesktopGroups.normalized(a)
	_check(na[0].position == Vector2i.ZERO and na[1].position == Vector2i(1920, 0), "группы: группа с нуля")
	var placed := DesktopGroups.compose([na, DesktopGroups.normalized(b)], [1, 2], {})
	_check((placed[1] as Array)[0].position == Vector2i(3840, 0), "группы: по умолчанию друг за другом")
	var moved := DesktopGroups.compose([na, DesktopGroups.normalized(b)], [1, 2], {2: Vector2i(0, 1080)})
	_check((moved[1] as Array)[0].position == Vector2i(0, 1080) and (moved[0] as Array)[0].position == Vector2i(1920, 0),
			"группы: перетащенная на своём месте, остальные после неё")
	var others: Array[Rect2i] = [Rect2i(0, 0, 3840, 1080)]
	_check(DesktopGroups.snapped(Vector2i(3900, 40), Vector2i(1920, 1080), others, 288) == Vector2i(3840, 0), "группы: прилипает вплотную и в линию")
	_check(DesktopGroups.snapped(Vector2i(6000, 3000), Vector2i(1920, 1080), others, 288) == Vector2i(6000, 3000), "группы: далеко — не прилипает")
	_check(DesktopGroups.offsets_from(DesktopGroups.offsets_to({3: Vector2i(5, -7)})) == {3: Vector2i(5, -7)}, "группы: места сохраняются")
	# Dropped: never on another screen, touching one; screens stick corner to corner.
	var one: Array[Rect2i] = [Rect2i(0, 0, 3840, 1080)]
	var single: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080)]
	var off_it := DesktopGroups.placed(Vector2i(1000, 200), single, one, 288)
	_check(off_it == Vector2i(1000, 1080), "группы: на другую не ложится, съезжает к ближнему краю (%s)" % off_it)
	var corner := DesktopGroups.placed(Vector2i(1800, 1150), single, one, 288)
	_check(corner == Vector2i(1920, 1080), "группы: угол к углу (%s)" % corner)
	var far := DesktopGroups.placed(Vector2i(9000, 300), single, one, 288)
	_check(DesktopGroups.fits(DesktopGroups.shifted(single, far), one) and far.x == 3840, "группы: далёкая притягивается вплотную (%s)" % far)
	_check(not DesktopGroups.touches(Rect2i(3840, 1080, 100, 100), one[0]), "группы: только углом — не касание")
	# A group of two screens of different size: the corner is a screen's, not the frame's.
	var uneven: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(1920, 300, 2560, 1440)]
	var by_screen := DesktopGroups.placed(Vector2i(4400, 380), single, uneven, 288)
	_check(by_screen == Vector2i(4480, 300), "группы: угол к углу экрана, а не рамки группы (%s)" % by_screen)
	# Dropped on another group: that one moves aside, whole; the dropped one stays.
	var on_top := {1: [Rect2i(1000, 0, 1920, 1080)] as Array[Rect2i], 2: [Rect2i(1920, 0, 1920, 1080)] as Array[Rect2i]}
	var pushed := DesktopGroups.pushed(on_top, 1)
	_check((pushed[1] as Array)[0] == Rect2i(1000, 0, 1920, 1080), "группы: брошенная остаётся")
	_check((pushed[2] as Array)[0] == Rect2i(2920, 0, 1920, 1080), "группы: та, на которую бросили, отодвинута (%s)" % (pushed[2] as Array)[0])
	# Two rows of three: slightly on the row below, it goes above it, in line.
	var row: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 1920, 1080), Rect2i(3840, 0, 1920, 1080)]
	var above := DesktopGroups.placed(Vector2i(150, 80), row, DesktopGroups.shifted(row, Vector2i(0, 1080)), 288)
	_check(above == Vector2i(0, 0), "группы: ряд над рядом ровно (%s)" % above)
	_check(DesktopGroups.covered(DesktopGroups.shifted(row, Vector2i(150, 80)), DesktopGroups.shifted(row, Vector2i(0, 1080))) < 0.5, "группы: случайное перекрытие — не половина")
	_check(DesktopGroups.covered(single, [Rect2i(0, 0, 3840, 1080)] as Array[Rect2i]) == 1.0, "группы: маленькая целиком на большой — перекрыта")
	# Joined: touching ones stay, a group cut off moves whole to touch the rest.
	var groups := {1: [Rect2i(0, 0, 1920, 1080)] as Array[Rect2i], 2: [Rect2i(1920, 0, 1920, 1080)] as Array[Rect2i],
			3: [Rect2i(9000, 5000, 1920, 1080), Rect2i(10920, 5000, 1920, 1080)] as Array[Rect2i]}
	var joined := DesktopGroups.joined(groups, 1)
	_check(joined[1] == groups[1] and joined[2] == groups[2], "группы: касающиеся остаются")
	var two_boxes: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 1920, 1080)]
	var cut_off: Array[Rect2i] = joined[3]
	_check(DesktopGroups.fits(cut_off, two_boxes) and cut_off[1].position - cut_off[0].position == Vector2i(1920, 0), "группы: оторванная приставлена целиком (%s)" % [cut_off])


func _test_world_edit() -> void:
	# The grip turns with the ray about the vertical only.
	var ahead := WorldEdit.grip(Vector3.ZERO, Vector3(0.0, 0.0, -1.0), 2.0)
	_check(ahead.origin.is_equal_approx(Vector3(0.0, 0.0, -2.0)) and absf(WorldEdit.yaw_of(ahead.basis)) < 0.0001, "редактор мира: хват впереди")
	var tipped := WorldEdit.grip(Vector3.ZERO, Vector3(0.0, -0.6, -0.8), 1.0)
	_check(tipped.basis.y.is_equal_approx(Vector3.UP), "редактор мира: наклон луча не наклоняет")
	# Carried: the ray turns 90° left — the fixture goes round with it and turns too.
	var start := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, -3.0))
	var left := WorldEdit.grip(Vector3.ZERO, Vector3(-1.0, 0.0, 0.0), 2.0)
	var moved := WorldEdit.carried(start, ahead, left)
	_check(moved.origin.is_equal_approx(Vector3(-3.0, 1.5, 0.0)), "редактор мира: заготовка идёт за лучом (%s)" % moved.origin)
	_check(is_equal_approx(WorldEdit.yaw_of(moved.basis), PI / 2.0), "редактор мира: и поворачивается с ним")
	# On the grid: a wall's front middle on the step, its turn in 15° steps.
	var anchor := WorldEdit.anchor_of("wall", 2.0)
	var frame := Transform3D(Basis(Vector3.UP, deg_to_rad(17.0)), Vector3(0.12, 1.43, 0.07))
	var snapped := WorldEdit.on_grid(frame, anchor, 0.25, deg_to_rad(15.0))
	var front := snapped * anchor
	_check(is_equal_approx(WorldEdit.yaw_of(snapped.basis), deg_to_rad(15.0)), "редактор мира: поворот по 15°")
	_check(front.is_equal_approx(front.snapped(Vector3.ONE * 0.25)), "редактор мира: лицо стены на сетке (%s)" % front)
	_check(WorldEdit.anchor_of("sphere", 1.5) == Vector3.ZERO, "редактор мира: у шара на сетке центр")
	var free := WorldEdit.on_grid(frame, anchor, 0.0, 0.0)
	_check(free.origin.is_equal_approx(frame.origin), "редактор мира: шаг 0 — свободно")
	# A new one: faces along the ray, its seat on the user's side.
	var fresh := WorldEdit.new_frame(ahead, anchor)
	_check(fresh.origin.is_equal_approx(Vector3.ZERO) and (fresh * anchor).is_equal_approx(ahead.origin), "редактор мира: новая стена лицом к тебе")
	# The ray and a sphere's shell: from outside the near side, from inside where it leaves.
	_check(is_equal_approx(WorldEdit.sphere_hit(Vector3(0.0, 0.0, 5.0), Vector3(0.0, 0.0, -1.0), Vector3.ZERO, 1.0), 4.0), "редактор мира: шар снаружи")
	_check(is_equal_approx(WorldEdit.sphere_hit(Vector3.ZERO, Vector3(1.0, 0.0, 0.0), Vector3.ZERO, 1.5), 1.5), "редактор мира: шар изнутри")
	_check(WorldEdit.sphere_hit(Vector3(0.0, 3.0, 5.0), Vector3(0.0, 0.0, -1.0), Vector3.ZERO, 1.0) == INF, "редактор мира: мимо шара")
	# The shelf: the nearest slot within reach.
	var slots := PackedVector3Array([Vector3(0.0, 0.0, 0.0), Vector3(0.15, 0.0, 0.0)])
	_check(WorldEdit.slot_at(Vector3(0.12, 0.02, 0.0), slots, 0.08) == 1 and WorldEdit.slot_at(Vector3(0.5, 0.0, 0.0), slots, 0.08) == -1, "редактор мира: полочка")
	_check(WorldEdit.next_world_name(["Мир 1", "Мир 3"]) == "Мир 2" and WorldEdit.next_world_name([]) == "Мир 1", "миры: имя нового")


func _test_link_protocol() -> void:
	_check(LinkProtocol.ask_version(LinkProtocol.ask_packet()) == LinkProtocol.VERSION, "протокол: вопрос узнаётся")
	_check(LinkProtocol.ask_version("hello".to_utf8_buffer()) == -1, "протокол: чужой пакет — не вопрос")
	_check(LinkProtocol.ask_version(PackedByteArray()) == -1, "протокол: пустой пакет — не вопрос")
	var answer := LinkProtocol.parse_answer(LinkProtocol.answer_packet("DESK|1", 47802))
	_check(answer.get("pc") == "DESK|1" and answer.get("port") == 47802 and answer.get("version") == LinkProtocol.VERSION,
			"протокол: ответ ПК разбирается, имя с разделителем цело")
	_check(LinkProtocol.parse_answer(LinkProtocol.ask_packet()).is_empty(), "протокол: вопрос — не ответ")
	_check(LinkProtocol.parse_answer("WoRkPlace!|1|0|PC".to_utf8_buffer()).is_empty(), "протокол: порт 0 отвергнут")
	_check(LinkProtocol.parse_answer("WoRkPlace!|1|x|PC".to_utf8_buffer()).is_empty(), "протокол: порт не число")
	var monitor := LinkProtocol.monitor("MTT1337#1", "\\\\.\\DISPLAY3", Vector2i(-1920, 0), Vector2i(1920, 1080), true)
	var welcome := LinkProtocol.welcome("DESK", [monitor])
	_check(LinkProtocol.problem(welcome) == "", "протокол: приветствие ПК правильное")
	# What PacketPeerStream does to it on the way.
	_check(LinkProtocol.problem(bytes_to_var(var_to_bytes(welcome))) == "", "протокол: приветствие переживает передачу")
	_check(LinkProtocol.problem(LinkProtocol.hello("Quest 3S")) == "", "протокол: привет шлема правильный")
	_check(LinkProtocol.problem(LinkProtocol.ping(1.5)) == "" and LinkProtocol.problem(LinkProtocol.pong(1.5)) == "",
			"протокол: пинг и понг правильные")
	_check(LinkProtocol.problem({"t": "hello", "v": 99, "device": "x"}) != "", "протокол: чужая версия отвергнута")
	_check(LinkProtocol.problem({"t": "welcome", "v": LinkProtocol.VERSION, "pc": "x"}) != "", "протокол: без мониторов отвергнуто")
	_check(LinkProtocol.problem({"t": "jump"}) != "", "протокол: неизвестный тип отвергнут")
	_check(LinkProtocol.problem([1, 2]) != "", "протокол: не словарь отвергнут")
	_check(LinkProtocol.problem(LinkProtocol.monitors_message([{"w": 0, "h": 10}])) != "", "протокол: монитор нулевой ширины отвергнут")
	_check(LinkProtocol.problem(LinkProtocol.monitors_message([])) == "", "протокол: пустой список мониторов допустим")
	var videos: Dictionary = bytes_to_var(var_to_bytes(LinkProtocol.videos_message(
			[LinkProtocol.video(LinkProtocol.VIDEO_PORT, "MTT1337#1", Vector2i(1920, 1080))])))
	_check(LinkProtocol.problem(videos) == "" and videos["videos"][0]["port"] == LinkProtocol.VIDEO_PORT,
			"протокол: список видео правильный")
	_check(LinkProtocol.problem(LinkProtocol.videos_message([{"port": 1, "key": "x"}])) != "", "протокол: видео без размера отвергнуто")
	_check(LinkProtocol.problem(LinkProtocol.videos_message([])) == "", "протокол: пустой список видео допустим")
	_check(LinkProtocol.problem(bytes_to_var(var_to_bytes(LinkProtocol.pointer("MTT1337#1", Vector2i(10, 20))))) == "",
			"протокол: курсор правильный")
	_check(LinkProtocol.problem({"t": "pointer", "key": "x", "x": 1.5, "y": 2}) != "", "протокол: курсор не в целых пикселях отвергнут")
	_check(LinkProtocol.problem(LinkProtocol.button(1, true)) == "", "протокол: кнопка правильная")
	_check(LinkProtocol.problem(LinkProtocol.button(5, true)) != "", "протокол: неизвестная кнопка отвергнута")
	_check(LinkProtocol.problem(LinkProtocol.wheel(120, -240)) == "", "протокол: колесо правильное")
	_check(HeadsetOptions.link_mode_name(HeadsetOptions.LINK_CABLE) == "только кабель" and HeadsetOptions.new().live_screens == 6,
			"шлем: настройки связи и живых экранов по умолчанию")
	_check(LinkProtocol.problem(bytes_to_var(var_to_bytes(LinkProtocol.call_message("topology", "arrange", [{"a": Vector2i(1, 2)}])))) == "",
			"протокол: вызов раскладки правильный")
	_check(LinkProtocol.problem(LinkProtocol.call_message("topology", "restore_layout_now")) != "",
			"протокол: действие вне списка отвергнуто")
	_check(LinkProtocol.problem(LinkProtocol.call_message("os", "execute")) != "", "протокол: чужая цель отвергнута")
	_check(LinkProtocol.problem(LinkProtocol.call_message("thumbs", "start")) == ""
			and LinkProtocol.problem(LinkProtocol.thumb("MTT1337#1", PackedByteArray([1]))) == "", "протокол: миниатюры")
	_check(LinkProtocol.problem({"t": "call", "target": "vdd", "op": "apply", "args": 3}) != "", "протокол: аргументы не списком отвергнуты")
	_check(LinkProtocol.problem(LinkProtocol.event("topology", "finished", [true, "arranged", ""])) == "", "протокол: событие правильное")
	_check(LinkProtocol.problem(LinkProtocol.pc_state(true, false, true)) == "", "протокол: состояние ПК правильное")
	_check(LinkProtocol.problem(LinkProtocol.secure_frame(PackedByteArray([1, 2]), Vector2i.ZERO, Vector2i(10, 10))) == "",
			"протокол: кадр защищённого стола правильный")
	_check(LinkProtocol.problem(LinkProtocol.settings_message("[ray]
x=1
")) == "" and LinkProtocol.problem({"t": "settings", "text": 5}) != "",
			"протокол: настройки — текст")
	_check(LinkProtocol.problem(bytes_to_var(var_to_bytes(LinkProtocol.keys([17, 90])))) == "", "протокол: сочетание правильное")
	_check(LinkProtocol.problem(LinkProtocol.keys([])) != "" and LinkProtocol.problem(LinkProtocol.keys([17, 999])) != "",
			"протокол: пустое сочетание и чужая клавиша отвергнуты")
	_check(LinkProtocol.problem(LinkProtocol.key(17, true)) == "" and LinkProtocol.problem({"t": "key", "vk": 0, "down": true}) != "",
			"протокол: клавиша правильная, нулевая отвергнута")
	# The headset takes src/ through tools/sync_headset.ps1; its stand-ins for the
	# PC module's classes live in headset/src/pc.
	for stand_in: String in ["mouse_input", "screen_capture", "global_hotkey", "secure_desktop", "display_topology", "vdd_control"]:
		_check(FileAccess.file_exists("res://headset/src/pc/%s.gd" % stand_in), "шлем: подмена %s есть" % stand_in)
