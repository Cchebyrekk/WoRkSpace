class_name InputWorker
extends RefCounted
## The link server's input to Windows on a thread of its own (slice o5c). Each
## MouseInput call may wait for the SYSTEM agent's pipe, and while Windows sets
## displays up anew the agent's SendInput can take seconds; on the server's main
## loop that froze the cursor, the clicks and the link itself (26.10.2026: "the
## mouse stops following the ray or answering anything"). Here the main loop only
## queues; consecutive cursor moves merge into the newest one, so a slow moment
## leaves no backlog behind.

## A call slower than this goes into the log.
const SLOW_MS := 100
## The agent's status messages are read this often (the module wants it every
## frame: left unread they fill the agent's pipe and it stops taking input).
const STATUS_SEC := 0.016

var _thread := Thread.new()
var _mutex := Mutex.new()
var _queue: Array[Dictionary] = []
var _running := true
var _agent := false
var _secure := false


func _init() -> void:
	_thread.start(_run)


## A LinkProtocol message of type pointer (with "at", desktop pixels), button,
## wheel, keys or key.
func push(message: Dictionary) -> void:
	_mutex.lock()
	if message["t"] == "pointer" and not _queue.is_empty() and _queue[-1]["t"] == "pointer":
		_queue[-1] = message
	else:
		_queue.append(message)
	_mutex.unlock()


func agent_connected() -> bool:
	_mutex.lock()
	var value := _agent
	_mutex.unlock()
	return value


func secure_desktop_active() -> bool:
	_mutex.lock()
	var value := _secure
	_mutex.unlock()
	return value


func stop() -> void:
	_mutex.lock()
	_running = false
	_mutex.unlock()
	_thread.wait_to_finish()


func _run() -> void:
	var next_status := 0.0
	while true:
		_mutex.lock()
		var running := _running
		var batch := _queue
		_queue = []
		_mutex.unlock()
		for message in batch:
			_deliver(message)
		var now := Time.get_ticks_msec() / 1000.0
		if now >= next_status:
			next_status = now + STATUS_SEC
			var started := Time.get_ticks_msec()
			var secure := MouseInput.is_secure_desktop_active()
			var agent := MouseInput.is_agent_connected()
			_report_slow("состояние агента", started)
			_mutex.lock()
			_secure = secure
			_agent = agent
			_mutex.unlock()
		if not running:
			return
		if batch.is_empty():
			OS.delay_msec(2)


func _deliver(message: Dictionary) -> void:
	var started := Time.get_ticks_msec()
	match message["t"]:
		"pointer":
			MouseInput.move_to(message["at"])
		"button":
			MouseInput.set_button(message["b"], message["down"])
		"wheel":
			if message["up"] != 0:
				MouseInput.scroll(message["up"])
			if message["right"] != 0:
				MouseInput.scroll_horizontal(message["right"])
		"keys":
			MouseInput.press_keys(PackedInt32Array(message["keys"]))
		"key":
			MouseInput.set_key(message["vk"], message["down"])
	_report_slow(message["t"], started)


func _report_slow(what: String, started: int) -> void:
	var took := Time.get_ticks_msec() - started
	if took >= SLOW_MS:
		print("[input] %s занял %d мс (агент или Windows не принимали ввод)" % [what, took])
