extends Node3D
var _controllers: Array[XRController3D] = []
var _labels: Array[Label3D] = []
var _pressed := [false, false]
var _pulse_counts := [0, 0]
var _hand_input := PacketPeerUDP.new()
var _hand_meshes: Array[MeshInstance3D] = []
var _hand_seen := 0
var _hand_lines: Array[MeshInstance3D] = []
## Standalone VR application: static geometry, no WoRkPlace layout or RemoteXR.
## Run with XR_RUNTIME_JSON pointing to SteamVR's manifest, never Meta's.

func _ready() -> void:
	_hand_input.bind(47923, "127.0.0.1")
	for h in 2:
		var lines := MeshInstance3D.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1, 0.7, 0) if h == 0 else Color(0, 0.8, 1)
		lines.material_override = mat
		add_child(lines)
		_hand_lines.append(lines)
	for hand in 2:
		for joint in 26:
			var marker := MeshInstance3D.new()
			var sphere := SphereMesh.new()
			sphere.radius = 0.006
			sphere.height = 0.012
			marker.mesh = sphere
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_color = Color(1, 0.7, 0) if hand == 0 else Color(0, 0.8, 1)
			marker.material_override = mat
			marker.visible = false
			add_child(marker)
			_hand_meshes.append(marker)
	var xr := XRServer.find_interface("OpenXR")
	if xr == null or not xr.is_initialized():
		push_error("[room] OpenXR not initialized")
		get_tree().quit(1)
		return
	get_viewport().use_xr = true
	var origin := XROrigin3D.new()
	add_child(origin)
	var camera := XRCamera3D.new()
	origin.add_child(camera)
	for hand in 2:
		var controller := XRController3D.new()
		controller.tracker = &"left_hand" if hand == 0 else &"right_hand"
		controller.pose = &"grip"
		origin.add_child(controller)
		_controllers.append(controller)
		var readout := Label3D.new()
		readout.position = Vector3(-0.65 if hand == 0 else 0.65, 1.9, -1.4)
		readout.pixel_size = 0.001
		readout.font_size = 22
		add_child(readout)
		_labels.append(readout)
		var marker := MeshInstance3D.new()
		var marker_mesh := BoxMesh.new()
		marker_mesh.size = Vector3(0.04, 0.04, 0.18)
		marker.mesh = marker_mesh
		var marker_material := StandardMaterial3D.new()
		marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		marker_material.albedo_color = Color(1, 0.7, 0) if hand == 0 else Color(0, 0.8, 1)
		marker.material_override = marker_material
		controller.add_child(marker)
		controller.tracking_changed.connect(_controller_tracking.bind(controller))
		controller.visible = false
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.025, 0.035, 0.06)
	add_child(environment)
	# White square grid at z=-2: every line must stay straight while turning.
	for i in range(-6, 7):
		_box(Vector3(i * 0.25, 1.5, -2.0), Vector3(0.008, 3.0, 0.008), Color(0.65, 0.7, 0.8))
	for i in range(13):
		_box(Vector3(0, i * 0.25, -2.0), Vector3(3.0, 0.008, 0.008), Color(0.65, 0.7, 0.8))
	_box(Vector3(-0.7, 1.4, -1.0), Vector3(0.2, 0.2, 0.2), Color(1.0, 0.15, 0.1))
	_box(Vector3(0, 1.4, -2.0), Vector3(0.3, 0.3, 0.3), Color(0.1, 1.0, 0.2))
	_box(Vector3(0.8, 1.4, -3.0), Vector3(0.4, 0.4, 0.4), Color(0.2, 0.4, 1.0))
	var label := Label3D.new()
	label.text = "STEAMVR GEOMETRY TEST\nSTATIC GRID / RED NEAR / BLUE FAR"
	label.position = Vector3(0, 2.4, -2)
	label.pixel_size = 0.001
	label.font_size = 30
	add_child(label)
	print("[room] OpenXR initialized; static geometry test running")


func _box(at: Vector3, size: Vector3, color: Color) -> void:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	node.material_override = material
	node.position = at
	add_child(node)


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_tree().quit()


func _controller_tracking(tracking: bool, controller: XRController3D) -> void:
	controller.visible = tracking
	print("[room] controller ", controller.tracker, " tracked: ", tracking)


func _process(_delta: float) -> void:
	while _hand_input.get_available_packet_count() > 0:
		var hands: Variant = bytes_to_var(_hand_input.get_packet())
		if not hands is Array or hands.size() != 2:
			continue
		_hand_seen = Time.get_ticks_msec()
		for h in 2:
			var data: Dictionary = hands[h]
			var joints: PackedFloat32Array = data.get("joints", PackedFloat32Array())
			var flags: PackedInt32Array = data.get("flags", PackedInt32Array())
			for j in 26:
				var marker := _hand_meshes[h * 26 + j]
				marker.visible = data.get("ok", false) and data.get("source", 0) in [0, 1] and joints.size() == 182 and flags.size() == 26
				if marker.visible:
					marker.visible = (flags[j] & 5) == 5
					marker.position = Vector3(joints[j * 7 + 4], joints[j * 7 + 5], joints[j * 7 + 6])
			var mesh := ImmediateMesh.new()
			if _hand_meshes[h * 26].visible:
				mesh.surface_begin(Mesh.PRIMITIVE_LINES)
				for j in range(2, 26):
					var parent := 1 if j in [2, 6, 11, 16, 21] else j - 1
					if _hand_meshes[h * 26 + j].visible and _hand_meshes[h * 26 + parent].visible:
						mesh.surface_add_vertex(_hand_meshes[h * 26 + parent].position)
						mesh.surface_add_vertex(_hand_meshes[h * 26 + j].position)
				mesh.surface_end()
			_hand_lines[h].mesh = mesh
	if Time.get_ticks_msec() - _hand_seen > 500:
		for line in _hand_lines:
			line.mesh = null
		for marker in _hand_meshes:
			marker.visible = false
	for hand in _controllers.size():
		var c := _controllers[hand]
		var trigger := c.get_float("trigger")
		var grip := c.get_float("grip")
		var stick := c.get_vector2("primary")
		var buttons := ""
		for action in ["ax_button", "by_button", "primary_click", "trigger_click", "grip_click", "ax_touch", "by_touch", "primary_touch", "trigger_touch", "menu_button", "thumbrest_touch"]:
			if c.is_button_pressed(action):
				buttons += action + "\n"
		var pressed := c.is_button_pressed("ax_button")
		if pressed and not _pressed[hand]:
			c.trigger_haptic_pulse("haptic", 100, 0.6, 0.25, 0)
			_pulse_counts[hand] += 1
			print("[room] haptic requested ", hand, " count ", _pulse_counts[hand])
		_pressed[hand] = pressed
		_labels[hand].text = ("LEFT X/Y" if hand == 0 else "RIGHT A/B") + "\ntrigger %.2f grip %.2f\nstick %.2f %.2f\n" % [trigger, grip, stick.x, stick.y] + buttons + "\nX/A: VIBRATION\npulses: %d" % _pulse_counts[hand]
