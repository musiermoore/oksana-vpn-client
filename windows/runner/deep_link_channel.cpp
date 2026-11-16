#include "deep_link_channel.h"

#include <windows.h>
#include <commdlg.h>
#include <shellapi.h>
#include <winhttp.h>
#include <flutter/standard_method_codec.h>

#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <utility>
#include <variant>

namespace {

constexpr char kChannelName[] = "oksanavpn/deep_links";
constexpr wchar_t kProtocolKey[] = L"Software\\Classes\\oksanavpn";
constexpr wchar_t kTelegramLoginUrl[] =
    L"https://public.oksana1984.ru/login?desktop=1";
constexpr size_t kMaxTemplateSize = 10 * 1024 * 1024;

bool IsAuthDeepLink(const std::string& value) {
  constexpr char kAuthPrefix[] = "oksanavpn://auth/";
  if (value.size() > 1024 || value.rfind(kAuthPrefix, 0) != 0) {
    return false;
  }
  return value.find_first_of(" \t\r\n") == std::string::npos;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty() || value.size() > 4096) {
    return {};
  }
  const int required = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (required <= 0) {
    return {};
  }
  std::wstring result(static_cast<size_t>(required), L'\0');
  const int written = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), result.data(), required);
  if (written != required) {
    return {};
  }
  return result;
}

bool IsHttpUrl(const std::wstring& url) {
  if (url.empty() || url.size() > 4096) {
    return false;
  }

  std::array<wchar_t, 16> scheme{};
  std::array<wchar_t, 1024> host{};
  std::array<wchar_t, 256> username{};
  std::array<wchar_t, 256> password{};
  URL_COMPONENTS components{};
  components.dwStructSize = sizeof(components);
  components.lpszScheme = scheme.data();
  components.dwSchemeLength = static_cast<DWORD>(scheme.size());
  components.lpszHostName = host.data();
  components.dwHostNameLength = static_cast<DWORD>(host.size());
  components.lpszUserName = username.data();
  components.dwUserNameLength = static_cast<DWORD>(username.size());
  components.lpszPassword = password.data();
  components.dwPasswordLength = static_cast<DWORD>(password.size());

  if (!WinHttpCrackUrl(url.c_str(), static_cast<DWORD>(url.size()), 0,
                       &components)) {
    return false;
  }

  return (components.nScheme == INTERNET_SCHEME_HTTP ||
          components.nScheme == INTERNET_SCHEME_HTTPS) &&
         components.dwHostNameLength > 0 &&
         components.dwUserNameLength == 0 &&
         components.dwPasswordLength == 0;
}

bool OpenUrl(const std::wstring& url) {
  if (!IsHttpUrl(url)) {
    return false;
  }
  const auto result = reinterpret_cast<INT_PTR>(ShellExecuteW(
      nullptr, L"open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
  return result > 32;
}

bool SetRegistryString(HKEY key, const wchar_t* name,
                       const std::wstring& value) {
  const DWORD byte_count =
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  return RegSetValueExW(key, name, 0, REG_SZ,
                        reinterpret_cast<const BYTE*>(value.c_str()),
                        byte_count) == ERROR_SUCCESS;
}

bool ReadTemplateFile(std::string* contents, std::string* error_code) {
  std::array<wchar_t, 32768> path{};
  constexpr wchar_t kFilter[] =
      L"Template files (*.json;*.txt)\0*.json;*.txt\0"
      L"JSON files (*.json)\0*.json\0"
      L"Text files (*.txt)\0*.txt\0\0";

  OPENFILENAMEW dialog{};
  dialog.lStructSize = sizeof(dialog);
  dialog.hwndOwner = GetActiveWindow();
  dialog.lpstrFilter = kFilter;
  dialog.lpstrFile = path.data();
  dialog.nMaxFile = static_cast<DWORD>(path.size());
  dialog.lpstrTitle = L"Select a routing template file";
  dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;

  if (!GetOpenFileNameW(&dialog)) {
    *error_code = CommDlgExtendedError() == 0 ? "cancelled" : "open_failed";
    return false;
  }

  std::ifstream file(std::filesystem::path(path.data()), std::ios::binary);
  if (!file) {
    *error_code = "read_failed";
    return false;
  }

  file.seekg(0, std::ios::end);
  const auto file_size = static_cast<std::streamoff>(file.tellg());
  if (file_size < 0 || static_cast<uint64_t>(file_size) > kMaxTemplateSize) {
    *error_code = "file_too_large";
    return false;
  }

  contents->resize(static_cast<size_t>(file_size));
  file.seekg(0, std::ios::beg);
  if (!contents->empty()) {
    file.read(contents->data(), static_cast<std::streamsize>(contents->size()));
    if (!file) {
      *error_code = "read_failed";
      return false;
    }
  }
  return true;
}

}  // namespace

bool RegisterOksanaVpnProtocol() {
  std::array<wchar_t, 32768> executable_path{};
  const DWORD path_length = GetModuleFileNameW(
      nullptr, executable_path.data(), static_cast<DWORD>(executable_path.size()));
  if (path_length == 0 ||
      path_length >= static_cast<DWORD>(executable_path.size())) {
    return false;
  }

  HKEY protocol_key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kProtocolKey, 0, nullptr,
                      REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr,
                      &protocol_key, nullptr) != ERROR_SUCCESS) {
    return false;
  }

  bool success = SetRegistryString(protocol_key, nullptr,
                                   L"URL:Oksana VPN authentication link") &&
                 SetRegistryString(protocol_key, L"URL Protocol", L"");
  RegCloseKey(protocol_key);
  if (!success) {
    return false;
  }

  HKEY command_key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Classes\\oksanavpn\\shell\\open\\command",
                      0, nullptr, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE,
                      nullptr, &command_key, nullptr) != ERROR_SUCCESS) {
    return false;
  }

  std::wstring command = L"\"";
  command.append(executable_path.data(), path_length);
  command += L"\" \"%1\"";
  success = SetRegistryString(command_key, nullptr, command);
  RegCloseKey(command_key);
  return success;
}

