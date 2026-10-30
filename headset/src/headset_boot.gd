extends Node3D
## The headset app (slice o5): links up with the PC and runs the world — the PC
## app's own main.gd, synced into shared/ by tools/sync_headset.ps1 — whose calls
## to the PC module go over the link through the stand-ins in src/pc/.

const MAIN_SCRIPT := "res://shared/main.gd"
## The PC app's settings are taken over once (the user's wish, 26.10.2026: "all
## the settings as they were"); after that the headset keeps its own. This file
## says when it happened; without it the next PC settings are taken again.
const SETTINGS_PATH := "user://settings.cfg"
const IMPORTED_MARK := "user://pc_settings_imported.txt"
## The world waits for the PC (its monitors and the driver's list, slice o5b:
## «Разрешение по клетке» took an empty list for "the driver has none") at most
## this long, then starts without it.
const WAIT_FOR_PC_SEC := 4.0
## A break shorter than this shows nothing (slice o6); longer, a line before the
## eyes says so: the screens stay with their last picture and seemed frozen.
const LOST_NOTICE_SEC := 1.5
const LOST_NOTICE_OFFSET := Vector3(0.0, -0.18, -0.9)
## The video's latency and load (slice o7): read this often, shown under the view
## when «Показывать задержку» is on, logged every VIDEO_LOG_EVERY-th time.
const VIDEO_STATS_SEC := 2.0
const VIDEO_LOG_EVERY := 5
const VIDEO_STATS_OFFSET := Vector3(0.0, -0.3, -0.9)

var _link: HeadsetLink
var _main: Node3D
var _started := 0.0
var _lost_notice: Label3D
## Since when the link is down (-1 while up).
var _lost_since := -1.0
var _video_label: Label3D
var _video_text := ""
var _next_video_stats := 0.0
var _video_reports := 0
## com.workplace.headset.VideoReceiver (its latency), null off Android.
var _receiver: Variant = null


func _ready() -> void:
	# Before main.gd every frame: the link's news (monitors, streams) come first.
	process_priority = -100
	_link = HeadsetLink.new(OS.get_model_name())
	PcLink.link = _link
	PcLink.screens = VideoScreens.new()
	VddConfig.remote_text = _vdd_config_text
	VddConfig.remote_write = _write_vdd_config
	_started = Time.get_ticks_msec() / 1000.0
	if OS.get_name() == "Android":
		_receiver = JavaClassWrapper.wrap("com.workplace.headset.VideoReceiver")


func _start_main() -> void:
	_main = Node3D.new()
	_main.set_script(load(MAIN_SCRIPT))
	_main.name = "Main"
	add_child(_main)


## Builds the world again, as the PC app restarted (after a driver change, after
## the PC's settings came).
func _restart_main(why: String) -> void:
	print("[app] мир строится заново: ", why)
	PcLink.screens.reset()
	remove_child(_main)
	_main.queue_free()
	_start_main()


## Writes the PC's settings over the headset's.
func _import_settings(text: String) -> bool:
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if file == null:
		print("[settings] не удалось записать настройки ПК: %d" % FileAccess.get_open_error())
		return false
	file.store_string(text)
	file.close()
	var mark := FileAccess.open(IMPORTED_MARK, FileAccess.WRITE)
	if mark != null:
		mark.store_string("%s %s\n" % [Time.get_datetime_string_from_system(), _link.pc_name])
		mark.close()
	print("[settings] настройки ПК %s перенесены (%d байт)" % [_link.pc_name, text.length()])
	return true


func _vdd_config_text() -> String:
	return PcLink.vdd_config


## VddConfig.write in the headset: the list goes to the PC, which writes the file
## and sends it back; what went wrong there shows in the log.
func _write_vdd_config(resolutions: Array[Vector2i]) -> String:
	if not PcLink.call_pc("vdd_config", "write", [resolutions]):
		return "нет связи с ПК"
	return ""


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var before := _link.state
	_link.poll(now)
	if _link.state != before:
		print("[link] ", _link.describe())
	PcLink.dispatch()
	var fresh_settings := false
	if _link.settings_changed:
		_link.settings_changed = false
		if not FileAccess.file_exists(IMPORTED_MARK):
			fresh_settings = _import_settings(_link.pc_settings)
	if _main == null:
		var pc_ready := PcLink.connected() and PcLink.has_vdd_config and not _link.monitors.is_empty()
		if pc_ready or now - _started > WAIT_FOR_PC_SEC:
			print("[app] мир начинается %s" % ("с ПК %s" % _link.pc_name if pc_ready else "без ПК"))
			_start_main()
	elif fresh_settings:
		_restart_main("пришли настройки ПК")
	elif PcLink.restart_world:
		_restart_main("драйвер ПК перезапущен")
	PcLink.restart_world = false
	# The stand-ins read these lists; nobody else consumes the change flags.
	_link.monitors_changed = false
	_link.videos_changed = false
	PcLink.screens.poll(now, get_viewport().get_camera_3d())
	PcLink.screens.update_textures()
	_update_lost_notice(now)
	var options := HeadsetOptions.current
	if options != null:
		_link.video_kbps = roundi(options.video_mbps * 1000.0)
		_link.video_fps = options.video_fps
	_update_video_stats(now, options != null and options.video_stats != 0)


