#ifndef RUNNER_WINDOWS_VPN_CHANNEL_H_
#define RUNNER_WINDOWS_VPN_CHANNEL_H_

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>

#include <memory>

class WindowsVpnChannel {
 public:
  explicit WindowsVpnChannel(flutter::FlutterEngine* engine);
  ~WindowsVpnChannel();
  WindowsVpnChannel(const WindowsVpnChannel&) = delete;
  WindowsVpnChannel& operator=(const WindowsVpnChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_WINDOWS_VPN_CHANNEL_H_