WindowsDeepLinkChannel::WindowsDeepLinkChannel(
    flutter::FlutterEngine* engine,
    const std::vector<std::string>& command_line_arguments,
    bool protocol_registered)
    : channel_(std::make_unique<
          flutter::MethodChannel<flutter::EncodableValue>>(
          engine->messenger(), kChannelName,
          &flutter::StandardMethodCodec::GetInstance())),
      protocol_registered_(protocol_registered) {
  for (const auto& argument : command_line_arguments) {
    if (IsAuthDeepLink(argument)) {
      pending_deep_links_.push_back(argument);
    }
  }

  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

WindowsDeepLinkChannel::~WindowsDeepLinkChannel() {
  channel_->SetMethodCallHandler(
      flutter::MethodCallHandler<flutter::EncodableValue>());
}

void WindowsDeepLinkChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "ready") {
    ready_ = true;
    DeliverPendingDeepLinks();
    result->Success();
    return;
  }

  if (call.method_name() == "readRoutingTemplateFile") {
    std::string contents;
    std::string error_code;
    if (!ReadTemplateFile(&contents, &error_code)) {
      result->Error(error_code, "Could not read the selected template file.");
      return;
    }
    result->Success(flutter::EncodableValue(contents));
    return;
  }

  if (call.method_name() != "openTelegramLogin" &&
      call.method_name() != "openExternalUrl") {
    result->NotImplemented();
    return;
  }

  const auto* raw_argument = call.arguments();
  const auto* raw_url = raw_argument
      ? std::get_if<std::string>(raw_argument)
      : nullptr;
  if (!raw_url) {
    result->Error("invalid_argument", "Expected a URL string.");
    return;
  }

  const std::wstring url = Utf8ToWide(*raw_url);
  if (url.empty()) {
    result->Error("invalid_argument", "The URL is not valid UTF-8.");
    return;
  }

  if (call.method_name() == "openTelegramLogin") {
    if (url != kTelegramLoginUrl) {
      result->Error("invalid_login_url", "The Telegram login URL is invalid.");
      return;
    }
    if (!protocol_registered_) {
      result->Error("protocol_registration_failed",
                    "Could not register the Oksana VPN sign-in link handler.");
      return;
    }
    result->Success(flutter::EncodableValue(OpenUrl(url)));
    return;
  }

  if (call.method_name() == "openExternalUrl") {
    result->Success(flutter::EncodableValue(OpenUrl(url)));
    return;
  }
}

void WindowsDeepLinkChannel::DeliverPendingDeepLinks() {
  if (!ready_) {
    return;
  }
  while (!pending_deep_links_.empty()) {
    const std::string link = std::move(pending_deep_links_.front());
    pending_deep_links_.erase(pending_deep_links_.begin());
    channel_->InvokeMethod(
        "onDeepLink",
        std::make_unique<flutter::EncodableValue>(link));
  }
}
