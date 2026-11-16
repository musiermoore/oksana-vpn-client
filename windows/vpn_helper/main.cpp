#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#include <sddl.h>
#include <shellapi.h>

#include <array>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace {
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\OksanaVpnRuntime-v1";
constexpr wchar_t kMutexName[] = L"Local\\OksanaVpnRuntime-v1";
constexpr size_t kMaximumPayload = 80 * 1024 * 1024;
HANDLE g_xray = nullptr;
std::filesystem::path g_data;
std::filesystem::path g_assets;
std::filesystem::path g_xrayPath;

bool ClientMatchesCurrentUser(HANDLE pipe) {
  ULONG client_pid = 0;
  if (!GetNamedPipeClientProcessId(pipe, &client_pid)) return false;
  DWORD client_session = 0, helper_session = 0;
  return ProcessIdToSessionId(client_pid, &client_session) &&
         ProcessIdToSessionId(GetCurrentProcessId(), &helper_session) &&
         client_session == helper_session;
}

bool ReadExact(HANDLE pipe, void* data, DWORD size) {
  auto* bytes = static_cast<BYTE*>(data);
  DWORD total = 0;
  while (total < size) {
    DWORD received = 0;
    if (!ReadFile(pipe, bytes + total, size - total, &received, nullptr) || received == 0) return false;
    total += received;
  }
  return true;
}

bool WriteExact(HANDLE pipe, const void* data, DWORD size) {
  const auto* bytes = static_cast<const BYTE*>(data);
  DWORD total = 0;
  while (total < size) {
    DWORD written = 0;
    if (!WriteFile(pipe, bytes + total, size - total, &written, nullptr) || written == 0) return false;
    total += written;
  }
  return true;
}

bool IsRunning() {
  return g_xray && WaitForSingleObject(g_xray, 0) == WAIT_TIMEOUT;
}

bool TunnelAdapterIsUp() {
  ULONG buffer_size = 16 * 1024;
  std::vector<BYTE> buffer(buffer_size);
  auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  ULONG status = GetAdaptersAddresses(AF_UNSPEC,
      GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
      nullptr, adapters, &buffer_size);
  if (status == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(buffer_size);
    adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    status = GetAdaptersAddresses(AF_UNSPEC,
        GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
        nullptr, adapters, &buffer_size);
  }
  if (status != NO_ERROR) return false;
  for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
    if (adapter->FriendlyName && _wcsicmp(adapter->FriendlyName, L"OksanaVPN") == 0 &&
        adapter->OperStatus == IfOperStatusUp) return true;
  }
  return false;
}

bool StopXray();

void CloseExitedProcess() {
  if (g_xray && !IsRunning()) {
    CloseHandle(g_xray);
    g_xray = nullptr;
    DeleteFileW((g_data / L"profile.json").c_str());
  }
}

bool EnsureProtectedDirectory(const std::filesystem::path& path) {
  if (!CreateDirectoryW(path.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return false;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", SDDL_REVISION_1,
          &descriptor, nullptr)) return false;
  const BOOL secured = SetFileSecurityW(path.c_str(),
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
      descriptor);
  LocalFree(descriptor);
  return secured != FALSE;
}

bool WriteGeoData(const std::vector<BYTE>& bytes, const wchar_t* filename) {
  if (bytes.empty()) return true;
  const auto path = g_assets / filename;
  std::ofstream file(path, std::ios::binary | std::ios::trunc);
  file.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
  file.close();
  if (!file.good()) return false;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:P(A;;FA;;;SY)(A;;FA;;;BA)", SDDL_REVISION_1,
          &descriptor, nullptr)) return false;
  const BOOL secured = SetFileSecurityW(path.c_str(),
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
      descriptor);
  LocalFree(descriptor);
  return secured != FALSE;
}

bool StartXray(const std::string& config, const std::vector<BYTE>& geoip,
               const std::vector<BYTE>& geosite) {
  CloseExitedProcess();
  if (IsRunning()) return true;
  if (config.empty()) return false;
  if (!EnsureProtectedDirectory(g_data) || !EnsureProtectedDirectory(g_assets)) return false;
  for (const auto* name : {L"geoip.dat", L"geosite.dat"}) {
    const auto bundled = g_xrayPath.parent_path() / name;
    const auto target = g_assets / name;
    if (std::filesystem::exists(bundled)) {
      if (!CopyFileW(bundled.c_str(), target.c_str(), FALSE)) return false;
    } else {
      DeleteFileW(target.c_str());
    }
  }
  if (!WriteGeoData(geoip, L"geoip.dat") || !WriteGeoData(geosite, L"geosite.dat")) return false;
  const auto config_path = g_data / L"profile.json";
  DeleteFileW(config_path.c_str());
  std::ofstream config_file(config_path, std::ios::binary | std::ios::trunc);
  config_file.write(config.data(), static_cast<std::streamsize>(config.size()));
  config_file.close();
  if (!config_file.good()) return false;
  PSECURITY_DESCRIPTOR file_descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:P(A;;FA;;;SY)(A;;FA;;;BA)", SDDL_REVISION_1,
          &file_descriptor, nullptr)) return false;
  const BOOL config_secured = SetFileSecurityW(config_path.c_str(),
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
      file_descriptor);
  LocalFree(file_descriptor);
  if (!config_secured) return false;

  std::wstring command = L"\"" + g_xrayPath.wstring() + L"\" run -c \"" + config_path.wstring() + L"\"";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
  startup.wShowWindow = SW_HIDE;
  SECURITY_ATTRIBUTES nul_security{sizeof(nul_security), nullptr, TRUE};
  HANDLE nul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE, &nul_security, OPEN_EXISTING, 0, nullptr);
  startup.hStdInput = nul;
  startup.hStdOutput = nul;
  startup.hStdError = nul;
  SetEnvironmentVariableW(L"XRAY_LOCATION_ASSET", g_assets.c_str());
  PROCESS_INFORMATION process{};
  const BOOL created = CreateProcessW(g_xrayPath.c_str(), command.data(), nullptr, nullptr,
      TRUE, CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP, nullptr,
      g_xrayPath.parent_path().c_str(), &startup, &process);
  if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
  if (!created) return false;
  CloseHandle(process.hThread);
  g_xray = process.hProcess;
  for (int i = 0; i < 60; ++i) {
    if (!IsRunning()) { CloseExitedProcess(); return false; }
    if (TunnelAdapterIsUp()) return true;
    Sleep(200);
  }
  StopXray();
  return false;
}

