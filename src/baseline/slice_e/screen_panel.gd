class_name ScreenPanelE
extends Node
## One Windows monitor as a live panel: a capture, and an OpenXR composition layer
## that shows it. The runtime samples a composition layer directly, which is
## noticeably sharper for text than a textured mesh.
##
## Do NOT put the capture texture on a 3D material: in VR that removes the D3D12
## device (0x887A0005) and crashes the engine.

var monitor_name := ""
## The monitor's rectangle on the Windows virtual desktop, in pixels.
var monitor_rect := Rect2i()
var primary := false
var capture: ScreenCapture
var layer: OpenXRCompositionLayerQuad

## A panel keeps being redrawn every frame for this long after its picture last changed.
const ACTIVE_HOLD_SEC := 1.0

var _viewport: SubViewport
var _rendered_frame := 0
var _active_until := 0.0


## `monitor` is an entry of ScreenCapture.list_monitors() and `monitor_index` its
## index. The layer has to be a child of the XR origin. Returns null, after
## printing the reason, if the capture cannot be started.
static func create(monitor_index: int, monitor: Dictionary, origin: XROrigin3D, hole_punch: bool) -> ScreenPanelE:
	var new_capture := ScreenCapture.new()
	if not new_capture.start(monitor_index):
		print("[capture] %s: ошибка: %s" % [monitor["name"], new_capture.get_last_error()])
		return null

	var panel := ScreenPanelE.new()
	panel.capture = new_capture
	panel.monitor_name = monitor["name"]
	panel.monitor_rect = Rect2i(monitor["position"], new_capture.get_size())
	panel.primary = monitor["primary"]

	var picture := TextureRect.new()
	picture.texture = new_capture.get_texture()
	picture.stretch_mode = TextureRect.STRETCH_SCALE
	picture.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel._viewport = SubViewport.new()
	panel._viewport.size = panel.monitor_rect.size
	panel._viewport.disable_3d = true
	# Drawn on demand, see refresh().
	panel._viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	panel._viewport.add_child(picture)
	panel.add_child(panel._viewport)

	panel.layer = OpenXRCompositionLayerQuad.new()
	panel.layer.layer_viewport = panel._viewport
	if hole_punch:
		# Behind the scene with a hole punched through it, so hands and rays draw over the panel.
		panel.layer.sort_order = -1
		panel.layer.enable_hole_punch = true
	origin.add_child(panel.layer)
	return panel


## The layer is a child of the origin but belongs at a fixed place in the world,
## so it is positioned globally.
func place(placement: PanelLayoutE.Placement) -> void:
	layer.quad_size = placement.size
	layer.global_transform = placement.transform


## Call every frame. Brings the texture up to date and decides whether the layer
## is redrawn. A panel whose picture changes is redrawn on every frame until it has
## been still for ACTIVE_HOLD_SEC; then it stops and keeps showing the last picture,
## so an idle monitor costs nothing. Redrawing only on frames that bring a new
## picture made busy panels flicker: the capture (~60 Hz) and the headset (72 Hz)
## do not line up, and on the frames in between the layer showed an older image.
## Drawing before the session is visible makes OpenXR acquire the layer's
## swapchain image twice ("image_acquired" errors).
func refresh(session_visible: bool, copy_frames: bool, now: float) -> void:
	if copy_frames:
		capture.update()
	var frame := capture.get_frame_count()
	if frame != _rendered_frame:
		_rendered_frame = frame
		_active_until = now + ACTIVE_HOLD_SEC
	var mode := SubViewport.UPDATE_ALWAYS if session_visible and now < _active_until else SubViewport.UPDATE_DISABLED
	if _viewport.render_target_update_mode != mode:
		_viewport.render_target_update_mode = mode


## Distance along the ray to this panel, or -1.0 on a miss.
func hit_distance(origin: Vector3, direction: Vector3) -> float:
	return PointerMathE.ray_rect_distance(origin, direction, layer.global_transform, layer.quad_size)


## Where a world point lies on the panel: 0..1 from its top-left corner.
func uv_at(point: Vector3) -> Vector2:
	return PointerMathE.rect_uv(point, layer.global_transform, layer.quad_size)


## The pixel on the Windows virtual desktop under a point of the panel.
func pixel_at(uv: Vector2) -> Vector2:
	return Vector2(monitor_rect.position) + uv * Vector2(monitor_rect.size - Vector2i.ONE)


func close() -> void:
	capture.stop()
	layer.queue_free()
	queue_free()
