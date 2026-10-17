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
	## How the panel leans: the elevation its face looks along (radians). Equal to
	## `elevation` when it faces the eye; 0 = upright.
	var pitch := 0.0
	## 0 = flat; above 0 curved round a vertical axis, 1 = the arc centred on the eye.
	var curvature := 0.0


## `degrees_per_1920_px` sets the scale: the horizontal angle a 1920-pixel-wide
## monitor covers. If the whole layout would span more than `max_arc_degrees`, it
## is shrunk to fit, because panels must not wrap around behind the user.
## The group of monitors is centred left-to-right in front of the user (with three
## in a row the middle one is straight ahead, wherever the primary is); vertically
## the primary monitor's row is at eye level.
##
## `scales` (one per monitor, empty = all 1) enlarge or shrink panels in VR only;
## panels that touch in Windows still touch edge to edge: in each row the panel
## nearest straight ahead stays put and the others move aside, and the rows move
## apart or together. `row_gap` (metres) leaves room between rows, e.g. for the
## handles under the panels. `pitches` (NAN = face the eye) and `curvatures` are
## per monitor, see Placement. Neighbours are spaced by the edge point that
## comes nearest the eye's vertical axis, so leaning or curved panels never cut
## into each other (above and below eye level flat panels facing the eye did).
static func arrange(monitors: Array[Rect2i], primary_index: int, eye: Vector3, distance: float,
		degrees_per_1920_px: float, max_arc_degrees: float, scales: Array[float] = [], row_gap := 0.0,
		pitches: Array[float] = [], curvatures: Array[float] = []) -> Array[Placement]:
	var placements: Array[Placement] = []
	if monitors.is_empty():
		return placements

	var scale := _scale(monitors, distance, degrees_per_1920_px, max_arc_degrees)
	var reference := _reference(monitors, primary_index)

	# Unscaled: centre angles and half-angles of every panel.
	var headings: Array[float] = []
	var elevations: Array[float] = []
	var half_widths: Array[float] = []
	var half_heights: Array[float] = []
	var sizes: Array[Vector2] = []
	var scaled_heights: Array[float] = []
	for i in monitors.size():
		var monitor := monitors[i]
		var centre := Vector2(monitor.position) + Vector2(monitor.size) * 0.5
		var width := 2.0 * distance * tan(monitor.size.x * 0.5 / scale.x)
		var size := Vector2(width, width * monitor.size.y / monitor.size.x)
		headings.append((centre.x - reference.x) / scale.x)
		elevations.append(-(centre.y - reference.y) / scale.y)
		half_widths.append(monitor.size.x * 0.5 / scale.x)
		half_heights.append(atan(size.y * 0.5 / distance))
		var factor: float = scales[i] if i < scales.size() else 1.0
		sizes.append(size * factor)
		scaled_heights.append(atan(factor * tan(half_heights[i])))

	# Up and down: rows stacked from the primary's row outward, `row_gap` apart.
	var row_list := LayoutEdit.rows(monitors)
	var new_elevations := elevations.duplicate()
	var gap_angle := row_gap / distance
	var primary_row := 0
	var shifts: Array[float] = []
	var tops: Array[float] = []
	var bottoms: Array[float] = []
	for r in row_list.size():
		if row_list[r].has(primary_index):
			primary_row = r
		var top := -INF
		var bottom := INF
		for i in row_list[r]:
			top = maxf(top, elevations[i] + scaled_heights[i])
			bottom = minf(bottom, elevations[i] - scaled_heights[i])
		tops.append(top)
		bottoms.append(bottom)
		shifts.append(0.0)
	for r in range(primary_row - 1, -1, -1):
		shifts[r] = shifts[r + 1] + tops[r + 1] + gap_angle - bottoms[r]
	for r in range(primary_row + 1, row_list.size()):
		shifts[r] = shifts[r - 1] + bottoms[r - 1] - gap_angle - tops[r]
	for r in row_list.size():
		for i in row_list[r]:
			new_elevations[i] = elevations[i] + shifts[r]

	var new_pitches: Array[float] = []
	var new_curvatures: Array[float] = []
	var half_azimuths: Array[float] = []
	for i in monitors.size():
		var pitch: float = pitches[i] if i < pitches.size() and not is_nan(pitches[i]) else new_elevations[i]
		var curvature: float = curvatures[i] if i < curvatures.size() else 0.0
		new_pitches.append(pitch)
		new_curvatures.append(curvature)
		half_azimuths.append(half_azimuth(sizes[i], new_elevations[i], pitch, curvature, distance))

	# Sideways, row by row: neighbours keep the gap they had (none, if they touched).
	var new_headings := headings.duplicate()
	for row in row_list:
		var anchor := 0
		for k in row.size():
			if absf(headings[row[k]]) < absf(headings[row[anchor]]):
				anchor = k
		for k in range(anchor + 1, row.size()):
			var a := row[k - 1]
			var b := row[k]
			var gap := (headings[b] - half_widths[b]) - (headings[a] + half_widths[a])
			new_headings[b] = new_headings[a] + half_azimuths[a] + gap + half_azimuths[b]
		for k in range(anchor - 1, -1, -1):
			var a := row[k]
			var b := row[k + 1]
			var gap := (headings[b] - half_widths[b]) - (headings[a] + half_widths[a])
			new_headings[a] = new_headings[b] - half_azimuths[b] - gap - half_azimuths[a]

	for i in monitors.size():
		placements.append(placement_at(new_headings[i], new_elevations[i], sizes[i], eye, distance, new_pitches[i], new_curvatures[i]))
	return placements


