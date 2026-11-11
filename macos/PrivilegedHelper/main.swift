import Darwin
import Foundation

private let daemonLabel = "com.oksana1984.oksanaVpnDesktop.daemon"
private let supportDirectory = "/Library/Application Support/OksanaVPN"
private let runtimeDirectory = supportDirectory + "/runtime"
private let ownerUIDFile = supportDirectory + "/control-owner-uid"
private let socketPath = "/var/run/com.oksana1984.oksanaVpnDesktop.sock"
private let xrayPath = supportDirectory + "/xray"
private let assetDirectory = supportDirectory + "/assets"
private let configurationPath = runtimeDirectory + "/active.json"
private let dnsSnapshotPath = runtimeDirectory + "/previous-dns.json"
private let maximumRequestBytes = 2 * 1024 * 1024

final class VpnDaemon {
  private let queue = DispatchQueue(label: "com.oksana1984.oksanaVpnDesktop.daemon")
  private var listener: Int32 = -1
  private var listenerSource: DispatchSourceRead?
  private var signalSources: [DispatchSourceSignal] = []
  private var authorizedUID: uid_t = 0
  private var xray: Process?

  func run() throws -> Never {
    umask(0o077)
    authorizedUID = try Self.loadAuthorizedUID()
    try FileManager.default.createDirectory(
      atPath: runtimeDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    restoreSystemDNS()
    try? FileManager.default.removeItem(atPath: configurationPath)

    listener = try makeListener()
    try prepareSocketPermissions()
    installSignalHandlers()

    let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
    source.setEventHandler { [weak self] in self?.acceptConnections() }
    source.setCancelHandler { [listener] in Darwin.close(listener) }
    listenerSource = source
    source.resume()

    dispatchMain()
  }

  private func makeListener() throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw Self.error("Could not create the VPN control socket.") }

    _ = unlink(socketPath)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = socketPath.utf8CString
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.count <= pathCapacity else {
      Darwin.close(descriptor)
      throw Self.error("The VPN control socket path is too long.")
    }
    withUnsafeMutableBytes(of: &address) { addressBytes in
      guard let baseAddress = addressBytes.baseAddress else { return }
      let pathOffset = MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size
      let destination = baseAddress
        .advanced(by: pathOffset)
        .assumingMemoryBound(to: CChar.self)
      path.withUnsafeBufferPointer { source in
        if let sourceAddress = source.baseAddress {
          destination.update(from: sourceAddress, count: source.count)
        }
      }
    }

