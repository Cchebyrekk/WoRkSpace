extends SceneTree
## Loads the scripts given after "--" and says whether each parses.

func _init() -> void:
	for path in OS.get_cmdline_user_args():
		var script := load(path) as GDScript
		print("[parse] %s: %s" % [path, "да" if script != null and script.can_instantiate() else "ОШИБКА"])
	quit()
