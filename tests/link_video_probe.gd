extends SceneTree
## Probe for slice o4: plays a headset that also opens every video stream (and
## reads it, discarding), then quits without saying goodbye after 6 s, as a
## killed headset app does. Run it twice: the second run shows the server lived.

var _link: RefCounted
var _streams: Array[StreamPeerTCP] = []
var _bytes := 0
var _end := 0.0


func _initialize() -> void:
	_link = load("res://headset/src/headset_link.gd").new("проба видео")
	_end = Time.get_ticks_msec() / 1000.0 + 6.0


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	_link.poll(now)
	if _link.videos_changed:
		_link.videos_changed = false
		for video: Dictionary in _link.videos:
			var stream := StreamPeerTCP.new()
			stream.connect_to_host(_link.pc_address, video["port"])
			_streams.append(stream)
		print("[probe] ПК %s, открыл видео: %d" % [_link.pc_name, _streams.size()])
	for stream in _streams:
		stream.poll()
		var available := stream.get_available_bytes()
		if available > 0:
			_bytes += available
			stream.get_data(available)
	if now > _end:
		print("[probe] принято %.1f МБ, ухожу не прощаясь" % (_bytes / 1e6))
		return true
	return false
