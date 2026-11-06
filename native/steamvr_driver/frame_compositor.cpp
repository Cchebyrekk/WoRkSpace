// See frame_compositor.h.

#include "frame_compositor.h"

#include <windows.h>

#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi1_2.h>

#include <winrt/base.h>

#include <chrono>
#include <cstdio>
#include <stdexcept>
#include <cstring>
#include <map>
#include <mutex>
#include <thread>
#include <vector>

namespace {

constexpr int SET_SIZE = 3;
constexpr int MAX_LAYERS = 16;

// A full-viewport triangle; u runs -1..1 across the eye, y downwards. Each output
// pixel at u shows the picture's point s = u * (a + (1 - a) * u²) (Foveation in
// src/foveation.gd; the headset draws the picture back on a mesh warped the same).
// Float layers hold linear colour: encoded to sRGB like the 8-bit ones are.
// The picture is the field of view the headset expects (target: tangents left,
// right, top, bottom, OpenVR's y down), resampled from the one the layer was
// really drawn with (drawn): SteamVR kept a field of view it had from before
// and the headset turned the picture by another — a fish-eye (04.11.2026).
const char *SHADER = R"(
cbuffer Layer : register(b0) {
	float4 bounds;
	float4 drawn;
	float4 target;
	float strength;
	float encode;
	float2 unused;
};
Texture2D picture : register(t0);
SamplerState linear_clamp : register(s0);

struct Varyings {
	float4 position : SV_Position;
	float2 u : TEXCOORD0;
};

Varyings vs(uint id : SV_VertexID) {
	Varyings result;
	float2 p = float2((id << 1) & 2, id & 2);
	result.position = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
	result.u = p * 2.0 - 1.0;
	return result;
}

float3 to_srgb(float3 c) {
	c = saturate(c);
	return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

float4 ps(Varyings input) : SV_Target {
	float2 u = input.u;
	float2 s = u * (strength + (1.0 - strength) * u * u);
	float2 tangent = lerp(target.xz, target.yw, (s + 1.0) * 0.5);
	float2 uv = lerp(bounds.xy, bounds.zw, (tangent - drawn.xz) / (drawn.yw - drawn.xz));
	float4 c = picture.Sample(linear_clamp, uv);
	if (encode > 0.5) {
		c.rgb = to_srgb(c.rgb);
	}
	return c;
}
)";

struct LayerConstants {
	float bounds[4];
	float drawn[4];
	float target[4];
	float strength;
	float encode;
	float unused[2];
};

void check(HRESULT result, const char *step) {
	if (FAILED(result)) {
		char text[96];
		std::snprintf(text, sizeof(text), "%s: 0x%08X", step, static_cast<uint32_t>(result));
		throw std::runtime_error(text);
	}
}

// A swap texture's own format family, typeless (so that SteamVR may write it in
// sRGB and this read the bytes as they are), and how this reads it.
struct FormatPlan {
	DXGI_FORMAT texture;
	DXGI_FORMAT view;
	bool linear; // float: linear colour, encoded when drawn
};

FormatPlan plan_for(DXGI_FORMAT format) {
	switch (format) {
		case DXGI_FORMAT_R8G8B8A8_TYPELESS:
		case DXGI_FORMAT_R8G8B8A8_UNORM:
		case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
			return { DXGI_FORMAT_R8G8B8A8_TYPELESS, DXGI_FORMAT_R8G8B8A8_UNORM, false };
		case DXGI_FORMAT_B8G8R8A8_TYPELESS:
		case DXGI_FORMAT_B8G8R8A8_UNORM:
		case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
			return { DXGI_FORMAT_B8G8R8A8_TYPELESS, DXGI_FORMAT_B8G8R8A8_UNORM, false };
		case DXGI_FORMAT_B8G8R8X8_TYPELESS:
		case DXGI_FORMAT_B8G8R8X8_UNORM:
		case DXGI_FORMAT_B8G8R8X8_UNORM_SRGB:
			return { DXGI_FORMAT_B8G8R8X8_TYPELESS, DXGI_FORMAT_B8G8R8X8_UNORM, false };
		case DXGI_FORMAT_R16G16B16A16_TYPELESS:
		case DXGI_FORMAT_R16G16B16A16_FLOAT:
			return { DXGI_FORMAT_R16G16B16A16_TYPELESS, DXGI_FORMAT_R16G16B16A16_FLOAT, true };
		case DXGI_FORMAT_R32G32B32A32_TYPELESS:
		case DXGI_FORMAT_R32G32B32A32_FLOAT:
			return { DXGI_FORMAT_R32G32B32A32_TYPELESS, DXGI_FORMAT_R32G32B32A32_FLOAT, true };
		case DXGI_FORMAT_R10G10B10A2_TYPELESS:
		case DXGI_FORMAT_R10G10B10A2_UNORM:
			return { DXGI_FORMAT_R10G10B10A2_TYPELESS, DXGI_FORMAT_R10G10B10A2_UNORM, false };
		case DXGI_FORMAT_R11G11B10_FLOAT:
			return { DXGI_FORMAT_R11G11B10_FLOAT, DXGI_FORMAT_R11G11B10_FLOAT, true };
		default:
			return { format, format, false };
	}
}

} // namespace

