#include "win_backend.h"
#include "input_events.h"

#include <windows.h>

#include <aclapi.h>

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
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace workplace {

namespace capture = winrt::Windows::Graphics::Capture;
namespace directx = winrt::Windows::Graphics::DirectX;

// Godot does not mark the process as aware of each monitor's own scale, so
// Windows hands it scaled sizes for monitors at more than 100 % (a 2560x1440
// monitor at 125 % reported as 2048x1152) and scaled virtual-desktop metrics,
// and the cursor landed off the ray once the user changed a scale (18.10.2026).
// Monitor rectangles and cursor moves are worked out in real pixels instead.
struct RealPixels {
	DPI_AWARENESS_CONTEXT previous;
	RealPixels() : previous(SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) {}
	~RealPixels() {
		if (previous != nullptr) {
			SetThreadDpiAwarenessContext(previous);
		}
	}
};

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
		DISPLAY_DEVICEW device{};
		device.cb = sizeof(device);
		if (EnumDisplayDevicesW(info.szDevice, 0, &device, EDD_GET_DEVICE_INTERFACE_NAME)) {
			entry.device_path = winrt::to_string(device.DeviceID);
		}
		list->push_back(entry);
	}
	return TRUE;
}

std::vector<MonitorInfo> enumerate_monitors() {
	RealPixels real_pixels;
	std::vector<MonitorInfo> monitors;
	EnumDisplayMonitors(nullptr, nullptr, monitor_proc, reinterpret_cast<LPARAM>(&monitors));
	return monitors;
}

static std::string describe(const winrt::hresult_error &error, const char *step) {
	char code[16];
	std::snprintf(code, sizeof(code), "0x%08X", static_cast<uint32_t>(error.code()));
	return std::string(step) + ": " + code + " " + winrt::to_string(error.message());
}

// What the frame callback touches. The callback owns a reference to it, so a
// callback already running when the capture is stopped and deleted (panels are
// rebuilt often) still finds it alive; unregistering does not wait for such a call.
struct FrameSink {
	// Guards the D3D11 objects against stop() racing with the frame callback.
	std::mutex mutex;
	winrt::com_ptr<ID3D11DeviceContext> context;
	winrt::com_ptr<ID3D11Texture2D> shared_texture;
	int32_t texture_width = 0;
	int32_t texture_height = 0;
	std::atomic<uint64_t> frames{ 0 };

	void on_frame_arrived(const capture::Direct3D11CaptureFramePool &sender) {
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
};

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

	std::shared_ptr<FrameSink> sink = std::make_shared<FrameSink>();
	int32_t texture_width = 0;
	int32_t texture_height = 0;

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
			{
				std::lock_guard<std::mutex> lock(sink->mutex);
				sink->context = context;
				sink->shared_texture = shared_texture;
				sink->texture_width = texture_width;
				sink->texture_height = texture_height;
			}
			frame_arrived_token = frame_pool.FrameArrived(
					[sink = sink](const capture::Direct3D11CaptureFramePool &sender, const winrt::Windows::Foundation::IInspectable &) {
						sink->on_frame_arrived(sender);
					});
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

		{
			std::lock_guard<std::mutex> lock(sink->mutex);
			sink->shared_texture = nullptr;
			sink->context = nullptr;
		}
		d3d12_texture = nullptr;
		shared_texture = nullptr;
		winrt_device = nullptr;
		context = nullptr;
		device = nullptr;
	}

	void *d3d12_resource() const override { return d3d12_texture.get(); }
	int32_t width() const override { return texture_width; }
	int32_t height() const override { return texture_height; }
	uint64_t frame_count() const override { return sink->frames.load(); }
};

CaptureBackend *CaptureBackend::create() {
	return new WgcCapture();
}

void mouse_position(int32_t &x, int32_t &y) {
	RealPixels real_pixels;
	POINT point{};
	GetCursorPos(&point);
	x = point.x;
	y = point.y;
}

