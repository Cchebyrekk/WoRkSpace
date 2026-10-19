// workplace_agent.exe: injects the app's mouse and keyboard input as SYSTEM, so
// that it reaches elevated windows (Task Manager, installers) and the secure
// desktop (UAC prompts, the lock screen, Ctrl+Alt+Del), which SendInput from the
// app cannot.
//
//   --agent [--allow <exe>]...  serve the pipe in this session (the real work)
//   --spawn [--allow <exe>]...  run as SYSTEM in session 0 (a service or a SYSTEM
//                               task): start "--agent" as SYSTEM in the session
//                               of the user at the console
//   --service                   the WoRkPlaceAgent service (installed by
//                               tools/install_agent.ps1): keeps one agent running
//                               in the console user's session, restarts it after a
//                               crash and when another user takes the console
//
// Safety: the pipe is open only to the user logged on in this session; the program
// on the other end must be one of the allowed executables (registry
// HKLM\SOFTWARE\WoRkPlace\Agent\AllowedClients, REG_MULTI_SZ, written by the admin
// install, plus --allow); only input records are accepted, nothing else.
// Log: %ProgramData%\WoRkPlace\agent\agent.log

#include "input_events.h"

#include <windows.h>

#include <sddl.h>
#include <wtsapi32.h>

#include <cstdarg>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

using namespace workplace;

namespace workplace {

// Defined in secure_capture.cpp: captures the secure desktop into the shared
// section whenever it is up (Desktop Duplication, SYSTEM on Winlogon).
void run_secure_capture();

namespace {
std::wstring log_path;
}

// One line to the log, shared by the service, the agent and its capture thread.
// A single append-only WriteFile per line: appends from several processes and
// threads then never overwrite each other (fopen "a" lost lines that way).
void agent_log_v(const wchar_t *tag, const wchar_t *format, va_list args) {
	if (log_path.empty()) {
		return;
	}
	SYSTEMTIME now;
	GetLocalTime(&now);
	wchar_t text[1024];
	int prefix = swprintf_s(text, L"%02d.%02d %02d:%02d:%02d.%03d [%lu]%s ", now.wDay, now.wMonth, now.wHour, now.wMinute,
			now.wSecond, now.wMilliseconds, GetCurrentProcessId(), tag);
	if (prefix < 0) {
		return;
	}
	int body = _vsnwprintf_s(text + prefix, _countof(text) - prefix - 1, _TRUNCATE, format, args);
	size_t length = prefix + (body < 0 ? wcslen(text + prefix) : static_cast<size_t>(body));
	text[length++] = L'\n';
	char utf8[4096];
	int bytes = WideCharToMultiByte(CP_UTF8, 0, text, static_cast<int>(length), utf8, sizeof(utf8), nullptr, nullptr);
	if (bytes <= 0) {
		return;
	}
	HANDLE file = CreateFileW(log_path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
			OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
	if (file == INVALID_HANDLE_VALUE) {
		return;
	}
	DWORD written = 0;
	WriteFile(file, utf8, static_cast<DWORD>(bytes), &written, nullptr);
	CloseHandle(file);
}

} // namespace workplace

namespace {

void log(const wchar_t *format, ...) {
	va_list args;
	va_start(args, format);
	agent_log_v(L"", format, args);
	va_end(args);
}

void open_log() {
	wchar_t data[MAX_PATH];
	DWORD length = GetEnvironmentVariableW(L"ProgramData", data, MAX_PATH);
	if (length == 0 || length >= MAX_PATH) {
		return;
	}
	std::wstring dir = std::wstring(data) + L"\\WoRkPlace";
	CreateDirectoryW(dir.c_str(), nullptr);
	dir += L"\\agent";
	CreateDirectoryW(dir.c_str(), nullptr);
	log_path = dir + L"\\agent.log";
}

std::wstring sid_string(PSID sid) {
	LPWSTR text = nullptr;
	if (!ConvertSidToStringSidW(sid, &text)) {
		return L"";
	}
	std::wstring result(text);
	LocalFree(text);
	return result;
}

std::wstring token_user_sid(HANDLE token) {
	DWORD size = 0;
	GetTokenInformation(token, TokenUser, nullptr, 0, &size);
	std::vector<BYTE> buffer(size);
	if (size == 0 || !GetTokenInformation(token, TokenUser, buffer.data(), size, &size)) {
		return L"";
	}
	return sid_string(reinterpret_cast<TOKEN_USER *>(buffer.data())->User.Sid);
}

std::wstring own_sid() {
	HANDLE token = nullptr;
	if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
		return L"";
	}
	std::wstring sid = token_user_sid(token);
	CloseHandle(token);
	return sid;
}

bool running_as_system() {
	return own_sid() == L"S-1-5-18";
}

DWORD own_session() {
	DWORD session = 0;
	ProcessIdToSessionId(GetCurrentProcessId(), &session);
	return session;
}

// The user whose desktop this is: the one logged on in our session when we are
// SYSTEM, ourselves otherwise (a manual run for testing).
std::wstring session_user_sid() {
	if (!running_as_system()) {
		return own_sid();
	}
	HANDLE token = nullptr;
	if (!WTSQueryUserToken(own_session(), &token)) {
		return L"";
	}
	std::wstring sid = token_user_sid(token);
	CloseHandle(token);
	return sid;
}

std::vector<std::wstring> allowed_clients(int argc, wchar_t **argv) {
	std::vector<std::wstring> allowed;
	for (int i = 1; i + 1 < argc; i++) {
		if (wcscmp(argv[i], L"--allow") == 0) {
			allowed.push_back(argv[++i]);
		}
	}
	HKEY key = nullptr;
	if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\WoRkPlace\\Agent", 0, KEY_READ, &key) == ERROR_SUCCESS) {
		DWORD type = 0;
		DWORD size = 0;
		if (RegQueryValueExW(key, L"AllowedClients", nullptr, &type, nullptr, &size) == ERROR_SUCCESS && type == REG_MULTI_SZ) {
			std::vector<wchar_t> buffer(size / sizeof(wchar_t) + 2, L'\0');
			if (RegQueryValueExW(key, L"AllowedClients", nullptr, nullptr, reinterpret_cast<BYTE *>(buffer.data()), &size) == ERROR_SUCCESS) {
				for (const wchar_t *item = buffer.data(); *item != L'\0'; item += wcslen(item) + 1) {
					allowed.push_back(item);
				}
			}
		}
		RegCloseKey(key);
	}
	return allowed;
}

