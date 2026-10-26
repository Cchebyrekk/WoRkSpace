// The PC side of the own video link (slice o3): one monitor, captured with
// Windows.Graphics.Capture, converted to NV12 by the D3D11 video processor,
// encoded by the hardware H.264 encoder through Media Foundation and sent to one
// TCP client. Windows-only, like win_backend.cpp; see StreamBackend in win_backend.h.

#include <winsock2.h>
#include <ws2tcpip.h>

#include "win_backend.h"

#include <windows.h>

#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <strmif.h>

#include <initguid.h>

#include <codecapi.h>

#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <future>
#include <mutex>
#include <thread>

namespace workplace {

namespace {

namespace capture = winrt::Windows::Graphics::Capture;
namespace directx = winrt::Windows::Graphics::DirectX;

constexpr uint32_t STREAM_VERSION = 1;
// NV12 frames handed to the encoder: it works asynchronously and may still be
// reading one while the next is being written.
constexpr int SURFACES = 4;
// With nothing changing on the desktop WGC sends no frames; the last picture is
// encoded again this often, so a new headset gets one and the quality settles.
constexpr auto REFRESH = std::chrono::milliseconds(1000);

struct Failure {
	std::string what;
};

void check(HRESULT result, const char *step) {
	if (FAILED(result)) {
		char code[16];
		std::snprintf(code, sizeof(code), "0x%08X", static_cast<uint32_t>(result));
		throw Failure{ std::string(step) + ": " + code };
	}
}

void put_u32(std::vector<uint8_t> &out, uint32_t value) {
	for (int shift = 24; shift >= 0; shift -= 8) {
		out.push_back(static_cast<uint8_t>(value >> shift));
	}
}

void put_u64(std::vector<uint8_t> &out, uint64_t value) {
	for (int shift = 56; shift >= 0; shift -= 8) {
		out.push_back(static_cast<uint8_t>(value >> shift));
	}
}

// Whether Annex B bytes carry a sequence parameter set (NAL type 7).
bool has_sps(const uint8_t *data, size_t size) {
	for (size_t i = 0; i + 3 < size; i++) {
		if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 && (data[i + 3] & 0x1f) == 7) {
			return true;
		}
	}
	return false;
}

void codec_u32(ICodecAPI *api, const GUID &key, ULONG value) {
	VARIANT variant{};
	variant.vt = VT_UI4;
	variant.ulVal = value;
	api->SetValue(&key, &variant); // Not every encoder knows every setting.
}

void codec_bool(ICodecAPI *api, const GUID &key, bool value) {
	VARIANT variant{};
	variant.vt = VT_BOOL;
	variant.boolVal = value ? VARIANT_TRUE : VARIANT_FALSE;
	api->SetValue(&key, &variant);
}

std::string narrow(const wchar_t *text) {
	int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
	std::string result(size > 0 ? size - 1 : 0, '\0');
	if (size > 1) {
		WideCharToMultiByte(CP_UTF8, 0, text, -1, result.data(), size, nullptr, nullptr);
	}
	return result;
}

class MfStream : public StreamBackend {
	std::thread thread;
	std::atomic<bool> stopping{ false };
	std::atomic<bool> alive{ false };
	mutable std::mutex stats_mutex;
	StreamStats shared_stats;

	// Everything below belongs to the stream thread.
	HMONITOR monitor = nullptr;
	int port = 0;
	int bitrate_kbps = 0;
	int fps = 0;
	int width = 0;
	int height = 0;

	winrt::com_ptr<ID3D11Device> device;
	winrt::com_ptr<ID3D11DeviceContext> context;
	directx::Direct3D11::IDirect3DDevice winrt_device{ nullptr };
	capture::GraphicsCaptureItem item{ nullptr };
	capture::Direct3D11CaptureFramePool frame_pool{ nullptr };
	capture::GraphicsCaptureSession session{ nullptr };
	winrt::event_token frame_token{};
	HANDLE frame_event = nullptr;

