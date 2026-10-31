class_name PlayerPose
extends RefCounted
## Where the user was in the world (31.10.2026, the user's wish: after a restart
## or a switch of work mode they stood at the start again): the head's place on
## the floor, the floor's height and the way the head looked. Kept in the
## settings file, put back at the first alignment of the next start. Not the
## rig's transform: the tracking space of Link and of the headset itself differ,
## and the user stands anywhere in the room at the next start. Pure logic,
## covered by tests/run_tests.gd.

## A pose differs once the head has gone this far or turned this much.
const MOVED_METRES := 0.3
const TURNED_RADIANS := deg_to_rad(20.0)


## The way `forward` looks, turned from -Z about +Y (radians).
static func yaw_of(forward: Vector3) -> float:
	return atan2(-forward.x, -forward.z)


## {"x", "y", "z", "yaw"}: the head over the floor (x, z), the rig's floor (y),
## the head's yaw, all in the world; `rig` is the XROrigin's global transform,
## `head` the camera's transform under it.
static func of(rig: Transform3D, head: Transform3D) -> Dictionary:
	var at := rig * head.origin
	return {"x": at.x, "y": rig.origin.y, "z": at.z, "yaw": yaw_of(rig.basis * -head.basis.z)}


## Whether a saved value is a pose.
static func is_valid(pose: Variant) -> bool:
	if not pose is Dictionary:
		return false
	for key: String in ["x", "y", "z", "yaw"]:
		var value: Variant = (pose as Dictionary).get(key)
		if not (value is float or value is int) or not is_finite(float(value)):
			return false
	return true


## The rig that puts a head at `head` (under the rig) where `pose` says.
static func rig_for(pose: Dictionary, head: Transform3D) -> Transform3D:
	var turn := Basis(Vector3.UP, float(pose["yaw"]) - yaw_of(-head.basis.z))
	var over := turn * Vector3(head.origin.x, 0.0, head.origin.z)
	return Transform3D(turn, Vector3(float(pose["x"]) - over.x, float(pose["y"]), float(pose["z"]) - over.z))


static func differs(a: Dictionary, b: Dictionary) -> bool:
	if not is_valid(a) or not is_valid(b):
		return is_valid(a) != is_valid(b)
	var moved := Vector3(a["x"] - b["x"], a["y"] - b["y"], a["z"] - b["z"]).length() >= MOVED_METRES
	return moved or absf(angle_difference(float(a["yaw"]), float(b["yaw"]))) >= TURNED_RADIANS