struct FrameCompositor::State {
	std::mutex mutex;
	winrt::com_ptr<ID3D11Device> device;
	winrt::com_ptr<ID3D11DeviceContext> context;
	uint64_t luid = 0;
	uint32_t eye_width = 0;
	uint32_t eye_height = 0;
	float foveation = 1.0f;

	winrt::com_ptr<ID3D11Texture2D> output;
	winrt::com_ptr<ID3D11RenderTargetView> output_view;
	HANDLE output_shared = nullptr;
	winrt::com_ptr<ID3D11VertexShader> vertex_shader;
	winrt::com_ptr<ID3D11PixelShader> pixel_shader;
	winrt::com_ptr<ID3D11Buffer> constants;
	winrt::com_ptr<ID3D11SamplerState> sampler;
	winrt::com_ptr<ID3D11BlendState> blend_over;
	winrt::com_ptr<ID3D11RasterizerState> rasterizer;
	winrt::com_ptr<ID3D11Query> done;

	struct Texture {
		uint32_t pid = 0;
		int set = 0; // the set's first handle, as an id
		winrt::com_ptr<ID3D11Texture2D> texture;
		winrt::com_ptr<ID3D11ShaderResourceView> view;
		bool linear = false;
	};
	// Shared handle -> texture; set (its first handle) -> its handles, and the index in use.
	std::map<vr::SharedTextureHandle_t, Texture> textures;
	struct Set {
		vr::SharedTextureHandle_t handles[SET_SIZE];
		uint32_t pid;
		uint32_t index;
	};
	std::vector<Set> sets;
	std::map<vr::SharedTextureHandle_t, winrt::com_ptr<IDXGIKeyedMutex>> syncs;

	std::vector<vr::IVRDriverDirectModeComponent::SubmitLayerPerEye_t> layers; // two per layer
};

FrameCompositor::FrameCompositor() : state(std::make_unique<State>()) {}

FrameCompositor::~FrameCompositor() = default;

