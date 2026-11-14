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

codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null

echo "Built $APP"
echo "Signed with: $IDENTITY"
