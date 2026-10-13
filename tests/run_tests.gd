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
	_check(result.press and result.position == Vector2(300.0, 300.0) and filter.last_press_snapped, "двойной щелчок: второе нажатие прилипает к первому")
	filter.update(Vector2(325.0, 300.0), true, false, 0.55)
	# Too late or too far away is a separate click.
	filter.update(Vector2(310.0, 305.0), true, false, 1.3)
	filter.update(Vector2(310.0, 305.0), true, false, 1.4)
	result = filter.update(Vector2(310.0, 305.0), true, true, 1.5)
	_check(result.position == Vector2(310.0, 305.0) and not filter.last_press_snapped, "нажатие через секунду — отдельный щелчок")
	filter.update(Vector2(310.0, 305.0), true, false, 1.55)
	filter.update(Vector2(900.0, 500.0), true, false, 1.6)
	filter.update(Vector2(900.0, 500.0), true, false, 1.7)
	result = filter.update(Vector2(900.0, 500.0), true, true, 1.8)
	_check(result.position == Vector2(900.0, 500.0) and not filter.last_press_snapped, "нажатие далеко от предыдущего — отдельный щелчок")

	_check(is_equal_approx(PointerMath.pinch_stability(0.05, 0.04, 0.018), 0.0), "пальцы разведены — луч не притормаживается")
	_check(is_equal_approx(PointerMath.pinch_stability(0.018, 0.04, 0.018), 1.0), "пальцы сведены — полное успокоение")
	_check(is_equal_approx(PointerMath.pinch_stability(0.029, 0.04, 0.018), 0.5), "на полпути — половина")

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

	_check(PointerMath.smooth_direction(Vector3.ZERO, Vector3.UP, 0.01, 0.05).is_equal_approx(Vector3.UP), "первый кадр — без сглаживания")
	_check(PointerMath.smooth_direction(Vector3.FORWARD, Vector3.UP, 0.01, 0.0).is_equal_approx(Vector3.UP), "сглаживание выключено")
	var smoothed := PointerMath.smooth_direction(Vector3.FORWARD, Vector3.UP, 0.01, 0.05)
	_check(smoothed.y > 0.0 and smoothed.z < 0.0 and smoothed.y < absf(smoothed.z), "один кадр — небольшой шаг к цели")
	var settled := Vector3.FORWARD
	for i in 60:
		settled = PointerMath.smooth_direction(settled, Vector3.UP, 0.011, 0.05)
	_check(settled.distance_to(Vector3.UP) < 0.001, "за 60 кадров сходится к цели")
