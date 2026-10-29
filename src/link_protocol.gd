class_name LinkProtocol
extends RefCounted
## The language the PC and the headset speak (slice o2). Pure logic, covered by
## tests/run_tests.gd. The headset project keeps a byte-for-byte copy in
## headset/src/link_protocol.gd (the tests compare them): edit both together.
##
## Finding each other: the headset broadcasts ASK over UDP to DISCOVERY_PORT,
## the PC answers the sender with its name and control port. Over USB the
## headset also tries 127.0.0.1 (adb reverse). Then one TCP control channel:
## Godot variants (PacketPeerStream, no objects), each a Dictionary with "t".

const VERSION := 1
const DISCOVERY_PORT := 47801
const CONTROL_PORT := 47802
## The H.264 stream of each monitor (slices o3, o4), each its own TCP
## connection on VIDEO_PORT + its index; the format is described at
## StreamBackend in native/src/win_backend.h.
const VIDEO_PORT := 47803
const VIDEO_MAGIC := "WRKV"
const VIDEO_HEADER_SIZE := 20
const VIDEO_FRAME_HEADER_SIZE := 13
const ASK := "WoRkPlace?"
const ANSWER := "WoRkPlace!"
## The headset pings this often; either side drops a silent link after LINK_TIMEOUT_SEC.
const PING_SEC := 1.0
## 8 s: a driver restart (VDD «Применить») keeps the PC busy for a few seconds.
const LINK_TIMEOUT_SEC := 8.0
## Control messages can be large (the settings file is ~30 KB): PacketPeerStream's
## buffers on both ends are made this big.
const CHANNEL_BUFFER := 1 << 20

## What the headset may ask the PC to run (slice o5b): target -> its operations.
## Nothing else is run, whatever arrives. "topology" is DisplayTopology, "vdd"
## VddControl, "vdd_config" VddConfig.write, "keyboard" MouseInput's recording.
const CALLS := {
	"topology": ["add_screen", "remove_screen", "arrange", "list_modes", "set_mode", "set_modes",
			"count_instances", "save_layout", "restore_layout"],
	"vdd": ["add_screen", "remove_screen", "apply"],
	"vdd_config": ["write"],
	"keyboard": ["start_key_recording", "stop_key_recording", "start_text_recording"],
	"thumbs": ["start", "stop"],
}

## Message types and the fields each must carry.
const FIELDS := {
	"hello": ["v", "device"],
	"welcome": ["v", "pc", "monitors"],
	"monitors": ["monitors"],
	"ping": ["time"],
	"pong": ["time"],
	"videos": ["videos"],
	"pointer": ["key", "x", "y"],
	"button": ["b", "down"],
	"wheel": ["up", "right"],
	"keys": ["keys"],
	"key": ["vk", "down"],
	"settings": ["text"],
	"call": ["target", "op", "args"],
	"event": ["target", "name", "args"],
	"pc_state": ["agent", "secure", "vdd_installed"],
	"vdd_config": ["text"],
	"secure_frame": ["jpg", "x", "y", "w", "h", "s"],
	"thumb": ["key", "jpg"],
	"bye": [],
}


static func ask_packet() -> PackedByteArray:
	return ("%s|%d" % [ASK, VERSION]).to_utf8_buffer()


## The version the asking headset speaks, or -1 if the packet is not an ask.
static func ask_version(packet: PackedByteArray) -> int:
	var parts := packet.get_string_from_utf8().split("|")
	if parts.size() != 2 or parts[0] != ASK or not parts[1].is_valid_int():
		return -1
	return parts[1].to_int()


## The name goes last: it may contain anything, the separator included.
static func answer_packet(pc_name: String, port: int) -> PackedByteArray:
	return ("%s|%d|%d|%s" % [ANSWER, VERSION, port, pc_name]).to_utf8_buffer()