// Input goes through workplace_agent.exe while it runs: as SYSTEM it reaches
// elevated windows (Task Manager, installers, UAC) and the secure desktop, which
// SendInput from this process cannot. Without the agent the app injects itself.
namespace {

std::mutex agent_mutex;
HANDLE agent_pipe = INVALID_HANDLE_VALUE;
ULONGLONG agent_retry_at = 0;
constexpr ULONGLONG AGENT_RETRY_MS = 2000;
// The agent's latest word on whether the secure desktop (UAC, lock screen,
// Ctrl+Alt+Del) is up. Updated by draining status messages; false without an agent.
bool secure_desktop_flag = false;

void close_agent_pipe() {
	if (agent_pipe != INVALID_HANDLE_VALUE) {
		CloseHandle(agent_pipe);
		agent_pipe = INVALID_HANDLE_VALUE;
	}
	agent_retry_at = GetTickCount64() + AGENT_RETRY_MS;
	secure_desktop_flag = false;
}

// Caller holds agent_mutex and the pipe is open. Reads any status messages the
// agent has sent (desktop changes), newest wins.
void drain_status_locked() {
	for (;;) {
		DWORD available = 0;
		if (!PeekNamedPipe(agent_pipe, nullptr, 0, nullptr, &available, nullptr)) {
			close_agent_pipe();
			return;
		}
		if (available < sizeof(StatusRecord)) {
			return;
		}
		StatusRecord record{};
		DWORD read = 0;
		if (!ReadFile(agent_pipe, &record, sizeof(record), &read, nullptr) || read != sizeof(record)) {
			close_agent_pipe();
			return;
		}
		if (record.tag == STATUS_TAG) {
			secure_desktop_flag = record.status == AgentStatus::DESKTOP_SECURE;
		}
	}
}

// The agent's pipe is created by the SYSTEM service; any program could create a
// pipe of that name first and receive every key the app types. So the pipe must
// be owned by SYSTEM or the administrators. WORKPLACE_AGENT_ANY_OWNER=1 lifts this
// for tests/agent_probe.gd, which runs the agent as the user.
bool agent_pipe_trusted(HANDLE pipe) {
	wchar_t any_owner[4] = {};
	if (GetEnvironmentVariableW(L"WORKPLACE_AGENT_ANY_OWNER", any_owner, 4) > 0 && any_owner[0] == L'1') {
		return true;
	}
	PSID owner = nullptr;
	PSECURITY_DESCRIPTOR descriptor = nullptr;
	if (GetSecurityInfo(pipe, SE_KERNEL_OBJECT, OWNER_SECURITY_INFORMATION, &owner, nullptr, nullptr, nullptr, &descriptor) != ERROR_SUCCESS) {
		return false;
	}
	bool trusted = owner != nullptr && (IsWellKnownSid(owner, WinLocalSystemSid) || IsWellKnownSid(owner, WinBuiltinAdministratorsSid));
	LocalFree(descriptor);
	return trusted;
}

// Caller holds agent_mutex.
bool open_agent_pipe() {
	if (agent_pipe != INVALID_HANDLE_VALUE) {
		return true;
	}
	if (GetTickCount64() < agent_retry_at) {
		return false;
	}
	// SECURITY_IDENTIFICATION: whoever owns the pipe may learn who we are, not act as us.
	agent_pipe = CreateFileW(AGENT_PIPE_NAME, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
			SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
	if (agent_pipe == INVALID_HANDLE_VALUE) {
		agent_retry_at = GetTickCount64() + AGENT_RETRY_MS;
		return false;
	}
	if (!agent_pipe_trusted(agent_pipe)) {
		close_agent_pipe();
		return false;
	}
	// Wait (briefly, without blocking for good) for the agent to accept us: a
	// refused client must not lose the input it would have sent.
	for (int i = 0; i < 50; i++) {
		DWORD available = 0;
		if (!PeekNamedPipe(agent_pipe, nullptr, 0, nullptr, &available, nullptr)) {
			break;
		}
		if (available > 0) {
			uint8_t answer = 0;
			DWORD read = 0;
			if (ReadFile(agent_pipe, &answer, 1, &read, nullptr) && read == 1 && answer == AGENT_ACCEPTED) {
				return true;
			}
			break;
		}
		Sleep(10);
	}
	close_agent_pipe();
	return false;
}

void deliver(const InputRecord *records, size_t count) {
	{
		std::lock_guard<std::mutex> lock(agent_mutex);
		if (open_agent_pipe()) {
			DWORD written = 0;
			if (WriteFile(agent_pipe, records, static_cast<DWORD>(count * sizeof(InputRecord)), &written, nullptr)) {
				return;
			}
			// The agent went away or turned us down: inject ourselves.
			close_agent_pipe();
		}
	}
	inject_input(records, count);
}

} // namespace

bool agent_connected() {
	std::lock_guard<std::mutex> lock(agent_mutex);
	return open_agent_pipe();
}

bool secure_desktop_active() {
	std::lock_guard<std::mutex> lock(agent_mutex);
	// Keep the connection up even when idle, so a prompt that appears without the
	// user touching anything is still reported.
	if (!open_agent_pipe()) {
		return false;
	}
	drain_status_locked();
	return secure_desktop_flag;
}

namespace {

HANDLE secure_mapping = nullptr;
const SecureFrameHeader *secure_view = nullptr;

bool open_secure_section() {
	if (secure_view != nullptr) {
		return true;
	}
	secure_mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, SECURE_FRAME_SECTION);
	if (secure_mapping == nullptr) {
		return false;
	}
	secure_view = static_cast<const SecureFrameHeader *>(MapViewOfFile(secure_mapping, FILE_MAP_READ, 0, 0, SECURE_FRAME_BYTES));
	if (secure_view == nullptr) {
		CloseHandle(secure_mapping);
		secure_mapping = nullptr;
		return false;
	}
	return true;
}

} // namespace

