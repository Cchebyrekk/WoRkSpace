extends SceneTree
## Probe: streams a monitor (WORKPLACE_PROBE_MONITOR, default the last one, an idle
## one) to a TCP reader for 5 s and reports the encoder's input-to-output time. On
## a still desktop only the once-a-second refresh is encoded; ~1000 ms here means
## the encoder holds each frame until the next one arrives.

var _streamer := ScreenStreamer.new()
var _tcp := StreamPeerTCP.new()
var _end := 0.0
var _samples: Array[float] = []
var _next_sample := 0.0


func _initialize() -> void:
	var monitors := ScreenCapture.list_monitors()
	var index := int(OS.get_environment("WORKPLACE_PROBE_MONITOR")) if OS.get_environment("WORKPLACE_PROBE_MONITOR") != "" else monitors.size() - 1
	if not _streamer.start(index, 47890, 12000, 60):
		print("[probe] не запустилось: ", _streamer.get_last_error())
		quit(1)
		return
	print("[probe] монитор %s" % monitors[index]["name"])
	_tcp.connect_to_host("127.0.0.1", 47890)
	_end = Time.get_ticks_msec() / 1000.0 + 5.0


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	_tcp.poll()
	if _tcp.get_available_bytes() > 0:
		_tcp.get_data(_tcp.get_available_bytes())
	if now >= _next_sample:
		_next_sample = now + 0.5
		_samples.append(_streamer.get_stats()["encode_ms"])
	if now > _end:
		var stats := _streamer.get_stats()
		print("[probe] снято %d, закодировано %d, кодирование (по замерам) %s мс" % [stats["frames_captured"], stats["frames_encoded"], str(_samples)])
		_streamer.stop()
		return true
	return false
