@tool
extends EditorPlugin
## Slice o3: adds bin/workplace_video.aar (a jar until slice o5d) (built from headset/java by
## headset/java/build_java.ps1) to the Android export, so that GDScript can reach
## com.workplace.headset.VideoReceiver through JavaClassWrapper.

var _export: EditorExportPlugin


func _enter_tree() -> void:
	_export = VideoExport.new()
	add_export_plugin(_export)


func _exit_tree() -> void:
	remove_export_plugin(_export)
	_export = null


class VideoExport extends EditorExportPlugin:
	func _get_name() -> String:
		return "WoRkPlaceVideo"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	# Relative to res://addons/.
	func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		return PackedStringArray(["workplace_video/bin/workplace_video.aar"])
