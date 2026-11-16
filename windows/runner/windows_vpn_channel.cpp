#include "windows_vpn_channel.h"

#include <windows.h>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>

#include <array>
#include <cstdint>
#include <filesystem>
#include <string>
#include <variant>
#include <vector>

namespace {
constexpr char kChannelName[] = "oksanavpn/vpn_runtime";
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\OksanaVpnRuntime-v1";
constexpr size_t kMaxConfigSize = 8 * 1024 * 1024;
constexpr size_t kMaxGeoDataSize = 32 * 1024 * 1024;
constexpr size_t kMaxPayloadSize = kMaxConfigSize + 2 * kMaxGeoDataSize + 12;
constexpr wchar_t kPreferredBrightnessKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr wchar_t kPreferredBrightnessValue[] = L"AppsUseLightTheme";

std::string ReadSystemBrightness() {
  DWORD light_mode = 1;
  DWORD value_size = sizeof(light_mode);
  const LSTATUS status = RegGetValueW(
      HKEY_CURRENT_USER, kPreferredBrightnessKey, kPreferredBrightnessValue,
      RRF_RT_REG_DWORD, nullptr, &light_mode, &value_size);
  return status == ERROR_SUCCESS && light_mode == 0 ? "dark" : "light";
}

std::wstring ExecutableDirectory() {
  std::array<wchar_t, 32768> path{};
  const DWORD length = GetModuleFileNameW(nullptr, path.data(),
                                          static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) return {};
  return std::filesystem::path(path.data()).parent_path().wstring();
}

bool EnsureHelperStarted(std::string* error) {
  const auto directory = ExecutableDirectory();
  const auto helper = directory + L"\\oksana_vpn_privileged_helper.exe";
  if (GetFileAttributesW(helper.c_str()) == INVALID_FILE_ATTRIBUTES) {
    *error = "missing_runtime";
    return false;
  }
  SHELLEXECUTEINFOW info{};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOCLOSEPROCESS;
  info.lpVerb = L"runas";
  info.lpFile = helper.c_str();
  info.lpParameters = L"--serve";
  info.nShow = SW_HIDE;
  if (!ShellExecuteExW(&info)) {
    *error = GetLastError() == ERROR_CANCELLED ? "cancelled" : "start_failed";
    return false;
  }
  if (info.hProcess) CloseHandle(info.hProcess);
  return true;
}

HANDLE ConnectToHelper(int attempts) {
  for (int attempt = 0; attempt < attempts; ++attempt) {
    HANDLE pipe = CreateFileW(kPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                             OPEN_EXISTING, 0, nullptr);
    if (pipe != INVALID_HANDLE_VALUE) return pipe;
    const DWORD error = GetLastError();
    if (error != ERROR_PIPE_BUSY && error != ERROR_FILE_NOT_FOUND) break;
    WaitNamedPipeW(kPipeName, 100);
  }
  return INVALID_HANDLE_VALUE;
}

bool WriteExact(HANDLE pipe, const void* data, DWORD size) {
  const auto* bytes = static_cast<const BYTE*>(data);
  DWORD total = 0;
  while (total < size) {
    DWORD written = 0;
    if (!WriteFile(pipe, bytes + total, size - total, &written, nullptr) ||
        written == 0) return false;
    total += written;
  }
  return true;
}

bool ReadExact(HANDLE pipe, void* data, DWORD size) {
  auto* bytes = static_cast<BYTE*>(data);
  DWORD total = 0;
  while (total < size) {
    DWORD received = 0;
    if (!ReadFile(pipe, bytes + total, size - total, &received, nullptr) ||
        received == 0) return false;
    total += received;
  }
  return true;
}

const flutter::EncodableValue* Find(const flutter::EncodableMap& map,
                                    const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

bool ReadString(const flutter::EncodableMap& map, const char* key,
                std::string* value) {
  const auto* item = Find(map, key);
  if (!item || !std::holds_alternative<std::string>(*item)) return false;
  *value = std::get<std::string>(*item);
  return true;
}

bool ReadBytes(const flutter::EncodableMap& map, const char* key,
               std::vector<uint8_t>* value) {
  const auto* item = Find(map, key);
  if (!item || !std::holds_alternative<std::vector<uint8_t>>(*item)) return true;
  *value = std::get<std::vector<uint8_t>>(*item);
  return value->size() <= kMaxGeoDataSize;
}

}  // namespace

WindowsVpnChannel::WindowsVpnChannel(flutter::FlutterEngine* engine) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

WindowsVpnChannel::~WindowsVpnChannel() {
  if (channel_) {
    channel_->SetMethodCallHandler(
        flutter::MethodCallHandler<flutter::EncodableValue>());
  }
}

void WindowsVpnChannel::NotifySystemThemeChanged() {
  if (channel_) {
    channel_->InvokeMethod(
        "systemThemeChanged",
        std::make_unique<flutter::EncodableValue>(ReadSystemBrightness()));
  }
}

void WindowsVpnChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "getSystemBrightness") {
    result->Success(flutter::EncodableValue(ReadSystemBrightness()));
    return;
  }
  if (call.method_name() != "request" || !call.arguments() ||
      !std::holds_alternative<flutter::EncodableMap>(*call.arguments())) {
    result->NotImplemented();
    return;
  }
  const auto& arguments = std::get<flutter::EncodableMap>(*call.arguments());
  std::string command;
  if (!ReadString(arguments, "command", &command) ||
      (command != "start" && command != "stop" && command != "status")) {
    result->Error("invalid_command", "Unsupported VPN operation.");
    return;
  }

  std::string config;
  std::vector<uint8_t> geoip, geosite;
  if (command == "start") {
    if (!ReadString(arguments, "configuration", &config) || config.empty() ||
        config.size() > kMaxConfigSize) {
      result->Error("invalid_configuration", "Invalid VPN configuration.");
      return;
    }
    if (!ReadBytes(arguments, "geoipData", &geoip) ||
        !ReadBytes(arguments, "geositeData", &geosite)) {
      result->Error("invalid_configuration", "Geodata is too large.");
      return;
    }
  }

  HANDLE pipe = ConnectToHelper(1);
  if (pipe == INVALID_HANDLE_VALUE && command == "start") {
    // Reuse a live companion without repeating UAC. Only a missing helper
    // starts a new elevated process; status never resurrects it.
    std::string error;
    if (!EnsureHelperStarted(&error)) {
      result->Error(error.c_str(), error == "cancelled"
          ? "Administrator consent was cancelled."
          : "The Windows VPN component is unavailable.");
      return;
    }
    pipe = ConnectToHelper(100);
  }
  if (pipe == INVALID_HANDLE_VALUE) {
    result->Error("start_failed", "The Windows VPN service did not respond.");
    return;
  }
  DWORD pipe_mode = PIPE_READMODE_BYTE;
  SetNamedPipeHandleState(pipe, &pipe_mode, nullptr, nullptr);
  const BYTE operation = command == "start" ? 1 : command == "stop" ? 2 : 3;
  const uint32_t config_length = static_cast<uint32_t>(config.size());
  const uint32_t geoip_length = static_cast<uint32_t>(geoip.size());
  const uint32_t geosite_length = static_cast<uint32_t>(geosite.size());
  const uint32_t payload_length = command == "start"
      ? static_cast<uint32_t>(sizeof(config_length) + sizeof(geoip_length) +
          sizeof(geosite_length) + config.size() + geoip.size() + geosite.size())
      : 0;
  if (payload_length > kMaxPayloadSize) {
    CloseHandle(pipe);
    result->Error("invalid_configuration", "VPN request is too large.");
    return;
  }
  BYTE response = 0;
  bool ok = WriteExact(pipe, &operation, sizeof(operation)) &&
            WriteExact(pipe, &payload_length, sizeof(payload_length)) &&
            (payload_length == 0 ||
             (WriteExact(pipe, &config_length, sizeof(config_length)) &&
              WriteExact(pipe, &geoip_length, sizeof(geoip_length)) &&
              WriteExact(pipe, &geosite_length, sizeof(geosite_length)) &&
              WriteExact(pipe, config.data(), config_length) &&
              (geoip_length == 0 || WriteExact(pipe, geoip.data(), geoip_length)) &&
              (geosite_length == 0 || WriteExact(pipe, geosite.data(), geosite_length)))) &&
            ReadExact(pipe, &response, sizeof(response));
  CloseHandle(pipe);
  if (!ok) {
    result->Error("start_failed", "Could not communicate with the Windows VPN service.");
    return;
  }

  flutter::EncodableMap response_map;
  response_map[flutter::EncodableValue("ok")] = flutter::EncodableValue(response != 0);
  response_map[flutter::EncodableValue("state")] =
      flutter::EncodableValue(response == 2 ? "running" : "disconnected");
  if (response == 0) {
    response_map[flutter::EncodableValue("error")] =
        flutter::EncodableValue("The VPN component could not complete the operation.");
  }
  result->Success(flutter::EncodableValue(response_map));
}
