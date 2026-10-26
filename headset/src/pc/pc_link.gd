class_name PcLink
extends RefCounted
## What the headset's stand-ins for the PC module's classes (MouseInput,
## ScreenCapture, ... in this folder) share (slice o5): the link to the PC and
## the video screens. headset_boot.gd sets them up and polls them every frame.

static var link: HeadsetLink
static var screens: VideoScreens


## The PC's monitors (LinkProtocol.monitor entries), [] without a PC.
static func monitors() -> Array:
	return link.monitors if link != null else []


static func send(message: Dictionary) -> void:
	if link != null:
		link.send(message)


## The monitor under a virtual-desktop pixel, {} if none.
static func monitor_at(pixel: Vector2i) -> Dictionary:
	for monitor: Dictionary in monitors():
		if Rect2i(monitor["x"], monitor["y"], monitor["w"], monitor["h"]).has_point(pixel):
			return monitor
	return {}