std::wstring process_image(DWORD pid) {
	HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
	if (process == nullptr) {
		return L"";
	}
	wchar_t path[MAX_PATH * 2];
	DWORD length = MAX_PATH * 2;
	std::wstring result;
	if (QueryFullProcessImageNameW(process, 0, path, &length)) {
		result.assign(path, length);
	}
	CloseHandle(process);
	return result;
}

bool client_allowed(HANDLE pipe, const std::vector<std::wstring> &allowed) {
	ULONG pid = 0;
	if (!GetNamedPipeClientProcessId(pipe, &pid)) {
		log(L"client: no process id (%lu)", GetLastError());
		return false;
	}
	DWORD session = 0;
	if (!ProcessIdToSessionId(pid, &session) || session != own_session()) {
		log(L"client %lu: from session %lu, refused", pid, session);
		return false;
	}
	std::wstring image = process_image(pid);
	for (const std::wstring &path : allowed) {
		if (_wcsicmp(path.c_str(), image.c_str()) == 0) {
			log(L"client %lu: %s", pid, image.c_str());
			return true;
		}
	}
	log(L"client %lu: %s is not allowed, refused", pid, image.empty() ? L"(unknown)" : image.c_str());
	return false;
}

// SendInput reaches only the desktop of the calling thread. The input desktop
// changes to "Winlogon" for UAC prompts, the lock screen and Ctrl+Alt+Del; the
// thread follows it before every batch (it owns no windows, so it may switch).
HDESK current_desktop = nullptr;
std::wstring current_desktop_name;

