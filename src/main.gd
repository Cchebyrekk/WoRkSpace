extends Node3D
## Slice (a): empty VR scene that proves OpenXR, hand joints and controllers
## arrive through Quest Link. Everything is built in code; no gameplay yet.

const HAND_TRACKER_NAMES: Array[StringName] = [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]
const CONTROLLER_TRACKER_NAMES: Array[StringName] = [&"left_hand", &"right_hand"]
const SIDE_LABELS: Array[String] = ["Левая", "Правая"]
const HAND_SOURCE_LABELS: Array[String] = ["неизвестен", "камеры шлема", "контроллер", "нет"]
const JOINT_RADIUS := 0.008
const RAY_LENGTH := 2.0
const LOG_INTERVAL_SEC := 1.0

var _origin: XROrigin3D
var _controllers: Array[XRController3D] = []
var _controller_visuals: Array[Node3D] = []
var _joint_meshes: Array[MultiMeshInstance3D] = []
var _status: Label3D
var _log_timer := 0.0
var _xr_ready := false


func _ready() -> void:
	_build_world()
	_build_rig()

	var xr: XRInterface = XRServer.find_interface("OpenXR")
	if xr == null or not xr.is_initialized():
		push_error("[xr] OpenXR не инициализирован. Шлем подключён через Link и Link активен?")
		_status.text = "OpenXR не инициализирован"
		return

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_viewport().use_xr = true
	_xr_ready = true

	print("[xr] система: ", xr.get_system_info())
	print("[xr] рендерер: ", RenderingServer.get_current_rendering_driver_name(),
			" / ", RenderingServer.get_current_rendering_method())
	var openxr := xr as OpenXRInterface
	if openxr != null:
		print("[xr] расширение hand tracking поддерживается средой: ", openxr.is_hand_tracking_supported())
		openxr.session_begun.connect(_on_session_begun.bind(openxr))


func _process(delta: float) -> void:
	if not _xr_ready:
		return

	var lines: PackedStringArray = []
	for i in 2:
		var joints := _update_hand(i)
		var controller := _controllers[i]
		var controller_tracked := controller.get_has_tracking_data()
		_controller_visuals[i].visible = controller_tracked
		lines.append("%s: суставов %d/%d (источник: %s) | контроллер: %s, триггер %.2f, grip %.2f, стик %s" % [
			SIDE_LABELS[i], joints, XRHandTracker.HAND_JOINT_MAX, _hand_source_label(i),
			"да" if controller_tracked else "нет",
			controller.get_float(&"trigger"), controller.get_float(&"grip"),
			controller.get_vector2(&"primary"),
		])
	_status.text = "\n".join(lines)

	_log_timer += delta
	if _log_timer >= LOG_INTERVAL_SEC:
		_log_timer = 0.0
		for line in lines:
			print("[track] ", line)


func _on_session_begun(openxr: OpenXRInterface) -> void:
	print("[xr] сессия начата, частота: ", openxr.display_refresh_rate, " Гц")


func _on_button_pressed(button: String, side: int) -> void:
	print("[input] ", SIDE_LABELS[side], " контроллер: нажато ", button)


## Moves the joint spheres of one hand; returns how many joints have a valid position.
func _update_hand(index: int) -> int:
	var mesh_instance := _joint_meshes[index]
	var tracker := XRServer.get_tracker(HAND_TRACKER_NAMES[index]) as XRHandTracker
	if tracker == null or not tracker.has_tracking_data:
		mesh_instance.visible = false
		return 0

	var valid := 0
	var multimesh := mesh_instance.multimesh
	for joint_index in XRHandTracker.HAND_JOINT_MAX:
		var joint := joint_index as XRHandTracker.HandJoint
		if tracker.get_hand_joint_flags(joint) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID:
			multimesh.set_instance_transform(valid, Transform3D(Basis.IDENTITY, tracker.get_hand_joint_transform(joint).origin))
			valid += 1
	multimesh.visible_instance_count = valid
	mesh_instance.visible = valid > 0
	return valid


func _hand_source_label(index: int) -> String:
	var tracker := XRServer.get_tracker(HAND_TRACKER_NAMES[index]) as XRHandTracker
	if tracker == null:
		return "трекера нет"
	var source := int(tracker.hand_tracking_source)
	return HAND_SOURCE_LABELS[source] if source < HAND_SOURCE_LABELS.size() else str(source)


func _build_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.05, 0.06, 0.08)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.6
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	add_child(light)

	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(6.0, 6.0)
	var floor_instance := MeshInstance3D.new()
	floor_instance.mesh = floor_mesh
	floor_instance.material_override = _flat_material(Color(0.15, 0.17, 0.2))
	add_child(floor_instance)

	_status = Label3D.new()
	_status.position = Vector3(0.0, 1.4, -1.2)
	_status.pixel_size = 0.0012
	_status.font_size = 40
	_status.outline_size = 8
	_status.text = "Запуск…"
	add_child(_status)


func _build_rig() -> void:
	_origin = XROrigin3D.new()
	add_child(_origin)
	_origin.add_child(XRCamera3D.new())

	var joint_mesh := SphereMesh.new()
	joint_mesh.radius = JOINT_RADIUS
	joint_mesh.height = JOINT_RADIUS * 2.0
	joint_mesh.radial_segments = 12
	joint_mesh.rings = 6
	var side_colors: Array[Color] = [Color(0.3, 0.7, 1.0), Color(1.0, 0.6, 0.3)]

	for i in 2:
		var controller := XRController3D.new()
		controller.tracker = CONTROLLER_TRACKER_NAMES[i]
		controller.pose = &"aim"
		controller.button_pressed.connect(_on_button_pressed.bind(i))
		_origin.add_child(controller)
		_controllers.append(controller)

		var visual := Node3D.new()
		visual.visible = false
		controller.add_child(visual)
		_controller_visuals.append(visual)

		var body_mesh := BoxMesh.new()
		body_mesh.size = Vector3(0.04, 0.04, 0.1)
		var body := MeshInstance3D.new()
		body.mesh = body_mesh
		body.material_override = _flat_material(side_colors[i])
		visual.add_child(body)

		var ray_mesh := BoxMesh.new()
		ray_mesh.size = Vector3(0.003, 0.003, RAY_LENGTH)
		var ray := MeshInstance3D.new()
		ray.mesh = ray_mesh
		ray.position = Vector3(0.0, 0.0, -RAY_LENGTH * 0.5)
		ray.material_override = _flat_material(side_colors[i])
		visual.add_child(ray)

		# Joint transforms are relative to the origin, so the spheres live under it.
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = joint_mesh
		multimesh.instance_count = XRHandTracker.HAND_JOINT_MAX
		multimesh.visible_instance_count = 0
		var joints := MultiMeshInstance3D.new()
		joints.multimesh = multimesh
		joints.material_override = _flat_material(side_colors[i])
		joints.visible = false
		_origin.add_child(joints)
		_joint_meshes.append(joints)


func _flat_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material
