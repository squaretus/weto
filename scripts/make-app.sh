#!/bin/bash
# Сборка .app-бандла для локального запуска без PKG-установщика.
# Полноценная релизная сборка с демоном и PKG появится в scripts/build.sh.
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

# Ad-hoc подпись: без неё macOS не отдаёт приложению Keychain и уведомления.
codesign --force --sign - "$OUT/Weto.app" 2>/dev/null || true

echo "✓ Готово: $OUT/Weto.app"
