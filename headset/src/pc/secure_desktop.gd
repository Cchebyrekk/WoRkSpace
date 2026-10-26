class_name SecureDesktop
extends RefCounted
## Headset stand-in for the PC module's SecureDesktop (slice o5): the secure
## desktop's picture (UAC, lock screen) does not come over the link yet (o5b).


func update() -> bool:
	return false


func get_texture() -> Texture2D:
	return null


func get_frame_size() -> Vector2i:
	return Vector2i.ZERO


func get_frame_origin() -> Vector2i:
	return Vector2i.ZERO
