class_name WorkMode
extends RefCounted
## How the PC and the headset work together (branch all-modes, 30.10.2026), one
## setting «Режим работы» for all three:
## - OPENXR: the PC app draws the world through the PC's OpenXR runtime (Quest
##   Link, SteamVR with ALVR or Virtual Desktop, VDXR...); started by hand.
## - HEADSET_WORLD: the world runs in the headset app, the PC runs the link
##   server (slices o2-o7).
## - PC_DRAWS: the PC app draws the headset's eyes and streams them to the
##   headset app (branch pc-render).
## The choice lives in its own file, which the PC's watchdog
## (tools/link_server_watch.ps1) reads: it runs the link server or the PC app for
## the last two and nothing for the first. Only one of them may run: the SYSTEM
## agent (admin windows, UAC) serves one program at a time.

const OPENXR := 0
const HEADSET_WORLD := 1
const PC_DRAWS := 2

## Set by main.gd's REMOTE_ENV (PC_DRAWS) and by the watchdog for what it runs.
const REMOTE_ENV := "WORKPLACE_REMOTE"
const WATCHED_ENV := "WORKPLACE_WATCHED"
## The plain app started after a switch to OPENXR waits for the old one to end.
const OPENXR_START_DELAY_SEC := 3

## In the headset app (headset_boot.gd sets it, a method, not a lambda): asks the
## PC to switch to the mode given, returns what went wrong ("" if sent).
static var remote_switch := Callable()


static func name_of(mode: int) -> String:
	return ["OpenXR на ПК (Link, SteamVR…)", "мир в шлеме", "ПК рисует"][clampi(mode, 0, 2)]


## The mode this process runs in.
static func current() -> int:
	if OS.has_feature("android"):
		return HEADSET_WORLD
	if OS.get_environment(REMOTE_ENV) != "":
		return PC_DRAWS
	return OPENXR


## %LOCALAPPDATA%\WoRkPlace\work_mode.txt (the watchdog reads the same file).
static func file_path() -> String:
	return OS.get_environment("LOCALAPPDATA").path_join("WoRkPlace").path_join("work_mode.txt")


static func parse(text: String) -> int:
	var stripped := text.strip_edges()
	if not stripped.is_valid_int():
		return -1
	var mode := stripped.to_int()
	return mode if mode >= OPENXR and mode <= PC_DRAWS else -1


static func write(mode: int) -> bool:
	DirAccess.make_dir_recursive_absolute(file_path().get_base_dir())
	var file := FileAccess.open(file_path(), FileAccess.WRITE)
	if file == null:
		print("[mode] не записать %s: %d" % [file_path(), FileAccess.get_open_error()])
		return false
	file.store_string("%d\n" % mode)
	file.close()
	return true


## On the PC: makes `mode` the chosen one and starts what runs it; the caller
## quits right after. The watchdog is started if it is not running (it holds a
## mutex, a second one ends at once); the plain app for OPENXR is started here.
static func switch_to(mode: int) -> void:
	print("[mode] переключаюсь: %s" % name_of(mode))
	write(mode)
	var tools := ProjectSettings.globalize_path("res://").trim_suffix("/").path_join("tools")
	OS.create_process("powershell.exe", ["-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass",
			"-File", tools.path_join("link_server_watch.ps1")])
	if mode == OPENXR:
		var command := "Start-Sleep -Seconds %d; Start-Process -FilePath '%s' -ArgumentList '--path','%s'" % [
			OPENXR_START_DELAY_SEC, OS.get_executable_path(), ProjectSettings.globalize_path("res://").trim_suffix("/")]
		OS.create_process("powershell.exe", ["-NoProfile", "-WindowStyle", "Hidden", "-Command", command])
