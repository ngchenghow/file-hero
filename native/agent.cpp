// File Hero agent (Windows): a tiny background process started at sign-in.
// It opens File Hero when an SSD that has a file-hero folder is plugged in, and it
// owns the per-user registry entries (autostart and the Explorer "Share to SSD" menu).
//   file-hero-agent.exe --app <File Hero.exe>          watch for SSD arrival
//   file-hero-agent.exe register <0|1> <0|1> <app.exe> set autostart / context menu
//   file-hero-agent.exe unregister                     remove both
//   file-hero-agent.exe stop                           close running agents
//   file-hero-agent.exe share <app.exe> <path>         Explorer menu target (one process per selected file or folder)
#include <windows.h>
#include <dbt.h>
#include <shellapi.h>
#include <shlobj.h>
#include <string>
#include <vector>
namespace {
const wchar_t* kClass = L"FileHeroAgentWindow";
const wchar_t* kRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const wchar_t* kRunValue = L"FileHeroAgent";
// The same menu entry for files and for folders.
const std::wstring kMenuKeys[] = {L"Software\\Classes\\*\\shell\\FileHero.ShareToSSD", L"Software\\Classes\\Directory\\shell\\FileHero.ShareToSSD"};
std::wstring appExe;
DWORD pending = 0;
int retries = 0;

std::wstring quoted(const std::wstring& s) { return L"\"" + s + L"\""; }
std::wstring selfPath() {
  std::wstring buffer(32768, L'\0');
  buffer.resize(GetModuleFileNameW(nullptr, buffer.data(), DWORD(buffer.size())));
  return buffer;
}
bool setString(const std::wstring& key, const wchar_t* name, const std::wstring& value) {
  HKEY handle;
  if(RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &handle, nullptr) != ERROR_SUCCESS) return false;
  auto result = RegSetValueExW(handle, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()), DWORD((value.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(handle);
  return result == ERROR_SUCCESS;
}
void removeValue(const wchar_t* key, const wchar_t* name) {
  HKEY handle;
  if(RegOpenKeyExW(HKEY_CURRENT_USER, key, 0, KEY_SET_VALUE, &handle) != ERROR_SUCCESS) return;
  RegDeleteValueW(handle, name);
  RegCloseKey(handle);
}
bool registerAll(bool autostart, bool menu, const std::wstring& app) {
  bool ok = true;
  if(autostart) ok &= setString(kRunKey, kRunValue, quoted(selfPath()) + L" --app " + quoted(app));
  else removeValue(kRunKey, kRunValue);
  for(const auto& key : kMenuKeys) {
    if(menu) {
      ok &= setString(key, nullptr, L"Share to SSD");
      ok &= setString(key, L"Icon", app + L",0");
      ok &= setString(key, L"MultiSelectModel", L"Player");
      ok &= setString(key + L"\\command", nullptr, quoted(selfPath()) + L" share " + quoted(app) + L" \"%1\"");
    } else RegDeleteTreeW(HKEY_CURRENT_USER, key.c_str());
  }
  SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
  return ok;
}
std::wstring spoolDir() {
  std::wstring temp(MAX_PATH + 1, L'\0');
  temp.resize(GetTempPathW(DWORD(temp.size()), temp.data()));
  return temp + L"file-hero-share\\";
}
std::vector<std::wstring> spooled() {
  std::vector<std::wstring> names;
  WIN32_FIND_DATAW found;
  HANDLE search = FindFirstFileW((spoolDir() + L"*.path").c_str(), &found);
  if(search == INVALID_HANDLE_VALUE) return names;
  do names.push_back(spoolDir() + found.cFileName); while(FindNextFileW(search, &found));
  FindClose(search);
  return names;
}
bool writeText(const std::wstring& file, const std::wstring& text) {
  int size = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), int(text.size()), nullptr, 0, nullptr, nullptr);
  std::string bytes(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.c_str(), int(text.size()), bytes.data(), size, nullptr, nullptr);
  HANDLE handle = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if(handle == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  bool ok = WriteFile(handle, bytes.data(), DWORD(bytes.size()), &written, nullptr) && written == bytes.size();
  CloseHandle(handle);
  return ok;
}
std::wstring readText(const std::wstring& file) {
  HANDLE handle = CreateFileW(file.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
  if(handle == INVALID_HANDLE_VALUE) return L"";
  std::string bytes(GetFileSize(handle, nullptr), '\0');
  DWORD got = 0;
  ReadFile(handle, bytes.data(), DWORD(bytes.size()), &got, nullptr);
  CloseHandle(handle);
  std::wstring text(MultiByteToWideChar(CP_UTF8, 0, bytes.data(), int(got), nullptr, 0), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, bytes.data(), int(got), text.data(), int(text.size()));
  return text;
}
// Explorer starts one menu process per selected file. Each process spools its path first, then waits for
// the shared lock; whoever holds it gathers every spooled path and opens File Hero once with the whole list.
// A path spooled before the holder releases the lock is picked up by the holder or by the next process.
int share(const std::wstring& app, const std::wstring& file) {
  CreateDirectoryW(spoolDir().c_str(), nullptr);
  std::wstring own = spoolDir() + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()) + L".path";
  if(!writeText(own, file)) return 1;
  HANDLE lock = CreateMutexW(nullptr, FALSE, L"Local\\FileHeroShareSpool");
  DWORD waited = WaitForSingleObject(lock, 30000);
  if(waited != WAIT_OBJECT_0 && waited != WAIT_ABANDONED) return 1;
  // Wait until Explorer has finished starting the other menu processes.
  size_t count = 0;
  for(int quiet = 0, total = 0; quiet < 6 && total < 100; ++total) {
    Sleep(100);
    size_t now = spooled().size();
    quiet = now == count ? quiet + 1 : 0;
    count = now;
  }
  std::wstring list;
  auto names = spooled();
  for(const auto& name : names) { auto path = readText(name); if(!path.empty()) list += path + L"\n"; }
  if(!list.empty()) {
    std::wstring listFile = spoolDir() + L"list-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()) + L".txt";
    if(writeText(listFile, list)) {
      std::wstring args = L"--share-list=" + quoted(listFile);
      ShellExecuteW(nullptr, L"open", app.c_str(), args.c_str(), nullptr, SW_SHOWNORMAL);
    }
  }
  for(const auto& name : names) DeleteFileW(name.c_str());
  ReleaseMutex(lock);
  CloseHandle(lock);
  return 0;
}
void stopAgents() {
  for(int i = 0; i < 20; ++i) {
    HWND window = FindWindowW(kClass, nullptr);
    if(!window) return;
    SendMessageTimeoutW(window, WM_CLOSE, 0, 0, SMTO_ABORTIFHUNG, 2000, nullptr);
  }
}
// Called shortly after a volume arrives, because the new drive letter is not always readable immediately.
void checkPending(HWND window) {
  DWORD waiting = 0;
  for(int i = 0; i < 26; ++i) {
    if(!(pending & (1u << i))) continue;
    wchar_t root[] = {wchar_t(L'A' + i), L':', L'\\', 0};
    if(GetFileAttributesW(root) == INVALID_FILE_ATTRIBUTES) { waiting |= 1u << i; continue; }
    std::wstring hero = std::wstring(root) + L"file-hero";
    DWORD attributes = GetFileAttributesW(hero.c_str());
    if(attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
      std::wstring args = L"--ssd=" + std::wstring(1, wchar_t(L'A' + i));
      ShellExecuteW(nullptr, L"open", appExe.c_str(), args.c_str(), nullptr, SW_SHOWNORMAL);
    }
  }
  pending = ++retries < 8 ? waiting : 0;
  if(!pending) KillTimer(window, 1);
}
LRESULT CALLBACK proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
  if(message == WM_DEVICECHANGE && wParam == DBT_DEVICEARRIVAL) {
    auto header = reinterpret_cast<DEV_BROADCAST_HDR*>(lParam);
    if(header && header->dbch_devicetype == DBT_DEVTYP_VOLUME) {
      pending |= reinterpret_cast<DEV_BROADCAST_VOLUME*>(lParam)->dbcv_unitmask;
      retries = 0;
      SetTimer(window, 1, 1500, nullptr);
    }
    return TRUE;
  }
  if(message == WM_TIMER) { checkPending(window); return 0; }
  if(message == WM_CLOSE) { DestroyWindow(window); return 0; }
  if(message == WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProcW(window, message, wParam, lParam);
}
int watch(HINSTANCE instance) {
  HANDLE mutex = CreateMutexW(nullptr, TRUE, L"Local\\FileHeroAgent");
  if(GetLastError() == ERROR_ALREADY_EXISTS) return 0;
  WNDCLASSW type{};
  type.lpfnWndProc = proc; type.hInstance = instance; type.lpszClassName = kClass;
  RegisterClassW(&type);
  // A hidden top-level window (not message-only) so it receives the volume arrival broadcast.
  if(!CreateWindowExW(0, kClass, L"File Hero Agent", WS_OVERLAPPED, 0, 0, 0, 0, nullptr, nullptr, instance, nullptr)) return 1;
  MSG message;
  while(GetMessageW(&message, nullptr, 0, 0) > 0) { TranslateMessage(&message); DispatchMessageW(&message); }
  ReleaseMutex(mutex);
  return 0;
}
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  std::wstring command = argc > 1 ? argv[1] : L"";
  int code = 2;
  if(command == L"--app" && argc == 3) { appExe = argv[2]; code = watch(instance); }
  else if(command == L"register" && argc == 5) code = registerAll(std::wstring(argv[2]) == L"1", std::wstring(argv[3]) == L"1", argv[4]) ? 0 : 1;
  else if(command == L"unregister") code = registerAll(false, false, L"") ? 0 : 1;
  else if(command == L"stop") { stopAgents(); code = 0; }
  else if(command == L"share" && argc == 4) code = share(argv[2], argv[3]);
  LocalFree(argv);
  return code;
}
