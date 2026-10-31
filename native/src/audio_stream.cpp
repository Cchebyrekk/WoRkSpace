// The PC's sound for the headset (31.10.2026): what the default output device
// plays, taken with WASAPI loopback and sent as 16-bit PCM to one TCP client.
// Windows-only, like video_stream.cpp; see SoundBackend in win_backend.h.

#include <winsock2.h>
#include <ws2tcpip.h>

#include "win_backend.h"

#include <windows.h>

#include <initguid.h>

#include <audioclient.h>
#include <propidl.h>
#include <propkeydef.h>
#include <propsys.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <future>
#include <mutex>
#include <thread>

namespace workplace {

namespace {

constexpr uint32_t SOUND_VERSION = 1;
constexpr int CHANNELS = 2;
constexpr int FRAME_BYTES = CHANNELS * 2;
// What Windows keeps for us between two reads.
constexpr REFERENCE_TIME DEVICE_BUFFER = 2'000'000; // 200 ms in 100 ns
// The samples are read this often.
constexpr auto TICK = std::chrono::milliseconds(5);
// The default output device is asked for this often (headphones plugged in, Link
// started: Windows switches it).
constexpr auto DEVICE_CHECK = std::chrono::milliseconds(1000);
// Samples waiting for the network, at most, and what is kept when that is passed:
// a slow Wi-Fi then loses a piece of sound instead of falling behind for good.
constexpr int MAX_WAITING_MS = 120;
constexpr int KEPT_WAITING_MS = 40;
// The socket's own buffer, small for the same reason.
constexpr int SEND_BUFFER = 8192;

void put_u32(std::vector<uint8_t> &out, uint32_t value) {
	for (int shift = 24; shift >= 0; shift -= 8) {
		out.push_back(static_cast<uint8_t>(value >> shift));
	}
}

std::string narrow(const wchar_t *text) {
	int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
	if (size <= 1) {
		return std::string();
	}
	std::string result(static_cast<size_t>(size - 1), '\0');
	WideCharToMultiByte(CP_UTF8, 0, text, -1, result.data(), size, nullptr, nullptr);
	return result;
}

template <typename T>
void release(T *&pointer) {
	if (pointer) {
		pointer->Release();
		pointer = nullptr;
	}
}

// The sample formats the mix format comes in.
enum class Sample { FLOAT32, INT16, INT24, INT32 };

class WasapiSound : public SoundBackend {
	std::thread thread;
	std::atomic<bool> stopping{ false };
	std::atomic<bool> alive{ false };
	mutable std::mutex stats_mutex;
	SoundStats shared_stats;

	// Everything below belongs to the sound thread.
	int port = 0;
	IMMDeviceEnumerator *enumerator = nullptr;
	IAudioClient *audio_client = nullptr;
	IAudioCaptureClient *capture_client = nullptr;
	std::wstring device_id;
	std::chrono::steady_clock::time_point next_device_check;
	int sample_rate = 0;
	int source_channels = 0;
	int source_frame_bytes = 0;
	Sample sample = Sample::FLOAT32;
	SOCKET listener = INVALID_SOCKET;
	SOCKET client = INVALID_SOCKET;
	// Converted samples not yet sent; the first byte is the next to go.
	std::vector<uint8_t> waiting;
	uint64_t sent_to_client = 0;

public:
	~WasapiSound() override { stop(); }

