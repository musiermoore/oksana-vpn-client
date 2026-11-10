# macOS TUN runtime

The first implementation targets macOS ARM64. It runs the bundled Xray binary as a root LaunchDaemon so the user does not need to enter a password for every VPN session. It does not use Apple's Network Extension and does not require the paid Developer Program or Network Extension entitlements.

## Build prerequisites

- Apple Silicon Mac, Flutter, Xcode, and Xray-core installed with Homebrew (`brew install xray`).
- Xray's `geoip.dat` and `geosite.dat` assets, which the Xcode build phase copies into the app.

The `Package VPN helper` build phase compiles `macos/PrivilegedHelper/main.swift` for ARM64 and bundles the helper, Xray, geodata, installer, and LaunchDaemon plist in the app's Resources. For a non-default Xray installation, set `XRAY_EXECUTABLE` and `XRAY_ASSET_DIR` in the build environment.

## First use

For an unnotarized private build, the recipient can clear the quarantine attribute and open the downloaded app with one Terminal command (adjust the app path if it was saved elsewhere):

```sh
xattr -dr com.apple.quarantine "$HOME/Downloads/oksana_vpn_desktop.app" && open "$HOME/Downloads/oksana_vpn_desktop.app"
```

When the user first turns on TUN, the app opens one standard macOS administrator authorization prompt. After approval, the bundled installer:

1. Copies the helper, Xray, and geodata to `/Library/Application Support/OksanaVPN` with root ownership.
2. Installs the root-owned plist at `/Library/LaunchDaemons/com.oksana1984.oksanaVpnDesktop.daemon.plist`.
3. Registers and starts the LaunchDaemon through `launchctl`.

Later connect/disconnect actions use a Unix socket at `/var/run/com.oksana1984.oksanaVpnDesktop.sock`. The socket is mode `0600`, owned by the installing user, and the daemon checks the peer UID. The IPC supports only `start`, `stop`, and `status`; app requests cannot choose a binary path or arbitrary command.

## Routes and DNS

The app replaces profile inbounds with Xray's `tun` inbound and enables full IPv4/IPv6 `autoSystemRoutingTable` routes plus `autoOutboundsInterface: auto` so Xray's own server connection stays on the physical interface. The helper runs as root because Xray needs permission to create `utun` and manage routes.

Xray does not apply the profile's DNS field to macOS system DNS. The helper snapshots DNS settings per network service with `networksetup`, sets the profile's IP DNS servers, and restores the previous settings when Xray stops or the daemon starts after a reboot. A TUN profile without an IP DNS server is rejected instead of silently substituting a public resolver. The DNS snapshot and temporary Xray config are kept under the root-only runtime directory.

The helper waits for Xray to create a new `utun` interface before it reports the tunnel as running. Xray owns route creation and removal. On stop or Xray termination, the helper restores DNS and removes the temporary config.

## Known limits

- This implementation directly changes macOS routes and DNS. Apple's Network Extension is the normal system VPN API; direct route management is a deliberate private-distribution trade-off.
- Runtime readiness checks verify that Xray remains alive and creates a new `utun` interface. They do not prove that every route is correct or that no traffic leaks.
- A live smoke test is still required for end-to-end traffic, DNS behavior, sleep/wake, app termination, helper restart, and recovery after forced Xray termination. The LaunchDaemon and route cleanup behavior must be confirmed on the actual target Mac.
- The UI app may quit while the system LaunchDaemon and VPN remain active. Disconnect from inside the app before quitting.
- The app and helper are currently built for macOS ARM64 only. Windows and Linux runtime implementations are future work.

Reference: [Xray-core TUN inbound documentation](https://github.com/XTLS/Xray-core/blob/main/proxy/tun/README.md).
