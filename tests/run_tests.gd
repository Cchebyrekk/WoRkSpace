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
	_test_cursor_filter()
	_test_aim_study()
	_test_panel_layout()
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
	_check(is_equal_approx(placed[1].heading, deg_to_rad(30.0)), "сдвиг на пол-экрана — сдвиг на половину угла")
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

	# A primary at the edge of a row that fits stays straight ahead.
	var five: Array[Rect2i] = []
	for i in 5:
		five.append(Rect2i(i * 1920, 0, 1920, 1080))
	placed = PanelLayout.arrange(five, 2, eye, distance, 60.0, 300.0)
	_check(is_zero_approx(placed[2].heading) and is_equal_approx(placed[4].heading, deg_to_rad(120.0)), "пять в ряд: основной по центру, масштаб не меняется")
	_check(PanelLayout.arrange([] as Array[Rect2i], 0, eye, distance, 60.0, 300.0).is_empty(), "нет мониторов — нет панелей")


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
