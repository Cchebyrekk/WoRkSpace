extends SceneTree
## Without the headset: the main scene with a wall resolution «Разрешение по
## клетке» wants and the driver lacks; prints the «Драйвер» tab's chips. Changes
## nothing in the system (reads the driver's settings file only).
##   & "<godot>" --headless --xr-mode off --path . -s tests/driver_chips_probe.gd


func _init() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 10:
		await process_frame
	main._wall_needed_resolutions = [Vector2i(1920, 496)] as Array[Vector2i]
	main._refresh_driver_section()
	_show(main, "after a wall asked")
	main._refresh_driver_section(true)
	_show(main, "after the tab opened")
	quit()


func _show(main: Node, when: String) -> void:
	var texts := PackedStringArray()
	for size: Vector2i in main._driver_chips:
		var chip: VrButton = main._driver_chips[size]
		texts.append("%s%s" % [chip._label.text, "" if chip.is_inside_tree() else " (not in tree)"])
	print("[probe] %s: tab %s, chips %d: %s" % [when, main._driver_tab, texts.size(), ", ".join(texts)])
	print("[probe] selected %s, marked %s" % [main._driver_selected, main._wall_marked])