## Every VIDEO_STATS_SEC: what the PC's streams and this headset's decoders did,
## and the latency of new pictures from the PC capturing them.
func _update_video_stats(now: float, shown: bool) -> void:
	if now >= _next_video_stats:
		_next_video_stats = now + VIDEO_STATS_SEC
		_video_text = _describe_video()
		_video_reports += 1
		if _video_reports % VIDEO_LOG_EVERY == 0 and PcLink.connected():
			print("[video] ", _video_text.replace("\n", "; "))
	var camera := get_viewport().get_camera_3d()
	if shown and camera != null and (_video_label == null or _video_label.get_parent() != camera):
		if _video_label != null:
			_video_label.queue_free()
		_video_label = Label3D.new()
		_video_label.pixel_size = 0.0007
		_video_label.font_size = 32
		_video_label.outline_size = 8
		_video_label.modulate = Color(0.75, 0.95, 1.0)
		_video_label.no_depth_test = true
		_video_label.render_priority = 20
		_video_label.position = VIDEO_STATS_OFFSET
		camera.add_child(_video_label)
	if is_instance_valid(_video_label):
		_video_label.visible = shown and PcLink.connected()
		_video_label.text = _video_text


func _describe_video() -> String:
	var lines: Array[String] = []
	var report: String = _receiver.latencyReport() if _receiver != null else ""
	if report != "":
		# count arrived shown shownMax decode decodeMax (VideoReceiver.latencyReport)
		var v := report.split(" ")
		lines.append("от захвата на ПК: принят %.0f мс, декодирован %.0f мс (худший %.0f), ±%.0f мс" % [
				float(v[1]), float(v[2]), float(v[3]), float(_receiver.clockErrorMs())])
		lines.append("декодер %.1f мс (худший %.0f); новых картинок %.0f/с" % [float(v[4]), float(v[5]),
				float(v[0]) / VIDEO_STATS_SEC])
	elif _receiver != null:
		lines.append("задержка: нет новых картинок" if float(_receiver.clockErrorMs()) >= 0.0 else "задержка: часы ещё не сверены")
	var pc := _link.pc_video_stats
	if not pc.is_empty():
		lines.append("ПК: смотрю %d из %d, %.0f к/с, %.1f Мбит/с, кодирование %.1f мс; %d кбит/с × %d к/с" % [
				pc["watched"], pc["streams"], pc["fps"], pc["mbps"], pc["encode_ms"], _link.video_kbps, _link.video_fps])
	return "\n".join(lines)


func _update_lost_notice(now: float) -> void:
	var up := PcLink.connected()
	if up:
		if _lost_since >= 0.0:
			print("[link] связь вернулась через %.1f с" % (now - _lost_since))
		_lost_since = -1.0
	elif _lost_since < 0.0:
		_lost_since = now
	var show := _main != null and not up and now - _lost_since >= LOST_NOTICE_SEC
	var camera := get_viewport().get_camera_3d()
	if show and camera != null and (_lost_notice == null or _lost_notice.get_parent() != camera):
		# The world built again has a camera of its own.
		if _lost_notice != null:
			_lost_notice.queue_free()
		_lost_notice = Label3D.new()
		_lost_notice.pixel_size = 0.0009
		_lost_notice.font_size = 40
		_lost_notice.outline_size = 10
		_lost_notice.modulate = Color(1.0, 0.82, 0.55)
		_lost_notice.no_depth_test = true
		_lost_notice.render_priority = 20
		_lost_notice.position = LOST_NOTICE_OFFSET
		camera.add_child(_lost_notice)
	if is_instance_valid(_lost_notice):
		_lost_notice.visible = show
		if show:
			_lost_notice.text = "Нет связи с ПК (%.0f с) — %s\nэкраны показывают последний кадр" % [now - _lost_since,
					_link.describe()]


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		if PcLink.screens != null:
			PcLink.screens.stop_all()
		if _link != null:
			_link.close()
