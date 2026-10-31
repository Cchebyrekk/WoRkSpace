class_name VirtualKeyboard
extends RefCounted
## The keyboard in VR (31.10.2026, the user's wish): the keys' layout, which key
## is where, and what pressing one sends. Pressed by a ray with a pinch (or a
## controller's trigger) or by touching it with the index fingertip. Shift, Ctrl,
## Alt and Win stay held until the next key (one-shot, like sticky keys), any
## number of them; one of the held pressed again sends the held ones alone
## (Shift+Alt, 31.10.2026); a key held down repeats. The keys show the letters of the layout Windows types with
## now (31.10.2026: before, English and Russian both), «Яз» switches it
## (Win+Space). Pure logic, covered by tests/run_tests.gd; main.gd builds the nodes.

## One key's side and the gap between keys (metres).
const UNIT := 0.04
const GAP := 0.004
## A held key repeats after this long, this often.
const REPEAT_DELAY_SEC := 0.5
const REPEAT_EVERY_SEC := 0.06

const VK_SHIFT := 0x10
const VK_CONTROL := 0x11
const VK_MENU := 0x12
const VK_LWIN := 0x5B
const MODIFIERS := [VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN]
## «Яз»: Win+Space, the layout switch of Windows 10 and 11.
const LANGUAGE := -1

## Rows top to bottom (31.10.2026: the arrows as an inverted T, ↑ over ↓, nothing
## right of ↑); each key [label, Russian label, virtual key, width in UNITs].
const ROWS := [
	[["Esc", "", 0x1B, 1.5], ["F1", "", 0x70, 1.0], ["F2", "", 0x71, 1.0], ["F3", "", 0x72, 1.0], ["F4", "", 0x73, 1.0],
		["F5", "", 0x74, 1.0], ["F6", "", 0x75, 1.0], ["F7", "", 0x76, 1.0], ["F8", "", 0x77, 1.0], ["F9", "", 0x78, 1.0],
		["F10", "", 0x79, 1.0], ["F11", "", 0x7A, 1.0], ["F12", "", 0x7B, 1.0], ["Del", "", 0x2E, 1.5]],
	[["`", "ё", 0xC0, 1.0], ["1", "", 0x31, 1.0], ["2", "", 0x32, 1.0], ["3", "", 0x33, 1.0], ["4", "", 0x34, 1.0],
		["5", "", 0x35, 1.0], ["6", "", 0x36, 1.0], ["7", "", 0x37, 1.0], ["8", "", 0x38, 1.0], ["9", "", 0x39, 1.0],
		["0", "", 0x30, 1.0], ["-", "", 0xBD, 1.0], ["=", "", 0xBB, 1.0], ["⌫", "", 0x08, 2.0]],
	[["Tab", "", 0x09, 1.5], ["Q", "Й", 0x51, 1.0], ["W", "Ц", 0x57, 1.0], ["E", "У", 0x45, 1.0], ["R", "К", 0x52, 1.0],
		["T", "Е", 0x54, 1.0], ["Y", "Н", 0x59, 1.0], ["U", "Г", 0x55, 1.0], ["I", "Ш", 0x49, 1.0], ["O", "Щ", 0x4F, 1.0],
		["P", "З", 0x50, 1.0], ["[", "Х", 0xDB, 1.0], ["]", "Ъ", 0xDD, 1.0], ["\\", "", 0xDC, 1.5]],
	[["Caps", "", 0x14, 1.75], ["A", "Ф", 0x41, 1.0], ["S", "Ы", 0x53, 1.0], ["D", "В", 0x44, 1.0], ["F", "А", 0x46, 1.0],
		["G", "П", 0x47, 1.0], ["H", "Р", 0x48, 1.0], ["J", "О", 0x4A, 1.0], ["K", "Л", 0x4B, 1.0], ["L", "Д", 0x4C, 1.0],
		[";", "Ж", 0xBA, 1.0], ["'", "Э", 0xDE, 1.0], ["Enter", "", 0x0D, 2.25]],
	[["Shift", "", VK_SHIFT, 2.25], ["Z", "Я", 0x5A, 1.0], ["X", "Ч", 0x58, 1.0], ["C", "С", 0x43, 1.0], ["V", "М", 0x56, 1.0],
		["B", "И", 0x42, 1.0], ["N", "Т", 0x4E, 1.0], ["M", "Ь", 0x4D, 1.0], [",", "Б", 0xBC, 1.0], [".", "Ю", 0xBE, 1.0],
		["/", ".", 0xBF, 1.0], ["⇧", "", VK_SHIFT, 0.75], ["↑", "", 0x26, 1.0]],
	[["Ctrl", "", VK_CONTROL, 1.5], ["Win", "", VK_LWIN, 1.25], ["Alt", "", VK_MENU, 1.25], ["", "", 0x20, 7.0],
		["Яз", "", LANGUAGE, 1.0], ["←", "", 0x25, 1.0], ["↓", "", 0x28, 1.0], ["→", "", 0x27, 1.0]],
]

