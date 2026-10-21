class_name ScreenPanel
extends Node
## One Windows monitor as a live panel: a capture, and an OpenXR composition layer
## that shows it. The runtime samples a composition layer directly, which is
## noticeably sharper for text than a textured mesh. A flat panel is a quad layer,
## a curved one a cylinder layer.
##
## Do NOT put the capture texture on a 3D material: in VR that removes the D3D12
## device (0x887A0005) and crashes the engine.

## The grips around a panel, all in the gap under it (the screen's own edges stay
## free for scroll bars): move in the middle, tilt to the left, curve to the
## right, resize at the bottom-right corner, and at the far left a button that
## makes this monitor the primary one in Windows; at the far right one that opens
## the monitor's menu (resolution, refresh rate, scale), if enabled in settings.
enum Grip { NONE, MOVE, RESIZE, TILT, CURVE, PRIMARY, MENU }

const GRIP_NAMES := {Grip.MOVE: "перенос", Grip.RESIZE: "размер", Grip.TILT: "наклон", Grip.CURVE: "изгиб", Grip.PRIMARY: "сделать основным", Grip.MENU: "настройки экрана"}

var monitor_name := ""
## What VR sizes, places, tilts and saved arrangements are kept under: the
## monitor's device path, which stays the same when the driver restarts (the
## \\.\DISPLAYnn names change); the name if the path is not known.
var monitor_key := ""
## The monitor's rectangle on the Windows virtual desktop, in pixels.
var monitor_rect := Rect2i()
var primary := false
var capture: ScreenCapture
var layer: OpenXRCompositionLayer
## Where the layout put the panel; its size already includes `vr_scale`.
var placement: PanelLayout.Placement
## Size in VR only, relative to the layout; Windows does not see it.
var vr_scale := 1.0
## The distance of the panels from the eye, for the curvature.
var distance := 1.0

## A panel keeps being redrawn every frame for this long after its picture last changed.
const ACTIVE_HOLD_SEC := 1.0
## Below the bottom edge, to the middle of the grips.
const GRIP_DROP := 0.036
const GRIP_SIZES := {Grip.MOVE: Vector2(0.18, 0.022), Grip.TILT: Vector2(0.07, 0.022),
		Grip.CURVE: Vector2(0.07, 0.022), Grip.RESIZE: Vector2(0.045, 0.045), Grip.PRIMARY: Vector2(0.03, 0.03),
		Grip.MENU: Vector2(0.03, 0.03)}
## Hit areas are larger than the drawn shapes: a hand ray is not that steady.
const GRIP_HITS := {Grip.MOVE: Vector2(0.22, 0.06), Grip.TILT: Vector2(0.09, 0.06),
		Grip.CURVE: Vector2(0.09, 0.06), Grip.RESIZE: Vector2(0.08, 0.08), Grip.PRIMARY: Vector2(0.06, 0.06),
		Grip.MENU: Vector2(0.06, 0.06)}
const SIDE_GRIP_OFFSET := 0.175
const PRIMARY_GRIP_OFFSET := 0.29
const GRIP_COLOR := Color(0.85, 0.88, 0.95, 0.55)
const GRIP_HOVER_COLOR := Color(1.0, 1.0, 1.0, 0.95)
const GRIP_ACTIVE_COLOR := Color(0.35, 0.8, 1.0, 1.0)

var _viewport: SubViewport
var _origin: XROrigin3D
var _hole_punch := false
var _rendered_frame := 0
var _active_until := 0.0
var _grips := {}
var _grip_label: Label3D
## The panel's back: a dark plate a little behind it, flat or curved like it.
## A composition layer is seen from the front only, so from behind the screen
## just vanished (20.10.2026); the plate is ordinary geometry, so it also hides
## the screens behind it as a real monitor would.
var _back: MeshInstance3D
var _back_shape := ""
const BACK_GAP := 0.012
const BACK_COLOR := Color(0.11, 0.12, 0.14)


## `monitor` is an entry of ScreenCapture.list_monitors() and `monitor_index` its
## index. The layer has to be a child of the XR origin. Returns null, after
## printing the reason, if the capture cannot be started.
static func create(monitor_index: int, monitor: Dictionary, origin: XROrigin3D, hole_punch: bool) -> ScreenPanel:
	var new_capture := ScreenCapture.new()
	if not new_capture.start(monitor_index):
		print("[capture] %s: ошибка: %s" % [monitor["name"], new_capture.get_last_error()])
		return null

	var panel := ScreenPanel.new()
	panel.capture = new_capture
	panel.monitor_name = monitor["name"]
	var path := str(monitor.get("path", ""))
	panel.monitor_key = key_of(path) if path != "" else panel.monitor_name
	panel.monitor_rect = Rect2i(monitor["position"], new_capture.get_size())
	panel.primary = monitor["primary"]
	panel._origin = origin
	panel._hole_punch = hole_punch

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
	panel._make_layer(false)

	for grip: int in GRIP_SIZES:
		panel._grips[grip] = _flat_quad(GRIP_SIZES[grip])
		panel.add_child(panel._grips[grip])
	panel._grip_label = Label3D.new()
	panel._grip_label.pixel_size = 0.0008
	panel._grip_label.font_size = 28
	panel._grip_label.outline_size = 8
	panel._grip_label.no_depth_test = true
	panel._grip_label.render_priority = 11
	panel.add_child(panel._grip_label)
	panel.show_grips(false, [], Grip.NONE, Grip.NONE)
	var back_material := StandardMaterial3D.new()
	back_material.albedo_color = BACK_COLOR
	back_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	panel._back = MeshInstance3D.new()
	panel._back.material_override = back_material
	panel._back.visible = false
	panel.add_child(panel._back)
	return panel


