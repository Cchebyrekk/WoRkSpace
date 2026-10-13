#include "win_backend.h"

#include <windows.h>

#include <d3d11_4.h>
#include <d3d12.h>
#include <dxgi1_6.h>

#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>

#include <atomic>
#include <cstdio>
#include <future>
#include <mutex>
#include <thread>

namespace workplace {

namespace capture = winrt::Windows::Graphics::Capture;
namespace directx = winrt::Windows::Graphics::DirectX;

static BOOL CALLBACK monitor_proc(HMONITOR monitor, HDC, LPRECT, LPARAM param) {
	auto *list = reinterpret_cast<std::vector<MonitorInfo> *>(param);
	MONITORINFOEXW info{};
	info.cbSize = sizeof(info);
	if (GetMonitorInfoW(monitor, &info)) {
		MonitorInfo entry;
		entry.handle = monitor;
		entry.device_name = winrt::to_string(info.szDevice);
		entry.x = info.rcMonitor.left;
		entry.y = info.rcMonitor.top;
		entry.width = info.rcMonitor.right - info.rcMonitor.left;
		entry.height = info.rcMonitor.bottom - info.rcMonitor.top;
		entry.primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
		list->push_back(entry);
	}
	return TRUE;
}

std::vector<MonitorInfo> enumerate_monitors() {
	std::vector<MonitorInfo> monitors;
	EnumDisplayMonitors(nullptr, nullptr, monitor_proc, reinterpret_cast<LPARAM>(&monitors));
	return monitors;
}

static std::string describe(const winrt::hresult_error &error, const char *step) {
	char code[16];
	std::snprintf(code, sizeof(code), "0x%08X", static_cast<uint32_t>(error.code()));
	return std::string(step) + ": " + code + " " + winrt::to_string(error.message());
}

class WgcCapture : public CaptureBackend {
	winrt::com_ptr<ID3D11Device> device;
	winrt::com_ptr<ID3D11DeviceContext> context;
	winrt::com_ptr<ID3D11Texture2D> shared_texture;
	winrt::com_ptr<ID3D12Resource> d3d12_texture;

	directx::Direct3D11::IDirect3DDevice winrt_device{ nullptr };
	capture::GraphicsCaptureItem item{ nullptr };
	capture::Direct3D11CaptureFramePool frame_pool{ nullptr };
	capture::GraphicsCaptureSession session{ nullptr };
	winrt::event_token frame_arrived_token{};

	// Guards the D3D11 objects against stop() racing with the frame callback.
	std::mutex mutex;
	std::atomic<uint64_t> frames{ 0 };
	int32_t texture_width = 0;
	int32_t texture_height = 0;

	void on_frame_arrived(const capture::Direct3D11CaptureFramePool &sender, const winrt::Windows::Foundation::IInspectable &) {
		try {
			capture::Direct3D11CaptureFrame frame = sender.TryGetNextFrame();
			if (!frame) {
				return;
			}
			std::lock_guard<std::mutex> lock(mutex);
			if (!shared_texture) {
				return;
			}
			// A resolution change needs a new shared texture; until that is handled, drop such frames.
			winrt::Windows::Graphics::SizeInt32 size = frame.ContentSize();
			if (size.Width != texture_width || size.Height != texture_height) {
				return;
			}
			auto access = frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
			winrt::com_ptr<ID3D11Texture2D> frame_texture;
			winrt::check_hresult(access->GetInterface(IID_PPV_ARGS(frame_texture.put())));
			context->CopyResource(shared_texture.get(), frame_texture.get());
			context->Flush();
			frames++;
		} catch (...) {
			// A lost frame is not worth taking the capture thread down for.
		}
	}

public:
	~WgcCapture() override { stop(); }

	bool start(void *monitor_handle, void *d3d12_device, std::string &error) override {
		const char *step = "init";
		try {
			try {
				winrt::init_apartment(winrt::apartment_type::multi_threaded);
			} catch (const winrt::hresult_error &) {
				// The engine already initialised COM on this thread in another mode; that is fine.
			}

			// The shared texture can only be opened by a D3D12 device on the same adapter.
			step = "create D3D11 device";
			ID3D12Device *d3d12 = static_cast<ID3D12Device *>(d3d12_device);
			LUID adapter_luid = d3d12->GetAdapterLuid();
			winrt::com_ptr<IDXGIFactory4> factory;
			winrt::check_hresult(CreateDXGIFactory1(IID_PPV_ARGS(factory.put())));
			winrt::com_ptr<IDXGIAdapter1> adapter;
			winrt::check_hresult(factory->EnumAdapterByLuid(adapter_luid, IID_PPV_ARGS(adapter.put())));
			winrt::check_hresult(D3D11CreateDevice(adapter.get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
					nullptr, 0, D3D11_SDK_VERSION, device.put(), nullptr, context.put()));
			context.as<ID3D11Multithread>()->SetMultithreadProtected(TRUE);

			winrt::com_ptr<::IInspectable> inspectable;
			winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(device.as<IDXGIDevice>().get(), inspectable.put()));
			winrt_device = inspectable.as<directx::Direct3D11::IDirect3DDevice>();

			step = "create capture item";
			auto interop = winrt::get_activation_factory<capture::GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
			winrt::check_hresult(interop->CreateForMonitor(static_cast<HMONITOR>(monitor_handle),
					winrt::guid_of<capture::GraphicsCaptureItem>(), winrt::put_abi(item)));
			winrt::Windows::Graphics::SizeInt32 size = item.Size();
			texture_width = size.Width;
			texture_height = size.Height;

			step = "create shared texture";
			D3D11_TEXTURE2D_DESC desc{};
			desc.Width = static_cast<UINT>(texture_width);
			desc.Height = static_cast<UINT>(texture_height);
			desc.MipLevels = 1;
			desc.ArraySize = 1;
			desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
			desc.SampleDesc.Count = 1;
			desc.Usage = D3D11_USAGE_DEFAULT;
			desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
			desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
			winrt::check_hresult(device->CreateTexture2D(&desc, nullptr, shared_texture.put()));

			step = "open shared texture on D3D12";
			HANDLE shared_handle = nullptr;
			winrt::check_hresult(shared_texture.as<IDXGIResource1>()->CreateSharedHandle(
					nullptr, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE, nullptr, &shared_handle));
			HRESULT opened = d3d12->OpenSharedHandle(shared_handle, IID_PPV_ARGS(d3d12_texture.put()));
			CloseHandle(shared_handle);
			winrt::check_hresult(opened);

			step = "start capture session";
			frame_pool = capture::Direct3D11CaptureFramePool::CreateFreeThreaded(
					winrt_device, directx::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
			frame_arrived_token = frame_pool.FrameArrived({ this, &WgcCapture::on_frame_arrived });
			session = frame_pool.CreateCaptureSession(item);
			try {
				session.IsBorderRequired(false);
			} catch (const winrt::hresult_error &) {
				// Older Windows builds keep the yellow border; capture still works.
			}
			session.IsCursorCaptureEnabled(true);
			session.StartCapture();
			return true;
		} catch (const winrt::hresult_error &e) {
			error = describe(e, step);
		} catch (const std::exception &e) {
			error = std::string(step) + ": " + e.what();
		}
		stop();
		return false;
	}

