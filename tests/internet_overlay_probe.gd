extends SceneTree
## Run against headset/ so the actual overlay scripts and class paths are used.

class ProbeRoot extends "res://src/headset_root.gd":
	var starts := 0
	var status_polls := 0
	func _ready() -> void:
		set_process(false)
	func _start(_mode: int) -> void:
		starts += 1
	func _poll_internet(_now: float, _pairing_only := false) -> void:
		status_polls += 1

class LiveWorld extends Node3D:
	var frames := 0
	var link_connected := true
	func _process(_delta: float) -> void:
		frames += 1
	func connected() -> bool:
		return link_connected

class WorldPointer extends RefCounted:
	var origin := Vector3.ZERO
	var direction := Vector3.FORWARD
	var active := true
	var pressed := false
	var just_pressed := false
	var hit_distance := INF
	var grab_panel: Node3D
	var slider: Object

class FrozenReceiver extends RefCounted:
	var frozen := 0
	var stopped := 0
	var started := 0
	func freeze(_id: int) -> void:
		frozen += 1
	func stop(_id: int) -> void:
		stopped += 1
	func stopAll() -> void:
		stopped += 1
	func startTexture(_id: int, _host: String, _port: int) -> void:
		started += 1
	func isAlive(_id: int) -> bool:
		return false

class ReleasePanel extends "res://src/internet_setup.gd":
	var held := true
	var choices: Array[bool] = []
	func _apply_choice(internet: bool) -> void:
		choices.append(internet)
	func _update_inputs(_delta: float) -> void:
		_down = [held, false]

var _checks := 0
var _failures := 0

func _init() -> void:
	_run.call_deferred()

func _check(value: bool, description: String) -> void:
	_checks += 1
	if not value:
		_failures += 1
		push_error(description)

func _cameras(node: Node) -> int:
	var count := 1 if node is Camera3D else 0
	for child in node.get_children():
		count += _cameras(child)
	return count