## Shows the back plate only when `head` is behind the panel (from the front the
## screen itself is there) and the panel is drawn at all.
func update_back(head: Vector3, shown: bool) -> void:
	if _back == null or placement == null:
		return
	_back.visible = shown and (head - placement.transform.origin).dot(placement.transform.basis.z) < 0.0


## The back plate's mesh in the panel's own frame (+Z towards the viewer): flat,
## or the same arc as a curved panel, BACK_GAP behind it.
static func back_mesh(size: Vector2, curvature: float, distance: float) -> ArrayMesh:
	var columns := 1 if curvature <= 0.0 else 24
	var radius := PanelLayout.curve_radius(curvature, distance)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var points: Array[Vector3] = []
	for i in columns + 1:
		var share := float(i) / columns
		var at := Vector3((share - 0.5) * size.x, 0.0, -BACK_GAP)
		if columns > 1:
			# On the arc (edges bend towards the viewer), moved out by the gap.
			var angle := (share - 0.5) * size.x / radius
			at = Vector3((radius + BACK_GAP) * sin(angle), 0.0, radius - (radius + BACK_GAP) * cos(angle))
		points.append(at)
	for i in columns:
		var a := points[i]
		var b := points[i + 1]
		var half := Vector3(0.0, size.y * 0.5, 0.0)
		for corner: Vector3 in [a - half, b - half, b + half, a - half, b + half, a + half]:
			surface.add_vertex(corner)
	surface.generate_normals()
	return surface.commit()


func _make_layer(curved: bool) -> void:
	if layer != null:
		# A viewport can feed only one layer: let the old one go first, or the new
		# layer stays empty ("Cannot use the same SubViewport with multiple OpenXR
		# composition layers") until the freed one is really gone.
		layer.layer_viewport = null
		layer.queue_free()
	layer = OpenXRCompositionLayerCylinder.new() if curved else OpenXRCompositionLayerQuad.new()
	layer.layer_viewport = _viewport
	if _hole_punch:
		# Behind the scene with a hole punched through it, so hands and rays draw over the panel.
		# -2: the secure-desktop prompt (main.gd, -1) sits between the panels and the scene.
		layer.sort_order = -2
		layer.enable_hole_punch = true
	_origin.add_child(layer)


## The part of a monitor's device path that stays the same: from
## "\\?\DISPLAY#MTT1337#1&2240405a&2&UID256#{...}" it is "MTT1337#1&2240405a&UID256".
## The third part ("&2") changed when the driver was reinstalled (18.10.2026), so
## saved places were not found. Anything else is returned as it is.
static func key_of(path: String) -> String:
	var parts := path.split("#")
	if parts.size() < 3 or not parts[0].ends_with("DISPLAY"):
		return path
	var instance := parts[2].split("&")
	if instance.size() == 4:
		instance.remove_at(2)
	return parts[1] + "#" + "&".join(instance)


static func _flat_quad(size: Vector2) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = GRIP_COLOR
	# Over everything, the hole punched for a neighbouring panel included.
	material.no_depth_test = true
	material.render_priority = 10
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	return instance


## The layer is a child of the origin but belongs at a fixed place in the world,
## so it is positioned globally. A curved panel's cylinder layer sits at the
## cylinder's axis, `radius` in front of the middle of the arc.
func place(new_placement: PanelLayout.Placement) -> void:
	placement = new_placement
	var curved := placement.curvature > 0.0
	if curved != (layer is OpenXRCompositionLayerCylinder):
		_make_layer(curved)
	# The shape only when it changed: each change may rebuild the layer's mesh (its
	# hole punch), and a wall being bent changes it every frame (21.10.2026: the
	# bend handle dropped the frame rate to ~20).
	if curved:
		var cylinder := layer as OpenXRCompositionLayerCylinder
		var radius := PanelLayout.curve_radius(placement.curvature, distance)
		if not is_equal_approx(cylinder.radius, radius):
			cylinder.radius = radius
		if not is_equal_approx(cylinder.central_angle, placement.size.x / radius):
			cylinder.central_angle = placement.size.x / radius
		if not is_equal_approx(cylinder.aspect_ratio, placement.size.x / placement.size.y):
			cylinder.aspect_ratio = placement.size.x / placement.size.y
		layer.global_transform = placement.transform * Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, radius))
	else:
		var quad := layer as OpenXRCompositionLayerQuad
		if not quad.quad_size.is_equal_approx(placement.size):
			quad.quad_size = placement.size
		layer.global_transform = placement.transform
	if _back != null:
		var shape := "%s|%s|%s" % [placement.size, placement.curvature, distance]
		if shape != _back_shape:
			_back_shape = shape
			_back.mesh = back_mesh(placement.size, placement.curvature, distance)
		_back.global_transform = placement.transform
	for grip: int in _grips:
		(_grips[grip] as Node3D).global_transform = _grip_transform(grip)


