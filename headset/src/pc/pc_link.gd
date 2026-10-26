class_name PcLink
extends RefCounted
## What the headset's stand-ins for the PC module's classes (MouseInput,
## ScreenCapture, ... in this folder) share (slice o5): the link to the PC, the
## video screens, and since o5b the PC's state and the routing of its events to
## the stand-in that asked. headset_boot.gd sets them up and polls them.

static var link: HeadsetLink
static var screens: VideoScreens
## Target ("topology", "vdd", ...) -> Callable(name: String, args: Array) of the
## stand-in that handles its events now (a world built again registers anew).
static var handlers: Dictionary = {}
## From the PC's pc_state.
static var agent := false
static var secure := false
static var vdd_installed := false
## The driver's settings file as the PC last sent it.
static var vdd_config := ""
static var has_vdd_config := false
## The secure desktop's latest picture (null until one came) and where it is.
static var secure_image: Image
static var secure_origin := Vector2i.ZERO
static var secure_sequence := 0
## A stand-in asks for the world to be built again (as the PC app restarted after
## the driver restarted under Quest Link); headset_boot.gd does it.
static var restart_world := false
## The monitor the PC's cursor is on (its key, "" if none): its screen is always
## decoded, whatever the gaze (VideoScreens), or the cursor seemed frozen there.
static var cursor_key := ""


## The PC's monitors (LinkProtocol.monitor entries), [] without a PC.
static func monitors() -> Array:
	return link.monitors if link != null else []


static func send(message: Dictionary) -> void:
	if link != null:
		link.send(message)


static func connected() -> bool:
	return link != null and link.state == HeadsetLink.State.CONNECTED and link.pc_name != ""


## Asks the PC to run one of its services' operations (LinkProtocol.CALLS).
static func call_pc(target: String, op: String, args: Array = []) -> bool:
	if not connected():
		return false
	link.send(LinkProtocol.call_message(target, op, args))
	return true


## The monitor under a virtual-desktop pixel, {} if none.
static func monitor_at(pixel: Vector2i) -> Dictionary:
	for monitor: Dictionary in monitors():
		if Rect2i(monitor["x"], monitor["y"], monitor["w"], monitor["h"]).has_point(pixel):
			return monitor
	return {}


## Every frame: what the PC sent for the services.
static func dispatch() -> void:
	if link == null:
		return
	var messages := link.inbox
	link.inbox = []
	for message in messages:
		match message["t"]:
			"event":
				var handler: Callable = handlers.get(message["target"], Callable())
				if handler.is_valid():
					handler.call(message["name"], message["args"])
			"pc_state":
				if message["agent"] != agent or message["secure"] != secure:
					print("[pc] агент: %s, защищённый стол: %s" % [message["agent"], message["secure"]])
				agent = message["agent"]
				secure = message["secure"]
				vdd_installed = message["vdd_installed"]
			"vdd_config":
				vdd_config = message["text"]
				has_vdd_config = true
			"secure_frame":
				var image := Image.new()
				if image.load_jpg_from_buffer(message["jpg"]) == OK:
					secure_image = image
					secure_origin = Vector2i(message["x"], message["y"])
					secure_sequence += 1