bool FrameCompositor::open(uint32_t eye_width, uint32_t eye_height, float foveation, std::string &error) {
	State &s = *state;
	try {
		check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
					  D3D11_SDK_VERSION, s.device.put(), nullptr, s.context.put()),
				"D3D11CreateDevice");
		DXGI_ADAPTER_DESC adapter_desc{};
		winrt::com_ptr<IDXGIAdapter> adapter;
		check(s.device.as<IDXGIDevice>()->GetAdapter(adapter.put()), "adapter");
		adapter->GetDesc(&adapter_desc);
		s.luid = (static_cast<uint64_t>(static_cast<uint32_t>(adapter_desc.AdapterLuid.HighPart)) << 32) |
				adapter_desc.AdapterLuid.LowPart;
		s.eye_width = eye_width;
		s.eye_height = eye_height;
		s.foveation = foveation;

		D3D11_TEXTURE2D_DESC desc{};
		desc.Width = eye_width * 2;
		desc.Height = eye_height;
		desc.MipLevels = 1;
		desc.ArraySize = 1;
		desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
		desc.SampleDesc.Count = 1;
		desc.Usage = D3D11_USAGE_DEFAULT;
		desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
		desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
		check(s.device->CreateTexture2D(&desc, nullptr, s.output.put()), "output texture");
		check(s.device->CreateRenderTargetView(s.output.get(), nullptr, s.output_view.put()), "output view");
		check(s.output.as<IDXGIResource>()->GetSharedHandle(&s.output_shared), "output handle");

		winrt::com_ptr<ID3DBlob> code;
		winrt::com_ptr<ID3DBlob> errors;
		HRESULT compiled = D3DCompile(SHADER, std::strlen(SHADER), "compositor", nullptr, nullptr, "vs", "vs_5_0", 0, 0,
				code.put(), errors.put());
		if (FAILED(compiled)) {
			throw std::runtime_error(errors ? static_cast<const char *>(errors->GetBufferPointer()) : "vertex shader");
		}
		check(s.device->CreateVertexShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr, s.vertex_shader.put()),
				"vertex shader");
		code = nullptr;
		errors = nullptr;
		compiled = D3DCompile(SHADER, std::strlen(SHADER), "compositor", nullptr, nullptr, "ps", "ps_5_0", 0, 0, code.put(),
				errors.put());
		if (FAILED(compiled)) {
			throw std::runtime_error(errors ? static_cast<const char *>(errors->GetBufferPointer()) : "pixel shader");
		}
		check(s.device->CreatePixelShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr, s.pixel_shader.put()),
				"pixel shader");

		D3D11_BUFFER_DESC buffer{};
		buffer.ByteWidth = sizeof(LayerConstants);
		buffer.Usage = D3D11_USAGE_DYNAMIC;
		buffer.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
		buffer.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
		check(s.device->CreateBuffer(&buffer, nullptr, s.constants.put()), "constants");

		D3D11_SAMPLER_DESC sampler{};
		sampler.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
		sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
		sampler.MaxLOD = D3D11_FLOAT32_MAX;
		check(s.device->CreateSamplerState(&sampler, s.sampler.put()), "sampler");

		D3D11_BLEND_DESC blend{};
		blend.RenderTarget[0].BlendEnable = TRUE;
		blend.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
		blend.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
		blend.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
		blend.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
		blend.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
		blend.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
		blend.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
		check(s.device->CreateBlendState(&blend, s.blend_over.put()), "blend");

		D3D11_RASTERIZER_DESC raster{};
		raster.FillMode = D3D11_FILL_SOLID;
		raster.CullMode = D3D11_CULL_NONE;
		check(s.device->CreateRasterizerState(&raster, s.rasterizer.put()), "rasterizer");

		D3D11_QUERY_DESC query{ D3D11_QUERY_EVENT, 0 };
		check(s.device->CreateQuery(&query, s.done.put()), "query");
	} catch (const std::exception &e) {
		error = e.what();
		return false;
	}
	return true;
}

uint64_t FrameCompositor::adapter_luid() const {
	return state->luid;
}

void *FrameCompositor::output_handle() const {
	return state->output_shared;
}

