class_name VddControl
extends Node
## Headset stand-in for VddControl (slice o5b): requests go to the PC's helper
## through the link server. Under Quest Link the app restarted after every driver
## change (Link dropped), and main.gd relies on that to finish what it started
## (the layout back after «Применить», a place load that needed new screens).
## Here nothing drops, so after the helper's answer the world is built again
## (PcLink.restart_world, done by headset_boot.gd).

signal finished(ok: bool, message: String)

const HELPER_VERSION := 7
const NO_PC := "нет связи с ПК"

var busy := false

## Shared by the stand-ins of all the worlds built in this run: a rebuilt world
## asks whether the request made before it has been answered.
static var _requests := 0
static var _answered := {}


func _init() -> void:
	PcLink.handlers["vdd"] = _on_event


func is_installed() -> bool:
	return PcLink.vdd_installed


func add_screen() -> void:
	_request("add_screen", [])


func remove_screen() -> void:
	_request("remove_screen", [])


func apply(count: int) -> void:
	_request("apply", [count])


func last_request_id() -> String:
	return "headset-%d" % _requests


func has_answered(id: String) -> bool:
	return _answered.has(id)


func _request(op: String, args: Array) -> void:
	if busy:
		return
	if not PcLink.call_pc("vdd", op, args):
		finished.emit.call_deferred(false, NO_PC)
		return
	_requests += 1
	busy = true
	_asked_at = Time.get_ticks_msec() / 1000.0
	print("[vdd] запрос на ПК: %s %s" % [op, args])


## The answer may come only after the link has dropped and come back (the PC
## keeps it for the next connection): it is waited for this long, then given up.
const ANSWER_WAIT_SEC := 180.0

var _asked_at := 0.0


func _process(_delta: float) -> void:
	if busy and Time.get_ticks_msec() / 1000.0 - _asked_at > ANSWER_WAIT_SEC:
		busy = false
		finished.emit(false, "ПК не ответил за %d с" % int(ANSWER_WAIT_SEC))


func _on_event(name: String, args: Array) -> void:
	if name != "finished":
		return
	busy = false
	_answered[last_request_id()] = true
	finished.emit(args[0], args[1])
	print("[vdd] ПК ответил, мир строится заново, как после перезапуска под Link")
	PcLink.restart_world = true