void follow_input_desktop() {
	HDESK desktop = OpenInputDesktop(0, FALSE, GENERIC_ALL);
	if (desktop == nullptr) {
		return;
	}
	wchar_t name[256] = L"";
	DWORD needed = 0;
	GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name), &needed);
	if (current_desktop != nullptr && current_desktop_name == name) {
		CloseDesktop(desktop);
		return;
	}
	if (!SetThreadDesktop(desktop)) {
		log(L"cannot switch to desktop %s (%lu)", name, GetLastError());
		CloseDesktop(desktop);
		return;
	}
	if (current_desktop != nullptr) {
		CloseDesktop(current_desktop);
	}
	current_desktop = desktop;
	current_desktop_name = name;
	log(L"input desktop: %s", name);
}

// The secure desktop (UAC, lock screen, Ctrl+Alt+Del) is the one named "Winlogon".
AgentStatus desktop_status() {
	HDESK desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
	if (desktop == nullptr) {
		// A medium-integrity caller is refused the secure desktop; from SYSTEM this
		// should not happen, but treat "cannot tell" as secure to be safe.
		return GetLastError() == ERROR_ACCESS_DENIED ? AgentStatus::DESKTOP_SECURE : AgentStatus::DESKTOP_NORMAL;
	}
	wchar_t name[256] = L"";
	DWORD needed = 0;
	GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name), &needed);
	CloseDesktop(desktop);
	return _wcsicmp(name, L"Winlogon") == 0 ? AgentStatus::DESKTOP_SECURE : AgentStatus::DESKTOP_NORMAL;
}

// Serves one connected client: reads input and reports secure-desktop changes.
// A single polling loop, never a blocking read: a synchronous pipe handle
// serializes all I/O, so a status WriteFile would otherwise stall behind a
// blocking ReadFile until the client happened to send input (19.10.2026 - the
// status never arrived while the user only looked at the prompt).
void serve_client(HANDLE pipe) {
	InputRecord records[AGENT_MAX_RECORDS];
	AgentStatus reported = AgentStatus::DESKTOP_NORMAL;
	bool first = true;
	uint64_t batches = 0;
	ULONGLONG next_desktop_check = 0;
	for (;;) {
		// Drain whatever input is waiting (one message per ReadFile, message mode).
		for (;;) {
			DWORD available = 0;
			if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) {
				log(L"client gone after %llu batches", batches);
				return;
			}
			if (available < sizeof(InputRecord)) {
				break;
			}
			DWORD read = 0;
			if (!ReadFile(pipe, records, sizeof(records), &read, nullptr)) {
				log(L"client gone after %llu batches", batches);
				return;
			}
			size_t count = read / sizeof(InputRecord);
			if (count == 0 || read % sizeof(InputRecord) != 0) {
				continue;
			}
			follow_input_desktop();
			if (inject_input(records, count) == 0) {
				log(L"SendInput took nothing on %s (%lu)", current_desktop_name.c_str(), GetLastError());
			}
			batches++;
		}
		// Report a secure-desktop change (and the first state right away).
		ULONGLONG now = GetTickCount64();
		if (now >= next_desktop_check) {
			next_desktop_check = now + 150;
			AgentStatus status = desktop_status();
			if (first || status != reported) {
				first = false;
				reported = status;
				log(L"secure desktop: %s", status == AgentStatus::DESKTOP_SECURE ? L"yes" : L"no");
				StatusRecord record{ STATUS_TAG, status };
				DWORD written = 0;
				if (!WriteFile(pipe, &record, sizeof(record), &written, nullptr)) {
					log(L"client gone (status write) after %llu batches", batches);
					return;
				}
			}
		}
		Sleep(8);
	}
}

