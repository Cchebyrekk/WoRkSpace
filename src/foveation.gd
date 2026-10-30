class_name Foveation
extends RefCounted
## Branch pc-render: the eyes are sent with more pixels in the middle, where the
## lens is sharp, and fewer towards the edges (as Quest Link and ALVR do). Along
## each axis a picture coordinate s (-1..1, plain perspective) is stored at
## u (-1..1) with s = warp(u) = u * (a + (1 - a) * u²): around the middle 1/a
## stored pixels per drawn one, at the edges 1/(3 - 2a). The PC warps with a
## compute shader (warp_eyes), the headset draws the stored picture on a mesh
## whose vertices sit at warp(u) (no inverse needed per pixel).
## Below the eyes go `mask_rows` more rows: the alpha (ScreenPanel's holes) as
## grey, warped the same way and squeezed vertically — the video has no alpha.

## a: the middle gets 1/0.55 ≈ 1.8 times the pixels of an even picture of the
## same size, the edges about half.
const STRENGTH := 0.55

const SHADER := """
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2DArray eyes;
layout(set = 0, binding = 1, rgba8) uniform restrict writeonly image2D target;
layout(push_constant, std430) uniform Params {
	vec2 eye_size;
	float strength;
	float mask_rows;
} params;

float warp(float u) {
	return u * (params.strength + (1.0 - params.strength) * u * u);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.eye_size);
	int mask_rows = int(params.mask_rows);
	if (pixel.x >= size.x * 2 || pixel.y >= size.y + mask_rows) {
		return;
	}
	int eye = pixel.x >= size.x ? 1 : 0;
	bool mask = pixel.y >= size.y;
	vec2 u = (vec2(pixel.x - eye * size.x, mask ? float(pixel.y - size.y) * float(size.y) / params.mask_rows : float(pixel.y))
			+ 0.5) / params.eye_size * 2.0 - 1.0;
	vec2 s = vec2(warp(u.x), warp(u.y));
	vec4 c = textureLod(eyes, vec3(s * 0.5 + 0.5, float(eye)), 0.0);
	imageStore(target, pixel, mask ? vec4(vec3(c.a), 1.0) : vec4(c.rgb, 1.0));
}
"""

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
## "source|target" -> uniform set.
var _sets: Dictionary = {}


static func warp(u: float, strength: float = STRENGTH) -> float:
	return u * (strength + (1.0 - strength) * u * u)


## u with warp(u) = s (Newton's method; warp rises steadily), for the headset's mesh.
static func unwarp(s: float, strength: float = STRENGTH) -> float:
	var u := s
	for i in 8:
		var slope := strength + 3.0 * (1.0 - strength) * u * u
		u -= (warp(u, strength) - s) / slope
	return u


## On the rendering thread: writes both eyes of `source` (the render target, a
## 2-layer array) warped into `target` (2 x eye_size, RGBA8 storage), and their
## alpha into the `mask_rows` rows below.
func warp_eyes(source: RID, target: RID, eye_size: Vector2i, mask_rows := 0) -> bool:
	if not _ready():
		return false
	var key := "%s|%s" % [source, target]
	var uniform_set: RID = _sets.get(key, RID())
	if not uniform_set.is_valid() or not _rd.uniform_set_is_valid(uniform_set):
		var eyes := RDUniform.new()
		eyes.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		eyes.binding = 0
		eyes.add_id(_sampler)
		eyes.add_id(source)
		var image := RDUniform.new()
		image.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		image.binding = 1
		image.add_id(target)
		uniform_set = _rd.uniform_set_create([eyes, image], _shader, 0)
		_sets[key] = uniform_set
	var push := PackedFloat32Array([eye_size.x, eye_size.y, STRENGTH, mask_rows]).to_byte_array()
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_set_push_constant(list, push, push.size())
	_rd.compute_list_dispatch(list, ceili(eye_size.x * 2 / 8.0), ceili((eye_size.y + mask_rows) / 8.0), 1)
	_rd.compute_list_end()
	return true


func release() -> void:
	if _rd == null:
		return
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _shader.is_valid():
		_rd.free_rid(_shader)
	if _sampler.is_valid():
		_rd.free_rid(_sampler)
	_sets.clear()


func _ready() -> bool:
	if _pipeline.is_valid():
		return true
	if _rd != null:
		return false  # Failed before.
	_rd = RenderingServer.get_rendering_device()
	var source := RDShaderSource.new()
	source.source_compute = SHADER
	var spirv := _rd.shader_compile_spirv_from_source(source)
	if spirv.compile_error_compute != "":
		print("[remote] шейдер фовеации не собрался: ", spirv.compile_error_compute)
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	var sampler := RDSamplerState.new()
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler)
	return _pipeline.is_valid()