## {"version", "port", "pc"} from a PC's answer, or {} if it is not one.
static func parse_answer(packet: PackedByteArray) -> Dictionary:
	var parts := packet.get_string_from_utf8().split("|", true, 3)
	if parts.size() != 4 or parts[0] != ANSWER or not parts[1].is_valid_int() or not parts[2].is_valid_int():
		return {}
	var port := parts[2].to_int()
	if port <= 0 or port > 65535:
		return {}
	return {"version": parts[1].to_int(), "port": port, "pc": parts[3]}


static func hello(device: String) -> Dictionary:
	return {"t": "hello", "v": VERSION, "device": device}


static func welcome(pc_name: String, monitors: Array) -> Dictionary:
	return {"t": "welcome", "v": VERSION, "pc": pc_name, "monitors": monitors}


static func monitors_message(monitors: Array) -> Dictionary:
	return {"t": "monitors", "monitors": monitors}


## One stream the PC offers: monitor `key` (w × h pixels) on `port` of its own address.
static func video(port: int, key: String, size: Vector2i) -> Dictionary:
	return {"port": port, "key": key, "w": size.x, "h": size.y}


## Every stream the PC runs now; a monitor missing from the list has none.
static func videos_message(videos: Array) -> Dictionary:
	return {"t": "videos", "videos": videos}


## The headset moves the cursor to pixel (x, y) of monitor `key`.
static func pointer(key: String, position: Vector2i) -> Dictionary:
	return {"t": "pointer", "key": key, "x": position.x, "y": position.y}


## Mouse button `b` (0 left, 1 right, 2 middle) goes down or up where the cursor is.
static func button(b: int, down: bool) -> Dictionary:
	return {"t": "button", "b": b, "down": down}


## The mouse wheel: `up` and `right`; 120 is one notch (MouseInput.scroll). Not
## "v": that field is the protocol version.
static func wheel(up: int, right: int) -> Dictionary:
	return {"t": "wheel", "up": up, "right": right}


## A shortcut: Windows virtual keys pressed in order, released in reverse (slice o5).
static func keys(virtual_keys: Array) -> Dictionary:
	return {"t": "keys", "keys": virtual_keys}


## One Windows virtual key held down or let go.
static func key(virtual_key: int, down: bool) -> Dictionary:
	return {"t": "key", "vk": virtual_key, "down": down}


## The PC app's settings file (user://settings.cfg) as text, for the headset to
## take over once (slice o5).
static func settings_message(text: String) -> Dictionary:
	return {"t": "settings", "text": text}


## The headset asks the PC to run `target`.`op`(`args`) (see CALLS).
static func call_message(target: String, op: String, args: Array = []) -> Dictionary:
	return {"t": "call", "target": target, "op": op, "args": args}


## The PC tells the headset what one of its services did: a signal and its arguments.
static func event(target: String, name: String, args: Array = []) -> Dictionary:
	return {"t": "event", "target": target, "name": name, "args": args}


## What the headset cannot see itself: whether the input agent is there, whether
## the secure desktop (UAC, lock screen) is up, whether the VDD helper is installed.
static func pc_state(agent: bool, secure: bool, vdd_installed: bool) -> Dictionary:
	return {"t": "pc_state", "agent": agent, "secure": secure, "vdd_installed": vdd_installed}


## The driver's settings file (VddConfig.PATH) as text, "" if there is none.
static func vdd_config(text: String) -> Dictionary:
	return {"t": "vdd_config", "text": text}


## A picture of the secure desktop (JPEG) and where it is on the virtual desktop.
## `scale`: monitor pixels per picture pixel (SecureDesktop.get_frame_scale).
static func secure_frame(jpg: PackedByteArray, origin: Vector2i, size: Vector2i, scale: int) -> Dictionary:
	return {"t": "secure_frame", "jpg": jpg, "x": origin.x, "y": origin.y, "w": size.x, "h": size.y, "s": scale}


## A small picture of monitor `key` (JPEG), for the plane of groups (slice o5c);
## sent while the headset has asked for them ("thumbs" "start").
static func thumb(key: String, jpg: PackedByteArray) -> Dictionary:
	return {"t": "thumb", "key": key, "jpg": jpg}


