#!/bin/bash

set -e

export XRAY_EXECUTABLE="/opt/homebrew/opt/xray/libexec/xray"
export XRAY_ASSET_DIR="/opt/homebrew/opt/xray/share/xray"

flutter pub get
flutter run -d macos
