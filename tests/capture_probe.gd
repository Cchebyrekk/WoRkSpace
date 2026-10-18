extends SceneTree
## Desktop smoke test for the native capture path, without VR. Opens a window for
## a few seconds, shows the primary monitor in it and checks that frames arrive
## and that the picture is not black:
##   godot --xr-mode off --path . -s tests/capture_probe.gd

const DURATION_SEC := 3.0

var _capture: ScreenCapture
var _elapsed := 0.0
var _next_report := 0.5


func _initialize() -> void:
	var monitors := ScreenCapture.list_monitors()
	print("probe: мониторы ", monitors)
	var monitor_index := 0
	for i in monitors.size():
		if monitors[i]["primary"]:
			monitor_index = i

	# Mouse injection round trip: "moving" the cursor to where it already is must
	# leave it there, which checks the pixel-to-SendInput mapping without disturbing the user.
	var before := MouseInput.get_position()
	MouseInput.move_to(before)
	var after := MouseInput.get_position()
	if (after - before).abs().x > 1 or (after - before).abs().y > 1:
		printerr("probe: ПРОВАЛ, курсор сместился: %s -> %s" % [before, after])
		quit(1)
		return
	print("probe: курсор на месте после move_to(%s): %s" % [before, after])

	_capture = ScreenCapture.new()
	if not _capture.start(monitor_index):
		printerr("probe: ПРОВАЛ, захват не запустился: ", _capture.get_last_error())
		quit(1)
		return
	print("probe: захват запущен, ", _capture.get_size())

	var picture := TextureRect.new()
	picture.texture = _capture.get_texture()
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_SCALE
	picture.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(picture)


func _process(delta: float) -> bool:
	if _capture == null or not _capture.is_running():
		return true
	_capture.update()
	_elapsed += delta
	if _elapsed >= _next_report:
		_next_report += 0.5
		print("probe: %.1f с, кадров %d" % [_elapsed, _capture.get_frame_count()])
	if _elapsed < DURATION_SEC:
		return false

	var frames := _capture.get_frame_count()
	var image := root.get_texture().get_image()
	# Optional: WORKPLACE_PROBE_SHOT=<path.png> saves a small copy of the window for inspection.
	var shot_path := OS.get_environment("WORKPLACE_PROBE_SHOT")
	if shot_path != "":
		var shot := image.duplicate() as Image
		shot.resize(640, 360, Image.INTERPOLATE_BILINEAR)
		shot.save_png(shot_path)
	image.resize(16, 16, Image.INTERPOLATE_BILINEAR)
	var brightness := 0.0
	for y in 16:
		for x in 16:
			brightness += image.get_pixel(x, y).get_luminance()
	brightness /= 256.0
	print("probe: всего кадров %d, средняя яркость окна %.3f" % [frames, brightness])
	_capture.stop()
	# Pure white is what a texture Godot failed to bind looks like.
	if frames == 0 or brightness < 0.01 or brightness > 0.99:
		printerr("probe: ПРОВАЛ (нет кадров, чёрная или сплошь белая картинка)")
		quit(1)
	else:
		print("probe: OK")
		quit(0)
	return true