	winrt::com_ptr<ID3D11Texture2D> picture; // the last captured frame, BGRA
	bool have_picture = false;
	winrt::com_ptr<ID3D11VideoDevice> video_device;
	winrt::com_ptr<ID3D11VideoContext> video_context;
	winrt::com_ptr<ID3D11VideoProcessorEnumerator> processor_enum;
	winrt::com_ptr<ID3D11VideoProcessor> processor;
	winrt::com_ptr<ID3D11VideoProcessorInputView> input_view;
	winrt::com_ptr<ID3D11Texture2D> surfaces[SURFACES];
	winrt::com_ptr<ID3D11VideoProcessorOutputView> output_views[SURFACES];
	int next_surface = 0;

	UINT reset_token = 0;
	winrt::com_ptr<IMFDXGIDeviceManager> device_manager;
	winrt::com_ptr<IMFTransform> encoder;
	winrt::com_ptr<IMFMediaEventGenerator> events;
	winrt::com_ptr<ICodecAPI> codec;
	std::vector<uint8_t> sequence_header;
	int need_input = 0;
	std::deque<std::chrono::steady_clock::time_point> in_flight;

	SOCKET listener = INVALID_SOCKET;
	SOCKET client = INVALID_SOCKET;
	bool want_key_frame = false;
	std::chrono::steady_clock::time_point started;

public:
	~MfStream() override { stop(); }

	bool start(void *monitor_handle, int32_t p_port, int32_t p_bitrate_kbps, int32_t p_fps, std::string &error) override {
		stop();
		monitor = static_cast<HMONITOR>(monitor_handle);
		port = p_port;
		bitrate_kbps = p_bitrate_kbps;
		fps = p_fps;
		stopping = false;
		{
			std::lock_guard<std::mutex> lock(stats_mutex);
			shared_stats = StreamStats();
		}
		std::promise<std::string> ready;
		std::future<std::string> result = ready.get_future();
		thread = std::thread([this, &ready] { run(ready); });
		error = result.get();
		if (!error.empty()) {
			thread.join();
			return false;
		}
		return true;
	}

	void stop() override {
		stopping = true;
		if (thread.joinable()) {
			thread.join();
		}
	}

	bool running() const override { return alive.load(); }

	StreamStats stats() const override {
		std::lock_guard<std::mutex> lock(stats_mutex);
		return shared_stats;
	}

private:
	void run(std::promise<std::string> &ready) {
		bool reported = false;
		try {
			try {
				winrt::init_apartment(winrt::apartment_type::multi_threaded);
			} catch (const winrt::hresult_error &) {
			}
			check(MFStartup(MF_VERSION, MFSTARTUP_LITE), "MFStartup");
			open_capture();
			open_converter();
			open_encoder();
			open_listener();
			started = std::chrono::steady_clock::now();
			alive = true;
			reported = true;
			ready.set_value("");
			loop();
		} catch (const Failure &failure) {
			finish(failure.what, ready, reported);
		} catch (const winrt::hresult_error &e) {
			char code[16];
			std::snprintf(code, sizeof(code), "0x%08X", static_cast<uint32_t>(e.code()));
			finish(std::string("WinRT ") + code + " " + winrt::to_string(e.message()), ready, reported);
		} catch (const std::exception &e) {
			finish(e.what(), ready, reported);
		}
		close_all();
		alive = false;
	}

	void finish(const std::string &what, std::promise<std::string> &ready, bool reported) {
		if (!reported) {
			ready.set_value(what.empty() ? "unknown error" : what);
		}
		std::lock_guard<std::mutex> lock(stats_mutex);
		shared_stats.error = what;
	}

