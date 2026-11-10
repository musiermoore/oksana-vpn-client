# Oksana VPN Desktop

Flutter desktop client, currently prepared for macOS ARM64. The Vue application in `../oksana-vpn-ui` remains the Web and Telegram Mini App; this project uses it as a design and API reference.

## Current scope

- Subscription UUID entry and profile download from `https://connect.oksana1984.ru/start?token=<UUID>`.
- Server/profile selection and VPN controls.
- Local Xray SOCKS/HTTP proxy mode. It does not change macOS-wide proxy settings.
- TUN mode through Xray's macOS `utun` inbound, controlled by a root LaunchDaemon.

## Run locally

Requirements: Flutter, Xcode, and Xray-core with its geodata installed (`brew install xray`). From this directory:

```sh
flutter pub get
flutter run -d macos
```

The Xcode build phase bundles Xray, geodata, and the helper. Set `XRAY_EXECUTABLE` and `XRAY_ASSET_DIR` as environment variables when packaging from non-default locations. The proxy runtime can also use `--dart-define=XRAY_EXECUTABLE=/opt/homebrew/bin/xray` for local development.

Override the subscription endpoint at build time if needed:

```sh
flutter run -d macos --dart-define=SUBSCRIPTION_ENDPOINT=https://connect.oksana1984.ru/start
```

## First use on a friend's Mac

This private, unnotarized build does not require a paid Apple Developer account. After downloading and extracting `oksana_vpn_desktop.app` into Downloads, the recipient runs this one command in Terminal to clear the download quarantine and open the app:

```sh
xattr -dr com.apple.quarantine "$HOME/Downloads/oksana_vpn_desktop.app" && open "$HOME/Downloads/oksana_vpn_desktop.app"
```

The first time they turn on TUN, macOS shows one administrator authorization prompt. The app then installs the signed/bundled helper and Xray under `/Library/Application Support/OksanaVPN` and registers the LaunchDaemon. Later connect/disconnect actions stay in the app; no Terminal commands are needed. Proxy mode does not need the administrator helper.

## Architecture and limitations

The UUID is stored in macOS Keychain via `flutter_secure_storage`; fetched profiles stay in memory. The helper communicates only with the installing user through a permission-restricted local Unix socket. It changes and restores system DNS while the tunnel runs; Xray adds and removes system routes.

TUN uses direct route-table management rather than Apple's Network Extension. The helper checks that Xray creates a new `utun` interface before reporting the tunnel as running, but real traffic, DNS leak, sleep/wake, crash recovery, and stale-route behavior still require a smoke test on the target Mac. See [docs/macos-tunnel.md](docs/macos-tunnel.md) and [docs/architecture.md](docs/architecture.md).

The helper remains running as a LaunchDaemon, and a tunnel can remain active if the UI app quits. Disconnect from the app before quitting. This private distribution approach is intended for a small trusted group, not public release; notarization and normal Gatekeeper distribution need a separate signed release process.
