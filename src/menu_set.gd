class_name MenuSet
extends RefCounted
## The radial menu: what it can do (ACTIONS), the categories the user fills with
## them, and the navigation (Navigator) — either two levels (a ring of categories,
## then the chosen one's items open beyond it) or by finger (the touching finger
## picks the category, its items open at once). Two levels is the default; the
## user picks in the settings (20.10.2026: one ring of nine was too many). Pure
## logic, covered by tests/run_tests.gd.

## id -> [label, Windows virtual keys pressed together]; no keys = done by main.gd.
const ACTIONS := {
	"copy": ["Копировать", [0x11, 0x43]],
	"paste": ["Вставить", [0x11, 0x56]],
	"cut": ["Вырезать", [0x11, 0x58]],
	"undo": ["Отменить", [0x11, 0x5A]],
	"redo": ["Повторить", [0x11, 0x10, 0x5A]],
	"select_all": ["Выделить всё", [0x11, 0x41]],
	"save": ["Сохранить", [0x11, 0x53]],
	"alt_tab": ["Alt+Tab", [0x12, 0x09]],
	"desktop": ["Рабочий стол", [0x5B, 0x44]],
	"minimize": ["Свернуть", [0x5B, 0x28]],
	"maximize": ["Развернуть", [0x5B, 0x26]],
	"close": ["Закрыть окно", [0x12, 0x73]],
	"snap_left": ["Окно влево", [0x5B, 0x25]],
	"snap_right": ["Окно вправо", [0x5B, 0x27]],
	"start": ["Пуск", [0x5B]],
	"explorer": ["Проводник", [0x5B, 0x45]],
	"task_manager": ["Диспетчер задач", [0x11, 0x10, 0x1B]],
	"center": ["Центр", []],
}
## The user's own functions: keyboard shortcuts recorded from the keyboard,
## id ("custom:N") -> [label like "Ctrl+Shift+T", keys]. Kept in [menus] custom.
static var custom := {}
const EMPTY := ""
const MAX_ITEMS := 8
const MAX_CATEGORIES := 6


static func has_action(id: String) -> bool:
	return ACTIONS.has(id) or custom.has(id)


## [label, keys] of a built-in or own function.
static func action(id: String) -> Array:
	if ACTIONS.has(id):
		return ACTIONS[id]
	return custom.get(id, [id, []])


static func all_ids() -> Array:
	return ACTIONS.keys() + custom.keys()


## A shortcut's name from its Windows virtual keys, e.g. [0x11, 0x10, 0x54] -> "Ctrl+Shift+T".
static func shortcut_label(keys: Array) -> String:
	var names := {0x11: "Ctrl", 0x12: "Alt", 0x10: "Shift", 0x5B: "Win", 0x09: "Tab", 0x0D: "Enter", 0x1B: "Esc",
			0x20: "Пробел", 0x08: "Backspace", 0x2E: "Delete", 0x2D: "Insert", 0x24: "Home", 0x23: "End",
			0x21: "PageUp", 0x22: "PageDown", 0x25: "←", 0x26: "↑", 0x27: "→", 0x28: "↓", 0x2C: "PrintScreen"}
	var parts: PackedStringArray = []
	for key: int in keys:
		if names.has(key):
			parts.append(names[key])
		elif (key >= 0x30 and key <= 0x39) or (key >= 0x41 and key <= 0x5A):
			parts.append(char(key))
		elif key >= 0x70 and key <= 0x87:
			parts.append("F%d" % (key - 0x6F))
		else:
			parts.append("#%d" % key)
	return "+".join(parts)
const MODE_FINGER := 0
const MODE_TWO_LEVEL := 1


static func default_menus() -> Array:
	return [
		{"name": "Правка", "items": ["copy", "paste", "cut", "undo", "redo", "select_all"]},
		{"name": "Окна", "items": ["alt_tab", "desktop", "minimize", "maximize", "close", "snap_left", "snap_right"]},
		{"name": "Мир и система", "items": ["center", "start", "save", "explorer", "task_manager"]},
	]


## The items of a menu without empty places and unknown ids.
static func items_of(menu: Dictionary) -> PackedStringArray:
	var result := PackedStringArray()
	for id: String in menu.get("items", []):
		if has_action(id):
			result.append(id)
	return result


