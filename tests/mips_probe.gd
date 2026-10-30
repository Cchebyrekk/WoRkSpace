extends SceneTree
## Probe for PanelMips (branch pc-render): a red viewport through PanelMips on a
## quad in front of the camera; prints the colour in the middle of the window.

var _mips := PanelMips.new()
var _viewport := SubViewport.new()
var _frames := 0
var _material: StandardMaterial3D


func _initialize() -> void:
	_viewport.size = Vector2i(512, 256)
	_viewport.disable_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var rect := ColorRect.new()
	rect.color = Color.RED
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_viewport.add_child(rect)
	root.add_child(_viewport)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_material = material
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.material_override = material
	quad.position = Vector3(0, 0, -1)
	root.add_child(quad)
	var camera := Camera3D.new()
	root.add_child(camera)


func _process(_delta: float) -> bool:
	_frames += 1
	RenderingServer.call_on_render_thread(_mips.update.bind(_viewport.get_texture().get_rid()))
	if _frames == 10:
		_material.albedo_texture = _mips.texture
	if _frames == 30:
		var image := root.get_texture().get_image()
		print("[probe] середина окна: ", image.get_pixel(image.get_width() / 2, image.get_height() / 2),
				", rd rid ", _mips.texture.texture_rd_rid, ", rs rid ", _mips.texture.get_rid())
		return true
	return false
