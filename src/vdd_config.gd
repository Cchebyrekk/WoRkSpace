class_name VddConfig
## The resolutions the MTT Virtual Display Driver offers come from its settings
## file, shared by all its instances. Changing the list takes effect when the
## driver restarts (VddControl.apply). Everything else in the file is kept as it
## is. parse_resolutions() and with_resolutions() are pure, covered by tests.

const PATH := "C:/VirtualDisplayDriver/vdd_settings.xml"
## Offered on the settings panel; any other resolution already in the file is shown too.
const PRESETS: Array[Vector2i] = [
	Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(1920, 1200),
	Vector2i(2560, 1080), Vector2i(2560, 1440), Vector2i(2560, 1600), Vector2i(2880, 1620),
	Vector2i(3440, 1440), Vector2i(3840, 1600), Vector2i(3840, 2160), Vector2i(5120, 1440), Vector2i(5120, 2160),
]
## Written for each resolution; the driver adds its global refresh rates on top.
const REFRESH_RATE := 120
## Resolutions outside these are never written. 22.10.2026: a list with 15992×8104,
## 13984×1080, 5760×4320 and 1920×200 in it left the driver with no screen at all;
## then tests/vdd_limit_probe.ps1 found widths up to 15360 at 1080 fine, but
## raising the height (1920×4320, then 1920×8640) crashed Windows (bug check 0x10E,
## VIDEO_MEMORY_MANAGEMENT_INTERNAL). One step at a time afterwards: with 2
## instances heights up to 8640 were fine, and with all 8 1920×4320 and 1920×8640
## were fine too — the crash came right after the helper's heavy fallback
## (restarting instances one by one, then reinstalling the driver), not from one
## size alone. So: no more than the sizes tried with 8 instances, 15360×1080 and
## 1920×8640 (the same number of pixels).
const MIN_SIDE := 360
const MAX_SIZE := Vector2i(15360, 8640)
const MAX_PIXELS := 15360 * 1080


## `size` made the biggest supported one of the same shape (the user's wish,
## 22.10.2026: a place too big for the limits gets the most it can, not nothing);
## a too thin side is raised. Steps of 8 px; Vector2i.ZERO if no size of that shape fits.
static func fitted(size: Vector2i) -> Vector2i:
	if size.x <= 0 or size.y <= 0 or supported(size):
		return size if size.x > 0 and size.y > 0 else Vector2i.ZERO
	var scale := 1.0
	if mini(size.x, size.y) < MIN_SIDE:
		scale = float(MIN_SIDE) / mini(size.x, size.y)
	scale = minf(scale, minf(float(MAX_SIZE.x) / size.x, float(MAX_SIZE.y) / size.y))
	scale = minf(scale, sqrt(float(MAX_PIXELS) / (float(size.x) * size.y)))
	var result := Vector2i(floori(size.x * scale / 8.0) * 8, floori(size.y * scale / 8.0) * 8)
	if mini(result.x, result.y) < MIN_SIDE:
		result = Vector2i(ceili(size.x * scale / 8.0) * 8, ceili(size.y * scale / 8.0) * 8)
	return result if supported(result) else Vector2i.ZERO


static func supported(size: Vector2i) -> bool:
	return mini(size.x, size.y) >= MIN_SIDE and size.x <= MAX_SIZE.x and size.y <= MAX_SIZE.y \
			and size.x * size.y <= MAX_PIXELS

static var _block := RegEx.create_from_string("(?s)<resolutions>.*?</resolutions>")
static var _entry := RegEx.create_from_string("(?s)<resolution>\\s*<width>\\s*(\\d+)\\s*</width>\\s*<height>\\s*(\\d+)\\s*</height>")


## The resolutions listed in the file's text, in order, without repeats.
static func parse_resolutions(text: String) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var block := _block.search(text)
	if block == null:
		return result
	for found in _entry.search_all(block.get_string()):
		var size := Vector2i(found.get_string(1).to_int(), found.get_string(2).to_int())
		if not result.has(size):
			result.append(size)
	return result


## The file's text with its list of resolutions replaced by `resolutions`.
static func with_resolutions(text: String, resolutions: Array[Vector2i]) -> String:
	var lines: PackedStringArray = ["<resolutions>"]
	for size in resolutions:
		lines.append("        <resolution>")
		lines.append("            <width>%d</width>" % size.x)
		lines.append("            <height>%d</height>" % size.y)
		lines.append("            <refresh_rate>%d</refresh_rate>" % REFRESH_RATE)
		lines.append("        </resolution>")
	lines.append("    </resolutions>")
	return _block.sub(text, "\n".join(lines))


static func read() -> Array[Vector2i]:
	if not FileAccess.file_exists(PATH):
		return []
	return parse_resolutions(FileAccess.get_file_as_string(PATH))


## The driver's list in the order it is written: 1920×1080 first. When Windows
## sets the screens up afresh it takes the first mode (22.10.2026: 960×1080, a
## wall's half cell, stood first, and every screen came back at 960×1080).
static func ordered(resolutions: Array[Vector2i]) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if resolutions.has(Vector2i(1920, 1080)):
		result.append(Vector2i(1920, 1080))
	for size in resolutions:
		if not result.has(size):
			result.append(size)
	return result


## Writes the list; the first time a copy of the original file is kept next to it.
## Returns an empty string or what went wrong.
static func write(wanted: Array[Vector2i]) -> String:
	var resolutions: Array[Vector2i] = []
	for size in wanted:
		if supported(size):
			resolutions.append(size)
	if resolutions.is_empty():
		return "нужно хотя бы одно разрешение"
	resolutions = ordered(resolutions)
	var text := FileAccess.get_file_as_string(PATH)
	if text.is_empty() or _block.search(text) == null:
		return "не удалось прочитать %s" % PATH
	var backup := PATH.get_basename() + ".workplace.bak"
	if not FileAccess.file_exists(backup):
		var copy := FileAccess.open(backup, FileAccess.WRITE)
		if copy == null:
			return "не удалось сохранить копию %s: %s" % [backup, error_string(FileAccess.get_open_error())]
		copy.store_string(text)
		copy.close()
	# Through a new file renamed over the old one: an interrupted write must not
	# leave the driver an empty or half-written settings file.
	var fresh := PATH + ".new"
	var file := FileAccess.open(fresh, FileAccess.WRITE)
	if file == null:
		return "не удалось записать %s: %s" % [fresh, error_string(FileAccess.get_open_error())]
	file.store_string(with_resolutions(text, resolutions))
	file.close()
	var moved := DirAccess.rename_absolute(fresh, PATH)
	if moved != OK:
		DirAccess.remove_absolute(fresh)
		return "не удалось заменить %s: %s" % [PATH, error_string(moved)]
	return ""
