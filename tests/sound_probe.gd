extends SceneTree
## Probe for the PC's sound (31.10.2026): SoundStreamer on SOUND_PORT, read back
## over TCP like the headset does for 4 s while a quiet 440 Hz tone plays for a
## second (a WAV played by PowerShell on the default output device). Checks the
## header, that samples came and that the tone is in them (not just silence).
## Plays sound: whatever the default device is (Link's headset too).

const PORT := 47819
const TONE_SEC := 1.0
var _streamer: SoundStreamer
var _tcp := StreamPeerTCP.new()
var _buffer := PackedByteArray()
var _end := 0.0
var _rate := 0
var _channels := 0
var _frames := 0
var _peak := 0
var _played := false


func _initialize() -> void:
	_streamer = SoundStreamer.new()
	if not _streamer.start(PORT):
		print("[probe] не запустилось: ", _streamer.get_last_error())
		quit(1)
		return
	print("[probe] звук запущен: ", _streamer.get_stats())
	_tcp.connect_to_host("127.0.0.1", PORT)
	_end = Time.get_ticks_msec() / 1000.0 + 4.0


func _process(_delta: float) -> bool:
	if _streamer == null:
		return true
	_tcp.poll()
	if _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		if not _played and Time.get_ticks_msec() / 1000.0 > _end - 3.5:
			_played = true
			_play_tone()
		if _tcp.get_available_bytes() > 0:
			_buffer.append_array(_tcp.get_data(_tcp.get_available_bytes())[1])
			_parse()
	if Time.get_ticks_msec() / 1000.0 > _end:
		_finish()
		return true
	return false


func _parse() -> void:
	if _rate == 0:
		if _buffer.size() < 16:
			return
		if _buffer.slice(0, 4).get_string_from_ascii() != "WRKA":
			print("[probe] ПРОВАЛ: заголовок ", _buffer.slice(0, 4))
			_rate = -1
			return
		_rate = _u32(8)
		_channels = _u32(12)
		_buffer = _buffer.slice(16)
		print("[probe] заголовок: %d Гц, каналов %d" % [_rate, _channels])
	var whole := _buffer.size() / 4 * 4
	for i in range(0, whole, 2):
		_peak = maxi(_peak, absi(_buffer.decode_s16(i)))
	_frames += whole / 4
	_buffer = _buffer.slice(whole)


## Big-endian, as the header is (decode_u32 is little-endian).
func _u32(at: int) -> int:
	return _buffer[at] << 24 | _buffer[at + 1] << 16 | _buffer[at + 2] << 8 | _buffer[at + 3]


func _play_tone() -> void:
	var rate := 48000
	var samples := int(rate * TONE_SEC)
	var wav := PackedByteArray()
	wav.resize(44 + samples * 2)
	wav.encode_u32(0, 0x46464952) # RIFF
	wav.encode_u32(4, 36 + samples * 2)
	wav.encode_u32(8, 0x45564157) # WAVE
	wav.encode_u32(12, 0x20746d66) # fmt
	wav.encode_u32(16, 16)
	wav.encode_u16(20, 1)
	wav.encode_u16(22, 1)
	wav.encode_u32(24, rate)
	wav.encode_u32(28, rate * 2)
	wav.encode_u16(32, 2)
	wav.encode_u16(34, 16)
	wav.encode_u32(36, 0x61746164) # data
	wav.encode_u32(40, samples * 2)
	for i in samples:
		wav.encode_s16(44 + i * 2, int(sin(TAU * 440.0 * i / rate) * 6000.0))
	var path := OS.get_user_data_dir().path_join("sound_probe.wav")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(wav)
	file.close()
	OS.create_process("powershell.exe", ["-NoProfile", "-Command",
			"(New-Object System.Media.SoundPlayer '%s').PlaySync()" % path])
	print("[probe] играю тон 440 Гц, %.0f с" % TONE_SEC)


func _finish() -> void:
	var stats := _streamer.get_stats()
	print("[probe] стат.: ", stats)
	var failures := 0
	if _rate <= 0 or _channels != 2:
		print("[probe] ПРОВАЛ: нет заголовка")
		failures += 1
	if _frames < _rate * TONE_SEC * 0.8:
		print("[probe] ПРОВАЛ: кадров %d, ждал ≥ %d" % [_frames, int(_rate * TONE_SEC * 0.8)])
		failures += 1
	if _peak < 1000:
		print("[probe] ПРОВАЛ: тона нет, пик %d" % _peak)
		failures += 1
	print("[probe] кадров %d (%.2f с), пик %d, провалов %d" % [_frames, float(_frames) / maxi(_rate, 1), _peak, failures])
	_streamer.stop()
	_tcp.disconnect_from_host()
	quit(1 if failures > 0 else 0)
