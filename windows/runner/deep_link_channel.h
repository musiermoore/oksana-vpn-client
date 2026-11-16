#ifndef RUNNER_DEEP_LINK_CHANNEL_H_
#define RUNNER_DEEP_LINK_CHANNEL_H_

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>
#include <vector>

// Registers the current executable as the current user's oksanavpn URL
// handler. This is per-user and does not require administrator privileges.
bool RegisterOksanaVpnProtocol();

class WindowsDeepLinkChannel {
 public:
  WindowsDeepLinkChannel(flutter::FlutterEngine* engine,
                         const std::vector<std::string>& command_line_arguments,
                         bool protocol_registered);
  ~WindowsDeepLinkChannel();

  WindowsDeepLinkChannel(const WindowsDeepLinkChannel&) = delete;
  WindowsDeepLinkChannel& operator=(const WindowsDeepLinkChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void DeliverPendingDeepLinks();

  std::unique_ptr<
      flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::vector<std::string> pending_deep_links_;
  bool ready_ = false;
  bool protocol_registered_;
};

#endif  // RUNNER_DEEP_LINK_CHANNEL_H_