	void open_capture() {
		check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
					  D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT, nullptr, 0,
					  D3D11_SDK_VERSION, device.put(), nullptr, context.put()),
				"D3D11CreateDevice");
		// The encoder uses the device from its own threads.
		context.as<ID3D11Multithread>()->SetMultithreadProtected(TRUE);
		winrt::com_ptr<::IInspectable> inspectable;
		check(CreateDirect3D11DeviceFromDXGIDevice(device.as<IDXGIDevice>().get(), inspectable.put()), "WinRT device");
		winrt_device = inspectable.as<directx::Direct3D11::IDirect3DDevice>();

		auto interop = winrt::get_activation_factory<capture::GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
		check(interop->CreateForMonitor(monitor, winrt::guid_of<capture::GraphicsCaptureItem>(), winrt::put_abi(item)),
				"capture item");
		winrt::Windows::Graphics::SizeInt32 size = item.Size();
		// NV12 and H.264 want even sides.
		width = size.Width & ~1;
		height = size.Height & ~1;
		if (width < 64 || height < 64 || width > 4096 || height > 4096) {
			throw Failure{ "monitor " + std::to_string(size.Width) + "x" + std::to_string(size.Height) +
				" is outside what H.264 hardware encodes (64..4096)" };
		}

		D3D11_TEXTURE2D_DESC desc{};
		desc.Width = static_cast<UINT>(width);
		desc.Height = static_cast<UINT>(height);
		desc.MipLevels = 1;
		desc.ArraySize = 1;
		desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
		desc.SampleDesc.Count = 1;
		desc.Usage = D3D11_USAGE_DEFAULT;
		desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
		check(device->CreateTexture2D(&desc, nullptr, picture.put()), "picture texture");

		frame_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
		frame_pool = capture::Direct3D11CaptureFramePool::CreateFreeThreaded(
				winrt_device, directx::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
		HANDLE signal = frame_event;
		frame_token = frame_pool.FrameArrived([signal](auto &&, auto &&) { SetEvent(signal); });
		session = frame_pool.CreateCaptureSession(item);
		try {
			session.IsBorderRequired(false);
		} catch (const winrt::hresult_error &) {
		}
		session.IsCursorCaptureEnabled(true);
		session.StartCapture();
		std::lock_guard<std::mutex> lock(stats_mutex);
		shared_stats.width = width;
		shared_stats.height = height;
	}

	void open_converter() {
		video_device = device.as<ID3D11VideoDevice>();
		video_context = context.as<ID3D11VideoContext>();
		D3D11_VIDEO_PROCESSOR_CONTENT_DESC content{};
		content.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
		content.InputFrameRate = { static_cast<UINT>(fps), 1 };
		content.InputWidth = static_cast<UINT>(width);
		content.InputHeight = static_cast<UINT>(height);
		content.OutputFrameRate = { static_cast<UINT>(fps), 1 };
		content.OutputWidth = static_cast<UINT>(width);
		content.OutputHeight = static_cast<UINT>(height);
		content.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
		check(video_device->CreateVideoProcessorEnumerator(&content, processor_enum.put()), "video processor enumerator");
		check(video_device->CreateVideoProcessor(processor_enum.get(), 0, processor.put()), "video processor");

		D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC input{};
		input.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
		check(video_device->CreateVideoProcessorInputView(picture.get(), processor_enum.get(), &input, input_view.put()),
				"video processor input");
		D3D11_TEXTURE2D_DESC desc{};
		desc.Width = static_cast<UINT>(width);
		desc.Height = static_cast<UINT>(height);
		desc.MipLevels = 1;
		desc.ArraySize = 1;
		desc.Format = DXGI_FORMAT_NV12;
		desc.SampleDesc.Count = 1;
		desc.Usage = D3D11_USAGE_DEFAULT;
		desc.BindFlags = D3D11_BIND_RENDER_TARGET;
		D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC output{};
		output.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
		for (int i = 0; i < SURFACES; i++) {
			check(device->CreateTexture2D(&desc, nullptr, surfaces[i].put()), "NV12 texture");
			check(video_device->CreateVideoProcessorOutputView(surfaces[i].get(), processor_enum.get(), &output,
						  output_views[i].put()),
					"video processor output");
		}
		// Desktop RGB is full range; the video is BT.709 with the usual 16..235.
		D3D11_VIDEO_PROCESSOR_COLOR_SPACE rgb{};
		rgb.RGB_Range = 0;
		video_context->VideoProcessorSetStreamColorSpace(processor.get(), 0, &rgb);
		D3D11_VIDEO_PROCESSOR_COLOR_SPACE yuv{};
		yuv.YCbCr_Matrix = 1;
		yuv.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
		video_context->VideoProcessorSetOutputColorSpace(processor.get(), &yuv);
		video_context->VideoProcessorSetStreamAutoProcessingMode(processor.get(), 0, FALSE);
	}

