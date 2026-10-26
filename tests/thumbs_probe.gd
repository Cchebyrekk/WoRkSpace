extends SceneTree
## Probe for slice o5c: plays the headset against a running link server, asks
## for thumbnails for 4 s and counts the pictures per monitor and their size.

var _link: RefCounted
var _end := 0.0
var _asked := false
var _counts := {}
var _size := Vector2i.ZERO
var _bytes := 0


func _initialize() -> void:
	_link = load("res://headset/src/headset_link.gd").new("проба миниатюр")
	_end = Time.get_ticks_msec() / 1000.0 + 8.0


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	_link.poll(now)
	if not _asked and _link.pc_name != "" and not _link.monitors.is_empty():
		_asked = true
		_end = now + 4.0
		_link.send(LinkProtocol.call_message("thumbs", "start"))
	for message: Dictionary in _link.inbox:
		if message["t"] == "thumb":
			_counts[message["key"]] = _counts.get(message["key"], 0) + 1
			_bytes += message["jpg"].size()
			var image := Image.new()
			if image.load_jpg_from_buffer(message["jpg"]) == OK:
				_size = image.get_size()
	_link.inbox.clear()
	if now > _end:
		var total := 0
		for key: String in _counts:
			total += _counts[key]
		print("[probe] миниатюр %d по %d мониторам за 4 с, размер %s, в среднем %d байт" % [total, _counts.size(), _size,
				_bytes / maxi(total, 1)])
		_link.close()
		return true
	return false
