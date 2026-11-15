import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers
import Vision

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

      if call.method == "readRoutingTemplateFile" {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json, UTType.plainText, UTType.image]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Импортировать"
        panel.message = "Выберите JSON-файл с шаблоном маршрутизации"
        guard panel.runModal() == .OK, let url = panel.url else {
          result(FlutterError(code: "cancelled", message: nil, details: nil))
          return
        }
        do {
          if ["png", "jpg", "jpeg", "heic", "tiff", "bmp"].contains(url.pathExtension.lowercased()) {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(url: url).perform([request])
            guard let payload = request.results?.first?.payloadStringValue else {
              result(FlutterError(code: "qr_not_found", message: "В изображении не найден QR-код.", details: nil))
              return
            }
            result(payload)
            return
          }
          let contents = try String(contentsOf: url, encoding: .utf8)
          result(contents)
        } catch {
          result(FlutterError(code: "read_failed", message: "Не удалось прочитать файл.", details: nil))
        }
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
