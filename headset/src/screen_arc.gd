class_name ScreenArc
extends RefCounted
## Where the PC's monitors hang in the headset (slice o4): the Windows desktop
## wrapped onto an arc around the start position, the primary monitor straight
## ahead at eye height; desktop y offsets become heights. Pure logic, tested
## from tests/run_tests.gd (loaded by path: the PC project does not see headset/).

const EYE_HEIGHT := 1.3
const METRES_PER_PIXEL := 1.0 / 1920.0
const MIN_RADIUS := 1.6
## The whole desktop never takes more than this much of the circle (radians, 200°).
const MAX_ARC := 3.49
## Each screen is drawn this much smaller, leaving a seam between neighbours.
const FILL := 0.98


## Monitor key -> {"transform": Transform3D (centre, +Z towards the user),
## "size": Vector2 metres} for each monitor of the list (LinkProtocol.monitor).
static func place(monitors: Array) -> Dictionary:
	var result := {}
	if monitors.is_empty():
		return result
	var primary: Dictionary = monitors[0]
	var left := INF
	var right := -INF
	for monitor: Dictionary in monitors:
		if monitor["primary"]:
			primary = monitor
		left = minf(left, monitor["x"])
		right = maxf(right, monitor["x"] + monitor["w"])
	var radius := maxf(MIN_RADIUS, (right - left) * METRES_PER_PIXEL / MAX_ARC)
	var centre := Vector2(primary["x"] + primary["w"] / 2.0, primary["y"] + primary["h"] / 2.0)
	for monitor: Dictionary in monitors:
		var offset := Vector2(monitor["x"] + monitor["w"] / 2.0, monitor["y"] + monitor["h"] / 2.0) - centre
		var angle := offset.x * METRES_PER_PIXEL / radius
		var position := Vector3(radius * sin(angle), EYE_HEIGHT - offset.y * METRES_PER_PIXEL, -radius * cos(angle))
		result[monitor["key"]] = {
			"transform": Transform3D(Basis(Vector3.UP, -angle), position),
			"size": Vector2(monitor["w"], monitor["h"]) * METRES_PER_PIXEL * FILL,
		}
	return result
