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
const ASK := "WoRkPlace?"
const ANSWER := "WoRkPlace!"
## The headset pings this often; either side drops a silent link after LINK_TIMEOUT_SEC.
const PING_SEC := 1.0
const LINK_TIMEOUT_SEC := 4.0

## Message types and the fields each must carry.
const FIELDS := {
	"hello": ["v", "device"],
	"welcome": ["v", "pc", "monitors"],
	"monitors": ["monitors"],
	"ping": ["time"],
	"pong": ["time"],
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
	if message.has("monitors"):
		if not message["monitors"] is Array:
			return "monitors не список"
		for entry: Variant in message["monitors"]:
			if not entry is Dictionary or not (entry.get("w", 0) is int and entry.get("h", 0) is int) \
					or int(entry.get("w", 0)) <= 0 or int(entry.get("h", 0)) <= 0:
				return "плохой монитор %s" % str(entry)
	return ""
