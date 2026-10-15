#!/usr/bin/env bash
# Builds the Go core, the Swift app, and assembles build/Wisp.app.
# Usage: scripts/build.sh [release|debug]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"

export MACOSX_DEPLOYMENT_TARGET=14.0
export CGO_ENABLED=1
export CGO_CFLAGS="-O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CGO_LDFLAGS="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"

echo "==> core (Go)"
# libsqlite3: link the system SQLite instead of bundling a second copy, so the
# Go store and the Swift data layer never run two SQLite builds in one process.
(cd "$ROOT/core" && go build -buildmode=c-archive -tags "libsqlite3 sqlite_omit_load_extension" -trimpath \
  -ldflags="-s -w" -o build/libwisp.a .)

echo "==> app (Swift, $CONFIG)"
(cd "$ROOT/app" && swift build -c "$CONFIG")
BIN_DIR="$(cd "$ROOT/app" && swift build -c "$CONFIG" --show-bin-path)"

echo "==> bundle"
APP="$ROOT/build/Wisp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Wisp" "$APP/Contents/MacOS/Wisp"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
[[ "$CONFIG" == release ]] && strip -x "$APP/Contents/MacOS/Wisp"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP ($(du -sh "$APP/Contents/MacOS/Wisp" | cut -f1) binary)"
