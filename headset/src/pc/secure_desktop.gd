class_name SecureDesktop
extends RefCounted
## Headset stand-in for the PC module's SecureDesktop (slice o5b): the secure
## desktop's picture (UAC, lock screen) comes from the PC as JPEG while it is up
## (PcLink.secure_image); clicks on it go back through MouseInput as usual.

var _texture: ImageTexture
var _sequence := 0
var _size := Vector2i.ZERO


## True when a new picture came since the last call.
func update() -> bool:
	if PcLink.secure_image == null or PcLink.secure_sequence == _sequence:
		return false
	_sequence = PcLink.secure_sequence
	var image := PcLink.secure_image
	if _texture == null or _size != image.get_size():
		_texture = ImageTexture.create_from_image(image)
	else:
		_texture.update(image)
	_size = image.get_size()
	return true


func get_texture() -> Texture2D:
	return _texture


func get_frame_size() -> Vector2i:
	return _size


func get_frame_origin() -> Vector2i:
	return PcLink.secure_origin
