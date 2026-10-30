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
## The longest side (px) of the picture handed to the layer (see layer_size).
const MAX_LAYER_SIDE := 4096
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
## A convex panel's picture: a curved mesh in the scene with the panel's own
## viewport texture (slice l, 22.10.2026: Quest Link does not draw a cylinder
## layer seen from outside — the picture was not there). Not the capture texture
## itself (that on a 3D material removed the D3D12 device), the viewport's.
var _surface: MeshInstance3D
## The thumbnail's own viewport (see thumbnail()).
var _thumb: SubViewport
const THUMB_WIDTH := 480
var _surface_shape := ""
var _origin: XROrigin3D
var _hole_punch := false
## In the headset (slice o5) the capture is a stand-in that has no texture: the
## PC's video stream is decoded straight into the layer's Android surface.
var _video := false
## In the headset a convex panel shows the stream on its curved mesh through this
## (slice o5d): a layer is not drawn from outside, and the decoded frames reach no
## viewport. `_video_convex` says the panel is in that state now.
var _external: ExternalTexture
var _video_convex := false
## Within main.gd's render radius (the last layer_shown).
var _in_range := true
## The decoder gives sRGB colours; the scene is drawn in linear ones.
const VIDEO_CONVEX_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform samplerExternalOES picture;
void fragment() {
	vec3 c = texture(picture, UV).rgb;
	ALBEDO = mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}
