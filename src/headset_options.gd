class_name HeadsetOptions
extends RefCounted
## Settings that matter only in the headset app (slice o5c), on the settings
## panel like the others (main.gd, section "headset"); the PC app keeps them
## too, unused. The headset's link and video code reads `current`.

const LINK_AUTO := 0
const LINK_CABLE := 1
const LINK_WIFI := 2

const LIVE_BY_GAZE := 0
const LIVE_BY_DISTANCE := 1
const LIVE_BY_RECENT := 2
## A screen already live keeps its place against a newcomer by this much (26.10.2026:
## on the edge two took turns every few seconds, each a new connection): radians
## of the view, metres of distance.
const LIVE_STICK_ANGLE := 0.17
const LIVE_STICK_METRES := 0.3

## Screens decoded at once; the rest keep their last frame. The Quest 3S refused
## a 7th 1920×1080 decoder (NO_MEMORY, slice o4); more may work with smaller screens.
var live_screens := 6
## Which screens are live (01.11.2026, the user's choice): those nearest to where
## the user looks (as it was), those nearest to the user, or those the cursor was
## on last. The one with the cursor is live either way.
var live_by := LIVE_BY_GAZE
## How the headset reaches the PC: either way, only the USB cable (adb reverse,
## which the PC's link server sets up itself), or only Wi-Fi.
var link_mode := LINK_AUTO
## The video of every screen (slice o7): megabits a second of each stream and
## new pictures a second; the PC restarts its streams when either changes.
var video_mbps := 12.0
var video_fps := 60
## Extra tangent coverage for PC VR games, percent. Applied on next game link.
var game_fov_percent := 30.0
## A line under the view: the latency from the PC's capture to the decoder, and
## what the PC's encoder and the headset's decoders take.
var video_stats := 0
## What the PC plays, in the headset (31.10.2026; the PC's SoundStreamer). Only
## without Link: Link brings the sound itself.
var pc_sound := 1
## The room around the user instead of the dark (31.10.2026; the headset's
## passthrough, «мир в шлеме» only). Marked areas show the room either way.
var passthrough := 0
## WorkMode: shown as the mode this process runs in (main.gd sets it on start);
## a change switches after a pause (main.gd, WORK_MODE_SWITCH_SEC).
var work_mode := WorkMode.OPENXR

## The options of the world now running (main.gd sets it); null before that.
static var current: HeadsetOptions
## In the headset app (headset_boot.gd, a method, not a lambda): main.gd has
## written its settings file, which goes to the PC (branch all-modes).
static var settings_saved := Callable()


static func link_mode_name(mode: int) -> String:
	return ["кабель или Wi-Fi", "только кабель", "только Wi-Fi"][clampi(mode, 0, 2)]


## The screens to keep live, best first, at most `count`: each entry {"key",
## "angle" (from where the user looks, radians), "distance" (m), "live" (decoded
## now), "last" (ms the cursor was last on it, 0 never)} ranked by `by` (LIVE_BY_…);
## `cursor` (the screen with the cursor) first.
static func live_order(entries: Array, by: int, count: int, cursor := "") -> PackedStringArray:
	var ranked: Array = []
	for entry: Dictionary in entries:
		var score := 0.0
		match by:
			LIVE_BY_DISTANCE:
				score = float(entry["distance"]) - (LIVE_STICK_METRES if entry["live"] else 0.0)
			LIVE_BY_RECENT:
				# The latest first; never seen ones after them, by the view.
				var last := int(entry["last"])
				score = -float(last) if last > 0 else 1e12 + float(entry["angle"])
			_:
				score = float(entry["angle"]) - (LIVE_STICK_ANGLE if entry["live"] else 0.0)
		if entry["key"] == cursor:
			score = -INF
		ranked.append([score, entry["key"]])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var result := PackedStringArray()
	for i in mini(count, ranked.size()):
		result.append(ranked[i][1])
	return result
