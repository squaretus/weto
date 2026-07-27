#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

CONFIG="${1:-debug}"
OUT=".build/app"
APP="$OUT/Weto.app/Contents"

if [ "$CONFIG" = "release" ]; then
    swift build -c release --product WetoMenuBar
    BUILD_DIR=".build/release"
else
    swift build --product WetoMenuBar
    BUILD_DIR=".build/debug"
fi

rm -rf "$OUT"
mkdir -p "$APP/MacOS" "$APP/Resources"

cp "$BUILD_DIR/WetoMenuBar" "$APP/MacOS/WetoMenuBar"
cp Resources/Weto-Info.plist "$APP/Info.plist"

for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Resources/"
done

codesign --force --sign - "$OUT/Weto.app" 2>/dev/null || true

echo "✓ Готово: $OUT/Weto.app"
