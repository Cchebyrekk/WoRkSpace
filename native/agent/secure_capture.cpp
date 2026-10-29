// Captures the secure desktop (UAC prompt, lock screen, Ctrl+Alt+Del) for the app
// to show in VR. Only a SYSTEM process attached to the "Winlogon" desktop can do
// this, and Windows.Graphics.Capture does not work there, so DXGI Desktop
// Duplication is used instead. Frames go to the shared section SECURE_FRAME_SECTION
// as BGRA; the app reads them (see secure_desktop.* on the app side).
//
// Runs only while the secure desktop is up: on the ordinary desktop the app uses
// its usual per-monitor capture.

#include "input_events.h"

#include <windows.h>

#include <d3d11.h>
#include <dxgi1_2.h>
#include <sddl.h>

#include <cstdarg>
#include <cstdio>
#include <string>

namespace workplace {

// Defined in agent.cpp: one line to agent.log.
void agent_log_v(const wchar_t *tag, const wchar_t *format, va_list args);

namespace {

void cap_log(const wchar_t *format, ...) {
	va_list args;
	va_start(args, format);
	agent_log_v(L" [capture]", format, args);
	va_end(args);
}

template <typename T>
void release(T *&p) {
	if (p != nullptr) {
		p->Release();
		p = nullptr;
	}
}

bool on_winlogon() {
	HDESK desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
	if (desktop == nullptr) {
		return GetLastError() == ERROR_ACCESS_DENIED; // can't tell: assume secure
	}
	wchar_t name[64] = L"";
	DWORD needed = 0;
	GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name), &needed);
	CloseDesktop(desktop);
	return _wcsicmp(name, L"Winlogon") == 0;
}

// The capture thread must sit on the desktop it duplicates. Keeps one handle to
// the thread's desktop and switches only when the input desktop is another one:
// a desktop in use by a thread cannot be closed (CloseDesktop fails), so opening
// a fresh handle every frame and closing it leaked one handle per frame.
HDESK thread_desktop = nullptr;

void follow_input_desktop() {
	HDESK desktop = OpenInputDesktop(0, FALSE, GENERIC_ALL);
	if (desktop == nullptr) {
		return;
	}
	if (thread_desktop != nullptr) {
		wchar_t now[64] = L"";
		wchar_t held[64] = L"";
		DWORD needed = 0;
		GetUserObjectInformationW(desktop, UOI_NAME, now, sizeof(now), &needed);
		GetUserObjectInformationW(thread_desktop, UOI_NAME, held, sizeof(held), &needed);
		if (_wcsicmp(now, held) == 0) {
			CloseDesktop(desktop);
			return;
		}
	}
	if (!SetThreadDesktop(desktop)) {
		cap_log(L"cannot switch to the input desktop (%lu)", GetLastError());
		CloseDesktop(desktop);
		return;
	}
	if (thread_desktop != nullptr) {
		CloseDesktop(thread_desktop);
	}
	thread_desktop = desktop;
}

// The shared section, created once (SYSTEM full control, Users may read).
SecureFrameHeader *map_section(HANDLE &mapping) {
	SECURITY_ATTRIBUTES attributes{ sizeof(attributes), nullptr, FALSE };
	if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;;GA;;;SY)(A;;GR;;;BU)", SDDL_REVISION_1,
			&attributes.lpSecurityDescriptor, nullptr)) {
		cap_log(L"bad security descriptor (%lu)", GetLastError());
		return nullptr;
	}
	mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, &attributes, PAGE_READWRITE,
			static_cast<DWORD>(SECURE_FRAME_BYTES >> 32), static_cast<DWORD>(SECURE_FRAME_BYTES & 0xFFFFFFFF), SECURE_FRAME_SECTION);
	LocalFree(attributes.lpSecurityDescriptor);
	if (mapping == nullptr) {
		cap_log(L"cannot create the frame section (%lu)", GetLastError());
		return nullptr;
	}
	void *view = MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, SECURE_FRAME_BYTES);
	if (view == nullptr) {
		cap_log(L"cannot map the frame section (%lu)", GetLastError());
		CloseHandle(mapping);
		mapping = nullptr;
		return nullptr;
	}
	SecureFrameHeader *header = static_cast<SecureFrameHeader *>(view);
	// The section outlives a restart of the agent while the app holds it open:
	// clear it under the seqlock and keep the sequence counting up, so the app
	// neither reads a half-cleared header nor mistakes a new frame for one it has.
	volatile uint32_t *sequence = &header->sequence;
	*sequence = *sequence | 1u;
	MemoryBarrier();
	header->width = 0;
	header->height = 0;
	header->magic = SECURE_FRAME_MAGIC;
	MemoryBarrier();
	*sequence = *sequence + 1u;
	return header;
}

