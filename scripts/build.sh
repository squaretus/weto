#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="${1:-0.1.0}"
PKG_ID="com.weto.pkg"
OUT=".build/release_build"

echo "=== weto $VERSION — сборка ==="

sed -i '' "s/public static let appVersion = \".*\"/public static let appVersion = \"$VERSION\"/" \
    Sources/WetoCore/Constants.swift
sed -i '' "s|<string>[0-9]*\.[0-9]*\.[0-9]*</string>|<string>$VERSION</string>|g" \
    Resources/Weto-Info.plist

swift build -c release --product WetoMenuBar

rm -rf "$OUT"
mkdir -p "$OUT"

APP="$OUT/_app/Weto.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
cp .build/release/WetoMenuBar "$APP/MacOS/"
cp Resources/Weto-Info.plist "$APP/Info.plist"
cp Resources/uninstall-weto.sh "$APP/Resources/"
chmod +x "$APP/Resources/uninstall-weto.sh"

# Сгенерированный SPM аксессор Bundle.module ищет ресурсный бандл в Bundle.main.bundleURL,
# то есть в КОРНЕ Weto.app, а вторым кандидатом берёт абсолютный путь .build машины сборки
# (в CI это /Users/runner/...). Без копии в корне приложение падает с fatalError при первой же
# иконке, и на машине сборки это незаметно — там fallback-путь существует.
# Копия в Contents/Resources остаётся для кода, ищущего ресурсы через Bundle.main.
for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Resources/"
    cp -R "$bundle" "$OUT/_app/Weto.app/"
done

if grep -q "resources:" Package.swift && ! ls -d "$OUT/_app/Weto.app"/*.bundle >/dev/null 2>&1; then
    echo "✗ Package.swift объявляет ресурсы, но в корне Weto.app нет ни одного .bundle" >&2
    exit 1
fi

codesign --force --sign - --deep "$OUT/_app/Weto.app" 2>/dev/null || true

ROOT="$OUT/_pkg-root"
SCRIPTS="$OUT/_pkg-scripts"
mkdir -p "$ROOT/Applications" "$ROOT/Library/LaunchAgents" "$SCRIPTS"

cp -R "$OUT/_app/Weto.app" "$ROOT/Applications/"
cp Resources/com.weto.app.plist "$ROOT/Library/LaunchAgents/"
cp scripts/preinstall scripts/postinstall "$SCRIPTS/"
chmod +x "$SCRIPTS/preinstall" "$SCRIPTS/postinstall"

# Без этого pkgbuild помечает Weto.app как relocatable, и Installer, найдя в LaunchServices
# любой бандл с идентификатором com.weto.app (например dev-сборку из .build/app), положит
# приложение поверх него вместо /Applications. LaunchAgent укажет в пустоту, launchd отдаст 78.
cat > "$OUT/_component.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>BundleHasStrictIdentifier</key>
        <true/>
        <key>BundleIsRelocatable</key>
        <false/>
        <key>BundleIsVersionChecked</key>
        <false/>
        <key>BundleOverwriteAction</key>
        <string>upgrade</string>
        <key>RootRelativeBundlePath</key>
        <string>Applications/Weto.app</string>
    </dict>
</array>
</plist>
PLIST

pkgbuild --root "$ROOT" --scripts "$SCRIPTS" --identifier "$PKG_ID" \
         --version "$VERSION" --install-location "/" \
         --component-plist "$OUT/_component.plist" "$OUT/_component.pkg"

# Страховки: обе прошлые поломки установки ловятся здесь, а не у пользователя.
pkgutil --expand "$OUT/_component.pkg" "$OUT/_verify"
if grep -q "<relocate>" "$OUT/_verify/PackageInfo"; then
    echo "✗ Weto.app помечен relocatable — установщик положит его не в /Applications" >&2
    exit 1
fi
rm -rf "$OUT/_verify"

for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] || continue
    name="$(basename "$bundle")"
    if ! pkgutil --payload-files "$OUT/_component.pkg" | grep -qx "./Applications/Weto.app/$name"; then
        echo "✗ $name отсутствует в корне Weto.app внутри пакета — Bundle.module упадёт" >&2
        exit 1
    fi
done

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
       "$OUT/_distribution.xml" "$OUT/_component.pkg" "$OUT/_component.plist"

echo "✓ Готово: $OUT/Weto-$VERSION.pkg"
