#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
CONFIG="${CONFIG:-release}"
APP="$BUILD/MCStackr.app"

mkdir -p "$BUILD"

echo "==> building Go engine"
(
  cd "$ROOT/engine"
  go build -trimpath -ldflags "-s -w" -o "$BUILD/mcstackr-engine" ./cmd/mcstackr-engine
)

echo "==> building SwiftUI app ($CONFIG)"
(
  cd "$ROOT/app"
  swift build -c "$CONFIG"
)
BIN_DIR="$(cd "$ROOT/app" && swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MCStackr" "$APP/Contents/MacOS/MCStackr"
cp "$BUILD/mcstackr-engine" "$APP/Contents/MacOS/mcstackr-engine"
cp "$ROOT/app/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature so macOS is happy launching a locally built bundle.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/mcstackr-engine" >/dev/null 2>&1 || true
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true
fi

echo "==> built $APP"