## Where a grip sits, in world space.
func _grip_transform(grip: int) -> Transform3D:
	var below := -placement.size.y * 0.5 - GRIP_DROP
	match grip:
		Grip.TILT:
			return placement.transform * Transform3D(Basis.IDENTITY, Vector3(-SIDE_GRIP_OFFSET, below, 0.0))
		Grip.CURVE:
			return placement.transform * Transform3D(Basis.IDENTITY, Vector3(SIDE_GRIP_OFFSET, below, 0.0))
		Grip.PRIMARY:
			return placement.transform * Transform3D(Basis.IDENTITY, Vector3(-PRIMARY_GRIP_OFFSET, below, 0.0))
		Grip.MENU:
			return placement.transform * Transform3D(Basis.IDENTITY, Vector3(PRIMARY_GRIP_OFFSET, below, 0.0))
		Grip.RESIZE:
			var edge := _edge(1.0)
			return placement.transform * Transform3D(Basis.IDENTITY,
					Vector3(edge.x + 0.011, -placement.size.y * 0.5 - 0.011, edge.y))
	return placement.transform * Transform3D(Basis.IDENTITY, Vector3(0.0, below, 0.0))


## The right (side = 1) or left edge in the panel's own frame: (x, z towards the viewer).
func _edge(side: float) -> Vector2:
	if placement.curvature <= 0.0:
		return Vector2(side * placement.size.x * 0.5, 0.0)
	var radius := PanelLayout.curve_radius(placement.curvature, distance)
	var angle := placement.size.x * 0.5 / radius
	return Vector2(side * radius * sin(angle), radius * (1.0 - cos(angle)))


## The grip a ray points at, and how far along the ray: Vector2(grip, distance).
## Only grips in `allowed` count.
func grip_at(origin: Vector3, direction: Vector3, allowed: Array) -> Vector2:
	var best := Vector2(Grip.NONE, INF)
	for grip: int in allowed:
		var distance_along := PointerMath.ray_rect_distance(origin, direction, _grip_transform(grip), GRIP_HITS[grip])
		if distance_along >= 0.0 and distance_along < best.y:
			best = Vector2(grip, distance_along)
	return best


## The ray passes over the panel or close around it (where the grips are).
func is_near(origin: Vector3, direction: Vector3) -> bool:
	return PointerMath.ray_rect_distance(origin, direction, placement.transform,
			placement.size + Vector2(0.2, 0.25)) >= 0.0


## Shows the grips in `allowed` (or none); `hovered` is lit, `held` coloured, and
## the name of whichever of them is pointed at or held is written under it.
func show_grips(visible: bool, allowed: Array, hovered: int, held: int) -> void:
	for grip: int in _grips:
		var shown := visible and allowed.has(grip)
		var mesh := _grips[grip] as MeshInstance3D
		mesh.visible = shown
		var color := GRIP_ACTIVE_COLOR if grip == held else (GRIP_HOVER_COLOR if grip == hovered else GRIP_COLOR)
		(mesh.material_override as StandardMaterial3D).albedo_color = color
	var named := held if held != Grip.NONE else hovered
	_grip_label.visible = visible and named != Grip.NONE
	if _grip_label.visible:
		_grip_label.text = GRIP_NAMES[named]
		_grip_label.global_transform = _grip_transform(named) * Transform3D(Basis.IDENTITY, Vector3(0.0, -0.045, 0.0))


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


## Whether the layer is redrawn on every frame now (its picture is changing).
func is_redrawing() -> bool:
	return _viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS


## Distance along the ray to this panel, or -1.0 on a miss.
func hit_distance(origin: Vector3, direction: Vector3) -> float:
	if placement.curvature > 0.0:
		return PointerMath.ray_arc(origin, direction, placement.transform, placement.size,
				PanelLayout.curve_radius(placement.curvature, distance)).x
	return PointerMath.ray_rect_distance(origin, direction, placement.transform, placement.size)


## Where a world point on the panel lies: 0..1 from its top-left corner.
func uv_at(point: Vector3) -> Vector2:
	if placement.curvature > 0.0:
		var radius := PanelLayout.curve_radius(placement.curvature, distance)
		var local := placement.transform.affine_inverse() * point - Vector3(0.0, 0.0, radius)
		return Vector2(atan2(local.x, -local.z) * radius / placement.size.x + 0.5, 0.5 - local.y / placement.size.y)
	return PointerMath.rect_uv(point, placement.transform, placement.size)


## The pixel on the Windows virtual desktop under a point of the panel.
func pixel_at(uv: Vector2) -> Vector2:
	return Vector2(monitor_rect.position) + uv * Vector2(monitor_rect.size - Vector2i.ONE)


func close() -> void:
	capture.stop()
	layer.queue_free()
	queue_free()  # the grips are children
