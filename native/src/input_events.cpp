#include "input_events.h"

#include <windows.h>

#include <vector>

namespace workplace {

namespace {

// Cursor moves are worked out in real pixels whatever the process is marked as
// (see RealPixels in win_backend.cpp).
struct RealPixelsScope {
	DPI_AWARENESS_CONTEXT previous;
	RealPixelsScope() : previous(SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) {}
	~RealPixelsScope() {
		if (previous != nullptr) {
			SetThreadDpiAwarenessContext(previous);
		}
	}
};

bool to_input(const InputRecord &record, INPUT &input) {
	static const DWORD down_flags[] = { MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_MIDDLEDOWN };
	static const DWORD up_flags[] = { MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_MIDDLEUP };
	input = INPUT{};
	switch (record.type) {
		case InputType::MOVE: {
			int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
			int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
			int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
			int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
			if (width <= 1 || height <= 1) {
				return false;
			}
			// Absolute moves take 0..65535 across the whole virtual desktop.
			input.type = INPUT_MOUSE;
			input.mi.dx = MulDiv(record.a - left, 65535, width - 1);
			input.mi.dy = MulDiv(record.b - top, 65535, height - 1);
			input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
			return true;
		}
		case InputType::BUTTON:
			if (record.a < 0 || record.a > 2) {
				return false;
			}
			input.type = INPUT_MOUSE;
			input.mi.dwFlags = record.b != 0 ? down_flags[record.a] : up_flags[record.a];
			return true;
		case InputType::WHEEL:
		case InputType::HWHEEL:
			input.type = INPUT_MOUSE;
			input.mi.dwFlags = record.type == InputType::WHEEL ? MOUSEEVENTF_WHEEL : MOUSEEVENTF_HWHEEL;
			input.mi.mouseData = static_cast<DWORD>(record.a);
			return true;
		case InputType::KEY: {
			if (record.a <= 0 || record.a > 0xFE) {
				return false;
			}
			WORD key = static_cast<WORD>(record.a);
			input.type = INPUT_KEYBOARD;
			input.ki.wVk = key;
			input.ki.wScan = static_cast<WORD>(MapVirtualKeyW(key, MAPVK_VK_TO_VSC));
			input.ki.dwFlags = record.b != 0 ? 0 : KEYEVENTF_KEYUP;
			input.ki.dwExtraInfo = INJECTED_BY_WORKPLACE;
			// Arrows, navigation keys and the Windows keys live on the extended part of the keyboard.
			switch (key) {
				case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN:
				case VK_HOME: case VK_END: case VK_PRIOR: case VK_NEXT:
				case VK_INSERT: case VK_DELETE: case VK_LWIN: case VK_RWIN: case VK_APPS:
					input.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
					break;
				default:
					break;
			}
			return true;
		}
	}
	return false;
}

} // namespace

uint32_t inject_input(const InputRecord *records, size_t count) {
	RealPixelsScope real_pixels;
	std::vector<INPUT> inputs;
	inputs.reserve(count);
	for (size_t i = 0; i < count; i++) {
		INPUT input;
		if (to_input(records[i], input)) {
			inputs.push_back(input);
		}
	}
	if (inputs.empty()) {
		return 0;
	}
	return SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
}

} // namespace workplace
