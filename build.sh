#!/bin/zsh
# Builds DevIsland.app from the Swift sources.
set -euo pipefail

cd "$(dirname "$0")"

APP="DevIsland.app"
BIN="DevIsland"

# Signing identity.
#
# TCC keys Accessibility and Automation grants on the code-signing *designated
# requirement*. An ad-hoc signature (`--sign -`) produces a new requirement on
# every build, so those grants drop after each rebuild and the feature looks
# broken with no error. Any stable identity avoids that.
#
# Resolution order:
#   1. ISLAND_SIGN_IDENTITY, for one-off overrides
#   2. "Dev Island Local Signing" — the self-signed certificate from PLAN.md §11
#   3. an Apple Development identity, if there is exactly one
#   4. fail loudly, because a silently unsigned build is indistinguishable from a
#      dropped permission
resolve_identity() {
  if [[ -n "${ISLAND_SIGN_IDENTITY:-}" ]]; then
    print -r -- "$ISLAND_SIGN_IDENTITY"
    return
  fi

  local identities
  identities=$(security find-identity -v -p codesigning 2>/dev/null || true)

  if print -r -- "$identities" | grep -q "Dev Island Local Signing"; then
    print -r -- "Dev Island Local Signing"
    return
  fi

  local development
  development=$(print -r -- "$identities" \
    | grep "Apple Development" \
    | head -1 \
    | sed -E 's/.*"(.*)"/\1/' || true)
  if [[ -n "$development" ]]; then
    print -r -- "$development"
    return
  fi

  print -u2 "No code signing identity found."
  print -u2 "Create 'Dev Island Local Signing' in Keychain Access"
  print -u2 "(Certificate Assistant → Create a Certificate → Code Signing),"
  print -u2 "or set ISLAND_SIGN_IDENTITY to an existing identity."
  exit 1
}

IDENTITY=$(resolve_identity)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

# Follow the host architecture instead of hardcoding arm64, so an Intel Mac gets
# either a working build or an honest error rather than a confusing "unsupported
# architecture". Override with ISLAND_TARGET when cross-compiling.
TARGET="${ISLAND_TARGET:-$(uname -m)-apple-macos26.0}"

swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -target "$TARGET" \
  -framework AppKit \
  -framework SwiftUI \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$BIN"

# MediaRemoteAdapter — built from vendored source, not shipped as a blob, so a
# clone plus this script is still the whole build. See Sources/MediaStream.swift
# for why the app needs a helper at all: reading the now-playing session stopped
# working for ordinary apps in macOS 15.4, but works from inside /usr/bin/perl,
# which is entitled. No cmake: 15 plain Objective-C files and a system clang.
ADAPTER_SRC="vendor/mediaremote-adapter"
FW="$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
mkdir -p "$FW/Versions/A/Headers" "$FW/Versions/A/Resources"

clang -dynamiclib -fobjc-arc -fvisibility=default -arch "$(uname -m)" \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -I "$ADAPTER_SRC/include" -I "$ADAPTER_SRC/src" \
  "$ADAPTER_SRC"/src/adapter/*.m "$ADAPTER_SRC"/src/private/*.m "$ADAPTER_SRC"/src/utility/*.m \
  -o "$FW/Versions/A/MediaRemoteAdapter"

# Classic framework layout: the perl loader opens <path>/<basename>, i.e. the
# top-level symlink, not the versioned directory.
ln -sfn A "$FW/Versions/Current"
ln -sfn Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -sfn Versions/Current/Resources "$FW/Resources"
ln -sfn Versions/Current/Headers "$FW/Headers"
cp "$ADAPTER_SRC/include/MediaRemoteAdapter.h" "$FW/Versions/A/Headers/"

cat > "$FW/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
<key>CFBundleName</key><string>MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
PLIST

cp "$ADAPTER_SRC/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
# BSD-3 requires the notice to travel with the binary.
cp "$ADAPTER_SRC/LICENSE" "$APP/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"

# Nested code is signed before the bundle that contains it, or the app signature
# does not cover the framework and Gatekeeper treats it as tampered.
codesign --force --sign "$IDENTITY" --timestamp=none "$FW" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null

# Install where Spotlight looks.
#
# A .app sitting in a source tree is not an Application as far as Spotlight and
# LaunchServices are concerned, so it cannot be typed into ⌘Space. ~/Applications
# is user-writable (no admin prompt) and is one of the folders macOS indexes for
# apps, so a copy there is findable by name without touching the build output.
#
# `lsregister -f` is what makes it appear immediately instead of on the next mdB
# pass. Skip with ISLAND_NO_INSTALL=1 when iterating and only the local copy
# matters; override the destination with ISLAND_INSTALL_DIR.
INSTALL_DIR="${ISLAND_INSTALL_DIR:-$HOME/Applications}"
# The installed name is what Spotlight shows and what `open -a` matches, so it has
# to be the spaced product name rather than the build directory's `DevIsland.app`.
INSTALLED="$INSTALL_DIR/Dev Island.app"
if [[ "${ISLAND_NO_INSTALL:-0}" != "1" ]]; then
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALLED"
  # Move rather than copy, then point the repo path at the installed bundle. Two
  # real bundles would both be indexed and Spotlight would offer the same app
  # twice; a symlink keeps `./DevIsland.app/...` working for scripts and tests
  # while only one bundle exists.
  mv "$APP" "$INSTALLED"
  ln -s "$INSTALLED" "$APP"
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$INSTALLED" 2>/dev/null || true
  echo "Installed: $INSTALLED"
fi

echo "Built $APP"
echo "Signed with: $IDENTITY"
