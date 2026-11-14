#!/bin/zsh
# Builds DynamicIsland.app from the Swift sources.
set -euo pipefail

cd "$(dirname "$0")"

APP="DynamicIsland.app"
BIN="DynamicIsland"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos26.0 \
  -framework AppKit \
  -framework SwiftUI \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$BIN"

codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