	void open_encoder() {
		MFT_REGISTER_TYPE_INFO input{ MFMediaType_Video, MFVideoFormat_NV12 };
		MFT_REGISTER_TYPE_INFO output{ MFMediaType_Video, MFVideoFormat_H264 };
		IMFActivate **activates = nullptr;
		UINT32 count = 0;
		check(MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, &input, &output,
					  &activates, &count),
				"MFTEnumEx");
		HRESULT activated = E_FAIL;
		std::string name;
		for (UINT32 i = 0; i < count; i++) {
			if (FAILED(activated)) {
				activated = activates[i]->ActivateObject(IID_PPV_ARGS(encoder.put()));
				wchar_t *friendly = nullptr;
				UINT32 length = 0;
				if (SUCCEEDED(activated) &&
						SUCCEEDED(activates[i]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute, &friendly, &length))) {
					name = narrow(friendly);
					CoTaskMemFree(friendly);
				}
			}
			activates[i]->Release();
		}
		CoTaskMemFree(activates);
		if (count == 0) {
			throw Failure{ "no hardware H.264 encoder" };
		}
		check(activated, "activate encoder");

		winrt::com_ptr<IMFAttributes> attributes;
		check(encoder->GetAttributes(attributes.put()), "encoder attributes");
		check(attributes->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE), "async unlock");
		attributes->SetUINT32(MF_LOW_LATENCY, TRUE);

		check(MFCreateDXGIDeviceManager(&reset_token, device_manager.put()), "DXGI device manager");
		check(device_manager->ResetDevice(device.get(), reset_token), "device manager reset");
		check(encoder->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, reinterpret_cast<ULONG_PTR>(device_manager.get())),
				"encoder D3D manager");

		codec = encoder.as<ICodecAPI>();
		codec_u32(codec.get(), CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_CBR);
		codec_u32(codec.get(), CODECAPI_AVEncCommonMeanBitRate, static_cast<ULONG>(bitrate_kbps) * 1000);
		codec_bool(codec.get(), CODECAPI_AVLowLatencyMode, true);
		codec_u32(codec.get(), CODECAPI_AVEncMPVDefaultBPictureCount, 0);
		codec_u32(codec.get(), CODECAPI_AVEncMPVGOPSize, static_cast<ULONG>(fps) * 2);

		winrt::com_ptr<IMFMediaType> out_type;
		check(MFCreateMediaType(out_type.put()), "output type");
		out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
		out_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
		out_type->SetUINT32(MF_MT_AVG_BITRATE, static_cast<UINT32>(bitrate_kbps) * 1000);
		MFSetAttributeSize(out_type.get(), MF_MT_FRAME_SIZE, width, height);
		MFSetAttributeRatio(out_type.get(), MF_MT_FRAME_RATE, fps, 1);
		MFSetAttributeRatio(out_type.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
		out_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
		out_type->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
		out_type->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
		out_type->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
		check(encoder->SetOutputType(0, out_type.get(), 0), "encoder output type");

		winrt::com_ptr<IMFMediaType> in_type;
		check(MFCreateMediaType(in_type.put()), "input type");
		in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
		in_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
		MFSetAttributeSize(in_type.get(), MF_MT_FRAME_SIZE, width, height);
		MFSetAttributeRatio(in_type.get(), MF_MT_FRAME_RATE, fps, 1);
		MFSetAttributeRatio(in_type.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
		in_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
		check(encoder->SetInputType(0, in_type.get(), 0), "encoder input type");
		read_sequence_header();

		events = encoder.as<IMFMediaEventGenerator>();
		check(encoder->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0), "encoder flush");
		check(encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0), "encoder begin");
		check(encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0), "encoder start");
		std::lock_guard<std::mutex> lock(stats_mutex);
		shared_stats.encoder = name;
	}

	// Some encoders put SPS/PPS only into the output type; key frames get it in front.
	void read_sequence_header() {
		sequence_header.clear();
		winrt::com_ptr<IMFMediaType> current;
		if (FAILED(encoder->GetOutputCurrentType(0, current.put()))) {
			return;
		}
		UINT32 size = 0;
		if (SUCCEEDED(current->GetBlobSize(MF_MT_MPEG_SEQUENCE_HEADER, &size)) && size > 0) {
			sequence_header.resize(size);
			current->GetBlob(MF_MT_MPEG_SEQUENCE_HEADER, sequence_header.data(), size, nullptr);
		}
	}

	void open_listener() {
		WSADATA data;
		if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
			throw Failure{ "WSAStartup" };
		}
		listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
		if (listener == INVALID_SOCKET) {
			throw Failure{ "socket" };
		}
		BOOL exclusive = TRUE;
		setsockopt(listener, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char *>(&exclusive), sizeof(exclusive));
		sockaddr_in address{};
		address.sin_family = AF_INET;
		address.sin_addr.s_addr = htonl(INADDR_ANY);
		address.sin_port = htons(static_cast<u_short>(port));
		if (bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 || listen(listener, 1) != 0) {
			throw Failure{ "TCP port " + std::to_string(port) + " is busy (" + std::to_string(WSAGetLastError()) + ")" };
		}
		u_long non_blocking = 1;
		ioctlsocket(listener, FIONBIO, &non_blocking);
	}

	void loop() {
		auto last_input = std::chrono::steady_clock::now() - REFRESH;
		bool fresh = false;
		while (!stopping) {
			accept_client();
			pump_events();
			if (WaitForSingleObject(frame_event, 0) == WAIT_OBJECT_0) {
				fresh = take_frame() || fresh;
			}
			auto now = std::chrono::steady_clock::now();
			bool due = fresh || want_key_frame || now - last_input >= REFRESH;
			if (client != INVALID_SOCKET && have_picture && need_input > 0 && due) {
				encode_picture();
				fresh = false;
				last_input = now;
				continue;
			}
			// The encoder's events have no handle to wait on: a short nap instead.
			if (WaitForSingleObject(frame_event, 2) == WAIT_OBJECT_0) {
				fresh = take_frame() || fresh;
			}
		}
	}

	// Copies the newest captured frame into `picture`; older ones are dropped.
	bool take_frame() {
		capture::Direct3D11CaptureFrame newest{ nullptr };
		for (;;) {
			capture::Direct3D11CaptureFrame frame = frame_pool.TryGetNextFrame();
			if (!frame) {
				break;
			}
			newest = frame;
		}
		if (!newest) {
			return false;
		}
		auto access = newest.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
		winrt::com_ptr<ID3D11Texture2D> texture;
		check(access->GetInterface(IID_PPV_ARGS(texture.put())), "frame texture");
		D3D11_TEXTURE2D_DESC desc{};
		texture->GetDesc(&desc);
		if (static_cast<int>(desc.Width) < width || static_cast<int>(desc.Height) < height) {
			return false; // The monitor changed size; the caller restarts the stream.
		}
		D3D11_BOX box{ 0, 0, 0, static_cast<UINT>(width), static_cast<UINT>(height), 1 };
		context->CopySubresourceRegion(picture.get(), 0, 0, 0, 0, texture.get(), 0, &box);
		have_picture = true;
		std::lock_guard<std::mutex> lock(stats_mutex);
		shared_stats.frames_captured++;
		return true;
	}

	void encode_picture() {
		int index = next_surface;
		next_surface = (next_surface + 1) % SURFACES;
		D3D11_VIDEO_PROCESSOR_STREAM stream{};
		stream.Enable = TRUE;
		stream.pInputSurface = input_view.get();
		check(video_context->VideoProcessorBlt(processor.get(), output_views[index].get(), 0, 1, &stream), "convert to NV12");

		winrt::com_ptr<IMFMediaBuffer> buffer;
		check(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), surfaces[index].get(), 0, FALSE, buffer.put()),
				"surface buffer");
		DWORD length = 0;
		if (auto flat = buffer.try_as<IMF2DBuffer>(); flat && SUCCEEDED(flat->GetContiguousLength(&length))) {
			buffer->SetCurrentLength(length);
		}
		winrt::com_ptr<IMFSample> sample;
		check(MFCreateSample(sample.put()), "sample");
		sample->AddBuffer(buffer.get());
		auto now = std::chrono::steady_clock::now();
		LONGLONG time = std::chrono::duration_cast<std::chrono::nanoseconds>(now - started).count() / 100;
		sample->SetSampleTime(time);
		sample->SetSampleDuration(10'000'000LL / fps);
		if (want_key_frame) {
			codec_u32(codec.get(), CODECAPI_AVEncVideoForceKeyFrame, 1);
			want_key_frame = false;
		}
		check(encoder->ProcessInput(0, sample.get(), 0), "encoder input");
		need_input--;
		in_flight.push_back(now);
	}

	void pump_events() {
		for (;;) {
			winrt::com_ptr<IMFMediaEvent> event;
			HRESULT result = events->GetEvent(MF_EVENT_FLAG_NO_WAIT, event.put());
			if (result == MF_E_NO_EVENTS_AVAILABLE) {
				return;
			}
			check(result, "encoder event");
			MediaEventType type = MEUnknown;
			event->GetType(&type);
			if (type == METransformNeedInput) {
				need_input++;
			} else if (type == METransformHaveOutput) {
				take_output();
			}
		}
	}

	void take_output() {
		MFT_OUTPUT_DATA_BUFFER output{};
		DWORD status = 0;
		HRESULT result = encoder->ProcessOutput(0, 1, &output, &status);
		if (output.pEvents) {
			output.pEvents->Release();
		}
		if (result == MF_E_TRANSFORM_STREAM_CHANGE) {
			winrt::com_ptr<IMFMediaType> type;
			check(encoder->GetOutputAvailableType(0, 0, type.put()), "encoder new type");
			check(encoder->SetOutputType(0, type.get(), 0), "encoder set new type");
			read_sequence_header();
			return;
		}
		winrt::com_ptr<IMFSample> sample;
		sample.attach(output.pSample);
		check(result, "encoder output");
		if (!sample) {
			return;
		}
		auto now = std::chrono::steady_clock::now();
		double encode_ms = 0.0;
		if (!in_flight.empty()) {
			encode_ms = std::chrono::duration<double, std::milli>(now - in_flight.front()).count();
			in_flight.pop_front();
		}
		bool key = MFGetAttributeUINT32(sample.get(), MFSampleExtension_CleanPoint, 0) != 0;
		LONGLONG time = 0;
		sample->GetSampleTime(&time);
		winrt::com_ptr<IMFMediaBuffer> buffer;
		check(sample->ConvertToContiguousBuffer(buffer.put()), "encoded buffer");
		BYTE *data = nullptr;
		DWORD size = 0;
		check(buffer->Lock(&data, nullptr, &size), "lock encoded buffer");
		bool prefix = key && !sequence_header.empty() && !has_sps(data, size);
		std::vector<uint8_t> packet;
		packet.reserve(13 + size + (prefix ? sequence_header.size() : 0));
		put_u32(packet, static_cast<uint32_t>(size + (prefix ? sequence_header.size() : 0)));
		put_u64(packet, static_cast<uint64_t>(time / 10));
		packet.push_back(key ? 1 : 0);
		if (prefix) {
			packet.insert(packet.end(), sequence_header.begin(), sequence_header.end());
		}
		packet.insert(packet.end(), data, data + size);
		buffer->Unlock();
		bool sent = send_all(packet);
		std::lock_guard<std::mutex> lock(stats_mutex);
		shared_stats.frames_encoded++;
		shared_stats.encode_ms = encode_ms;
		if (sent) {
			shared_stats.frames_sent++;
			shared_stats.bytes_sent += packet.size();
		}
	}

	void accept_client() {
		sockaddr_in address{};
		int length = sizeof(address);
		SOCKET incoming = accept(listener, reinterpret_cast<sockaddr *>(&address), &length);
		if (incoming == INVALID_SOCKET) {
			return;
		}
		// The newest headset wins: there is one user.
		close_client();
		client = incoming;
		u_long blocking = 0;
		ioctlsocket(client, FIONBIO, &blocking);
		BOOL no_delay = TRUE;
		setsockopt(client, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char *>(&no_delay), sizeof(no_delay));
		DWORD timeout_ms = 3000;
		setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char *>(&timeout_ms), sizeof(timeout_ms));
		std::vector<uint8_t> header{ 'W', 'R', 'K', 'V' };
		put_u32(header, STREAM_VERSION);
		put_u32(header, static_cast<uint32_t>(width));
		put_u32(header, static_cast<uint32_t>(height));
		put_u32(header, static_cast<uint32_t>(fps));
		want_key_frame = true;
		char ip[INET_ADDRSTRLEN] = {};
		inet_ntop(AF_INET, &address.sin_addr, ip, sizeof(ip));
		{
			std::lock_guard<std::mutex> lock(stats_mutex);
			shared_stats.client = std::string(ip) + ":" + std::to_string(ntohs(address.sin_port));
		}
		send_all(header);
	}

	bool send_all(const std::vector<uint8_t> &bytes) {
		if (client == INVALID_SOCKET) {
			return false;
		}
		size_t done = 0;
		while (done < bytes.size()) {
			int sent = send(client, reinterpret_cast<const char *>(bytes.data() + done), static_cast<int>(bytes.size() - done), 0);
			if (sent <= 0) {
				close_client();
				return false;
			}
			done += static_cast<size_t>(sent);
		}
		return true;
	}

	void close_client() {
		if (client != INVALID_SOCKET) {
			closesocket(client);
			client = INVALID_SOCKET;
		}
		std::lock_guard<std::mutex> lock(stats_mutex);
		shared_stats.client.clear();
	}

	void close_all() {
		close_client();
		if (listener != INVALID_SOCKET) {
			closesocket(listener);
			listener = INVALID_SOCKET;
			WSACleanup();
		}
		if (encoder) {
			encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
			encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
			encoder->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, 0);
		}
		if (auto shutdown = encoder.try_as<IMFShutdown>()) {
			shutdown->Shutdown();
		}
		events = nullptr;
		codec = nullptr;
		encoder = nullptr;
		device_manager = nullptr;
		try {
			if (frame_pool) {
				frame_pool.FrameArrived(frame_token);
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
		for (int i = 0; i < SURFACES; i++) {
			output_views[i] = nullptr;
			surfaces[i] = nullptr;
		}
		input_view = nullptr;
		processor = nullptr;
		processor_enum = nullptr;
		video_context = nullptr;
		video_device = nullptr;
		picture = nullptr;
		have_picture = false;
		winrt_device = nullptr;
		context = nullptr;
		device = nullptr;
		if (frame_event) {
			CloseHandle(frame_event);
			frame_event = nullptr;
		}
		need_input = 0;
		in_flight.clear();
		MFShutdown();
	}
};

} // namespace

StreamBackend *StreamBackend::create() {
	return new MfStream();
}

} // namespace workplace