// One Desktop Duplication of the primary output. Rebuilt whenever the desktop
// switches (ACCESS_LOST) or setup fails.
struct Duplication {
	ID3D11Device *device = nullptr;
	ID3D11DeviceContext *context = nullptr;
	IDXGIOutputDuplication *duplication = nullptr;
	ID3D11Texture2D *staging = nullptr;
	int32_t origin_x = 0;
	int32_t origin_y = 0;
	// The picture written (the monitor shrunk by `scale`) and the monitor's own size.
	uint32_t width = 0;
	uint32_t height = 0;
	uint32_t scale = 1;
	uint32_t source_width = 0;
	uint32_t source_height = 0;

	void stop() {
		release(staging);
		release(duplication);
		release(context);
		release(device);
		width = height = 0;
	}

	// Picks the primary output (top-left at 0,0) on whichever adapter has it and
	// duplicates it; the device has to live on that same adapter.
	bool start() {
		stop();
		IDXGIFactory1 *factory = nullptr;
		if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void **>(&factory)))) {
			cap_log(L"CreateDXGIFactory1 failed");
			return false;
		}
		IDXGIAdapter1 *adapter = nullptr;
		IDXGIOutput *primary = nullptr;
		for (UINT a = 0; primary == nullptr && SUCCEEDED(factory->EnumAdapters1(a, &adapter)); a++) {
			IDXGIOutput *output = nullptr;
			for (UINT i = 0; SUCCEEDED(adapter->EnumOutputs(i, &output)); i++) {
				DXGI_OUTPUT_DESC desc{};
				output->GetDesc(&desc);
				if (desc.AttachedToDesktop && desc.DesktopCoordinates.left == 0 && desc.DesktopCoordinates.top == 0) {
					primary = output;
					origin_x = desc.DesktopCoordinates.left;
					origin_y = desc.DesktopCoordinates.top;
					break;
				}
				output->Release();
			}
			if (primary == nullptr) {
				release(adapter);
			}
		}
		factory->Release();
		if (primary == nullptr) {
			cap_log(L"no primary output found");
			return false;
		}
		D3D_FEATURE_LEVEL level;
		HRESULT hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &device, &level,
				&context);
		adapter->Release();
		if (FAILED(hr)) {
			cap_log(L"D3D11CreateDevice failed (0x%08lx)", hr);
			primary->Release();
			stop();
			return false;
		}
		IDXGIOutput1 *output1 = nullptr;
		HRESULT q = primary->QueryInterface(__uuidof(IDXGIOutput1), reinterpret_cast<void **>(&output1));
		primary->Release();
		if (FAILED(q)) {
			stop();
			return false;
		}
		hr = output1->DuplicateOutput(device, &duplication);
		output1->Release();
		if (FAILED(hr)) {
			cap_log(L"DuplicateOutput failed (0x%08lx)", hr);
			stop();
			return false;
		}
		DXGI_OUTDUPL_DESC desc{};
		duplication->GetDesc(&desc);
		source_width = desc.ModeDesc.Width;
		source_height = desc.ModeDesc.Height;
		if (source_width == 0 || source_height == 0) {
			cap_log(L"output %ux%u is empty", source_width, source_height);
			stop();
			return false;
		}
		scale = 1;
		while (source_width / scale > SECURE_FRAME_MAX_WIDTH || source_height / scale > SECURE_FRAME_MAX_HEIGHT) {
			scale++;
		}
		width = source_width / scale;
		height = source_height / scale;
		D3D11_TEXTURE2D_DESC staging_desc{};
		staging_desc.Width = source_width;
		staging_desc.Height = source_height;
		staging_desc.MipLevels = 1;
		staging_desc.ArraySize = 1;
		staging_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
		staging_desc.SampleDesc.Count = 1;
		staging_desc.Usage = D3D11_USAGE_STAGING;
		staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
		if (FAILED(device->CreateTexture2D(&staging_desc, nullptr, &staging))) {
			cap_log(L"cannot create the staging texture");
			stop();
			return false;
		}
		cap_log(L"duplicating the primary output %ux%u at %d,%d, picture %ux%u", source_width, source_height, origin_x, origin_y,
				width, height);
		return true;
	}

	// Grabs one frame into the section. Returns false on a lost duplication (switch
	// of desktop), so the caller rebuilds; a timeout with no new frame is true.
	bool grab(SecureFrameHeader *header) {
		DXGI_OUTDUPL_FRAME_INFO info{};
		IDXGIResource *resource = nullptr;
		HRESULT hr = duplication->AcquireNextFrame(200, &info, &resource);
		if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
			return true; // nothing changed; the last frame still stands
		}
		if (FAILED(hr)) {
			return false;
		}
		ID3D11Texture2D *frame = nullptr;
		if (SUCCEEDED(resource->QueryInterface(__uuidof(ID3D11Texture2D), reinterpret_cast<void **>(&frame)))) {
			context->CopyResource(staging, frame);
			frame->Release();
			D3D11_MAPPED_SUBRESOURCE mapped{};
			if (SUCCEEDED(context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped))) {
				write_frame(header, mapped.pData, mapped.RowPitch);
				context->Unmap(staging, 0);
			}
		}
		release(resource);
		duplication->ReleaseFrame();
		return true;
	}

	void write_frame(SecureFrameHeader *header, const void *pixels, uint32_t source_pitch) {
		uint32_t dest_pitch = width * 4;
		uint8_t *data = reinterpret_cast<uint8_t *>(header + 1);
		begin_write(header);
		const uint8_t *source = static_cast<const uint8_t *>(pixels);
		for (uint32_t row = 0; row < height; row++) {
			const uint8_t *from = source + static_cast<size_t>(row) * scale * source_pitch;
			uint8_t *to = data + static_cast<size_t>(row) * dest_pitch;
			if (scale == 1) {
				memcpy(to, from, dest_pitch);
				continue;
			}
			// Every scale-th pixel: enough to read and click a prompt.
			const uint32_t *in = reinterpret_cast<const uint32_t *>(from);
			uint32_t *out = reinterpret_cast<uint32_t *>(to);
			for (uint32_t x = 0; x < width; x++) {
				out[x] = in[x * scale];
			}
		}
		header->scale = scale;
		header->width = width;
		header->height = height;
		header->pitch = dest_pitch;
		header->origin_x = origin_x;
		header->origin_y = origin_y;
		end_write(header);
	}

	// The seqlock around every change of the section: odd while writing, even when
	// whole. Through volatile and full barriers, so neither the compiler nor the CPU
	// moves the data across the sequence (the app reads it from another process).
	static void begin_write(SecureFrameHeader *header) {
		volatile uint32_t *sequence = &header->sequence;
		*sequence = *sequence | 1u;
		MemoryBarrier();
	}

	static void end_write(SecureFrameHeader *header) {
		MemoryBarrier();
		volatile uint32_t *sequence = &header->sequence;
		*sequence = *sequence + 1u;
	}
};

} // namespace

// Runs forever on its own thread. Captures the secure desktop whenever it is up.
void run_secure_capture() {
	HANDLE mapping = nullptr;
	SecureFrameHeader *header = map_section(mapping);
	if (header == nullptr) {
		return;
	}

	Duplication duplication;
	bool capturing = false;
	for (;;) {
		if (!on_winlogon()) {
			if (capturing) {
				duplication.stop();
				capturing = false;
				// No frame until the next secure desktop: the app must not show this one again.
				Duplication::begin_write(header);
				header->width = 0;
				header->height = 0;
				Duplication::end_write(header);
				cap_log(L"secure desktop gone, capture stopped");
			}
			Sleep(150);
			continue;
		}
		follow_input_desktop();
		if (!capturing) {
			capturing = duplication.start();
			if (!capturing) {
				Sleep(200);
				continue;
			}
		}
		if (!duplication.grab(header)) {
			duplication.stop();
			capturing = false; // access lost (a desktop switch, a mode change); rebuild next round
			Sleep(50); // not a tight loop of new devices while the switch lasts
		}
	}
}

} // namespace workplace