## Half the angle round the eye's vertical axis that a panel takes up sideways:
## measured at its edge point nearest that axis (the top or bottom corner of a
## leaning panel, the edge of a curved one, which bends towards the viewer).
static func half_azimuth(size: Vector2, elevation: float, pitch: float, curvature: float, distance: float) -> float:
	var nearest := distance * cos(elevation) - size.y * 0.5 * absf(sin(pitch))
	var sideways := size.x * 0.5
	if curvature > 0.0:
		var radius := distance / curvature
		var angle := size.x * 0.5 / radius
		sideways = radius * sin(angle)
		nearest -= radius * (1.0 - cos(angle)) * cos(pitch)
	return atan(sideways / maxf(nearest, 0.05))


## Half-width (round the eye's vertical axis) and half-height of a panel as the
## eye sees them at its middle height: the edges of a curved panel bend towards
## the viewer, so it looks narrower than flat. For the magnet.
static func visible_half(size: Vector2, elevation: float, curvature: float, distance: float) -> Vector2:
	var sideways := size.x * 0.5
	var depth := distance * cos(elevation)
	if curvature > 0.0:
		var radius := distance / curvature
		var angle := size.x * 0.5 / radius
		sideways = radius * sin(angle)
		depth -= radius * (1.0 - cos(angle))
	return Vector2(atan(sideways / maxf(depth, 0.05)), atan(size.y * 0.5 / distance))


## Radius of a curved panel's cylinder; 0 for a flat one.
static func curve_radius(curvature: float, distance: float) -> float:
	return distance / curvature if curvature > 0.0 else 0.0


## A panel of `size` metres centred at `heading` / `elevation` (radians) on the
## sphere around `eye`; it faces the eye unless `pitch` says how it leans.
static func placement_at(heading: float, elevation: float, size: Vector2, eye: Vector3, distance: float,
		pitch := NAN, curvature := 0.0) -> Placement:
	var placement := Placement.new()
	placement.heading = heading
	placement.elevation = elevation
	placement.size = size
	placement.pitch = elevation if is_nan(pitch) else pitch
	placement.curvature = curvature
	placement.transform = Transform3D(Basis.looking_at(direction_of(heading, placement.pitch), Vector3.UP),
			eye + direction_of(heading, elevation) * distance)
	return placement


static func direction_of(heading: float, elevation: float) -> Vector3:
	return Vector3(sin(heading) * cos(elevation), sin(elevation), -cos(heading) * cos(elevation))


