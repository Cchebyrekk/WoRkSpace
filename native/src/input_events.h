#pragma once

// Mouse and keyboard events as plain records, shared by the app (which injects
// them itself or hands them to the agent) and by workplace_agent.exe (which runs
// as SYSTEM and can reach elevated windows and the secure desktop). No Godot and
// no Windows types here: the same bytes go through the agent's pipe.

#include <cstddef>
#include <cstdint>

namespace workplace {

// The agent's pipe. Only the user's own session may open it, and the agent
// checks which program is on the other end.
constexpr const wchar_t *AGENT_PIPE_NAME = L"\\\\.\\pipe\\WoRkPlaceAgent";

enum class InputType : uint32_t {
	MOVE = 1, // a, b: virtual-desktop pixels
	BUTTON = 2, // a: 0 left, 1 right, 2 middle; b: 1 down, 0 up
	WHEEL = 3, // a: 120 is one notch, positive scrolls up
	HWHEEL = 4, // a: 120 is one notch, positive scrolls right
	KEY = 5, // a: virtual key; b: 1 down, 0 up
};

struct InputRecord {
	InputType type;
	int32_t a;
	int32_t b;
};
static_assert(sizeof(InputRecord) == 12, "the pipe carries these records as they are");

// The agent's one-byte answer once it has checked the client; nothing comes for a refused one.
constexpr uint8_t AGENT_ACCEPTED = 0xA5;

// Put in dwExtraInfo of every key we inject, so that recording a shortcut can
// tell our own keys from the user's — also when the user's keyboard reaches
// Windows as injected input (a remote or virtual keyboard), 20.10.2026.
constexpr uintptr_t INJECTED_BY_WORKPLACE = 0x57504B42; // "WPKB"

// Records in one pipe message are injected together, in one SendInput call.
constexpr size_t AGENT_MAX_RECORDS = 64;

// What the app may learn from the agent, which sees things the app (medium
// integrity, ordinary session) cannot.
enum class AgentStatus : uint32_t {
	DESKTOP_NORMAL = 0, // the ordinary desktop takes input
	DESKTOP_SECURE = 1, // the secure desktop is up: a UAC prompt, the lock screen or Ctrl+Alt+Del
};

// agent -> app, after the accept byte: sent once at connect and again whenever it
// changes. Its first field is kept distinct from InputType so the two directions
// can never be confused if a buffer is misread.
struct StatusRecord {
	uint32_t tag; // always STATUS_TAG
	AgentStatus status;
};
constexpr uint32_t STATUS_TAG = 0x57505354; // "WPST"
static_assert(sizeof(StatusRecord) == 8, "the pipe carries these records as they are");

// The secure desktop's picture, shared from the agent to the app through a named
// memory section (the agent captures it with Desktop Duplication, which only
// SYSTEM on the Winlogon desktop can do; WGC cannot). A whole desktop, so the
// section is sized for the largest monitor and the real size is in the header.
constexpr const wchar_t *SECURE_FRAME_SECTION = L"Global\\WoRkPlaceSecureFrame";
constexpr uint32_t SECURE_FRAME_MAGIC = 0x53465057; // "WPFS"
constexpr uint32_t SECURE_FRAME_MAX_WIDTH = 3840;
constexpr uint32_t SECURE_FRAME_MAX_HEIGHT = 2160;

// At the start of the section, then `height * pitch` bytes of BGRA. `sequence` is
// a seqlock: odd while the agent writes, even and unchanged across a read means
// the frame is whole. `width`/`height` are zero until the first frame.
struct SecureFrameHeader {
	uint32_t magic; // SECURE_FRAME_MAGIC once the agent has set it up
	uint32_t sequence;
	uint32_t width;
	uint32_t height;
	uint32_t pitch; // bytes per row of the BGRA data
	int32_t origin_x; // the captured monitor's top-left on the virtual desktop
	int32_t origin_y;
	uint32_t reserved;
};

constexpr size_t SECURE_FRAME_BYTES =
		sizeof(SecureFrameHeader) + static_cast<size_t>(SECURE_FRAME_MAX_WIDTH) * SECURE_FRAME_MAX_HEIGHT * 4;

// Injects the records with SendInput, in real pixels. Returns how many Windows took.
uint32_t inject_input(const InputRecord *records, size_t count);

} // namespace workplace
