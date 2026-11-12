import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var deepLinkChannel: FlutterMethodChannel?
  private var pendingDeepLinks: [String] = []
  private var deepLinkHandlerReady = false

  func registerDeepLinkChannel(_ channel: FlutterMethodChannel) {
    deepLinkChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "ready" {
        self?.deepLinkHandlerReady = true
        self?.deliverPendingDeepLinks()
        result(nil)
        return
      }

      if call.method == "openTelegramLogin" {
        guard let rawURL = call.arguments as? String,
              let components = URLComponents(string: rawURL),
              components.scheme == "https",
              components.host == "public.oksana1984.ru",
              components.path == "/login",
              components.queryItems?.contains(where: {
                $0.name == "desktop" && $0.value == "1"
              }) == true,
              let url = components.url else {
          result(FlutterError(code: "invalid_login_url", message: nil, details: nil))
          return
        }
        result(NSWorkspace.shared.open(url))
        return
      }

      if call.method == "openExternalUrl" {
        guard let rawURL = call.arguments as? String,
              let components = URLComponents(string: rawURL),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              components.user == nil,
              let url = components.url else {
          result(FlutterError(code: "invalid_external_url", message: nil, details: nil))
          return
        }
        result(NSWorkspace.shared.open(url))
        return
      }

      result(FlutterMethodNotImplemented)
    }
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      guard url.scheme?.lowercased() == "oksanavpn",
            url.host?.lowercased() == "auth" else {
        continue
      }
      pendingDeepLinks.append(url.absoluteString)
    }
    deliverPendingDeepLinks()
  }

  private func deliverPendingDeepLinks() {
    guard deepLinkHandlerReady, let channel = deepLinkChannel else { return }
    while !pendingDeepLinks.isEmpty {
      let link = pendingDeepLinks.removeFirst()
      channel.invokeMethod("onDeepLink", arguments: link)
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
