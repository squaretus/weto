#!/bin/bash
# Релизная сборка: .app + PKG-установщик.
# Для локального запуска без установки есть scripts/make-app.sh.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="${1:-0.1.0}"
PKG_ID="com.weto.pkg"
OUT=".build/release_build"

echo "=== weto $VERSION — сборка ==="

# Подстановка версии в исходники и Info.plist.
sed -i '' "s/public static let appVersion = \".*\"/public static let appVersion = \"$VERSION\"/" \
    Sources/WetoCore/Constants.swift
sed -i '' "s|<string>[0-9]*\.[0-9]*\.[0-9]*</string>|<string>$VERSION</string>|g" \
    Resources/Weto-Info.plist

swift build -c release --product WetoMenuBar

rm -rf "$OUT"
mkdir -p "$OUT"

# ── .app ────────────────────────────────────────────────
APP="$OUT/_app/Weto.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
cp .build/release/WetoMenuBar "$APP/MacOS/"
cp Resources/Weto-Info.plist "$APP/Info.plist"
cp Resources/uninstall-weto.sh "$APP/Resources/"
chmod +x "$APP/Resources/uninstall-weto.sh"
cp Resources/AppIcon.icns "$APP/Resources/" 2>/dev/null || true

# Ad-hoc подпись: без неё macOS не отдаёт приложению Keychain и уведомления.
codesign --force --sign - "$OUT/_app/Weto.app" 2>/dev/null || true

# ── payload PKG ─────────────────────────────────────────
ROOT="$OUT/_pkg-root"
SCRIPTS="$OUT/_pkg-scripts"
mkdir -p "$ROOT/Applications" "$ROOT/Library/LaunchAgents" "$SCRIPTS"

cp -R "$OUT/_app/Weto.app" "$ROOT/Applications/"
cp Resources/com.weto.app.plist "$ROOT/Library/LaunchAgents/"
cp scripts/preinstall scripts/postinstall "$SCRIPTS/"
chmod +x "$SCRIPTS/preinstall" "$SCRIPTS/postinstall"

pkgbuild --root "$ROOT" --scripts "$SCRIPTS" --identifier "$PKG_ID" \
         --version "$VERSION" --install-location "/" "$OUT/_component.pkg"

cat > "$OUT/_distribution.xml" << DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>weto</title>
    <welcome file="welcome.html"/>
    <conclusion file="conclusion.html"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <volume-check>
        <allowed-os-versions><os-version min="26.0"/></allowed-os-versions>
    </volume-check>
    <pkg-ref id="$PKG_ID"/>
    <choices-outline><line choice="default"><line choice="$PKG_ID"/></line></choices-outline>
    <choice id="default"/>
    <choice id="$PKG_ID" visible="false"><pkg-ref id="$PKG_ID"/></choice>
    <pkg-ref id="$PKG_ID" version="$VERSION" onConclusion="none">_component.pkg</pkg-ref>
</installer-gui-script>
DIST

mkdir -p "$OUT/_pkg-resources"
cp Resources/welcome.html Resources/conclusion.html "$OUT/_pkg-resources/"

productbuild --distribution "$OUT/_distribution.xml" \
             --resources "$OUT/_pkg-resources" \
             --package-path "$OUT/" \
             "$OUT/Weto-$VERSION.pkg"

rm -rf "$OUT/_app" "$OUT/_pkg-root" "$OUT/_pkg-scripts" "$OUT/_pkg-resources" \
       "$OUT/_distribution.xml" "$OUT/_component.pkg"

echo "✓ Готово: $OUT/Weto-$VERSION.pkg"