    let addressLength = socklen_t(
      MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + path.count
    )
    address.sun_len = UInt8(addressLength)
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, addressLength)
      }
    }
    guard bindResult == 0, Darwin.listen(descriptor, 8) == 0 else {
      let savedErrno = errno
      Darwin.close(descriptor)
      throw Self.error("Could not open the VPN control socket (code \(savedErrno)).")
    }

    let flags = fcntl(descriptor, F_GETFL, 0)
    if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    return descriptor
  }

  private func prepareSocketPermissions() throws {
    guard chown(socketPath, authorizedUID, 0) == 0,
          chmod(socketPath, mode_t(0o600)) == 0 else {
      throw Self.error("Could not secure the VPN control socket.")
    }
  }

  private func installSignalHandlers() {
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
    for signalNumber in [SIGTERM, SIGINT] {
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
      source.setEventHandler { [weak self] in self?.shutdown() }
      source.resume()
      signalSources.append(source)
    }
  }

  private func acceptConnections() {
    while true {
      let client = Darwin.accept(listener, nil, nil)
      if client < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK { return }
        if errno == EINTR { continue }
        return
      }
      let flags = fcntl(client, F_GETFL, 0)
      if flags >= 0 { _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK) }
      serve(client)
      Darwin.close(client)
    }
  }

  private func serve(_ client: Int32) {
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == authorizedUID else {
      writeResponse(["ok": false, "error": "This account cannot control the VPN service."], to: client)
      return
    }

    guard let request = readRequest(from: client),
          let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
          let command = object["command"] as? String else {
      writeResponse(["ok": false, "error": "Invalid VPN service request."], to: client)
      return
    }

    do {
      switch command {
      case "start":
        guard let configuration = object["configuration"] as? String else {
          throw Self.error("The VPN profile is missing.")
        }
        try start(configuration: configuration)
        writeResponse(["ok": true, "state": "running"], to: client)
      case "stop":
        try stop()
        writeResponse(["ok": true, "state": "disconnected"], to: client)
      case "status":
        writeResponse(["ok": true, "state": currentState], to: client)
      default:
        writeResponse(["ok": false, "error": "Unsupported VPN service command."], to: client)
      }
    } catch {
      writeResponse(["ok": false, "error": error.localizedDescription], to: client)
    }
  }

  private var currentState: String {
    guard let xray, xray.isRunning else { return "disconnected" }
    return "running"
  }

  private func start(configuration: String) throws {
    try stop()

    guard let data = configuration.data(using: .utf8), data.count <= maximumRequestBytes,
          var profile = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let inbounds = profile["inbounds"] as? [[String: Any]],
          inbounds.contains(where: { $0["protocol"] as? String == "tun" }),
          let outbounds = profile["outbounds"] as? [[String: Any]], !outbounds.isEmpty else {
      throw Self.error("The VPN profile is invalid or does not contain a TUN inbound.")
    }

    // Xray runs as root so it can create utun and manage routes. Prevent the
    // subscription profile from writing Xray logs to arbitrary file paths.
    profile["log"] = ["loglevel": "none"]
    let safeConfiguration = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
    try safeConfiguration.write(to: URL(fileURLWithPath: configurationPath), options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600, .ownerAccountID: 0, .groupOwnerAccountID: 0],
      ofItemAtPath: configurationPath
    )

    let existingTunnelInterfaces = try tunnelInterfaces()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: xrayPath)
    process.arguments = ["run", "-config", configurationPath]
    process.environment = ProcessInfo.processInfo.environment.merging([
      "XRAY_LOCATION_ASSET": assetDirectory,
    ]) { _, new in new }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [weak self] _ in
      self?.queue.async { [weak self] in
        self?.restoreSystemDNS()
        try? FileManager.default.removeItem(atPath: configurationPath)
      }
    }
    do {
      try process.run()
    } catch {
      try? FileManager.default.removeItem(atPath: configurationPath)
      throw Self.error("Could not start the VPN engine.")
    }

    xray = process
    let startupDeadline = Date().addingTimeInterval(8)
    var tunnelInterfaceCreated = false
    while Date() < startupDeadline && process.isRunning {
      if let interfaces = try? tunnelInterfaces(),
         !interfaces.subtracting(existingTunnelInterfaces).isEmpty {
        tunnelInterfaceCreated = true
        break
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    guard process.isRunning, tunnelInterfaceCreated else {
      let didExit = !process.isRunning
      try? stop()
      throw Self.error(didExit
        ? "Xray exited during startup. Check the selected server profile."
        : "Xray did not create the VPN tunnel interface.")
    }
    do {
      try configureSystemDNS(from: profile["dns"])
    } catch {
      try? stop()
      throw error
    }
  }

  private func stop() throws {
    guard let process = xray else {
      try? FileManager.default.removeItem(atPath: configurationPath)
      return
    }
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    xray = nil
    restoreSystemDNS()
    try? FileManager.default.removeItem(atPath: configurationPath)
  }

  private func configureSystemDNS(from value: Any?) throws {
    let servers = Self.dnsAddresses(from: value)
    guard !servers.isEmpty else {
      throw Self.error("The selected profile does not contain an IP DNS server.")
    }
    let services = try command("/usr/sbin/networksetup", ["-listallnetworkservices"])
      .components(separatedBy: .newlines)
      .dropFirst(1)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.hasPrefix("*") }

    var snapshot: [[String: Any]] = []
    for service in services {
      guard let result = try? command("/usr/sbin/networksetup", ["-getdnsservers", service]) else {
        continue
      }
      let addresses = result
        .components(separatedBy: .whitespacesAndNewlines)
        .filter(Self.isIPAddress)
      snapshot.append(["service": service, "servers": addresses])
    }

    guard !snapshot.isEmpty else {
      throw Self.error("Could not read DNS settings for any network service.")
    }
    try writeRootJSON(snapshot, to: dnsSnapshotPath)
    do {
      for entry in snapshot {
        guard let service = entry["service"] as? String else { continue }
        _ = try command(
          "/usr/sbin/networksetup",
          ["-setdnsservers", service] + servers
        )
      }
    } catch {
      restoreSystemDNS()
      throw Self.error("Could not route DNS through the VPN.")
    }
  }

  private func restoreSystemDNS() {
    guard let data = FileManager.default.contents(atPath: dnsSnapshotPath),
          let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return
    }
    for entry in entries {
      guard let service = entry["service"] as? String,
            let servers = entry["servers"] as? [String] else { continue }
      let arguments = servers.isEmpty
        ? ["-setdnsservers", service, "Empty"]
        : ["-setdnsservers", service] + servers
      _ = try? command("/usr/sbin/networksetup", arguments)
    }
    try? FileManager.default.removeItem(atPath: dnsSnapshotPath)
  }

  private func command(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Self.error("A required network setting could not be changed.")
    }
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  }

  private func tunnelInterfaces() throws -> Set<String> {
    Set(try command("/sbin/ifconfig", ["-l"])
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
      .filter { $0.hasPrefix("utun") })
  }

  private func writeRootJSON(_ value: Any, to path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600, .ownerAccountID: 0, .groupOwnerAccountID: 0],
      ofItemAtPath: path
    )
  }

  private static func dnsAddresses(from value: Any?) -> [String] {
    guard let dns = value as? [String: Any], let servers = dns["servers"] as? [Any] else {
      return []
    }
    var result: [String] = []
    for server in servers {
      let candidate: String?
      if let string = server as? String {
        candidate = string
      } else if let object = server as? [String: Any] {
        candidate = object["address"] as? String
      } else {
        candidate = nil
      }
      guard let candidate, isIPAddress(candidate), !result.contains(candidate) else { continue }
      result.append(candidate)
      if result.count == 4 { break }
    }
    return result
  }

  private static func isIPAddress(_ value: String) -> Bool {
    var ipv4 = in_addr()
    if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
    var ipv6 = in6_addr()
    return value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
  }

  private func readRequest(from descriptor: Int32) -> Data? {
    var request = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while request.count <= maximumRequestBytes {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.recv(descriptor, bytes.baseAddress, bytes.count, 0)
      }
      if count <= 0 { return nil }
      if let newline = buffer[..<count].firstIndex(of: 10) {
        request.append(contentsOf: buffer[..<newline])
        return request
      }
      request.append(contentsOf: buffer[..<count])
    }
    return nil
  }

  private func writeResponse(_ value: [String: Any], to descriptor: Int32) {
    guard var data = try? JSONSerialization.data(withJSONObject: value) else { return }
    data.append(10)
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var sent = 0
      while sent < bytes.count {
        let result = Darwin.send(descriptor, baseAddress.advanced(by: sent), bytes.count - sent, 0)
        if result <= 0 { return }
        sent += result
      }
    }
  }

  private func shutdown() {
    try? stop()
    listenerSource?.cancel()
    listenerSource = nil
    _ = unlink(socketPath)
    exit(0)
  }

  private static func loadAuthorizedUID() throws -> uid_t {
    guard let value = try? String(contentsOfFile: ownerUIDFile, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines),
      let uid = UInt32(value), uid > 0 else {
      throw error("The VPN service has not been installed for a user account.")
    }
    return uid_t(uid)
  }

  private static func error(_ message: String) -> NSError {
    NSError(domain: daemonLabel, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

let daemon = VpnDaemon()
do {
  try daemon.run()
} catch {
  fputs("VPN helper failed to start.\n", stderr)
  exit(1)
}