## The modifiers held for the next key (virtual keys).
var held: Array = []
## The key down now (index into keys()) and when it repeats next; -1 none.
var down := -1
var _repeat_at := 0.0
var _repeat_combo := PackedInt32Array()


## Every key flat: [label, Russian label, virtual key, rect] with the rect in
## metres on the keyboard's face (x right, y up, centred on the keyboard).
static func keys() -> Array:
	var size := extent()
	var list: Array = []
	for r in ROWS.size():
		var x := -size.x * 0.5
		var y := size.y * 0.5 - (r + 1) * UNIT
		for key: Array in ROWS[r]:
			var width: float = key[3] * UNIT
			list.append([key[0], key[1], key[2], Rect2(x + GAP * 0.5, y + GAP * 0.5, width - GAP, UNIT - GAP)])
			x += width
	return list


## The keyboard's width and height (metres).
static func extent() -> Vector2:
	var widest := 0.0
	for row: Array in ROWS:
		var width := 0.0
		for key: Array in row:
			width += key[3]
		widest = maxf(widest, width)
	return Vector2(widest * UNIT, ROWS.size() * UNIT)


## The key at `at` (metres on the face), or -1 between and outside the keys.
static func key_at(at: Vector2) -> int:
	var list := keys()
	for i in list.size():
		if (list[i][3] as Rect2).has_point(at):
			return i
	return -1


## Whether a Windows layout (language id, MouseInput.get_keyboard_layout) is Russian.
static func is_russian(layout: int) -> bool:
	return layout & 0x3FF == 0x19


## What key `index` shows under that layout: its Russian letter, if it has one.
static func label_of(index: int, russian: bool) -> String:
	var key: Array = keys()[index]
	return key[1] if russian and key[1] != "" else key[0]


static func is_modifier(virtual_key: int) -> bool:
	return virtual_key in MODIFIERS


## A key goes down: a modifier is held for the next key (pressed again, the held
## modifiers are sent by themselves, e.g. Shift+Alt, and let go);
## any other key returns what to send — the held modifiers with it — and lets
## the modifiers go. `now` in seconds, for the repeat.
func press(index: int, now: float) -> PackedInt32Array:
	var list := keys()
	if index < 0 or index >= list.size():
		return PackedInt32Array()
	var virtual_key: int = list[index][2]
	if is_modifier(virtual_key):
		down = -1
		if virtual_key in held:
			var alone := PackedInt32Array(held)
			held.clear()
			return alone
		held.append(virtual_key)
		return PackedInt32Array()
	# The combo as pressed repeats, modifiers too (they are let go for the next key).
	_repeat_combo = _send(virtual_key)
	down = index if virtual_key != LANGUAGE else -1
	_repeat_at = now + REPEAT_DELAY_SEC
	return _repeat_combo


## Each frame while the key is held: what to send again (empty when not yet).
func hold(now: float) -> PackedInt32Array:
	if down < 0 or now < _repeat_at:
		return PackedInt32Array()
	_repeat_at = now + REPEAT_EVERY_SEC
	return _repeat_combo


func release() -> void:
	down = -1


func _send(virtual_key: int) -> PackedInt32Array:
	var combo := _combo(virtual_key)
	held.clear()
	return combo


func _combo(virtual_key: int) -> PackedInt32Array:
	var combo := PackedInt32Array(held)
	if virtual_key == LANGUAGE:
		combo.append_array([VK_LWIN, 0x20])
	else:
		combo.append(virtual_key)
	return combo
