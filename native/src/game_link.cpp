// The game host's side of the GameLink mapping (slice q1, game_link.h).
// Windows-only, like win_backend.cpp.

#include "game_link.h"
#include "win_backend.h"

#include <windows.h>

#include <mutex>
#include <new>

namespace workplace {

namespace {

std::mutex link_mutex;
HANDLE mapping = nullptr;
HANDLE pose_event = nullptr;
GameLink *view = nullptr;

} // namespace

GameLink *game_link_open(std::string &error) {
	std::lock_guard<std::mutex> lock(link_mutex);
	if (view) {
		return view;
	}
	mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(GameLink), GAME_LINK_MAPPING);
	if (!mapping) {
		error = "CreateFileMapping: " + std::to_string(GetLastError());
		return nullptr;
	}
	bool existed = GetLastError() == ERROR_ALREADY_EXISTS;
	void *memory = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(GameLink));
	if (!memory) {
		error = "MapViewOfFile: " + std::to_string(GetLastError());
		CloseHandle(mapping);
		mapping = nullptr;
		return nullptr;
	}
	pose_event = CreateEventW(nullptr, FALSE, FALSE, GAME_LINK_EVENT);
	if (existed && static_cast<GameLink *>(memory)->magic == GAME_LINK_MAGIC &&
			static_cast<GameLink *>(memory)->version == GAME_LINK_VERSION) {
		// The driver made it first: its half stays.
		view = static_cast<GameLink *>(memory);
	} else {
		view = new (memory) GameLink{};
		view->magic = GAME_LINK_MAGIC;
		view->version = GAME_LINK_VERSION;
	}
	return view;
}

void game_link_signal() {
	if (pose_event) {
		SetEvent(pose_event);
	}
}

void game_link_close() {
	std::lock_guard<std::mutex> lock(link_mutex);
	if (view) {
		view->headset = 0;
		UnmapViewOfFile(view);
		view = nullptr;
	}
	if (mapping) {
		CloseHandle(mapping);
		mapping = nullptr;
	}
	if (pose_event) {
		CloseHandle(pose_event);
		pose_event = nullptr;
	}
}

} // namespace workplace
