extends SceneTree
## Where does MouseInput.move_to() really put the cursor? Moves it to the middle
## and near the corners of every monitor and reads it back. Run it after changing
## a monitor's Windows scale to see whether the cursor drifts from the ray:
##   godot --xr-mode off --path . -s tests/cursor_probe.gd
## Moves the real mouse cursor for a moment.


func _initialize() -> void:
	var start := MouseInput.get_position()
	var worst := 0
	for monitor: Dictionary in ScreenCapture.list_monitors():
		var rect := Rect2i(monitor["position"], monitor["size"])
		for share: Vector2 in [Vector2(0.5, 0.5), Vector2(0.1, 0.1), Vector2(0.9, 0.9)]:
			var target := rect.position + Vector2i(Vector2(rect.size) * share)
			MouseInput.move_to(target)
			OS.delay_msec(30)
			var got := MouseInput.get_position()
			var miss := (got - target).abs()
			worst = maxi(worst, maxi(miss.x, miss.y))
			if miss.x > 1 or miss.y > 1:
				print("cursor_probe: %s: хотел %s, получил %s" % [monitor["name"], target, got])
	MouseInput.move_to(start)
	print("cursor_probe: наибольший промах %d px" % worst)
	quit(0 if worst <= 1 else 1)
