class_name VddControl
extends Node
## Headset stand-in for VddControl (slice o5a): the driver's screens are changed
## from the PC only for now (slice o5b sends the requests to the PC).

signal finished(ok: bool, message: String)

const HELPER_VERSION := 7
const NOT_YET := "в шлеме пока недоступно (срез o5b)"

var busy := false


func is_installed() -> bool:
	return false


func add_screen() -> void:
	finished.emit.call_deferred(false, NOT_YET)


func remove_screen() -> void:
	finished.emit.call_deferred(false, NOT_YET)


func apply(_count: int) -> void:
	finished.emit.call_deferred(false, NOT_YET)


func last_request_id() -> String:
	return ""


func has_answered(_id: String) -> bool:
	return false
