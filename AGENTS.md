# Project instructions

## Project boundaries

- This repository is the Flutter desktop application. The current Vue 3 Web and Telegram Mini App lives in the sibling repository `../oksana-vpn-ui` and is the design and API-contract reference.
- Do not copy Vue components or change the Vue project unless a separately requested migration requires it.
- The current implementation target is macOS ARM64. Keep the VPN runtime behind a platform boundary so Windows and Linux implementations can be added later, but do not add placeholder implementations for them.
- Keep the project small: no monorepo, workspace, extra `shared/` package, or separate Rust service unless a concrete need appears.

## Product scope

- Keep the first release to two screens: subscription UUID entry/API load, then VPN controls with profile/server selection.
- Match the existing UI's purple accent, surfaces, spacing, rounded cards, and light/dark behavior.
- Use the existing subscription contract: `GET https://connect.oksana1984.ru/start?token=<uuid>` returns the Xray JSON profiles. Make the endpoint configurable at build time.
- Treat the UUID as a credential. Persist it only through the platform secure-storage API (macOS Keychain here); never log it or returned profiles.
- Do not claim that VPN is connected unless the native runtime has started and its local proxy or tunnel is ready. TUN is currently implemented only for macOS ARM64 through the root LaunchDaemon and bundled Xray runtime.

## VPN architecture

- Keep screens independent of process, proxy, TUN, and OS-specific code through a small typed `VpnRuntime` boundary.
- Proxy mode exposes the local SOCKS/HTTP endpoints supplied in the fetched profile; it does not silently change macOS-wide network settings.
- TUN mode runs Xray's native macOS `utun` inbound from a root LaunchDaemon. The app installs the helper on first TUN use through one macOS administrator authorization prompt, then talks to it through the UID-checked Unix socket. Keep the helper API restricted to `start`, `stop`, and `status`; never accept executable paths or arbitrary shell commands from the app.
- Xray manages TUN routes with `autoSystemRoutingTable` and `autoOutboundsInterface: auto`; the helper snapshots and changes DNS through `networksetup`, and restores it on stop and daemon startup. Keep DNS/config files root-only and never log UUIDs, profiles, or process output.
- The development distribution is private and may be ad-hoc signed. Document the one-time Gatekeeper/quarantine step separately from the in-app administrator prompt. Do not require a paid Apple Developer account or Network Extension entitlement for this route-based implementation.
- Keep Windows/Linux work for later, but avoid macOS assumptions in profile models and the runtime contract.
- Redact subscription UUIDs, tokens, full configs, and process output from logs.

## Validation and changes

- Use only dependencies and commands that are present or explicitly added for this Flutter project.
- Read `../oksana-vpn-ui/AGENTS.md` before making any UI changes there. Preserve its Web and Telegram Mini App behavior.
- Inspect Git status before editing and preserve unrelated changes.
- If Flutter or platform tooling is unavailable, continue with independent work and report that builds could not be run.
