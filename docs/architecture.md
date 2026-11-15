# Архитектура Flutter VPN-клиента

## Проекты

- `../oksana-vpn-ui` — действующий Vue 3 SPA для Web и Telegram Mini App. Он остаётся рабочим и используется как дизайн-референс и источник API-контрактов.
- `oksana-vpn-desktop` — Flutter desktop-приложение. В репозитории есть macOS ARM64 runtime и Windows runner для сборки Flutter shell; VPN runtime для Windows ещё не реализован. Отдельное приложение `flutter/` рядом с `desktop/` не нужно.
- Нативная macOS интеграция находится в Flutter host/plugin слое. Выделять отдельный Rust service можно позже, если появится требование переиспользовать VPN engine несколькими клиентами.

## Экраны

1. **Подписка** — ввод UUID, запрос профилей, ошибки и загрузка.
2. **VPN** — выбор профиля/сервера, Proxy/TUN режим, статус и кнопка подключения.

Другие разделы, включая платежи, поддержку и кабинет, пока не переносим.

## Стиль UI

Референс: `../oksana-vpn-ui/src/css/telegram-mini-app.css`.

- Primary: `#6C4CF5`; pressed: `#5B3DE2`.
- Light background: `#F6F7FB`; surface: `#FFFFFF`; text: `#121826`; secondary text: `#667085`; border: `#E7EAF0`.
- Dark background: `#0C1222`; surface: `#11192D`; text: `#F2F5FB`; secondary text: `#A9B5C9`; border: `#22304A`.
- Cards use 16 px radius, subtle shadow and compact spacing. Follow macOS window layout rather than Telegram's phone frame.

## Subscription API contract

The Vue reference uses a public connection domain. The backend's `VlessDeepLinkService` constructs `/start?token=<users.uuid>`; the reverse proxy rewrites `/start` to `/connect-v2`. The response is a JSON array of Xray profiles.

Default endpoint:

```text
https://connect.oksana1984.ru/start?token=<UUID>
```

Each profile is an Xray JSON object with fields such as `remarks`, `inbounds`, `outbounds`, `routing`, and `dns`. The API's configured local proxy inbounds are normally SOCKS `127.0.0.1:10808` and HTTP `127.0.0.1:10809`. The app should preserve the backend profile except for explicitly documented runtime-specific adaptations.

The UUID grants access to the profile and must not be logged or written to plaintext persistence. The macOS app persists it in Keychain using `flutter_secure_storage`; fetched profiles remain in memory. Endpoint URL is configurable at build time; no client secret is required by this public URL contract.

Security follow-up before production: the current backend `VlessConfigController::connectV2` logs the request query map, which includes this `token`. The backend should redact `token` from request logs; this desktop repository does not change the backend.

## Runtime boundary

UI screens depend on a small typed `VpnRuntime` contract. The first runtime supports macOS local proxy mode and reports runtime status to the UI. Profile models and state names should not embed OS-specific details. Add Windows/Linux implementations later without adding dummy implementations now.

Proxy mode starts the local Xray listeners from the returned profile. It does not change macOS system proxy settings automatically.

Routing templates can match `process` names in addition to domain/IP/port and other supported conditions. Rules retain Xray's AND semantics when imported conditions are combined. On Windows, use the executable process name (the `.exe` suffix is optional and matching is case-sensitive); the template default route can be set to direct for VPN-only-listed apps or proxy for VPN-except-listed apps. Xray's current routing documentation lists process matching for Windows and Linux, not macOS, so the macOS runtime refuses to start an enabled template containing process rules. The Windows rule model and JSON generation are in place, but a Windows `VpnRuntime` is not.

## Windows build path

The repository includes Flutter's generated Windows runner and a PowerShell release script. Build on Windows with Flutter 3.35.7 and Visual Studio 2022's **Desktop development with C++** workload using `./scripts/build-windows.ps1 -Architecture x64`. It packages the Flutter output into a ZIP and does not bundle Xray or implement Windows VPN controls yet. GitHub Actions can produce the same build on a Windows runner when started manually or on a `v*` tag.

## macOS TUN runtime

TUN currently runs Xray's native macOS `utun` inbound from a root LaunchDaemon. On first TUN use, the app installs its bundled helper through one macOS administrator authorization dialog. Subsequent start, stop, and status requests use a peer-UID-checked Unix socket; the UI cannot pass arbitrary commands or executable paths.

The runtime enables Xray's `autoSystemRoutingTable` and `autoOutboundsInterface: auto`. Because Xray does not apply its `dns` config to macOS system DNS, the helper snapshots and changes DNS with `networksetup` to the effective resolver's IP address and restores it when the tunnel stops or the daemon restarts. Settings can choose a global DNS provider for TUN; DNS configured by the active routing template takes precedence. Profiles must expose an IP resolver directly or through a DoH hostname's `dns.hosts` bootstrap mapping. Runtime status waits for both a live Xray process and a newly-created `utun` interface. Traffic routing, DNS leak behavior, sleep/wake, and forced-crash recovery still need a real Mac smoke test.

This is a private-distribution trade-off: Apple's Network Extension is the normal VPN API, but requires additional entitlements and signing. The LaunchDaemon approach avoids that requirement for the current small trusted group and directly manages system routes and DNS.

References:

- [Xray-core TUN inbound](https://github.com/XTLS/Xray-core/blob/main/proxy/tun/README.md)
- [Apple LaunchDaemons](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [Flutter platform channels](https://docs.flutter.dev/platform-integration/platform-channels)
