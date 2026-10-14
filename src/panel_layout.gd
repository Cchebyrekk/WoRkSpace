class_name PanelLayout
## Pure layout maths: no nodes, no engine state, covered by tests/run_tests.gd.
## Turns the Windows monitor layout (rectangles in virtual-desktop pixels) into
## panel placements on a sphere around the user, so that whatever is to the left
## in Windows is to the left in VR, with the same relative sizes and offsets.


class Placement:
	## Centre and orientation of the panel; its front (+Z) faces the user.
	var transform := Transform3D.IDENTITY
	## Width and height in metres.
	var size := Vector2.ZERO
	## Where the panel sits as seen from the eye, in radians (right and up are positive).
	var heading := 0.0
	var elevation := 0.0


## `degrees_per_1920_px` sets the scale: the horizontal angle a 1920-pixel-wide
## monitor covers. If the whole layout would span more than `max_arc_degrees`, it
## is shrunk to fit, because panels must not wrap around behind the user.
## The primary monitor is straight ahead unless that would push the far end of
## the layout past the allowed arc.
static func arrange(monitors: Array[Rect2i], primary_index: int, eye: Vector3, distance: float,
		degrees_per_1920_px: float, max_arc_degrees: float) -> Array[Placement]:
	var placements: Array[Placement] = []
	if monitors.is_empty():
		return placements

	var bounds := monitors[0]
	for monitor in monitors:
		bounds = bounds.merge(monitor)

	var max_arc := deg_to_rad(max_arc_degrees)
	var pixels_per_radian := 1920.0 / deg_to_rad(degrees_per_1920_px)
	if bounds.size.x / pixels_per_radian > max_arc:
		pixels_per_radian = bounds.size.x / max_arc

	# Panels are flat, so a panel's height in metres does not match its height in
	# pixels at the horizontal scale exactly; rows are spaced by the real height.
	var metres_per_pixel := 2.0 * distance * tan(960.0 / pixels_per_radian) / 1920.0
	var vertical_pixels_per_radian := 1080.0 / (2.0 * atan(metres_per_pixel * 540.0 / distance))

	var primary := monitors[clampi(primary_index, 0, monitors.size() - 1)]
	var half_arc_pixels := max_arc * pixels_per_radian * 0.5
	var reference := Vector2(
			clampf(primary.position.x + primary.size.x * 0.5, bounds.end.x - half_arc_pixels, bounds.position.x + half_arc_pixels),
			primary.position.y + primary.size.y * 0.5)

	for monitor in monitors:
		var centre := Vector2(monitor.position) + Vector2(monitor.size) * 0.5
		var placement := Placement.new()
		placement.heading = (centre.x - reference.x) / pixels_per_radian
		placement.elevation = -(centre.y - reference.y) / vertical_pixels_per_radian
		var direction := Vector3(sin(placement.heading) * cos(placement.elevation), sin(placement.elevation),
				-cos(placement.heading) * cos(placement.elevation))
		var width := 2.0 * distance * tan(monitor.size.x * 0.5 / pixels_per_radian)
		placement.size = Vector2(width, width * monitor.size.y / monitor.size.x)
		placement.transform = Transform3D(Basis.looking_at(direction, Vector3.UP), eye + direction * distance)
		placements.append(placement)
	return placements