bool read_secure_frame(uint32_t &last_sequence, int32_t &width, int32_t &height, int32_t &origin_x, int32_t &origin_y,
		std::vector<uint8_t> &out) {
	if (!open_secure_section()) {
		return false;
	}
	const SecureFrameHeader *header = secure_view;
	if (header->magic != SECURE_FRAME_MAGIC) {
		return false;
	}
	// Seqlock: a stable, even sequence that did not move across the copy means the
	// frame is whole. A few tries in case the agent writes mid-read. The sequence
	// is read through volatile with full barriers around the copy, so the compiler
	// cannot merge the two reads or move the copy outside them.
	const volatile uint32_t *sequence = &header->sequence;
	for (int attempt = 0; attempt < 8; attempt++) {
		uint32_t start = *sequence;
		MemoryBarrier();
		if (start & 1u) {
			YieldProcessor();
			continue; // the agent is writing
		}
		uint32_t w = header->width;
		uint32_t h = header->height;
		uint32_t pitch = header->pitch;
		if (w == 0 || h == 0 || w > SECURE_FRAME_MAX_WIDTH || h > SECURE_FRAME_MAX_HEIGHT) {
			return false; // no frame yet
		}
		// Never read past the section, whatever the header says (a torn header is
		// rejected by the sequence check below, but the copy happens first).
		if (pitch < w * 4 || static_cast<size_t>(pitch) * h > SECURE_FRAME_BYTES - sizeof(SecureFrameHeader)) {
			continue;
		}
		if (start == last_sequence) {
			return false; // nothing new since last time
		}
		int32_t ox = header->origin_x;
		int32_t oy = header->origin_y;
		out.resize(static_cast<size_t>(w) * h * 4);
		const uint8_t *source = reinterpret_cast<const uint8_t *>(header + 1);
		for (uint32_t row = 0; row < h; row++) {
			const uint8_t *s = source + static_cast<size_t>(row) * pitch;
			uint8_t *d = out.data() + static_cast<size_t>(row) * w * 4;
			for (uint32_t x = 0; x < w; x++) {
				d[x * 4 + 0] = s[x * 4 + 2]; // B G R A -> R G B A
				d[x * 4 + 1] = s[x * 4 + 1];
				d[x * 4 + 2] = s[x * 4 + 0];
				d[x * 4 + 3] = 255;
			}
		}
		MemoryBarrier();
		if (*sequence == start) {
			last_sequence = start;
			width = static_cast<int32_t>(w);
			height = static_cast<int32_t>(h);
			origin_x = ox;
			origin_y = oy;
			return true;
		}
	}
	return false;
}