## Magnet for a panel placed freely in VR. `half` is its half-width and half-height
## as angles; each of `others` is (heading, elevation, half-width, half-height).
## Within `reach` (radians) heading and elevation each snap to: edge to edge with
## another panel, edges in line, middles in line. Returns (heading, elevation).
##
## `held` is what it snapped to last frame (NAN where it did not): it stays there
## until pulled half as far again as `reach`, so it does not flicker at the edge.
##
## `own_widths`, if given, is the panel's own half-width as seen at each other
## panel's elevation: then where it sticks does not depend on how high the hand
## holds it (with its own elevation it crept sideways when moved up and down).
static func snap_angles(heading: float, elevation: float, half: Vector2, others: Array[Vector4], reach: float,
		held := Vector2(NAN, NAN), own_widths: Array[float] = []) -> Vector2:
	var best := Vector2(reach, reach)
	var result := Vector2(heading, elevation)
	var found_x := false
	var found_y := false
	for k in others.size():
		var other := others[k]
		var width: float = own_widths[k] if k < own_widths.size() else half.x
		var sideways := [other.x - other.z - width, other.x + other.z + width,  # touching
				other.x - other.z + width, other.x + other.z - width, other.x]  # edges, middles in line
		var vertical := [other.y - other.w - half.y, other.y + other.w + half.y,
				other.y - other.w + half.y, other.y + other.w - half.y, other.y]
		for candidate: float in sideways:
			if absf(candidate - heading) < best.x:
				best.x = absf(candidate - heading)
				result.x = candidate
				found_x = true
		for candidate: float in vertical:
			if absf(candidate - elevation) < best.y:
				best.y = absf(candidate - elevation)
				result.y = candidate
				found_y = true
	# Nothing within reach: stay where it held until pulled further. Only then: the
	# nearest place always wins, or it stayed a little off when the hold was on a
	# neighbouring candidate (17.10.2026).
	if not found_x and not is_nan(held.x) and absf(held.x - heading) < reach * 1.5:
		result.x = held.x
	if not found_y and not is_nan(held.y) and absf(held.y - elevation) < reach * 1.5:
		result.y = held.y
	return result


## Magnet for the VR size of a panel: `scale` snaps to 1 or to the scale at which
## the panel is as wide or as tall as another one, if within `reach` (a share,
## 0.04 = 4 %). `unscaled` is the panel's size in metres at scale 1, `others` the
## other panels' sizes; real sizes, so a curved panel counts as big as it is.
static func snap_scale(scale: float, unscaled: Vector2, others: Array[Vector2], reach: float) -> float:
	var candidates: Array[float] = [1.0]
	for other in others:
		candidates.append(other.x / unscaled.x)
		candidates.append(other.y / unscaled.y)
	var result := scale
	var best := reach
	for candidate in candidates:
		if absf(candidate / scale - 1.0) < best:
			best = absf(candidate / scale - 1.0)
			result = candidate
	return result


## Heading and elevation (radians) of where a ray from inside the sphere around
## `eye` leaves it; Vector2(NAN, NAN) if the ray starts outside and misses.
static func sphere_angles(origin: Vector3, direction: Vector3, eye: Vector3, distance: float) -> Vector2:
	var offset := origin - eye
	var b := offset.dot(direction)
	var c := offset.length_squared() - distance * distance
	var discriminant := b * b - c
	if discriminant < 0.0:
		return Vector2(NAN, NAN)
	var t := -b + sqrt(discriminant)
	if t < 0.0:
		return Vector2(NAN, NAN)
	var point := (offset + direction * t).normalized()
	return Vector2(atan2(point.x, -point.z), asin(clampf(point.y, -1.0, 1.0)))


## The inverse of arrange(): the desktop pixel that would sit at `heading` and
## `elevation` (radians, as seen from the eye) in that layout.
static func to_desktop(monitors: Array[Rect2i], primary_index: int, distance: float,
		degrees_per_1920_px: float, max_arc_degrees: float, heading: float, elevation: float) -> Vector2:
	var scale := _scale(monitors, distance, degrees_per_1920_px, max_arc_degrees)
	var reference := _reference(monitors, primary_index)
	return Vector2(reference.x + heading * scale.x, reference.y - elevation * scale.y)


## The desktop point that ends up straight ahead at eye level: the middle of the
## group sideways, the middle of the primary vertically.
static func _reference(monitors: Array[Rect2i], primary_index: int) -> Vector2:
	var bounds := monitors[0]
	for monitor in monitors:
		bounds = bounds.merge(monitor)
	var primary := monitors[clampi(primary_index, 0, monitors.size() - 1)]
	return Vector2(bounds.position.x + bounds.size.x * 0.5, primary.position.y + primary.size.y * 0.5)


## Desktop pixels per radian: (horizontal, vertical).
static func _scale(monitors: Array[Rect2i], distance: float, degrees_per_1920_px: float, max_arc_degrees: float) -> Vector2:
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
	return Vector2(pixels_per_radian, 1080.0 / (2.0 * atan(metres_per_pixel * 540.0 / distance)))