func _run() -> void:
	InternetLink._loaded = true
	InternetLink.identity = {}
	InternetLink.profile = {}
	var video_options := HeadsetOptions.new()
	video_options.video_mbps = 30.0
	video_options.video_fps = 60
	_check(video_options.video_for_transport(true) == Vector2i(6000, 30), "internet quality defaults to accepted bitrate and frame rate")
	_check(video_options.video_for_transport(false) == Vector2i(30000, 60), "local transport retains selected quality")
	_check(video_options.video_mbps == 30.0 and video_options.video_fps == 60, "internet trial does not rewrite saved quality")
	video_options.video_mbps = 2.0
	video_options.video_fps = 15
	video_options.internet_video_mbps = 30.0
	video_options.internet_video_fps = 60
	_check(video_options.video_for_transport(true) == Vector2i(30000, 60), "internet quality can restore original 30 Mbps and 60 FPS independently")
	_check(video_options.video_for_transport(false) == Vector2i(2000, 15), "internet settings leave local quality unchanged")
	video_options.internet_video_mbps = 0.0
	video_options.internet_video_fps = 1000
	_check(video_options.video_for_transport(true) == Vector2i(2000, 90), "invalid persisted internet quality is bounded")
	var selected := 0
	for expected in [1, 2, 3, 0, 1, 2, 3, 0]:
		selected = HeadsetOptions.cycle_link_mode(selected, 1)
		_check(selected == expected, "forward transport cycle")
	for expected in [3, 2, 1, 0, 3, 2, 1, 0]:
		selected = HeadsetOptions.cycle_link_mode(selected, -1)
		_check(selected == expected, "reverse transport cycle")
	var host := ProbeRoot.new()
	root.add_child(host)
	var world := LiveWorld.new()
	host._child = world
	host.add_child(world)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.make_current()
	await process_frame
	var cameras_before := _cameras(root)
	host._show_internet_setup()
	await process_frame
	var panel: Variant = host._internet_setup
	_check(host._child == world and world.is_inside_tree(), "opening PIN keeps original world")
	_check(root.get_camera_3d() == camera, "opening PIN keeps current camera")
	_check(_cameras(root) == cameras_before, "opening PIN creates no new camera")
	var position: Vector3 = panel._panel.global_position
	camera.position += Vector3(0.2, 0, 0)
	camera.rotate_y(0.25)
	var frames_before := world.frames
	await process_frame
	await process_frame
	_check(panel._panel.global_position.is_equal_approx(position), "PIN stays in the world when head turns")
	_check(world.frames > frames_before, "background world keeps processing")
	var replacement := Camera3D.new()
	world.add_child(replacement)
	replacement.global_transform = camera.global_transform
	replacement.make_current()
	camera.queue_free()
	camera = replacement
	await process_frame
	await process_frame
	_check(panel._camera == replacement, "overlay follows a camera reference replaced by the world")
	_check(_cameras(root) == cameras_before, "camera replacement does not leave a PIN camera behind")
	panel._hide_panel()
	_check(host._child == world and root.get_camera_3d() == camera, "closing PIN keeps world and camera")
	_check(host.starts == 0, "closing PIN does not restart work mode")
	host._show_internet_setup()
	_check(host._internet_setup == panel, "reopening reuses the panel")
	_check(not panel._panel.global_position.is_equal_approx(position), "reopening places PIN before current head pose")
	world.position = Vector3(12, 0, -8)
	world.rotation.y = 0.7
	panel.open_panel()
	await process_frame
	await process_frame
	var left := WorldPointer.new()
	var right := WorldPointer.new()
	left.origin = camera.global_position
	var button_position: Vector3 = panel._buttons[0].global_position
	left.direction = left.origin.direction_to(button_position)
	right.origin = camera.global_position
	right.direction = Vector3.UP
	var capture: Array[bool] = panel.accept_inputs([left, right], 0.01)
	_check(capture == [true, false], "PIN uses world rays after movement and only captures the hovering hand")
	_check(is_finite(left.hit_distance), "main ray receives distance to the PIN key")
	_check(panel._dots[0].global_position.is_equal_approx(button_position), "world-space cursor meets the key")
	left.pressed = true
	left.just_pressed = true
	panel.accept_inputs([left, right], 0.4)
	_check(panel._code == "1", "existing world pointer can enter a digit")
	left.just_pressed = false
	left.direction = Vector3.UP
	capture = panel.accept_inputs([left, right], 0.1)
	_check(capture == [true, false], "press started on PIN stays captured if ray leaves it")
	left.pressed = false
	capture = panel.accept_inputs([left, right], 0.01)
	_check(capture == [false, false], "outside PIN both pointers remain available to the world")
	var stage := XROrigin3D.new()
	world.add_child(stage)
	camera.reparent(stage, true)
	var tracker := XRControllerTracker.new()
	tracker.name = &"left_hand"
	tracker.type = XRServer.TRACKER_CONTROLLER
	var local_origin := stage.global_transform.affine_inverse() * camera.global_position
	var local_target := stage.global_transform.affine_inverse() * button_position
	tracker.set_pose(&"aim", Transform3D(Basis.looking_at(local_origin.direction_to(local_target)), local_origin), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	tracker.set_input(&"trigger", 0.0)
	XRServer.add_tracker(tracker)
	panel._update_inputs(0.01)
	_check(panel._fallback_rays[0].visible, "PC-render fallback shows an actual ray")
	_check(panel._dots[0].visible and panel._dots[0].global_position.distance_to(button_position) < 0.0001, "raw tracking ray is transformed through the moved XR origin")
	XRServer.remove_tracker(tracker)
	camera.reparent(world, true)
	stage.queue_free()
	panel._hide_panel()
	var release := ReleasePanel.new()
	host.add_child(release)
	release._choose(false)
	await process_frame
	_check(release.visible and InternetLink.setup_visible, "closing press remains captured until release")
	_check(release.choices == [false], "transport choice applies once")
	release.held = false
	await process_frame
	await process_frame
	_check(not release.visible and not InternetLink.setup_visible, "release closes panel and returns input")
	_check(root.get_camera_3d() == camera, "release never clears current camera")
	var previous_link := PcLink.link
	var link := HeadsetLink.new("test")
	PcLink.link = link
	var screens := VideoScreens.new()
	var receiver := FrozenReceiver.new()
	screens._receiver = receiver
	screens._videos_serial = 7
	link.videos_serial = 7
	var screen_node := MeshInstance3D.new()
	host.add_child(screen_node)
	screens._attached["test-screen"] = {"id": 1, "started": true, "buffer": 77,
			"layer": screen_node, "texture": ExternalTexture.new(), "port": 47803}
	screens._live["test-screen"] = true
	screens.freeze_last_frames()
	screens.poll(1.0, null)
	screens.update_textures()
	_check(receiver.frozen == 1 and receiver.stopped == 0, "transport switch freezes receiver instead of destroying it")
	_check(screens._attached["test-screen"]["buffer"] == 77, "last texture remains while offline")
	link.state = HeadsetLink.State.CONNECTED
	link.pc_name = "test"
	link.pc_address = "test"
	link.videos = [{"key": "test-screen", "port": 47803}]
	screens.poll(2.0, null)
	_check(receiver.started == 0, "old stream generation does not discard frozen frame")
	link.videos_serial = 8
	screens.poll(3.0, null)
	_check(receiver.stopped == 1 and receiver.started == 1, "new stream generation resumes reception")
	screens.stop_all()
	link.close()
	PcLink.link = previous_link
	var previous_identity := InternetLink.identity
	var previous_selected := InternetLink._selected
	var previous_options := HeadsetOptions.current
	HeadsetOptions.current = null
	InternetLink.identity = {"device": "test", "token": "test", "trusted": true}
	InternetLink._selected = true
	world.link_connected = false
	host._show_internet_setup(true)
	host._process(0.0)
	_check(host.status_polls == 1, "outage panel keeps polling the PC mode")
	_check(panel.visible, "outage notice stays visible while disconnected")
	world.link_connected = true
	host._process(0.0)
	panel._process(0.0)
	_check(not panel.visible and not InternetLink.setup_visible, "restored link dismisses outage panel without user action")
	_check(host._child == world and host.starts == 0, "recovery preserves the existing world")
	host._show_internet_setup()
	host._process(0.0)
	_check(panel.visible and not panel._closing, "manual pairing panel is not dismissed by existing connection")
	panel._hide_panel()
	InternetLink.identity = previous_identity
	InternetLink._selected = previous_selected
	HeadsetOptions.current = previous_options
	host.queue_free()
	await process_frame
	print("Internet overlay: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
