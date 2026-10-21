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


## Writes the list; the first time a copy of the original file is kept next to it.
## Returns an empty string or what went wrong.
static func write(resolutions: Array[Vector2i]) -> String:
	if resolutions.is_empty():
		return "нужно хотя бы одно разрешение"
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
