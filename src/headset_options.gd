class_name HeadsetOptions
extends RefCounted
## Settings that matter only in the headset app (slice o5c), on the settings
## panel like the others (main.gd, section "headset"); the PC app keeps them
## too, unused. The headset's link and video code reads `current`.

const LINK_AUTO := 0
const LINK_CABLE := 1
const LINK_WIFI := 2

## Screens decoded at once; the rest keep their last frame. The Quest 3S refused
## a 7th 1920×1080 decoder (NO_MEMORY, slice o4); more may work with smaller screens.
var live_screens := 6
## How the headset reaches the PC: either way, only the USB cable (adb reverse,
## which the PC's link server sets up itself), or only Wi-Fi.
var link_mode := LINK_AUTO
## The video of every screen (slice o7): megabits a second of each stream and
## new pictures a second; the PC restarts its streams when either changes.
var video_mbps := 12.0
var video_fps := 60
## A line under the view: the latency from the PC's capture to the decoder, and
## what the PC's encoder and the headset's decoders take.
var video_stats := 0
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
