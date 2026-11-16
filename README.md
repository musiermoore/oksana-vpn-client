# Oksana VPN Desktop

Flutter desktop client. The macOS ARM64 and Windows x64 VPN runtimes are implemented. The Vue application in `../oksana-vpn-ui` remains the Web and Telegram Mini App; this project uses it as a design and API reference.

## Current scope

- Subscription UUID entry and profile download from `https://connect.oksana1984.ru/start?token=<UUID>`.
- Server/profile selection and VPN controls.
- Local Xray SOCKS/HTTP proxy mode. It exposes the profile's local proxy endpoints and does not change system-wide proxy settings.
- TUN mode through Xray's native macOS `utun` inbound and Windows Wintun adapter.
- Xray routing templates with domain, IP, port, and process rules. Process rules are serialized for Xray on Windows/Linux; the current macOS client reports them as unsupported.

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

On Windows, install Flutter and Visual Studio Build Tools (or Visual Studio Community) with the **Desktop development with C++** workload and the **C++ ATL for x64/x86** component. VS Code is an editor and does not include these C++ build tools. The ATL headers are required by `flutter_secure_storage_windows`. Enable **Developer Mode** in Windows Settings so Flutter can create the symlinks required by plugins, then start the debug build from PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run-windows.ps1
```

This prepares the official Xray Windows x64 package (including `wintun.dll`), verifies its published SHA-256 digest, and starts the Windows desktop client. Proxy mode launches the bundled Xray process without administrator rights. TUN mode asks Windows for administrator consent and runs Xray through a fixed-operation companion; Xray manages its adapter, routes, DNS and leak-block filters. The companion accepts only `start`, `stop` and `status`, and does not log profile data or process output.

Windows TUN requires a profile or DNS setting that resolves to at least one IP address. Routing templates, custom DNS, local SOCKS authentication, imported profiles, Telegram login, and process routing rules are supported by the Windows runtime. Proxy mode remains app-local; choose TUN when system traffic should use the profile. Windows ARM64 is not supported yet.

The Windows runner implements the `oksanavpn/deep_links` channel for Telegram login, external HTTP(S) links, and JSON/text routing-template files. At app startup it registers the `oksanavpn://` URL handler for the current Windows user; no administrator prompt is required. Telegram's browser callback opens the app, which validates the ticket before completing sign-in. The macOS channel remains implemented by the macOS runner.

The script finds Flutter on `PATH`, through `FLUTTER_ROOT`, or in a sibling `../flutter` folder. The release build script also prepares the same verified Xray/Wintun files before packaging.

If Flutter reports that building with plugins requires symlink support, open Developer settings with `start ms-settings:developers`, turn on **Developer Mode**, and rerun the command. The package version notices from `flutter pub get` are informational; the project dependencies were resolved successfully.

If CMake reports that the Visual Studio generator differs from the one used previously, run `flutter clean` once to clear generated build files, then rerun the Windows debug command.

## Build a Windows release bundle

Windows executables must be compiled on Windows. Install Flutter 3.35.7 and Visual Studio 2022 with the **Desktop development with C++** workload and **C++ ATL for x64/x86**, then run PowerShell from the repository:

```powershell
./scripts/build-windows.ps1 -Architecture x64
```

The script writes `build/release/oksana-vpn-windows-x64.zip`. The same build runs on GitHub Actions through **Windows release build** (manually from Actions or when a `v*` tag is pushed).

This packages the Flutter app, the fixed-operation TUN companion, and Xray/Wintun runtime. The first TUN connection in each Windows logon session shows a Windows administrator consent prompt. The tunnel remains managed by the helper if the UI closes; stop it in the app before exiting. Windows ARM64 and installer signing are still future work.

## Process routing

In a routing template, add an **Application** rule and enter the process name, such as `chrome` or `Telegram`. Xray matches process names case-sensitively; on Windows its process matcher treats `chrome` and `chrome.exe` as the same name. Choose **Direct** to exclude an app while the template's default is **VPN**, or choose **VPN** for an app while the default is **Direct**. The built-in presets **VPN except listed** and **VPN only listed** set those defaults for all listed rules.

Xray documents process matching for Windows and Linux. The macOS client rejects enabled templates with process rules because its Xray process lookup is unsupported there. See [Xray routing](https://github.com/XTLS/Xray-docs-next/blob/main/docs/en/config/routing.md#ruleobject).

## First use on a friend's Mac

This private, unnotarized build does not require a paid Apple Developer account. After downloading and extracting `oksana_vpn_desktop.app` into Downloads, the recipient runs this one command in Terminal to clear the download quarantine and open the app:

```sh
xattr -dr com.apple.quarantine "$HOME/Downloads/oksana_vpn_desktop.app" && open "$HOME/Downloads/oksana_vpn_desktop.app"
```

The first time they turn on TUN, macOS shows one administrator authorization prompt. The app then installs the signed/bundled helper and Xray under `/Library/Application Support/OksanaVPN` and registers the LaunchDaemon. Later connect/disconnect actions stay in the app; no Terminal commands are needed. Proxy mode does not need the administrator helper.

## Architecture and limitations

The UUID is stored in macOS Keychain via `flutter_secure_storage`; fetched profiles stay in memory. The helper communicates only with the installing user through a permission-restricted local Unix socket. It changes and restores system DNS while the tunnel runs; Xray adds and removes system routes. A global DNS provider can be selected in Settings for TUN, while DNS configured by the active routing template takes precedence.

TUN uses direct route-table management rather than Apple's Network Extension. The helper checks that Xray creates a new `utun` interface before reporting the tunnel as running, but real traffic, DNS leak, sleep/wake, crash recovery, and stale-route behavior still require a smoke test on the target Mac. See [docs/macos-tunnel.md](docs/macos-tunnel.md) and [docs/architecture.md](docs/architecture.md).

The helper remains running as a LaunchDaemon, and a tunnel can remain active if the UI app quits. Disconnect from the app before quitting. This private distribution approach is intended for a small trusted group, not public release; notarization and normal Gatekeeper distribution need a separate signed release process.
