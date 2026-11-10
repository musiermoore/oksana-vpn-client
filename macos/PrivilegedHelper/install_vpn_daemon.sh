#!/bin/bash
set -euo pipefail

readonly LABEL="com.oksana1984.oksanaVpnDesktop.daemon"
readonly SUPPORT_DIRECTORY="/Library/Application Support/OksanaVPN"
readonly RUNTIME_DIRECTORY="$SUPPORT_DIRECTORY/runtime"
readonly PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This installer must run with administrator privileges." >&2
  exit 1
fi

owner_uid="${1:-}"
if [[ ! "$owner_uid" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid control-socket owner." >&2
  exit 1
fi

readonly RESOURCE_DIRECTORY="$(cd -- "$(dirname -- "$0")" && pwd)"
for resource in vpn-helper xray geoip.dat geosite.dat com.oksana1984.oksanaVpnDesktop.daemon.plist; do
  if [[ ! -f "$RESOURCE_DIRECTORY/$resource" ]]; then
    echo "VPN resource is missing: $resource" >&2
    exit 1
  fi
done

# Stop an older helper before replacing its root-owned executable or Xray.
/bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true

/usr/bin/install -d -o root -g wheel -m 0755 "$SUPPORT_DIRECTORY"
/usr/bin/install -d -o root -g wheel -m 0700 "$RUNTIME_DIRECTORY"
/usr/bin/install -o root -g wheel -m 0755 "$RESOURCE_DIRECTORY/vpn-helper" "$SUPPORT_DIRECTORY/vpn-helper"
/usr/bin/install -o root -g wheel -m 0755 "$RESOURCE_DIRECTORY/xray" "$SUPPORT_DIRECTORY/xray"
/usr/bin/install -d -o root -g wheel -m 0755 "$SUPPORT_DIRECTORY/assets"
/usr/bin/install -o root -g wheel -m 0644 "$RESOURCE_DIRECTORY/geoip.dat" "$SUPPORT_DIRECTORY/assets/geoip.dat"
/usr/bin/install -o root -g wheel -m 0644 "$RESOURCE_DIRECTORY/geosite.dat" "$SUPPORT_DIRECTORY/assets/geosite.dat"
/usr/bin/install -o root -g wheel -m 0644 "$RESOURCE_DIRECTORY/com.oksana1984.oksanaVpnDesktop.daemon.plist" "$PLIST_PATH"

printf '%s\n' "$owner_uid" > "$SUPPORT_DIRECTORY/control-owner-uid"
/usr/sbin/chown root:wheel "$SUPPORT_DIRECTORY/control-owner-uid"
/bin/chmod 0644 "$SUPPORT_DIRECTORY/control-owner-uid"
/usr/sbin/chown -R root:wheel "$SUPPORT_DIRECTORY"
/bin/chmod 0700 "$RUNTIME_DIRECTORY"
/bin/chmod 0644 "$PLIST_PATH"
/usr/bin/plutil -lint "$PLIST_PATH" >/dev/null

/bin/launchctl bootstrap system "$PLIST_PATH"
/bin/launchctl kickstart -k "system/$LABEL"
