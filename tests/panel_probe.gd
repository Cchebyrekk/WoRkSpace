extends SceneTree
## Smoke test of a real ScreenPanel without the headset: flat and curved, leaning,
## hits, grips. Composition layers need OpenXR to be seen, but are created and
## placed all the same:
##   godot --xr-mode off --path . -s tests/panel_probe.gd

var _failures := 0


func _initialize() -> void:
	var origin := XROrigin3D.new()
	root.add_child(origin)
	var monitors := ScreenCapture.list_monitors()
	var panel := ScreenPanel.create(0, monitors[0], origin, true)
	if panel == null:
		_fail("панель не создалась")
		quit(1)
		return
	root.add_child(panel)
	panel.distance = 1.1
	var eye := Vector3(0.0, 1.45, 0.0)
	var placements := PanelLayout.arrange([panel.monitor_rect] as Array[Rect2i], 0, eye, 1.1, 60.0, 300.0)

	panel.place(placements[0])
	_check(panel.layer is OpenXRCompositionLayerQuad, "плоская панель — квадратный слой")
	var hit := panel.hit_distance(eye, Vector3.FORWARD)
	_check(is_equal_approx(hit, 1.1), "плоская: луч из глаза попадает на 1.1 м (%.3f)" % hit)
	_check(panel.uv_at(eye + Vector3.FORWARD * hit).is_equal_approx(Vector2(0.5, 0.5)), "плоская: середина")

	var curved := PanelLayout.placement_at(0.0, 0.0, placements[0].size, eye, 1.1, NAN, 0.8)
	panel.place(curved)
	_check(panel.layer is OpenXRCompositionLayerCylinder, "изогнутая панель — цилиндрический слой")
	# The picture has to reach the new layer (on 16.10.2026 it stayed with the old one: blank).
	_check(panel.layer.layer_viewport != null, "изогнутая панель получила картинку")
	hit = panel.hit_distance(eye, Vector3.FORWARD)
	_check(is_equal_approx(hit, 1.1), "изогнутая: середина на прежнем месте (%.3f)" % hit)
	var aside := panel.hit_distance(eye, Vector3(sin(0.4), 0.0, -cos(0.4)))
	_check(aside > 0.0 and aside < 1.1 / cos(0.4), "изогнутая: край ближе, чем у плоской")
	var uv := panel.uv_at(eye + Vector3(sin(0.4), 0.0, -cos(0.4)) * aside)
	_check(uv.x > 0.5 and uv.x < 1.0 and is_equal_approx(uv.y, 0.5), "изогнутая: u справа от середины (%s)" % uv)

	var leaning := PanelLayout.placement_at(0.0, 0.0, placements[0].size, eye, 1.1, deg_to_rad(20.0), 0.0)
	panel.place(leaning)
	_check(panel.layer is OpenXRCompositionLayerQuad, "обратно плоская — снова квадратный слой")
	_check(panel.layer.layer_viewport != null, "обратно плоская получила картинку")
	_check(panel.hit_distance(eye, Vector3.FORWARD) > 0.0, "наклонённая: луч попадает")

	var below := Vector3(0.0, -placements[0].size.y * 0.5 - ScreenPanel.GRIP_DROP, 0.0)
	panel.place(placements[0])
	var grip_point := placements[0].transform * below
	var grip := panel.grip_at(eye, (grip_point - eye).normalized(), [ScreenPanel.Grip.MOVE, ScreenPanel.Grip.TILT])
	_check(int(grip.x) == ScreenPanel.Grip.MOVE, "ручка переноса под серединой")
	grip = panel.grip_at(eye, (grip_point - eye).normalized(), [ScreenPanel.Grip.TILT])
	_check(int(grip.x) == ScreenPanel.Grip.NONE, "запрещённая ручка не ловится")
	# Bent the other way (slice l): a mesh with the viewport's picture, the layer
	# empty and without a hole; hit from the front, not from behind.
	var convex := PanelLayout.placement_at(0.0, 0.0, placements[0].size, eye, 1.1, NAN, -0.8)
	panel.place(convex)
	panel.update_back(eye, true)
	_check(panel.layer is OpenXRCompositionLayerQuad and panel.layer.layer_viewport == null, "выпуклая: слой пустой")
	_check(not panel.layer.enable_hole_punch, "выпуклая: без дыры в сцене")
	var surface := panel._surface
	_check(surface.visible and surface.mesh != null and surface.transform.is_equal_approx(convex.transform), "выпуклая: сетка с картинкой на месте")
	var arrays := (surface.mesh as ArrayMesh).surface_get_arrays(0)
	_check(arrays[Mesh.ARRAY_TEX_UV] != null and (arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size() == (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(),
			"выпуклая: у сетки есть координаты картинки")
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	_check(verts[0].x < 0.0 and verts[0].z < 0.0, "выпуклая: левый край уходит назад")
	hit = panel.hit_distance(eye, Vector3.FORWARD)
	_check(is_equal_approx(hit, 1.1), "выпуклая: середина на месте (%.3f)" % hit)
	var side := panel.hit_distance(eye, Vector3(sin(0.2), 0.0, -cos(0.2)))
	_check(side > 1.1 / cos(0.2), "выпуклая: край дальше, чем у плоской")
	_check(panel.uv_at(eye + Vector3(sin(0.2), 0.0, -cos(0.2)) * side).x > 0.5, "выпуклая: u справа от середины")
	_check(panel.hit_distance(eye + Vector3.FORWARD * 3.0, Vector3.BACK) < 0.0, "выпуклая: сзади не ловится")
	panel.place(placements[0])
	_check(panel.layer is OpenXRCompositionLayerQuad and panel.layer.layer_viewport != null and not panel._surface.visible,
			"снова плоская: картинка в слое")

	panel.show_grips(true, [ScreenPanel.Grip.MOVE], ScreenPanel.Grip.MOVE, ScreenPanel.Grip.NONE)
	panel.close()

	# The monitor menu: stepping through modes and scales, and what "Применить" sends.
	var menu := MonitorMenu.new()
	root.add_child(menu)
	var sent := []
	menu.apply_requested.connect(func(monitor_name: String, mode: String, scale: int) -> void: sent.append([monitor_name, mode, scale]))
	menu.show_loading("\\\\.\\DISPLAY9")
	menu.set_modes({"name": "\\\\.\\DISPLAY9", "width": 1920, "height": 1080, "refresh": 120, "scale": 100,
			"modes": ["1920x1080@120", "1920x1080@60", "2560x1440@120", "2560x1440@60"], "scales": [100, 125, 150]})
	menu._step(0, 1)  # 2560x1440, keeps 120 Hz
	menu._step(1, -1)  # 60 Hz
	menu._step(2, 1)  # 125 %
	menu._on_apply()
	_check(sent == [["\\\\.\\DISPLAY9", "2560x1440@60", 125]], "меню экрана: отправлено %s" % [sent])
	menu.set_modes({"name": "\\\\.\\DISPLAY9", "width": 1920, "height": 1080, "refresh": 120, "scale": 100,
			"modes": ["1920x1080@120"], "scales": [100]})
	sent.clear()
	menu._on_apply()
	_check(sent == [["\\\\.\\DISPLAY9", "", 0]], "меню экрана: без изменений ничего не меняется")
	_check(menu.hit_distance(Vector3(0, 0, 1), Vector3.FORWARD) > 0.0, "меню экрана: луч по меню ловится")
	menu.visible = false
	_check(menu.hit_distance(Vector3(0, 0, 1), Vector3.FORWARD) < 0.0, "меню экрана: скрытое не ловит луч")

	for monitor: Dictionary in ScreenCapture.list_monitors():
		print("panel_probe: %s -> %s" % [monitor["name"], monitor.get("path", "")])
		_check(str(monitor.get("path", "")).begins_with("\\\\?\\DISPLAY#"), "у монитора есть путь устройства")

	var driver := VddConfig.read()
	print("panel_probe: разрешения драйвера сейчас ", driver)
	_check(driver.size() >= 1, "настройки драйвера читаются")
	print("panel_probe: %s" % ("всё в порядке" if _failures == 0 else "%d провалов" % _failures))
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, what: String) -> void:
	if not condition:
		_fail(what)


func _fail(what: String) -> void:
	_failures += 1
	printerr("panel_probe: ПРОВАЛ: ", what)
