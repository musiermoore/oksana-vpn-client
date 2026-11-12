import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let deepLinkChannel = FlutterMethodChannel(
      name: "oksanavpn/deep_links",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    (NSApplication.shared.delegate as? AppDelegate)?.registerDeepLinkChannel(deepLinkChannel)

    super.awakeFromNib()

    let initialContentSize = NSSize(width: 450, height: 800)
    let minimumScale: CGFloat = 1.5
    let minimumContentSize = NSSize(
      width: initialContentSize.width / minimumScale,
      height: initialContentSize.height / minimumScale
    )
    self.contentAspectRatio = NSSize(width: 9, height: 16)
    self.contentMinSize = minimumContentSize
    self.minSize = self.frameRect(
      forContentRect: NSRect(origin: .zero, size: minimumContentSize)
    ).size
    self.setContentSize(initialContentSize)
    self.center()
  }
}
