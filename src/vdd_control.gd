class_name VddControl
extends Node
## Asks the elevated helper (tools/vdd_helper.ps1, run through a scheduled task so
## no UAC prompt appears in the headset) to add or remove one virtual display.

signal finished(ok: bool, message: String)

const TASK_NAME := "WoRkPlaceVddHelper"
const TIMEOUT_SEC := 120.0
const POLL_INTERVAL_SEC := 0.25

var busy := false

var _request_id := ""
var _elapsed := 0.0
var _poll_timer := 0.0


func is_installed() -> bool:
	return FileAccess.file_exists(_helper_path()) and DirAccess.dir_exists_absolute(_exchange_dir())


func add_screen() -> void:
	_request("add")


func remove_screen() -> void:
	_request("remove")


func _process(delta: float) -> void:
	if not busy:
		return
	_elapsed += delta
	_poll_timer += delta
	if _poll_timer < POLL_INTERVAL_SEC:
		return
	_poll_timer = 0.0

	var response := _read_response()
	if not response.is_empty():
		busy = false
		finished.emit(bool(response.get("ok", false)), str(response.get("message", "")))
	elif _elapsed > TIMEOUT_SEC:
		busy = false
		finished.emit(false, "помощник не ответил за %d с" % int(TIMEOUT_SEC))


func _request(verb: String) -> void:
	if busy:
		return
	if not is_installed():
		finished.emit(false, "помощник не установлен: запустите tools/install_vdd_helper.ps1 от администратора")
		return

	DirAccess.remove_absolute(_response_path())
	_request_id = str(Time.get_ticks_usec())
	var file := FileAccess.open(_request_path(), FileAccess.WRITE)
	if file == null:
		finished.emit(false, "не удалось записать запрос: %s" % error_string(FileAccess.get_open_error()))
		return
	file.store_string("%s %s" % [_request_id, verb])
	file.close()

	if OS.create_process("schtasks.exe", ["/run", "/tn", TASK_NAME]) < 0:
		finished.emit(false, "не удалось запустить задачу %s" % TASK_NAME)
		return
	busy = true
	_elapsed = 0.0
	_poll_timer = 0.0


## Returns the parsed response for the current request, or an empty dictionary.
func _read_response() -> Dictionary:
	if not FileAccess.file_exists(_response_path()):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_response_path()))
	if parsed is Dictionary and str((parsed as Dictionary).get("id", "")) == _request_id:
		return parsed
	return {}


func _exchange_dir() -> String:
	return OS.get_environment("ProgramData").path_join("WoRkPlace/vdd")


func _request_path() -> String:
	return _exchange_dir().path_join("request.txt")


func _response_path() -> String:
	return _exchange_dir().path_join("response.txt")


func _helper_path() -> String:
	return OS.get_environment("ProgramFiles").path_join("WoRkPlace/vdd_helper.ps1")
