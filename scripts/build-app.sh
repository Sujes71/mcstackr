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

# The bundle is built in a staging folder and swapped at the end, so an
# interrupted build never leaves a half built app behind.
STAGE="$BUILD/.MCStackr.stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_DIR/MCStackr" "$STAGE/Contents/MacOS/MCStackr"
cp "$BUILD/mcstackr-engine" "$STAGE/Contents/MacOS/mcstackr-engine"
cp "$ROOT/app/Resources/Info.plist" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# Ad-hoc signature so macOS is happy launching a locally built bundle.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --timestamp=none "$STAGE/Contents/MacOS/mcstackr-engine" >/dev/null 2>&1 || true
  codesign --force --sign - --timestamp=none "$STAGE" >/dev/null 2>&1 || true
fi

# The bundle is swapped only when everything is ready.
rm -rf "$APP"
mv "$STAGE" "$APP"

echo "==> built $APP"
