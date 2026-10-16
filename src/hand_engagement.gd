class_name HandEngagement
extends RefCounted
## Decides whether a tracked hand is being used to control the computer or is
## at rest (on the keyboard, on the lap, hanging down). A resting hand is hidden,
## draws no ray and sends no clicks: typing would otherwise produce pinches.
## Pure logic, covered by tests/run_tests.gd.
##
## A hand is in use while it is held up (not far below the eyes) and its ray is
## not pointing steeply down. The state changes only after the new condition has
## lasted a moment, so that a quick dip does not drop a held drag.


## Tunable in VR (settings panel in main.gd). Distances in metres, times in seconds.
class Settings:
	## A palm further below the eyes than this is at rest.
	var drop := 0.5
	## A ray pointing further below the horizon than this (degrees) is at rest.
	var ray_down_deg := 40.0
	## How long the hand has to look used before it takes control again...
	var engage_sec := 0.3
	## ...and how long it has to look at rest before it lets go.
	var disengage_sec := 0.2


var settings := Settings.new()
var engaged := false

var _agreed_at := NAN


## `palm_drop`: how far the palm is below the eyes (metres, positive = below).
## `ray_elevation`: the ray's angle to the horizon (radians, negative = down).
func update(time: float, palm_drop: float, ray_elevation: float) -> bool:
	var in_use := palm_drop < settings.drop and ray_elevation > -deg_to_rad(settings.ray_down_deg)
	if is_nan(_agreed_at) or in_use == engaged:
		_agreed_at = time
		return engaged
	if time - _agreed_at >= (settings.engage_sec if in_use else settings.disengage_sec):
		engaged = in_use
		_agreed_at = time
	return engaged