	void stop() override {
		try {
			if (frame_pool) {
				frame_pool.FrameArrived(frame_arrived_token);
			}
			if (session) {
				session.Close();
			}
			if (frame_pool) {
				frame_pool.Close();
			}
		} catch (...) {
		}
		session = nullptr;
		frame_pool = nullptr;
		item = nullptr;

		std::lock_guard<std::mutex> lock(mutex);
		d3d12_texture = nullptr;
		shared_texture = nullptr;
		winrt_device = nullptr;
		context = nullptr;
		device = nullptr;
	}

	void *d3d12_resource() const override { return d3d12_texture.get(); }
	int32_t width() const override { return texture_width; }
	int32_t height() const override { return texture_height; }
	uint64_t frame_count() const override { return frames.load(); }
};

CaptureBackend *CaptureBackend::create() {
	return new WgcCapture();
}

void mouse_move(int32_t x, int32_t y) {
	int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
	int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
	int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
	int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
	if (width <= 1 || height <= 1) {
		return;
	}
	// Absolute moves take 0..65535 across the whole virtual desktop.
	INPUT input{};
	input.type = INPUT_MOUSE;
	input.mi.dx = MulDiv(x - left, 65535, width - 1);
	input.mi.dy = MulDiv(y - top, 65535, height - 1);
	input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
	SendInput(1, &input, sizeof(INPUT));
}

void mouse_button(int32_t button, bool down) {
	static const DWORD down_flags[] = { MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_MIDDLEDOWN };
	static const DWORD up_flags[] = { MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_MIDDLEUP };
	if (button < 0 || button > 2) {
		return;
	}
	INPUT input{};
	input.type = INPUT_MOUSE;
	input.mi.dwFlags = down ? down_flags[button] : up_flags[button];
	SendInput(1, &input, sizeof(INPUT));
}

void mouse_wheel(int32_t delta) {
	INPUT input{};
	input.type = INPUT_MOUSE;
	input.mi.dwFlags = MOUSEEVENTF_WHEEL;
	input.mi.mouseData = static_cast<DWORD>(delta);
	SendInput(1, &input, sizeof(INPUT));
}

class Win32Hotkey : public HotkeyBackend {
	std::thread thread;
	std::atomic<DWORD> thread_id{ 0 };
	std::atomic<bool> pressed{ false };

public:
	~Win32Hotkey() override { stop(); }

	bool start(bool ctrl, bool alt, bool shift, uint32_t virtual_key) override {
		stop();
		UINT modifiers = MOD_NOREPEAT | (ctrl ? MOD_CONTROL : 0) | (alt ? MOD_ALT : 0) | (shift ? MOD_SHIFT : 0);
		std::promise<bool> registered;
		std::future<bool> result = registered.get_future();
		// RegisterHotKey delivers WM_HOTKEY to the registering thread, so it needs its own message loop.
		thread = std::thread([this, modifiers, virtual_key, &registered]() {
			if (!RegisterHotKey(nullptr, 1, modifiers, virtual_key)) {
				registered.set_value(false);
				return;
			}
			thread_id = GetCurrentThreadId();
			registered.set_value(true);
			MSG message;
			while (GetMessageW(&message, nullptr, 0, 0) > 0) {
				if (message.message == WM_HOTKEY) {
					pressed = true;
				}
			}
			UnregisterHotKey(nullptr, 1);
		});
		if (result.get()) {
			return true;
		}
		thread.join();
		return false;
	}

	void stop() override {
		if (!thread.joinable()) {
			return;
		}
		PostThreadMessageW(thread_id, WM_QUIT, 0, 0);
		thread.join();
		thread_id = 0;
	}

	bool consume_pressed() override { return pressed.exchange(false); }
};

HotkeyBackend *HotkeyBackend::create() {
	return new Win32Hotkey();
}

} // namespace workplace
