extends SceneTree
## Probe for slice o3: streams monitor 0 with ScreenStreamer, reads the stream
## back over TCP like the headset does for 4 s, and checks its shape: the header,
## a key frame first, sequence parameters in it, frames keep coming.

const PORT := 47803
var _streamer: ScreenStreamer
var _tcp := StreamPeerTCP.new()
var _buffer := PackedByteArray()
var _end := 0.0
var _header_seen := false
var _frames := 0
var _keys := 0
var _bytes := 0
var _first_key := false
var _sps := false


func _initialize() -> void:
	_streamer = ScreenStreamer.new()
	if not _streamer.start(0, PORT, 12000, 60):
		print("[probe] не запустилось: ", _streamer.get_last_error())
		quit(1)
		return
	print("[probe] поток запущен: ", _streamer.get_stats())
	_tcp.connect_to_host("127.0.0.1", PORT)
	_end = Time.get_ticks_msec() / 1000.0 + 4.0


func _process(_delta: float) -> bool:
	if _streamer == null:
		return true
	_tcp.poll()
	if _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED and _tcp.get_available_bytes() > 0:
		var got := _tcp.get_data(_tcp.get_available_bytes())
		_buffer.append_array(got[1])
		_parse()
	if Time.get_ticks_msec() / 1000.0 > _end:
		print("[probe] кадров %d (ключевых %d), %.1f Мбит/с, первый ключевой: %s, SPS: %s" % [_frames, _keys,
				_bytes * 8.0 / 4.0 / 1e6, _first_key, _sps])
		print("[probe] итог ПК: ", _streamer.get_stats())
		_streamer.stop()
		return true
	return false


func _parse() -> void:
	if not _header_seen:
		if _buffer.size() < 20:
			return
		var magic := _buffer.slice(0, 4).get_string_from_ascii()
		print("[probe] заголовок %s версия %d %dx%d %d к/с" % [magic, _u32(4), _u32(8), _u32(12), _u32(16)])
		_buffer = _buffer.slice(20)
		_header_seen = true
	while _buffer.size() >= 13:
		var length := _u32(0)
		if _buffer.size() < 13 + length:
			return
		var key := _buffer[12] == 1
		var data := _buffer.slice(13, 13 + length)
		if _frames == 0:
			_first_key = key
			for i in range(0, data.size() - 4):
				if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1 and (data[i + 3] & 0x1f) == 7:
					_sps = true
					break
		_frames += 1
		_keys += 1 if key else 0
		_bytes += length
		_buffer = _buffer.slice(13 + length)


func _u32(at: int) -> int:
	return (_buffer[at] << 24) | (_buffer[at + 1] << 16) | (_buffer[at + 2] << 8) | _buffer[at + 3]
