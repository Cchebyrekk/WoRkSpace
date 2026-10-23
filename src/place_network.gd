class_name PlaceNetwork
extends RefCounted
## The network of places (slice m): every fixture's seat is a place; places are
## linked to their nearest ones by themselves, and the user adds or takes away
## links of their own; places share a group (a colour and a cloud on the map).
## The map is the world made small in front of the user; a place chosen on it
## is flown to. Pure logic, covered by tests/run_tests.gd. Decided with the user
## on 22.10.2026: a map before you, chosen by hand or ray, a quick flight, links
## by themselves and by hand, groups as colours set on «Заготовки».

## How many groups there are (0 = none).
const MAX_GROUPS := 6
const GROUP_COLORS: Array[Color] = [Color(0.75, 0.78, 0.85), Color(0.3, 0.8, 1.0), Color(1.0, 0.6, 0.25),
		Color(0.45, 0.9, 0.4), Color(0.95, 0.4, 0.85), Color(1.0, 0.9, 0.3), Color(0.5, 0.55, 1.0)]


## A link between two places by their fixtures' ids, the smaller first.
static func pair(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))


## Each place linked to its `nearest` nearest others (no link twice).
static func auto_links(points: Dictionary, nearest := 2) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if nearest <= 0:
		return result
	for id: int in points:
		var others: Array = points.keys().filter(func(other: int) -> bool: return other != id)
		others.sort_custom(func(a: int, b: int) -> bool:
			var da: float = (points[a] as Vector3).distance_to(points[id])
			var db: float = (points[b] as Vector3).distance_to(points[id])
			return da < db or (da == db and a < b))
		for k in mini(nearest, others.size()):
			var link := pair(id, others[k])
			if not result.has(link):
				result.append(link)
	return result


## The links there are: the automatic ones the user did not take away, and theirs.
## Links to places that are gone do not count.
static func links(points: Dictionary, nearest: int, added: Array[Vector2i], removed: Array[Vector2i]) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for link in auto_links(points, nearest):
		if not removed.has(link):
			result.append(link)
	for link in added:
		if points.has(link.x) and points.has(link.y) and not result.has(link):
			result.append(link)
	return result


## A link drawn by hand between `a` and `b` turns it on or off: an automatic one
## is taken away (or given back), the user's own added (or taken away).
## Returns {"added": …, "removed": …}.
static func toggled(a: int, b: int, points: Dictionary, nearest: int, added: Array[Vector2i], removed: Array[Vector2i]) -> Dictionary:
	var link := pair(a, b)
	var now_added := added.duplicate()
	var now_removed := removed.duplicate()
	if auto_links(points, nearest).has(link):
		if now_removed.has(link):
			now_removed.erase(link)
		else:
			now_removed.append(link)
	elif now_added.has(link):
		now_added.erase(link)
	else:
		now_added.append(link)
	return {"added": now_added, "removed": now_removed}


## How the world goes onto a map `size` across: [the middle of the places, metres
## of map per metre of world]. A world smaller than a metre is not blown up past it.
static func map_frame(points: Array, size: float) -> Array:
	if points.is_empty():
		return [Vector3.ZERO, size]
	var low: Vector3 = points[0]
	var high: Vector3 = points[0]
	for point: Vector3 in points:
		low = low.min(point)
		high = high.max(point)
	var extent := maxf(maxf(high.x - low.x, high.y - low.y), maxf(high.z - low.z, 1.0))
	return [(low + high) * 0.5, size / extent]


## A group's cloud: round its places, [middle, radius].
static func cloud(points: Array, margin := 0.0) -> Array:
	if points.is_empty():
		return [Vector3.ZERO, 0.0]
	var middle := Vector3.ZERO
	for point: Vector3 in points:
		middle += point
	middle /= points.size()
	var radius := 0.0
	for point: Vector3 in points:
		radius = maxf(radius, middle.distance_to(point))
	return [middle, radius + margin]


## Where the rig is `share` (0..1) of the way through a flight: eased in and out,
## turning on the way.
static func flight(from: Transform3D, to: Transform3D, share: float) -> Transform3D:
	var t := smoothstep(0.0, 1.0, clampf(share, 0.0, 1.0))
	var turn := Quaternion(from.basis.orthonormalized()).slerp(Quaternion(to.basis.orthonormalized()), t)
	return Transform3D(Basis(turn), from.origin.lerp(to.origin, t))


## A group's name ("" for none).
static func group_name(group: int) -> String:
	return "Группа %d" % group if group > 0 else ""


static func group_color(group: int) -> Color:
	return GROUP_COLORS[clampi(group, 0, GROUP_COLORS.size() - 1)]


## Saved links ([[a, b], …]) back into pairs.
static func links_from(saved: Variant) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if saved is Array:
		for entry: Variant in saved:
			if entry is Array and entry.size() == 2:
				result.append(pair(int(entry[0]), int(entry[1])))
	return result


static func links_to(links: Array[Vector2i]) -> Array:
	var result := []
	for link in links:
		result.append([link.x, link.y])
	return result