bool StopXray() {
  CloseExitedProcess();
  if (!g_xray) return true;
  // Give Xray time to close Wintun and remove routes/WFP filters. Never force
  // terminate it: a killed process could leave OS networking state behind.
  DWORD pid = GetProcessId(g_xray);
  if (pid != 0) {
    GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, pid);
  }
  if (WaitForSingleObject(g_xray, 15000) == WAIT_TIMEOUT) return false;
  CloseHandle(g_xray);
  g_xray = nullptr;
  DeleteFileW((g_data / L"profile.json").c_str());
  return true;
}

DWORD HandleRequest(HANDLE pipe) {
  BYTE command = 0;
  uint32_t length = 0;
  if (!ReadExact(pipe, &command, sizeof(command)) || !ReadExact(pipe, &length, sizeof(length)) || length > kMaximumPayload) return 0;
  std::string config;
  std::vector<BYTE> geoip, geosite;
  if (length) {
    uint32_t config_length = 0, geoip_length = 0, geosite_length = 0;
    if (!ReadExact(pipe, &config_length, sizeof(config_length)) ||
        !ReadExact(pipe, &geoip_length, sizeof(geoip_length)) ||
        !ReadExact(pipe, &geosite_length, sizeof(geosite_length)) ||
        config_length > 8 * 1024 * 1024 || geoip_length > 32 * 1024 * 1024 ||
        geosite_length > 32 * 1024 * 1024 ||
        static_cast<uint64_t>(config_length) + geoip_length + geosite_length + 12 != length) return 0;
    config.resize(config_length);
    geoip.resize(geoip_length);
    geosite.resize(geosite_length);
    if (!ReadExact(pipe, config.data(), config_length) ||
        (geoip_length && !ReadExact(pipe, geoip.data(), geoip_length)) ||
        (geosite_length && !ReadExact(pipe, geosite.data(), geosite_length))) return 0;
  }
  CloseExitedProcess();
  BYTE result = 0;
  if (command == 1) result = StartXray(config, geoip, geosite) ? 2 : 0;
  else if (command == 2) result = StopXray() ? 1 : 0;
  else if (command == 3) {
    result = !IsRunning() ? 1 : TunnelAdapterIsUp() ? 2 : 0;
  }
  WriteExact(pipe, &result, sizeof(result));
  return 1;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  HANDLE mutex = CreateMutexW(nullptr, TRUE, kMutexName);
  if (!mutex || GetLastError() == ERROR_ALREADY_EXISTS) {
    if (mutex) CloseHandle(mutex);
    return 0;
  }
  std::array<wchar_t, 32768> module{};
  const DWORD length = GetModuleFileNameW(nullptr, module.data(), static_cast<DWORD>(module.size()));
  if (length == 0 || length >= module.size()) return 2;
  const auto directory = std::filesystem::path(module.data()).parent_path();
  g_xrayPath = directory / L"xray.exe";
  if (!std::filesystem::exists(g_xrayPath) ||
      !std::filesystem::exists(directory / L"wintun.dll")) return 3;
  AllocConsole();
  if (const HWND console = GetConsoleWindow()) ShowWindow(console, SW_HIDE);
  SetConsoleCtrlHandler(nullptr, TRUE);
  wchar_t program_data[MAX_PATH]{};
  if (!GetEnvironmentVariableW(L"ProgramData", program_data, MAX_PATH)) return 4;
  g_data = std::filesystem::path(program_data) / L"OksanaVPN";
  g_assets = g_data / L"assets";

  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)", SDDL_REVISION_1,
          &descriptor, nullptr)) return 5;
  SECURITY_ATTRIBUTES security{sizeof(security), descriptor, FALSE};
  for (;;) {
    HANDLE pipe = CreateNamedPipeW(kPipeName,
        PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1, 64, 64, 0, &security);
    if (pipe == INVALID_HANDLE_VALUE) break;
    const BOOL connected = ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED;
    if (connected && ClientMatchesCurrentUser(pipe)) HandleRequest(pipe);
    FlushFileBuffers(pipe);
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
    CloseExitedProcess();
  }
  StopXray();
  DeleteFileW((g_data / L"profile.json").c_str());
  LocalFree(descriptor);
  ReleaseMutex(mutex);
  CloseHandle(mutex);
  return 0;
}