"""
## In the headset the hole for each layer is the panel's own mesh (_surface) with
## this: Godot's hole punch does not clear the alpha on the Compatibility renderer,
## and the walls, the grid and the buttons behind a screen were drawn over it
## (29.10.2026). Multiplying by 0 clears colour and alpha (transparent background).
const VIDEO_HOLE_SHADER := """
shader_type spatial;
render_mode blend_mul, unshaded, cull_disabled, shadows_disabled;
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
"""
static var _hole_material: ShaderMaterial
var _video_material: ShaderMaterial
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
	panel._video = new_capture.has_method("attach_layer")

	var picture := TextureRect.new()
	picture.texture = new_capture.get_texture()
	picture.stretch_mode = TextureRect.STRETCH_SCALE
	# Not at least the texture's own size: a monitor over MAX_LAYER_SIDE gets a smaller
	# viewport (layer_size), and a picture keeping its size spilled past it — the
	# right and lower parts were cut off and the cursor missed (23.10.2026, 4632×3576).
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel._viewport = SubViewport.new()
	panel._viewport.size = layer_size(panel.monitor_rect.size)
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
	var surface_material := StandardMaterial3D.new()
	surface_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	surface_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	surface_material.albedo_texture = panel._viewport.get_texture()
	panel._surface = MeshInstance3D.new()
	panel._surface.material_override = surface_material
	if panel._video:
		panel._surface.material_override = hole_material()
	panel._surface.visible = false
	panel.add_child(panel._surface)
	return panel


## Shows the back plate only when `head` is behind the panel (from the front the
## screen itself is there) and the panel is drawn at all.
func update_back(head: Vector3, shown: bool) -> void:
	if _back == null or placement == null:
		return
	_back.visible = shown and (head - placement.transform.origin).dot(placement.transform.basis.z) < 0.0
	_surface.visible = shown and (placement.curvature < 0.0 or (_video and _hole_punch))


## The back plate's mesh in the panel's own frame (+Z towards the viewer): flat,
## or the same arc as a curved panel, `gap` behind it (0: on the panel itself,
## with `uv` the picture's coordinates, left to right and top to bottom).
static func back_mesh(size: Vector2, curvature: float, distance: float, gap := BACK_GAP, uv := false) -> ArrayMesh:
	var columns := 1 if curvature == 0.0 else 24
	var radius := PanelLayout.curve_radius(curvature, distance)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var points: Array[Vector3] = []
	for i in columns + 1:
		var share := float(i) / columns
		var at := Vector3((share - 0.5) * size.x, 0.0, -gap)
		if columns > 1 and radius > 0.0:
			# On the arc (edges bend towards the viewer), moved out by the gap.
			var angle := (share - 0.5) * size.x / radius
			at = Vector3((radius + gap) * sin(angle), 0.0, radius - (radius + gap) * cos(angle))
		elif columns > 1:
			# Convex: the edges bend away, the axis behind; the gap is towards it.
			var bulge := -radius
			var angle := (share - 0.5) * size.x / bulge
			at = Vector3((bulge - gap) * sin(angle), 0.0, -bulge + (bulge - gap) * cos(angle))
		points.append(at)
	for i in columns:
		var a := points[i]
		var b := points[i + 1]
		var half := Vector3(0.0, size.y * 0.5, 0.0)
		var left := float(i) / columns
		var right := float(i + 1) / columns
		var corners: Array[Vector3] = [a - half, b - half, b + half, a - half, b + half, a + half]
		var coords: Array[Vector2] = [Vector2(left, 1.0), Vector2(right, 1.0), Vector2(right, 0.0),
				Vector2(left, 1.0), Vector2(right, 0.0), Vector2(left, 0.0)]
		for k in corners.size():
			if uv:
				surface.set_uv(coords[k])
			surface.add_vertex(corners[k])
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
	if _video:
		layer.use_android_surface = true
		# The PC encodes at most 4096 on a side too (native video_stream.cpp).
		layer.android_surface_size = layer_size(monitor_rect.size)
		# On the Compatibility renderer the surface's picture came upside down
		# (29.10.2026); the Meta vendors plugin turns it back (ignored elsewhere).
		layer.set(&"XR_FB_composition_layer_image_layout/vertical_flip", true)
	else:
		layer.layer_viewport = _viewport
	if _hole_punch:
		# Behind the scene with a hole punched through it, so hands and rays draw over the panel.
		# -2: the secure-desktop prompt (main.gd, -1) sits between the panels and the scene.
		layer.sort_order = -2
		layer.enable_hole_punch = not _video
	_origin.add_child(layer)
	if _video and _video_convex:
		layer.visible = false
	elif _video:
		capture.call(&"attach_layer", layer)


## Whether the layer is drawn for a panel `in_range` (main.gd's render radius): a
## headset panel shown on its convex mesh keeps its layer hidden.
func layer_shown(in_range: bool) -> bool:
	_in_range = in_range
	return in_range and not _video_convex


## Whether the panel is drawn (within the render radius), on its layer or its
## convex mesh: rays and clicks go only to these. Not `layer.visible`: a headset
## convex panel hides its layer, and the ray went through it (30.10.2026).
func is_drawn() -> bool:
	return _in_range


## Moves a headset panel's stream between its layer and its convex mesh (see _external).
func _set_video_convex(convex: bool) -> void:
	_video_convex = convex
	layer.visible = not convex
	if convex:
		if _external == null:
			_external = ExternalTexture.new()
			# An external (decoder's) picture is read only through samplerExternalOES,
			# which StandardMaterial3D does not use (Compatibility renderer, slice o5d).
			_video_material = ShaderMaterial.new()
			_video_material.shader = Shader.new()
			_video_material.shader.code = VIDEO_CONVEX_SHADER
			_video_material.set_shader_parameter(&"picture", _external)
		_surface.material_override = _video_material
		capture.call(&"attach_texture", _external, _surface)
	else:
		_surface.material_override = hole_material()
		capture.call(&"attach_layer", layer)


## The headset's hole under a layer (see VIDEO_HOLE_SHADER), also for main.gd's UAC quad.
static func hole_material() -> ShaderMaterial:
	if _hole_material == null:
		_hole_material = ShaderMaterial.new()
		_hole_material.shader = Shader.new()
		_hole_material.shader.code = VIDEO_HOLE_SHADER
	return _hole_material


## The part of a monitor's device path that stays the same: from
## "\\?\DISPLAY#MTT1337#1&2240405a&2&UID256#{...}" it is "MTT1337#1&2240405a&UID256".
## The third part ("&2") changed when the driver was reinstalled (18.10.2026), so
## saved places were not found. Anything else is returned as it is.
## The picture the layer gets for a monitor of `pixels`: at most MAX_LAYER_SIDE
## on its longer side, its shape kept. 22.10.2026 a 5120×2160 screen made Quest
## Link refuse the layer's swapchain (XR_ERROR_FEATURE_UNSUPPORTED) and the GPU
## device was lost (0x887A0005); 3840×2160 had always worked. Clicks still map to
## the monitor's real pixels (monitor_rect).
static func layer_size(pixels: Vector2i) -> Vector2i:
	var longer := maxi(pixels.x, pixels.y)
	if longer <= MAX_LAYER_SIDE:
		return pixels
	var scale := float(MAX_LAYER_SIDE) / longer
	return Vector2i(maxi(roundi(pixels.x * scale), 1), maxi(roundi(pixels.y * scale), 1))


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
	# Convex (on a wall or a column, slice l): drawn as a mesh (_surface); its quad
	# layer stays, empty and without a hole, so the panel keeps its place in the list.
	var convex := placement.curvature < 0.0
	# A video layer stays as it is: its surface has no texture for the convex mesh.
	if not _video and convex == (layer.layer_viewport != null):
		layer.layer_viewport = null if convex else _viewport
		layer.enable_hole_punch = _hole_punch and not convex
	if _video and convex != _video_convex:
		_set_video_convex(convex)
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
	if convex or _video:
		if _surface_shape != _back_shape:
			_surface_shape = _back_shape
			_surface.mesh = back_mesh(placement.size, placement.curvature, distance, 0.0, true)
		_surface.global_transform = placement.transform
	elif _surface.visible:
		_surface.visible = false
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
	if placement.curvature == 0.0:
		return Vector2(side * placement.size.x * 0.5, 0.0)
	var radius := PanelLayout.curve_radius(placement.curvature, distance)
	var angle := placement.size.x * 0.5 / absf(radius)
	# Concave: the edges come towards the viewer; convex: they go away.
	return Vector2(side * absf(radius) * sin(angle), radius * (1.0 - cos(angle)))


## The grip a ray points at, and how far along the ray: Vector2(grip, distance).
## Only grips in `allowed` count.
func grip_at(origin: Vector3, direction: Vector3, allowed: Array) -> Vector2:
	var best := Vector2(Grip.NONE, INF)
	if not _in_front(origin):
		return best
	for grip: int in allowed:
		var distance_along := PointerMath.ray_rect_distance(origin, direction, _grip_transform(grip), GRIP_HITS[grip])
		if distance_along >= 0.0 and distance_along < best.y:
			best = Vector2(grip, distance_along)
	return best


## Whether a ray from `origin` can reach the panel's face: not from behind a flat
## one (on a column a ray between the near screens went on to the backs of the
## far ones, slice l).
func _in_front(origin: Vector3) -> bool:
	return placement.curvature > 0.0 or (placement.transform.affine_inverse() * origin).z > 0.0


## The ray passes over the panel or close around it (where the grips are).
func is_near(origin: Vector3, direction: Vector3) -> bool:
	return _in_front(origin) and PointerMath.ray_rect_distance(origin, direction, placement.transform,
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
	if _video:
		return  # The decoder draws into the layer itself; the viewport stays idle.
	var mode := SubViewport.UPDATE_ALWAYS if session_visible and now < _active_until else SubViewport.UPDATE_DISABLED
	if _viewport.render_target_update_mode != mode:
		_viewport.render_target_update_mode = mode


## Whether the layer is redrawn on every frame now (its picture is changing).
func is_redrawing() -> bool:
	return _viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS


## Distance along the ray to this panel, or -1.0 on a miss.
func hit_distance(origin: Vector3, direction: Vector3) -> float:
	if not _in_front(origin):
		return -1.0
	if placement.curvature != 0.0:
		return PointerMath.ray_arc(origin, direction, placement.transform, placement.size,
				PanelLayout.curve_radius(placement.curvature, distance)).x
	return PointerMath.ray_rect_distance(origin, direction, placement.transform, placement.size)


## Where a world point on the panel lies: 0..1 from its top-left corner.
func uv_at(point: Vector3) -> Vector2:
	if placement.curvature != 0.0:
		var radius := PanelLayout.curve_radius(placement.curvature, distance)
		var local := placement.transform.affine_inverse() * point - Vector3(0.0, 0.0, radius)
		return Vector2(atan2(local.x, -signf(radius) * local.z) * absf(radius) / placement.size.x + 0.5, 0.5 - local.y / placement.size.y)
	return PointerMath.rect_uv(point, placement.transform, placement.size)


## The pixel on the Windows virtual desktop under a point of the panel.
func pixel_at(uv: Vector2) -> Vector2:
	return Vector2(monitor_rect.position) + uv * Vector2(monitor_rect.size - Vector2i.ONE)


## A small picture of the monitor for the plane of groups (slice n): a viewport of
## its own, not the panel's one (that draws into its OpenXR layer, and its texture
## was black on the plane, 23.10.2026), nor the capture texture itself (which must
## not go on a 3D material). Drawn only while `set_thumbnail_live(true)`.
func thumbnail() -> Texture2D:
	if _thumb == null:
		_thumb = SubViewport.new()
		_thumb.size = Vector2i(THUMB_WIDTH, maxi(roundi(THUMB_WIDTH * float(monitor_rect.size.y) / maxf(monitor_rect.size.x, 1.0)), 1))
		_thumb.disable_3d = true
		_thumb.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var small := TextureRect.new()
		small.texture = capture.get_texture()
		small.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		small.stretch_mode = TextureRect.STRETCH_SCALE
		small.set_anchors_preset(Control.PRESET_FULL_RECT)
		_thumb.add_child(small)
		add_child(_thumb)
	return _thumb.get_texture()


func set_thumbnail_live(live: bool) -> void:
	if _video:
		# In the headset the picture comes from the PC, which sends it only on demand.
		capture.call(&"set_thumbnail_live", live)
	if _thumb != null:
		_thumb.render_target_update_mode = SubViewport.UPDATE_ALWAYS if live else SubViewport.UPDATE_DISABLED


func close() -> void:
	capture.stop()
	layer.queue_free()
	queue_free()  # the grips are children