	bool start(int32_t p_port, std::string &error) override {
		stop();
		port = p_port;
		stopping = false;
		{
			std::lock_guard<std::mutex> lock(stats_mutex);
			shared_stats = SoundStats();
		}
		std::promise<std::string> ready;
		std::future<std::string> started = ready.get_future();
		thread = std::thread([this, &ready]() { run(ready); });
		error = started.get();
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

	bool running() const override { return alive; }

	SoundStats stats() const override {
		std::lock_guard<std::mutex> lock(stats_mutex);
		return shared_stats;
	}

private:
	void run(std::promise<std::string> &ready) {
		HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
		std::string failure = open_listener();
		if (failure.empty() && FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
									   __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(&enumerator)))) {
			failure = "no MMDeviceEnumerator";
		}
		if (!failure.empty()) {
			close_all();
			if (SUCCEEDED(com)) {
				CoUninitialize();
			}
			ready.set_value(failure);
			return;
		}
		// No output device yet is no reason to fail: one is looked for every second.
		open_device();
		next_device_check = std::chrono::steady_clock::now() + DEVICE_CHECK;
		alive = true;
		ready.set_value("");
		while (!stopping) {
			accept_client();
			watch_client();
			auto now = std::chrono::steady_clock::now();
			if (now >= next_device_check) {
				next_device_check = now + DEVICE_CHECK;
				if (default_device_id() != device_id || !audio_client) {
					close_device();
					open_device();
				}
			}
			if (audio_client && !read_samples()) {
				// The device went away (unplugged, the driver restarted).
				close_device();
			}
			send_waiting();
			std::this_thread::sleep_for(TICK);
		}
		close_all();
		if (SUCCEEDED(com)) {
			CoUninitialize();
		}
		alive = false;
	}

	std::string open_listener() {
		WSADATA data;
		if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
			return "WSAStartup";
		}
		listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
		if (listener == INVALID_SOCKET) {
			WSACleanup();
			return "socket";
		}
		BOOL exclusive = TRUE;
		setsockopt(listener, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char *>(&exclusive), sizeof(exclusive));
		sockaddr_in address{};
		address.sin_family = AF_INET;
		address.sin_addr.s_addr = htonl(INADDR_ANY);
		address.sin_port = htons(static_cast<u_short>(port));
		if (bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 || listen(listener, 1) != 0) {
			return "TCP port " + std::to_string(port) + " is busy (" + std::to_string(WSAGetLastError()) + ")";
		}
		u_long non_blocking = 1;
		ioctlsocket(listener, FIONBIO, &non_blocking);
		return std::string();
	}

