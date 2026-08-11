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
cp Resources/AppIcon.icns "$APP/Resources/AppIcon.icns"

# Раскладка ресурсов та же, что в PKG: Contents/Resources и ничего в корне бандла.
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Resources/"
done

if ! codesign --force --sign - --deep "$OUT/Weto.app"; then
    echo "✗ ad-hoc подпись Weto.app не удалась" >&2
    exit 1
fi

echo "✓ Готово: $OUT/Weto.app"