int run_agent(int argc, wchar_t **argv) {
	SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
	std::vector<std::wstring> allowed = allowed_clients(argc, argv);
	log(L"agent started in session %lu as %s, %zu allowed client(s)", own_session(), running_as_system() ? L"SYSTEM" : L"the user",
			allowed.size());
	if (allowed.empty()) {
		log(L"no allowed clients: nothing to serve");
		return 2;
	}

	std::wstring user;
	for (int attempt = 0; attempt < 60 && (user = session_user_sid()).empty(); attempt++) {
		Sleep(5000); // nobody logged on in this session yet
	}
	if (user.empty()) {
		log(L"no user in session %lu", own_session());
		return 3;
	}
	// SYSTEM and that user only; medium integrity may write (a pipe made by
	// SYSTEM is labelled System and would refuse the app otherwise).
	std::wstring sddl = L"D:P(A;;GA;;;SY)(A;;GRGW;;;" + user + L")S:(ML;;NW;;;ME)";
	SECURITY_ATTRIBUTES attributes{ sizeof(attributes), nullptr, FALSE };
	if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &attributes.lpSecurityDescriptor, nullptr)) {
		log(L"bad security descriptor (%lu)", GetLastError());
		return 4;
	}

	// FIRST_PIPE_INSTANCE: if someone else already holds the name, stop rather than
	// share it. The one instance is kept for good and only disconnected between
	// clients: closing and creating it again would leave a moment in which another
	// program of the user could take the name.
	HANDLE pipe = CreateNamedPipeW(AGENT_PIPE_NAME, PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
			PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 0,
			sizeof(InputRecord) * AGENT_MAX_RECORDS, 256, &attributes);
	LocalFree(attributes.lpSecurityDescriptor);
	if (pipe == INVALID_HANDLE_VALUE) {
		log(L"cannot create the pipe (%lu): another agent running?", GetLastError());
		return 5;
	}

	std::thread(run_secure_capture).detach();

	for (;;) {
		BOOL connected = ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED;
		if (connected && client_allowed(pipe, allowed)) {
			// The client sends nothing before this byte: a refused one keeps its input.
			DWORD written = 0;
			WriteFile(pipe, &AGENT_ACCEPTED, 1, &written, nullptr);
			serve_client(pipe);
		} else if (!connected) {
			log(L"ConnectNamedPipe failed (%lu)", GetLastError());
			Sleep(100);
		}
		DisconnectNamedPipe(pipe);
	}
}

// From session 0 (a service or a task running as SYSTEM): starts this program as
// SYSTEM in `session`, where the desktops the user sees live. The process handle,
// or nullptr.
HANDLE start_agent(DWORD session, const std::wstring &extra_arguments) {
	HANDLE token = nullptr;
	HANDLE primary = nullptr;
	if (!OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY | TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_SESSIONID, &token)) {
		log(L"cannot open our token (%lu)", GetLastError());
		return nullptr;
	}
	BOOL prepared = DuplicateTokenEx(token, MAXIMUM_ALLOWED, nullptr, SecurityImpersonation, TokenPrimary, &primary) &&
			SetTokenInformation(primary, TokenSessionId, &session, sizeof(session));
	CloseHandle(token);
	if (!prepared) {
		log(L"cannot prepare a token for session %lu (%lu)", session, GetLastError());
		if (primary != nullptr) {
			CloseHandle(primary);
		}
		return nullptr;
	}
	wchar_t exe[MAX_PATH];
	GetModuleFileNameW(nullptr, exe, MAX_PATH);
	std::wstring command = L"\"" + std::wstring(exe) + L"\" --agent" + extra_arguments;
	STARTUPINFOW startup{ sizeof(startup) };
	startup.lpDesktop = const_cast<wchar_t *>(L"winsta0\\default");
	PROCESS_INFORMATION process{};
	BOOL started = CreateProcessAsUserW(primary, exe, command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process);
	DWORD error = GetLastError();
	CloseHandle(primary);
	if (!started) {
		log(L"cannot start the agent in session %lu (%lu)", session, error);
		return nullptr;
	}
	log(L"agent %lu started in session %lu", process.dwProcessId, session);
	CloseHandle(process.hThread);
	return process.hProcess;
}

int spawn_agent(int argc, wchar_t **argv) {
	if (!running_as_system()) {
		log(L"--spawn needs to run as SYSTEM");
		return 10;
	}
	DWORD session = WTSGetActiveConsoleSessionId();
	if (session == 0xFFFFFFFF) {
		log(L"no console session");
		return 11;
	}
	std::wstring extra;
	for (int i = 1; i + 1 < argc; i++) {
		if (wcscmp(argv[i], L"--allow") == 0) {
			extra += L" --allow \"" + std::wstring(argv[++i]) + L"\"";
		}
	}
	HANDLE process = start_agent(session, extra);
	if (process == nullptr) {
		return 13;
	}
	CloseHandle(process);
	return 0;
}