void mouse_move(int32_t x, int32_t y) {
	InputRecord record{ InputType::MOVE, x, y };
	deliver(&record, 1);
}

void mouse_button(int32_t button, bool down) {
	InputRecord record{ InputType::BUTTON, button, down ? 1 : 0 };
	deliver(&record, 1);
}

void mouse_wheel(int32_t delta) {
	InputRecord record{ InputType::WHEEL, delta, 0 };
	deliver(&record, 1);
}

void mouse_hwheel(int32_t delta) {
	InputRecord record{ InputType::HWHEEL, delta, 0 };
	deliver(&record, 1);
}

void key_event(uint16_t virtual_key, bool down) {
	InputRecord record{ InputType::KEY, virtual_key, down ? 1 : 0 };
	deliver(&record, 1);
}

void press_keys(const std::vector<uint16_t> &virtual_keys) {
	std::vector<InputRecord> records;
	for (uint16_t key : virtual_keys) {
		records.push_back({ InputType::KEY, key, 1 });
	}
	for (auto key = virtual_keys.rbegin(); key != virtual_keys.rend(); ++key) {
		records.push_back({ InputType::KEY, *key, 0 });
	}
	if (!records.empty() && records.size() <= AGENT_MAX_RECORDS) {
		deliver(records.data(), records.size());
	}
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
			// The queue must exist before the id is published, or a WM_QUIT posted
			// right away would be lost and stop() would wait for ever.
			MSG queue;
			PeekMessageW(&queue, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
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

// Recording a keyboard shortcut for the radial menu (20.10.2026): a low-level
// keyboard hook on its own thread (the Godot window has no focus) swallows every
// key while recording, so the shortcut does nothing in the focused program, and
// keeps the first non-modifier key with the modifiers held at that moment.
namespace {

std::mutex record_mutex;
std::thread record_thread;
std::atomic<DWORD> record_thread_id{ 0 };
bool record_ctrl = false, record_alt = false, record_shift = false, record_win = false;
bool record_done = false;
std::vector<uint16_t> record_keys;
std::atomic<int> record_seen{ 0 };
// Text mode (slice n2): the characters typed so far and how it ended (0 typing,
// 1 Enter, 2 Esc).
bool record_text_mode = false;
std::wstring record_text;
int record_end = 0;
const size_t RECORD_TEXT_MAX = 40;

bool key_down_now(int key);

// One key typed in text mode (record_mutex held): Enter, Esc and Backspace
// steer, the rest become characters in the focused window's keyboard layout.
// `hooked`: from the hook, which swallows the modifiers too, so Windows never
// sees them down and their state is the hook's own.
void add_text_key(UINT vk, UINT scan, bool hooked) {
	if (vk == VK_RETURN || vk == VK_ESCAPE) {
		record_end = vk == VK_RETURN ? 1 : 2;
		record_done = true;
		return;
	}
	if (vk == VK_BACK) {
		if (!record_text.empty()) {
			record_text.pop_back();
		}
		return;
	}
	if (vk == VK_PACKET) {
		// A character sent as itself (SendInput with KEYEVENTF_UNICODE): in the scan code.
		if (scan >= 0x20 && record_text.size() < RECORD_TEXT_MAX) {
			record_text.push_back(static_cast<wchar_t>(scan));
		}
		return;
	}
	BYTE state[256] = {};
	bool shift = hooked ? record_shift : key_down_now(VK_SHIFT);
	bool ctrl = hooked ? record_ctrl : key_down_now(VK_CONTROL);
	bool alt = hooked ? record_alt : key_down_now(VK_MENU);
	if (shift) state[VK_SHIFT] = state[VK_LSHIFT] = 0x80;
	if (ctrl) state[VK_CONTROL] = state[VK_LCONTROL] = 0x80;
	if (alt) state[VK_MENU] = state[VK_RMENU] = 0x80;
	if ((GetKeyState(VK_CAPITAL) & 1) != 0) {
		state[VK_CAPITAL] = 0x01;
	}
	if (state[VK_CONTROL] != 0 && state[VK_MENU] == 0) {
		return; // Ctrl+key types nothing (AltGr is Ctrl+Alt and does)
	}
	HWND focused = GetForegroundWindow();
	HKL layout = GetKeyboardLayout(focused != nullptr ? GetWindowThreadProcessId(focused, nullptr) : 0);
	wchar_t chars[8] = {};
	// 0x4: the keyboard state (dead keys) of the focused program is left alone.
	int count = ToUnicodeEx(vk, scan, state, chars, 8, 0x4, layout);
	for (int i = 0; i < count && record_text.size() < RECORD_TEXT_MAX; i++) {
		if (chars[i] >= 0x20) {
			record_text.push_back(chars[i]);
		}
	}
}

LRESULT CALLBACK record_proc(int code, WPARAM message, LPARAM data) {
	if (code != HC_ACTION) {
		return CallNextHookEx(nullptr, code, message, data);
	}
	record_seen++;
	const KBDLLHOOKSTRUCT *key = reinterpret_cast<const KBDLLHOOKSTRUCT *>(data);
	if (key->dwExtraInfo == INJECTED_BY_WORKPLACE) {
		return CallNextHookEx(nullptr, code, message, data); // our own keys (gestures, the menu)
	}
	bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
	std::lock_guard<std::mutex> lock(record_mutex);
	switch (key->vkCode) {
		case VK_CONTROL: case VK_LCONTROL: case VK_RCONTROL:
			record_ctrl = down;
			break;
		case VK_MENU: case VK_LMENU: case VK_RMENU:
			record_alt = down;
			break;
		case VK_SHIFT: case VK_LSHIFT: case VK_RSHIFT:
			record_shift = down;
			break;
		case VK_LWIN: case VK_RWIN:
			record_win = down;
			break;
		default:
			if (down && record_text_mode) {
				if (!record_done) {
					add_text_key(key->vkCode, key->scanCode, true);
					if (record_done) {
						PostThreadMessageW(record_thread_id, WM_QUIT, 0, 0);
					}
				}
			} else if (down && !record_done) {
				record_keys.clear();
				if (record_ctrl) record_keys.push_back(VK_CONTROL);
				if (record_alt) record_keys.push_back(VK_MENU);
				if (record_shift) record_keys.push_back(VK_SHIFT);
				if (record_win) record_keys.push_back(VK_LWIN);
				record_keys.push_back(static_cast<uint16_t>(key->vkCode));
				record_done = true;
				PostThreadMessageW(record_thread_id, WM_QUIT, 0, 0);
			}
			break;
	}
	return 1; // swallowed while recording
}

// The hook saw nothing in the headset (20.10.2026: 0 events in 20 s) — Windows
// does not call a hook of an ordinary process while an elevated window has the
// focus. So the keys are also polled; a shortcut found this way is not swallowed.
bool record_was_down[256] = {};

bool key_down_now(int key) {
	return (GetAsyncKeyState(key) & 0x8000) != 0;
}

bool is_modifier(int key) {
	return key == VK_SHIFT || key == VK_CONTROL || key == VK_MENU || key == VK_LWIN || key == VK_RWIN ||
			(key >= VK_LSHIFT && key <= VK_RMENU);
}

void poll_keys(bool first) {
	for (int key = 0x08; key <= 0xFE; key++) {
		bool down = key_down_now(key);
		bool pressed = down && !record_was_down[key];
		record_was_down[key] = down;
		if (first || !pressed || is_modifier(key) || record_seen > 0) {
			continue;
		}
		std::lock_guard<std::mutex> lock(record_mutex);
		if (record_done) {
			return;
		}
		if (record_text_mode) {
			add_text_key(key, MapVirtualKeyW(key, MAPVK_VK_TO_VSC), false);
			continue;
		}
		record_keys.clear();
		if (key_down_now(VK_CONTROL)) record_keys.push_back(VK_CONTROL);
		if (key_down_now(VK_MENU)) record_keys.push_back(VK_MENU);
		if (key_down_now(VK_SHIFT)) record_keys.push_back(VK_SHIFT);
		if (key_down_now(VK_LWIN) || key_down_now(VK_RWIN)) record_keys.push_back(VK_LWIN);
		record_keys.push_back(static_cast<uint16_t>(key));
		record_done = true;
		return;
	}
}

} // namespace

void key_recording_stop() {
	if (!record_thread.joinable()) {
		return;
	}
	PostThreadMessageW(record_thread_id, WM_QUIT, 0, 0);
	record_thread.join();
	record_thread_id = 0;
}

namespace {

bool recording_start(bool text) {
	key_recording_stop();
	{
		std::lock_guard<std::mutex> lock(record_mutex);
		record_ctrl = record_alt = record_shift = record_win = false;
		record_done = false;
		record_keys.clear();
		record_text_mode = text;
		record_text.clear();
		record_end = 0;
	}
	record_seen = 0;
	std::promise<bool> hooked;
	std::future<bool> result = hooked.get_future();
	record_thread = std::thread([&hooked]() {
		HHOOK hook = SetWindowsHookExW(WH_KEYBOARD_LL, record_proc, GetModuleHandleW(nullptr), 0);
		if (hook == nullptr) {
			hooked.set_value(false);
			return;
		}
		// The queue must exist before the id is published, or a WM_QUIT posted
		// right away would be lost and stop() would wait for ever.
		MSG queue;
		PeekMessageW(&queue, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
		record_thread_id = GetCurrentThreadId();
		hooked.set_value(true);
		// The hook is called through this thread's message queue; between
		// messages the keys are polled every 15 ms.
		poll_keys(true);
		bool quit = false;
		while (!quit) {
			MsgWaitForMultipleObjects(0, nullptr, FALSE, 15, QS_ALLINPUT);
			MSG message;
			while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
				if (message.message == WM_QUIT) {
					quit = true;
				}
			}
			if (!quit) {
				poll_keys(false);
			}
		}
		UnhookWindowsHookEx(hook);
	});
	if (result.get()) {
		return true;
	}
	record_thread.join();
	return false;
}

} // namespace

bool key_recording_start() {
	return recording_start(false);
}

bool text_recording_start() {
	return recording_start(true);
}

int text_recording_result(std::wstring &text) {
	std::lock_guard<std::mutex> lock(record_mutex);
	text = record_text;
	return record_end;
}

int key_recording_seen() {
	return record_seen;
}

bool key_recording_result(std::vector<uint16_t> &keys) {
	std::lock_guard<std::mutex> lock(record_mutex);
	if (!record_done) {
		return false;
	}
	keys = record_keys;
	return true;
}

void shutdown_backend() {
	// A recording left running would keep its hook thread (and a joinable static
	// std::thread, which terminates the process at exit).
	key_recording_stop();
	std::lock_guard<std::mutex> lock(agent_mutex);
	close_agent_pipe();
}

} // namespace workplace
