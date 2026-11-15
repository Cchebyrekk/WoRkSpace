#pragma once
// Slice q1, PC VR games over the own link: what the game host (Godot,
// src/game_host.gd through GameBridge) and the SteamVR driver
// (native/steamvr_driver) share. The host holds the headset's control channel
// and writes its newest poses here; the driver gives them to SteamVR, streams the
// compositor's pictures to the headset itself and says here how. A named file
// mapping of this one struct in the user's session; plain types only (no Godot,
// no Windows), so both sides include it.

#include <atomic>
#include <cstdint>

namespace workplace {

constexpr const wchar_t *GAME_LINK_MAPPING = L"Local\\WoRkPlaceGameLinkV7";
// Set by the host after each new pose: the driver's pose thread waits on it.
constexpr const wchar_t *GAME_LINK_EVENT = L"Local\\WoRkPlaceGameLinkPose";
constexpr uint32_t GAME_LINK_MAGIC = 0x57524b47; // "WRKG"
constexpr uint32_t GAME_LINK_VERSION = 7;

// Godot's and OpenVR's spaces agree (right-handed, Y up, -Z forward, metres).
struct GameTransform {
	float rotation[4]; // quaternion x, y, z, w
	float position[3];
};

// Buttons of a Touch controller (GameController::buttons, ::touches).
enum GameButton : uint32_t {
	GAME_BUTTON_A = 1 << 0, // A / X
	GAME_BUTTON_B = 1 << 1, // B / Y
	GAME_BUTTON_MENU = 1 << 2,
	GAME_BUTTON_STICK = 1 << 3,
	GAME_BUTTON_TRIGGER = 1 << 4,
	GAME_BUTTON_GRIP = 1 << 5,
	GAME_BUTTON_THUMBREST = 1 << 6,
};

struct GameController {
	uint32_t ok; // tracked now
	GameTransform aim;
	GameTransform grip;
	uint32_t buttons; // GameButton, pressed
	uint32_t touches; // GameButton, touched
	float trigger;
	float grip_value;
	float stick[2];
};

struct GameLink {
	uint32_t magic;
	uint32_t version;

	// Host → driver. A seqlock: odd while the host writes; a reader copies and
	// keeps the copy only if the number is even and the same before and after.
	std::atomic<uint32_t> sequence;
	std::atomic<int32_t> game_profile{-1}; // -1 custom, 0 original, 1 q4 comparison
	uint32_t headset; // 1 while a headset is connected
	uint32_t pose_id; // the headset's pose number (the eyes' stream tags pictures with it)
	uint32_t head_ok;
	uint64_t written_us; // StreamBackend::clock_us when written
	GameTransform head; // predicted by the headset to when its picture shows
	GameTransform eyes[2]; // left, right, relative to the head
	float fov[2][4]; // tangents per eye: left (negative), right, down (negative), up
	GameController controllers[2]; // left, right
	uint32_t hand_ok[2];
	float hand_trigger[2];
	GameTransform wrist[2];
	GameTransform hand_grip[2]; // anatomical frame, separate from the pointing ray
	GameTransform bones[2][31]; // SteamVR parent-local bones, root identity

	// Driver → host (written by the driver only).
	std::atomic<uint64_t> driver_beat_us; // clock_us, every RunFrame while SteamVR runs
	std::atomic<uint32_t> eyes_port; // the eyes' stream listens here, 0 while it does not
	std::atomic<uint32_t> eyes_width; // both eyes side by side
	std::atomic<uint32_t> eyes_height;
	std::atomic<uint32_t> frames_presented;
	std::atomic<uint32_t> scene_pid;
	// Latest pulse per hand: duration ms (16), amplitude/1000 (10), Hz (16).
	// Single atomic exchange: no partial parameter reads across processes.
	std::atomic<uint64_t> haptics[2];
};

} // namespace workplace