// ---- The service ---------------------------------------------------------

constexpr const wchar_t *SERVICE_NAME = L"WoRkPlaceAgent";
SERVICE_STATUS_HANDLE service_handle = nullptr;
SERVICE_STATUS service_status{};
HANDLE stop_event = nullptr;
HANDLE wake_event = nullptr; // a session change: look at the console again

void report_status(DWORD state) {
	service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
	service_status.dwCurrentState = state;
	service_status.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SESSIONCHANGE : 0;
	service_status.dwWin32ExitCode = NO_ERROR;
	SetServiceStatus(service_handle, &service_status);
}

DWORD WINAPI service_control(DWORD control, DWORD event_type, LPVOID, LPVOID) {
	switch (control) {
		case SERVICE_CONTROL_STOP:
			report_status(SERVICE_STOP_PENDING);
			SetEvent(stop_event);
			return NO_ERROR;
		case SERVICE_CONTROL_SESSIONCHANGE:
			log(L"session change %lu", event_type);
			SetEvent(wake_event);
			return NO_ERROR;
		case SERVICE_CONTROL_INTERROGATE:
			return NO_ERROR;
		default:
			return ERROR_CALL_NOT_IMPLEMENTED;
	}
}

bool user_logged_on(DWORD session) {
	HANDLE token = nullptr;
	if (!WTSQueryUserToken(session, &token)) {
		return false;
	}
	CloseHandle(token);
	return true;
}

void WINAPI service_main(DWORD, LPWSTR *) {
	service_handle = RegisterServiceCtrlHandlerExW(SERVICE_NAME, service_control, nullptr);
	if (service_handle == nullptr) {
		return;
	}
	stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
	wake_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
	report_status(SERVICE_RUNNING);
	log(L"service running");

	HANDLE agent = nullptr;
	DWORD agent_session = 0xFFFFFFFF;
	ULONGLONG next_start = 0;
	for (;;) {
		DWORD console = WTSGetActiveConsoleSessionId();
		bool wanted = console != 0xFFFFFFFF && user_logged_on(console);
		// Another user (or nobody) at the console: the old agent goes.
		if (agent != nullptr && (!wanted || console != agent_session)) {
			TerminateProcess(agent, 0);
			CloseHandle(agent);
			agent = nullptr;
			log(L"agent in session %lu stopped (console is session %lu)", agent_session, console);
		}
		if (agent != nullptr && WaitForSingleObject(agent, 0) == WAIT_OBJECT_0) {
			DWORD code = 0;
			GetExitCodeProcess(agent, &code);
			log(L"agent exited with %lu", code);
			CloseHandle(agent);
			agent = nullptr;
			next_start = GetTickCount64() + 2000;
		}
		if (agent == nullptr && wanted && GetTickCount64() >= next_start) {
			agent = start_agent(console, L"");
			agent_session = console;
			if (agent == nullptr) {
				next_start = GetTickCount64() + 10000;
			}
		}
		HANDLE waits[3] = { stop_event, wake_event, agent };
		DWORD which = WaitForMultipleObjects(agent != nullptr ? 3 : 2, waits, FALSE, 2000);
		if (which == WAIT_OBJECT_0) {
			break;
		}
	}
	if (agent != nullptr) {
		TerminateProcess(agent, 0);
		CloseHandle(agent);
	}
	log(L"service stopped");
	report_status(SERVICE_STOPPED);
}

} // namespace

int wmain(int argc, wchar_t **argv) {
	open_log();
	if (argc >= 2 && wcscmp(argv[1], L"--agent") == 0) {
		return run_agent(argc, argv);
	}
	if (argc >= 2 && wcscmp(argv[1], L"--spawn") == 0) {
		return spawn_agent(argc, argv);
	}
	if (argc >= 2 && wcscmp(argv[1], L"--service") == 0) {
		SERVICE_TABLE_ENTRYW table[] = { { const_cast<wchar_t *>(SERVICE_NAME), service_main }, { nullptr, nullptr } };
		if (!StartServiceCtrlDispatcherW(table)) {
			log(L"not started by the service manager (%lu)", GetLastError());
			return 20;
		}
		return 0;
	}
	log(L"unknown command line");
	return 1;
}
