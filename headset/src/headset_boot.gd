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

var _link: HeadsetLink
var _main: Node3D
var _started := 0.0


func _ready() -> void:
	# Before main.gd every frame: the link's news (monitors, streams) come first.
	process_priority = -100
	_link = HeadsetLink.new(OS.get_model_name())
	PcLink.link = _link
	PcLink.screens = VideoScreens.new()
	VddConfig.remote_text = _vdd_config_text
	VddConfig.remote_write = _write_vdd_config
	_started = Time.get_ticks_msec() / 1000.0


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


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		if PcLink.screens != null:
			PcLink.screens.stop_all()
		if _link != null:
			_link.close()
