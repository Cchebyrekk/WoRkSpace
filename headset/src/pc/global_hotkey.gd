class_name GlobalHotkey
extends RefCounted
## Headset stand-in for the PC module's GlobalHotkey (slice o5): there is no PC
## keyboard here, so the emergency shortcut never fires; the Meta button and the
## app's own exit do the job.


func start(_ctrl: bool, _alt: bool, _shift: bool, _virtual_key: int) -> bool:
	return false


func stop() -> void:
	pass


func consume_pressed() -> bool:
	return false