void FrameCompositor::create_set(uint32_t pid, const vr::IVRDriverDirectModeComponent::SwapTextureSetDesc_t &desc,
		vr::IVRDriverDirectModeComponent::SwapTextureSet_t &out) {
	State &s = *state;
	std::lock_guard<std::mutex> lock(s.mutex);
	FormatPlan plan = plan_for(static_cast<DXGI_FORMAT>(desc.nFormat));
	D3D11_TEXTURE2D_DESC texture{};
	texture.Width = desc.nWidth;
	texture.Height = desc.nHeight;
	texture.MipLevels = 1;
	texture.ArraySize = 1;
	texture.Format = plan.texture;
	texture.SampleDesc.Count = 1;
	texture.Usage = D3D11_USAGE_DEFAULT;
	texture.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
	texture.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
	State::Set set{};
	set.pid = pid;
	set.index = 0;
	out.unTextureFlags = 0;
	for (int i = 0; i < SET_SIZE; i++) {
		State::Texture entry;
		entry.pid = pid;
		entry.linear = plan.linear;
		HANDLE handle = nullptr;
		if (FAILED(s.device->CreateTexture2D(&texture, nullptr, entry.texture.put())) ||
				FAILED(entry.texture.as<IDXGIResource>()->GetSharedHandle(&handle))) {
			out.rSharedTextureHandles[i] = 0;
			continue;
		}
		D3D11_SHADER_RESOURCE_VIEW_DESC view{};
		view.Format = plan.view;
		view.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
		view.Texture2D.MipLevels = 1;
		s.device->CreateShaderResourceView(entry.texture.get(), &view, entry.view.put());
		auto shared = reinterpret_cast<vr::SharedTextureHandle_t>(handle);
		out.rSharedTextureHandles[i] = shared;
		set.handles[i] = shared;
		s.textures[shared] = std::move(entry);
	}
	s.sets.push_back(set);
}

void FrameCompositor::destroy_set(vr::SharedTextureHandle_t handle) {
	State &s = *state;
	std::lock_guard<std::mutex> lock(s.mutex);
	for (auto it = s.sets.begin(); it != s.sets.end(); ++it) {
		bool mine = false;
		for (auto h : it->handles) {
			mine = mine || h == handle;
		}
		if (mine) {
			for (auto h : it->handles) {
				s.textures.erase(h);
			}
			s.sets.erase(it);
			return;
		}
	}
}

void FrameCompositor::destroy_all(uint32_t pid) {
	State &s = *state;
	std::lock_guard<std::mutex> lock(s.mutex);
	for (auto it = s.sets.begin(); it != s.sets.end();) {
		if (it->pid == pid) {
			for (auto h : it->handles) {
				s.textures.erase(h);
			}
			it = s.sets.erase(it);
		} else {
			++it;
		}
	}
}

void FrameCompositor::next_indices(const vr::SharedTextureHandle_t handles[2], uint32_t (*indices)[2]) {
	State &s = *state;
	std::lock_guard<std::mutex> lock(s.mutex);
	for (int eye = 0; eye < 2; eye++) {
		for (auto &set : s.sets) {
			for (int i = 0; i < SET_SIZE; i++) {
				if (set.handles[i] == handles[eye]) {
					set.index = (i + 1) % SET_SIZE;
					(*indices)[eye] = set.index;
				}
			}
		}
	}
}

void FrameCompositor::add_layer(const vr::IVRDriverDirectModeComponent::SubmitLayerPerEye_t (&eyes)[2]) {
	State &s = *state;
	std::lock_guard<std::mutex> lock(s.mutex);
	if (s.layers.size() < MAX_LAYERS * 2) {
		s.layers.push_back(eyes[0]);
		s.layers.push_back(eyes[1]);
	}
}

