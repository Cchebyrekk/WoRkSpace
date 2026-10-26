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

var _link: HeadsetLink
var _main: Node3D


func _ready() -> void:
	# Before main.gd every frame: the link's news (monitors, streams) come first.
	process_priority = -100
	_link = HeadsetLink.new(OS.get_model_name())
	PcLink.link = _link
	PcLink.screens = VideoScreens.new()
	_start_main()


func _start_main() -> void:
	_main = Node3D.new()
	_main.set_script(load(MAIN_SCRIPT))
	_main.name = "Main"
	add_child(_main)


## Writes the PC's settings over the headset's and starts the world again on them.
func _import_settings(text: String) -> void:
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if file == null:
		print("[settings] не удалось записать настройки ПК: %d" % FileAccess.get_open_error())
		return
	file.store_string(text)
	file.close()
	var mark := FileAccess.open(IMPORTED_MARK, FileAccess.WRITE)
	if mark != null:
		mark.store_string("%s %s\n" % [Time.get_datetime_string_from_system(), _link.pc_name])
		mark.close()
	print("[settings] настройки ПК %s перенесены (%d байт), перезапускаю мир" % [_link.pc_name, text.length()])
	PcLink.screens.reset()
	remove_child(_main)
	_main.queue_free()
	_start_main()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var before := _link.state
	_link.poll(now)
	if _link.state != before:
		print("[link] ", _link.describe())
	if _link.settings_changed:
		_link.settings_changed = false
		if not FileAccess.file_exists(IMPORTED_MARK):
			_import_settings(_link.pc_settings)
	# The stand-ins read these lists; nobody else consumes the change flags.
	_link.monitors_changed = false
	_link.videos_changed = false
	PcLink.screens.poll(now, get_viewport().get_camera_3d())


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		if PcLink.screens != null:
			PcLink.screens.stop_all()
		if _link != null:
			_link.close()