	std::wstring default_device_id() {
		IMMDevice *device = nullptr;
		std::wstring id;
		if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device))) {
			LPWSTR text = nullptr;
			if (SUCCEEDED(device->GetId(&text))) {
				id = text;
				CoTaskMemFree(text);
			}
			device->Release();
		}
		return id;
	}

	void open_device() {
		IMMDevice *device = nullptr;
		WAVEFORMATEX *format = nullptr;
		std::string name;
		std::string failure;
		int old_rate = sample_rate;
		if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device))) {
			failure = "no output device";
		} else {
			LPWSTR text = nullptr;
			if (SUCCEEDED(device->GetId(&text))) {
				device_id = text;
				CoTaskMemFree(text);
			}
			IPropertyStore *properties = nullptr;
			if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &properties))) {
				PROPVARIANT value;
				PropVariantInit(&value);
				if (SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &value)) && value.vt == VT_LPWSTR) {
					name = narrow(value.pwszVal);
				}
				PropVariantClear(&value);
				properties->Release();
			}
			if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void **>(&audio_client)))) {
				failure = "IAudioClient";
			} else if (FAILED(audio_client->GetMixFormat(&format))) {
				failure = "GetMixFormat";
			} else if (!take_format(format)) {
				failure = "unknown sample format (" + std::to_string(format->wBitsPerSample) + " bit)";
			} else if (FAILED(audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, DEVICE_BUFFER,
							   0, format, nullptr))) {
				failure = "Initialize (loopback)";
			} else if (FAILED(audio_client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void **>(&capture_client)))) {
				failure = "IAudioCaptureClient";
			} else if (FAILED(audio_client->Start())) {
				failure = "Start";
			}
			device->Release();
		}
		if (format) {
			CoTaskMemFree(format);
		}
		if (!failure.empty()) {
			close_device();
			if (device_id.empty()) {
				device_id = default_device_id();
			}
		}
		{
			std::lock_guard<std::mutex> lock(stats_mutex);
			shared_stats.device = failure.empty() ? name : (name.empty() ? failure : name + ": " + failure);
			shared_stats.sample_rate = failure.empty() ? sample_rate : 0;
			shared_stats.source_channels = failure.empty() ? source_channels : 0;
		}
		// The client's header has the old rate: it connects again and gets the new one.
		if (failure.empty() && old_rate != 0 && sample_rate != old_rate) {
			close_client();
		}
	}

	bool take_format(const WAVEFORMATEX *format) {
		bool floating = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
		bool integer = format->wFormatTag == WAVE_FORMAT_PCM;
		if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE && format->cbSize >= 22) {
			const auto *extensible = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(format);
			floating = IsEqualGUID(extensible->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
			integer = IsEqualGUID(extensible->SubFormat, KSDATAFORMAT_SUBTYPE_PCM);
		}
		if (format->nChannels < 1 || format->nBlockAlign < format->nChannels) {
			return false;
		}
		int bytes = format->nBlockAlign / format->nChannels;
		if (floating && bytes == 4) {
			sample = Sample::FLOAT32;
		} else if (integer && bytes == 2) {
			sample = Sample::INT16;
		} else if (integer && bytes == 3) {
			sample = Sample::INT24;
		} else if (integer && bytes == 4) {
			sample = Sample::INT32;
		} else {
			return false;
		}
		sample_rate = static_cast<int>(format->nSamplesPerSec);
		source_channels = format->nChannels;
		source_frame_bytes = format->nBlockAlign;
		return true;
	}

	int16_t read_sample(const uint8_t *at) const {
		switch (sample) {
			case Sample::FLOAT32: {
				float value;
				std::memcpy(&value, at, 4);
				value = value > 1.0f ? 1.0f : (value < -1.0f ? -1.0f : value);
				return static_cast<int16_t>(value * 32767.0f);
			}
			case Sample::INT16: {
				int16_t value;
				std::memcpy(&value, at, 2);
				return value;
			}
			case Sample::INT24:
				return static_cast<int16_t>(at[1] | (at[2] << 8));
			case Sample::INT32:
				return static_cast<int16_t>(at[2] | (at[3] << 8));
		}
		return 0;
	}

	// Takes what Windows has; false if the device is gone.
	bool read_samples() {
		uint64_t captured = 0;
		while (true) {
			UINT32 next = 0;
			if (FAILED(capture_client->GetNextPacketSize(&next))) {
				return false;
			}
			if (next == 0) {
				break;
			}
			BYTE *data = nullptr;
			UINT32 frames = 0;
			DWORD flags = 0;
			if (FAILED(capture_client->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) {
				return false;
			}
			if (client != INVALID_SOCKET) {
				size_t at = waiting.size();
				waiting.resize(at + static_cast<size_t>(frames) * FRAME_BYTES);
				uint8_t *out = waiting.data() + at;
				if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
					std::memset(out, 0, static_cast<size_t>(frames) * FRAME_BYTES);
				} else {
					int bytes = source_frame_bytes / source_channels;
					for (UINT32 i = 0; i < frames; i++) {
						const uint8_t *frame = data + static_cast<size_t>(i) * source_frame_bytes;
						int16_t left = read_sample(frame);
						int16_t right = source_channels > 1 ? read_sample(frame + bytes) : left;
						std::memcpy(out, &left, 2);
						std::memcpy(out + 2, &right, 2);
						out += FRAME_BYTES;
					}
				}
			}
			captured += frames;
			capture_client->ReleaseBuffer(frames);
		}
		if (captured > 0) {
			std::lock_guard<std::mutex> lock(stats_mutex);
			shared_stats.frames_captured += captured;
		}
		return true;
	}

	void send_waiting() {
		if (client == INVALID_SOCKET || waiting.empty()) {
			return;
		}
		size_t limit = static_cast<size_t>(sample_rate) * MAX_WAITING_MS / 1000 * FRAME_BYTES;
		if (waiting.size() > limit) {
			// A frame begun on the wire is finished first, or the samples after it shift.
			size_t begun = (FRAME_BYTES - sent_to_client % FRAME_BYTES) % FRAME_BYTES;
			size_t kept = static_cast<size_t>(sample_rate) * KEPT_WAITING_MS / 1000 * FRAME_BYTES;
			size_t dropped = (waiting.size() - begun - kept) / FRAME_BYTES * FRAME_BYTES;
			waiting.erase(waiting.begin() + static_cast<std::ptrdiff_t>(begun),
					waiting.begin() + static_cast<std::ptrdiff_t>(begun + dropped));
			std::lock_guard<std::mutex> lock(stats_mutex);
			shared_stats.frames_dropped += dropped / FRAME_BYTES;
		}
		size_t done = 0;
		while (done < waiting.size()) {
			int sent = send(client, reinterpret_cast<const char *>(waiting.data() + done), static_cast<int>(waiting.size() - done), 0);
			if (sent == SOCKET_ERROR) {
				if (WSAGetLastError() != WSAEWOULDBLOCK) {
					close_client();
					return;
				}
				break;
			}
			done += static_cast<size_t>(sent);
		}
		waiting.erase(waiting.begin(), waiting.begin() + static_cast<std::ptrdiff_t>(done));
		sent_to_client += done;
		std::lock_guard<std::mutex> lock(stats_mutex);
		shared_stats.bytes_sent += done;
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
		u_long non_blocking = 1;
		ioctlsocket(client, FIONBIO, &non_blocking);
		BOOL no_delay = TRUE;
		setsockopt(client, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char *>(&no_delay), sizeof(no_delay));
		int buffer = SEND_BUFFER;
		setsockopt(client, SOL_SOCKET, SO_SNDBUF, reinterpret_cast<const char *>(&buffer), sizeof(buffer));
		waiting.clear();
		sent_to_client = 0;
		std::vector<uint8_t> header{ 'W', 'R', 'K', 'A' };
		put_u32(header, SOUND_VERSION);
		put_u32(header, static_cast<uint32_t>(sample_rate));
		put_u32(header, CHANNELS);
		// An empty socket buffer takes the 16 bytes at once; samples never mix with it.
		if (send(client, reinterpret_cast<const char *>(header.data()), static_cast<int>(header.size()), 0) !=
				static_cast<int>(header.size())) {
			close_client();
			return;
		}
		char ip[INET_ADDRSTRLEN] = {};
		inet_ntop(AF_INET, &address.sin_addr, ip, sizeof(ip));
		std::lock_guard<std::mutex> lock(stats_mutex);
		shared_stats.client = std::string(ip) + ":" + std::to_string(ntohs(address.sin_port));
	}

	// The headset sends nothing; reading tells when it has gone.
	void watch_client() {
		if (client == INVALID_SOCKET) {
			return;
		}
		char bytes[256];
		int got = recv(client, bytes, sizeof(bytes), 0);
		if (got == 0 || (got == SOCKET_ERROR && WSAGetLastError() != WSAEWOULDBLOCK)) {
			close_client();
		}
	}

	void close_client() {
		if (client != INVALID_SOCKET) {
			closesocket(client);
			client = INVALID_SOCKET;
		}
		waiting.clear();
		std::lock_guard<std::mutex> lock(stats_mutex);
		shared_stats.client.clear();
	}

	void close_device() {
		if (audio_client) {
			audio_client->Stop();
		}
		release(capture_client);
		release(audio_client);
		device_id.clear();
	}

	void close_all() {
		close_client();
		close_device();
		release(enumerator);
		if (listener != INVALID_SOCKET) {
			closesocket(listener);
			listener = INVALID_SOCKET;
			WSACleanup();
		}
	}
};

} // namespace

SoundBackend *SoundBackend::create() {
	return new WasapiSound();
}

} // namespace workplace
