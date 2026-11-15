#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/build/FanGuard.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
  -framework Cocoa \
  -framework IOKit \
  -framework UserNotifications \
  "$ROOT_DIR/src/SMCReader.m" \
  "$ROOT_DIR/src/ProcessMonitor.m" \
  "$ROOT_DIR/src/AlertPanelController.m" \
  "$ROOT_DIR/src/AppDelegate.m" \
  "$ROOT_DIR/src/main.m" \
  -o "$MACOS_DIR/FanGuard"

xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
