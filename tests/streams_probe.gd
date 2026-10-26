extends SceneTree
## Probe for slice o4: starts a stream for every monitor at once (one hardware
## encoder session each) and reports which ones the GPU refused.


func _initialize() -> void:
	var streamers: Array[ScreenStreamer] = []
	var monitors := ScreenCapture.list_monitors()
	for i in monitors.size():
		var streamer := ScreenStreamer.new()
		if streamer.start(i, 47803 + i, 12000, 60):
			streamers.append(streamer)
			print("[probe] %s: запущен" % monitors[i]["name"])
		else:
			print("[probe] %s: отказ — %s" % [monitors[i]["name"], streamer.get_last_error()])
	print("[probe] потоков %d из %d" % [streamers.size(), monitors.size()])
	for streamer in streamers:
		streamer.stop()
	quit()
