class_name PanelMips
extends RefCounted
## Branch pc-render: a panel's picture with mipmaps for its mesh. Seen from afar
## a 1920-pixel monitor covers a few hundred pixels of an eye, and its viewport's
## texture (which has no mipmaps) was sampled straight — text far away smeared
## and shimmered, while close up it was sharp (30.10.2026). Each time the
## viewport has a new picture it is copied into level 0 here and a compute
## shader halves it level by level (averaging in linear colour, so thin dark
## text keeps its weight). `texture` goes on the material.

const SHADER := """
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba8) uniform restrict readonly image2D source;
layout(set = 0, binding = 1, rgba8) uniform restrict writeonly image2D target;

vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 to_srgb(vec3 c) {
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(target);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}
	ivec2 last = imageSize(source) - 1;
	ivec2 at = pixel * 2;
	vec4 a = imageLoad(source, min(at, last));
	vec4 b = imageLoad(source, min(at + ivec2(1, 0), last));
	vec4 c = imageLoad(source, min(at + ivec2(0, 1), last));
	vec4 d = imageLoad(source, min(at + ivec2(1, 1), last));
	vec3 sum = to_linear(a.rgb) + to_linear(b.rgb) + to_linear(c.rgb) + to_linear(d.rgb);
	imageStore(target, pixel, vec4(to_srgb(sum * 0.25), (a.a + b.a + c.a + d.a) * 0.25));
}
"""

## Shared by every panel (one pipeline).
static var _rd: RenderingDevice
static var _shader := RID()
static var _pipeline := RID()

var texture := Texture2DRD.new()
## Grows each time the texture is made anew: a material must take `texture` only
## after that — given it before, it kept Texture2DRD's placeholder and the panel
## stayed white (30.10.2026).
var generation := 0
var _size := Vector2i.ZERO
var _rid := RID()
## One storage view per level, and a uniform set per step (level i-1 -> i).
var _levels: Array[RID] = []
var _sets: Array[RID] = []
var _failed := false


## On the rendering thread: takes the viewport's current picture.
func update(viewport_texture: RID) -> void:
	if _failed:
		return
	var rd := RenderingServer.get_rendering_device()
	var source := RenderingServer.texture_get_rd_texture(viewport_texture)
	if not source.is_valid():
		return
	var format := rd.texture_get_format(source)
	var size := Vector2i(format.width, format.height)
	if size != _size or not _rid.is_valid():
		print("[remote] мип-уровни экрана: %dx%d, формат картинки %d, уровней %d" % [size.x, size.y, format.format,
				int(floor(log(maxf(size.x, size.y)) / log(2.0))) + 1])
		release()
		if not _make(rd, size):
			_failed = true
			release()
			print("[remote] мип-уровни экрана не сделались — экран будет как без них")
			return
	rd.texture_copy(source, _rid, Vector3.ZERO, Vector3.ZERO, Vector3(size.x, size.y, 1), 0, 0, 0, 0)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	for level in range(1, _levels.size()):
		var level_size := Vector2i(maxi(size.x >> level, 1), maxi(size.y >> level, 1))
		rd.compute_list_bind_uniform_set(list, _sets[level - 1], 0)
		rd.compute_list_dispatch(list, ceili(level_size.x / 8.0), ceili(level_size.y / 8.0), 1)
		rd.compute_list_add_barrier(list)
	rd.compute_list_end()


func release() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return
	texture.texture_rd_rid = RID()
	for uniform_set in _sets:
		if rd.uniform_set_is_valid(uniform_set):
			rd.free_rid(uniform_set)
	_sets.clear()
	for view in _levels:
		if view.is_valid():
			rd.free_rid(view)
	_levels.clear()
	if _rid.is_valid():
		rd.free_rid(_rid)
	_rid = RID()
	_size = Vector2i.ZERO


func _make(rd: RenderingDevice, size: Vector2i) -> bool:
	if not _pipeline.is_valid():
		_rd = rd
		var source := RDShaderSource.new()
		source.source_compute = SHADER
		var spirv := rd.shader_compile_spirv_from_source(source)
		if spirv.compile_error_compute != "":
			print("[remote] шейдер мип-уровней не собрался: ", spirv.compile_error_compute)
			return false
		_shader = rd.shader_create_from_spirv(spirv)
		_pipeline = rd.compute_pipeline_create(_shader)
	var levels := int(floor(log(maxf(size.x, size.y)) / log(2.0))) + 1
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.width = size.x
	format.height = size.y
	format.mipmaps = levels
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	# The material samples through an sRGB view (Texture2DRD makes one if allowed).
	format.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	format.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB)
	_rid = rd.texture_create(format, RDTextureView.new())
	if not _rid.is_valid():
		return false
	for level in levels:
		var view := RDTextureView.new()
		view.format_override = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
		_levels.append(rd.texture_create_shared_from_slice(view, _rid, 0, level, 1, RenderingDevice.TEXTURE_SLICE_2D))
	for level in range(1, levels):
		var source := RDUniform.new()
		source.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		source.binding = 0
		source.add_id(_levels[level - 1])
		var target := RDUniform.new()
		target.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		target.binding = 1
		target.add_id(_levels[level])
		_sets.append(rd.uniform_set_create([source, target], _shader, 0))
	_size = size
	texture.texture_rd_rid = _rid
	generation += 1
	return true