bool FrameCompositor::compose(vr::SharedTextureHandle_t sync, const float (&target)[2][4], vr::HmdMatrix34_t &pose,
		vr::HmdMatrix44_t (&projection)[2]) {
	State &s = *state;
	std::lock_guard<std::mutex> lock(s.mutex);
	if (s.layers.empty()) {
		return false;
	}
	pose = s.layers[0].mHmdPose;
	projection[0] = s.layers[0].mProjection;
	projection[1] = s.layers[1].mProjection;
	// The compositor releases the sync texture's mutex once its layers are drawn.
	winrt::com_ptr<IDXGIKeyedMutex> keyed;
	if (sync) {
		auto found = s.syncs.find(sync);
		if (found == s.syncs.end()) {
			winrt::com_ptr<ID3D11Texture2D> texture;
			if (SUCCEEDED(s.device->OpenSharedResource(reinterpret_cast<HANDLE>(sync), IID_PPV_ARGS(texture.put())))) {
				found = s.syncs.emplace(sync, texture.try_as<IDXGIKeyedMutex>()).first;
			}
		}
		if (found != s.syncs.end()) {
			keyed = found->second;
		}
		if (keyed && keyed->AcquireSync(0, 10) != S_OK) {
			keyed = nullptr;
		}
	}
	const float black[4] = { 0, 0, 0, 1 };
	ID3D11RenderTargetView *output = s.output_view.get();
	s.context->ClearRenderTargetView(output, black);
	s.context->OMSetRenderTargets(1, &output, nullptr);
	s.context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
	s.context->IASetInputLayout(nullptr);
	s.context->VSSetShader(s.vertex_shader.get(), nullptr, 0);
	s.context->PSSetShader(s.pixel_shader.get(), nullptr, 0);
	ID3D11Buffer *constants = s.constants.get();
	s.context->PSSetConstantBuffers(0, 1, &constants);
	ID3D11SamplerState *sampler = s.sampler.get();
	s.context->PSSetSamplers(0, 1, &sampler);
	s.context->RSSetState(s.rasterizer.get());
	for (size_t layer = 0; layer * 2 < s.layers.size(); layer++) {
		// The first layer is the scene, the rest (overlays, the dashboard) go over it.
		s.context->OMSetBlendState(layer == 0 ? nullptr : s.blend_over.get(), nullptr, 0xffffffff);
		for (int eye = 0; eye < 2; eye++) {
			const auto &submitted = s.layers[layer * 2 + eye];
			auto found = s.textures.find(submitted.hTexture);
			if (found == s.textures.end() || !found->second.view) {
				continue;
			}
			D3D11_MAPPED_SUBRESOURCE mapped{};
			if (FAILED(s.context->Map(s.constants.get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
				continue;
			}
			// The layer's tangents from its projection (OpenVR's: y down).
			const auto &m = submitted.mProjection.m;
			LayerConstants values{ { submitted.bounds.uMin, submitted.bounds.vMin, submitted.bounds.uMax, submitted.bounds.vMax },
				{ (m[0][2] - 1) / m[0][0], (m[0][2] + 1) / m[0][0], (m[1][2] - 1) / m[1][1], (m[1][2] + 1) / m[1][1] },
				{ target[eye][0], target[eye][1], target[eye][2], target[eye][3] }, s.foveation,
				found->second.linear ? 1.0f : 0.0f, { 0, 0 } };
			std::memcpy(mapped.pData, &values, sizeof(values));
			s.context->Unmap(s.constants.get(), 0);
			D3D11_VIEWPORT viewport{ static_cast<float>(eye * s.eye_width), 0.0f, static_cast<float>(s.eye_width),
				static_cast<float>(s.eye_height), 0.0f, 1.0f };
			s.context->RSSetViewports(1, &viewport);
			ID3D11ShaderResourceView *view = found->second.view.get();
			s.context->PSSetShaderResources(0, 1, &view);
			s.context->Draw(3, 0);
		}
	}
	ID3D11ShaderResourceView *none = nullptr;
	s.context->PSSetShaderResources(0, 1, &none);
	s.context->OMSetRenderTargets(0, nullptr, nullptr);
	s.context->End(s.done.get());
	if (keyed) {
		keyed->ReleaseSync(0);
	}
	s.context->Flush();
	s.layers.clear();
	// The stream copies the output on its own device: only once this is drawn.
	auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(20);
	BOOL finished = FALSE;
	while (s.context->GetData(s.done.get(), &finished, sizeof(finished), 0) == S_FALSE &&
			std::chrono::steady_clock::now() < until) {
		std::this_thread::yield();
	}
	return true;
}