## The next action for a place in a menu when the user presses it: the actions in
## order, then empty, round again.
static func next_action(current: String) -> String:
	var ids: Array = ACTIONS.keys()
	if current == EMPTY or not ACTIONS.has(current):
		return ids[0]
	var at := ids.find(current)
	return ids[at + 1] if at + 1 < ids.size() else EMPTY


## `items` with `id` put at place `index` (taken out of where it was first), as
## when it is dropped onto that place in the editor; the order is the ring's,
## clockwise from the top.
static func moved(items: Array, id: String, index: int) -> Array:
	var result := items.filter(func(item: String) -> bool: return item != id)
	result.insert(clampi(index, 0, result.size()), id)
	return result


## How wide the ring of `count` items is (m): the labels stood on each other at
## 0.1 m with seven or eight items (20.10.2026).
static func ring_radius_for(count: int) -> float:
	return maxf(0.1, count * 0.024)


## Index of the item `offset` points at among `count` around a ring (clockwise
## from the top), or -1 within `dead`.
static func item_at(offset: Vector2, dead: float, count: int) -> int:
	if count <= 0 or offset.length() < dead:
		return -1
	var angle := fposmod(atan2(offset.x, offset.y), TAU)
	return int(round(angle / (TAU / count))) % count


## One open menu on one hand or controller.
class Navigator:
	var menus: Array = []
	var mode := MODE_TWO_LEVEL
	## Ring sizes (m): categories, and the items around a chosen category.
	var radius := 0.13
	var item_radius := 0.1
	var dead := 0.03
	## Level 0 = categories, 1 = items of `category`.
	var level := 0
	var category := -1
	var centre := Vector3.ZERO
	var item_centre := Vector3.ZERO
	## Where the items' ring starts (radians, clockwise from the top): turned so
	## that a gap, not an item, faces the middle of the categories.
	var item_start := 0.0
	var right := Vector3.RIGHT
	var up := Vector3.UP

	## Opens at `at`, facing `viewer`. `pick` >= 0 opens that category's items at
	## once (by finger); otherwise the categories (two levels).
	func open(at: Vector3, viewer: Vector3, pick := -1) -> void:
		var toward := PointerMath.horizontal_toward(at, viewer)
		up = Vector3.UP
		right = (-toward).cross(up).normalized()
		centre = at
		item_centre = at
		item_start = 0.0
		level = 0
		category = -1
		if pick >= 0 and pick < menus.size():
			level = 1
			category = pick
			item_radius = MenuSet.ring_radius_for(MenuSet.items_of(menus[pick]).size())

	func offset(from: Vector3, hand: Vector3) -> Vector2:
		var local := hand - from
		return Vector2(local.dot(right), local.dot(up))

	## Follows the hand; returns the action id it points at, or "" (none).
	func update(hand: Vector3) -> String:
		if level == 0:
			var picked := MenuSet.item_at(offset(centre, hand), radius * 0.6, menus.size())
			if picked >= 0:
				level = 1
				category = picked
				# The items open around the chosen category (the user's wish,
				# 20.10.2026), turned so that a gap between two items faces the
				# middle, where the hand goes to get back to the categories.
				item_centre = category_position(picked)
				var count := maxi(MenuSet.items_of(menus[picked]).size(), 1)
				item_radius = MenuSet.ring_radius_for(count)
				var back := offset(item_centre, centre)
				item_start = atan2(back.x, back.y) + PI / count
			return ""
		var items := MenuSet.items_of(menus[category])
		# Two levels: back near the middle of the categories = back to them.
		if mode == MODE_TWO_LEVEL and item_centre != centre and hand.distance_to(centre) < radius * 0.25:
			level = 0
			category = -1
			return ""
		var turned := offset(item_centre, hand).rotated(item_start)
		var index := MenuSet.item_at(turned, dead, items.size())
		return items[index] if index >= 0 else ""

	func category_position(index: int) -> Vector3:
		var angle := index * TAU / maxi(menus.size(), 1)
		return centre + (right * sin(angle) + up * cos(angle)) * radius

	func item_position(index: int, count: int) -> Vector3:
		var angle := item_start + index * TAU / maxi(count, 1)
		return item_centre + (right * sin(angle) + up * cos(angle)) * item_radius
