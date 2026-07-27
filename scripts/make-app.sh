#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

CONFIG="${1:-debug}"
OUT=".build/app"
APP="$OUT/Weto.app/Contents"

if [ "$CONFIG" = "release" ]; then
    swift build -c release --product WetoMenuBar
    BIN=".build/release/WetoMenuBar"
else
    swift build --product WetoMenuBar
    BIN=".build/debug/WetoMenuBar"
fi

rm -rf "$OUT"
mkdir -p "$APP/MacOS" "$APP/Resources"

cp "$BIN" "$APP/MacOS/WetoMenuBar"
cp Resources/Weto-Info.plist "$APP/Info.plist"

codesign --force --sign - "$OUT/Weto.app" 2>/dev/null || true

echo "✓ Готово: $OUT/Weto.app"
