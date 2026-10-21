extends SceneTree
## Checks the input path through workplace_agent.exe without VR: moves the cursor
## to a few points through MouseInput and reads it back, then puts it where it was.
## Start the agent first (bin/workplace_agent.exe --agent --allow <this Godot>) and set
## WORKPLACE_AGENT_ANY_OWNER=1: a pipe the user created is otherwise refused.
##   & "<godot>" --headless --xr-mode off --path . -s tests/agent_probe.gd


func _initialize() -> void:
	var start := MouseInput.get_position()
	print("[agent] подключён: ", MouseInput.is_agent_connected())
	var misses := 0
	for target: Vector2i in [Vector2i(200, 300), Vector2i(-1700, 500), Vector2i(2500, 700)]:
		MouseInput.move_to(target)
		OS.delay_msec(100)
		var got := MouseInput.get_position()
		print("[agent] курсор в %s, хотел %s" % [got, target])
		if got != target:
			misses += 1
	MouseInput.move_to(start)
	print("[agent] промахов: %d, агент: %s" % [misses, MouseInput.is_agent_connected()])
	quit(misses)