static func ping(time: float) -> Dictionary:
	return {"t": "ping", "time": time}


static func pong(time: float) -> Dictionary:
	return {"t": "pong", "time": time}


## One monitor as the headset sees it: `key` is the PC's stable id
## (ScreenPanel.key_of), the rectangle is in desktop pixels.
static func monitor(key: String, name: String, position: Vector2i, size: Vector2i, primary: bool) -> Dictionary:
	return {"key": key, "name": name, "x": position.x, "y": position.y, "w": size.x, "h": size.y, "primary": primary}


## "" if `message` is a well-formed message, otherwise what is wrong with it.
static func problem(message: Variant) -> String:
	if not message is Dictionary:
		return "не словарь"
	var type: Variant = message.get("t")
	if not type is String or not FIELDS.has(type):
		return "неизвестный тип %s" % str(type)
	for field: String in FIELDS[type]:
		if not message.has(field):
			return "%s без поля %s" % [type, field]
	if message.has("v") and message["v"] != VERSION:
		return "версия %s, а нужна %d" % [str(message["v"]), VERSION]
	if message.has("videos"):
		if not message["videos"] is Array:
			return "videos не список"
		for entry: Variant in message["videos"]:
			if not entry is Dictionary or not entry.get("port", 0) is int or not entry.get("key", 0) is String 					or not entry.get("w", 0) is int or not entry.get("h", 0) is int 					or int(entry.get("port", 0)) <= 0 or int(entry.get("w", 0)) <= 0 or int(entry.get("h", 0)) <= 0:
				return "плохое видео %s" % str(entry)
	if type == "pointer" and not (message["key"] is String and message["x"] is int and message["y"] is int):
		return "pointer с плохими полями"
	if type == "button" and not (message["b"] is int and int(message["b"]) >= 0 and int(message["b"]) <= 2 and message["down"] is bool):
		return "button с плохими полями"
	if type == "call":
		if not message["target"] is String or not CALLS.has(message["target"]):
			return "call: чужая цель %s" % str(message["target"])
		if not message["op"] is String or not (message["op"] in CALLS[message["target"]]):
			return "call: чужое действие %s" % str(message["op"])
		if not message["args"] is Array:
			return "call: аргументы не список"
	if type == "event" and not (message["target"] is String and message["name"] is String and message["args"] is Array):
		return "event с плохими полями"
	if type == "pc_state" and not (message["agent"] is bool and message["secure"] is bool and message["vdd_installed"] is bool):
		return "pc_state с плохими полями"
	if type == "vdd_config" and not message["text"] is String:
		return "vdd_config не текст"
	if type == "thumb" and not (message["key"] is String and message["jpg"] is PackedByteArray):
		return "thumb с плохими полями"
	if type == "secure_frame" and not message["jpg"] is PackedByteArray:
		return "secure_frame без картинки"
	if type == "settings" and not message["text"] is String:
		return "settings не текст"
	if type == "wheel" and not (message["up"] is int and message["right"] is int):
		return "wheel с плохими полями"
	if type == "keys":
		if not message["keys"] is Array or (message["keys"] as Array).is_empty():
			return "keys пустой"
		for code: Variant in message["keys"]:
			if not code is int or int(code) <= 0 or int(code) > 255:
				return "keys: плохая клавиша %s" % str(code)
	if type == "key" and not (message["vk"] is int and int(message["vk"]) > 0 and int(message["vk"]) <= 255 and message["down"] is bool):
		return "key с плохими полями"
	if message.has("monitors"):
		if not message["monitors"] is Array:
			return "monitors не список"
		for entry: Variant in message["monitors"]:
			if not entry is Dictionary or not (entry.get("w", 0) is int and entry.get("h", 0) is int) \
					or int(entry.get("w", 0)) <= 0 or int(entry.get("h", 0)) <= 0:
				return "плохой монитор %s" % str(entry)
	return ""
