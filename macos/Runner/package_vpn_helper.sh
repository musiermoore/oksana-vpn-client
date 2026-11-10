#!/bin/bash
set -euo pipefail

readonly resources_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
readonly source_directory="${SRCROOT}/PrivilegedHelper"
mkdir -p "$resources_directory"

if [[ -n "${XRAY_EXECUTABLE:-}" ]]; then
  xray_binary="$XRAY_EXECUTABLE"
elif command -v brew >/dev/null 2>&1 && brew --prefix xray >/dev/null 2>&1; then
  xray_prefix="$(brew --prefix xray)"
  xray_binary="$xray_prefix/libexec/xray"
else
  echo "Xray is required to package TUN. Install it with 'brew install xray'." >&2
  exit 1
fi

if [[ -n "${XRAY_ASSET_DIR:-}" ]]; then
  asset_directory="$XRAY_ASSET_DIR"
elif [[ -n "${xray_prefix:-}" ]]; then
  asset_directory="$xray_prefix/share/xray"
else
  asset_directory="$(dirname "$xray_binary")/../share/xray"
fi

if [[ ! -x "$xray_binary" ]]; then
  echo "Xray executable is missing or not executable." >&2
  exit 1
fi

xcrun --sdk macosx swiftc \
  -sdk "$SDKROOT" \
  -target "arm64-apple-macosx${MACOSX_DEPLOYMENT_TARGET}" \
  -O \
  -framework Foundation \
  -o "$resources_directory/vpn-helper" \
  "$source_directory/main.swift"

cp "$xray_binary" "$resources_directory/xray"
for asset in geoip.dat geosite.dat; do
  if [[ ! -f "$asset_directory/$asset" ]]; then
    echo "Xray geodata is missing: $asset" >&2
    exit 1
  fi
  cp "$asset_directory/$asset" "$resources_directory/$asset"
done

cp "$source_directory/install_vpn_daemon.sh" "$resources_directory/install_vpn_daemon.sh"
cp "$source_directory/com.oksana1984.oksanaVpnDesktop.daemon.plist" \
  "$resources_directory/com.oksana1984.oksanaVpnDesktop.daemon.plist"

chmod 0755 "$resources_directory/vpn-helper" "$resources_directory/xray" "$resources_directory/install_vpn_daemon.sh"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$resources_directory/vpn-helper"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$resources_directory/xray"
