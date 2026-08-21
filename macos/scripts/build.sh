#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="${1:-0.1.0}"
PKG_ID="com.weto.pkg"
OUT=".build/release_build"

# Базовый размер собранного .app в КБ. Превышение больше чем на 10% валит сборку:
# так замечается случайно попавшая в payload документация или ресурсы.
# История правок базы — чтобы рост был осознанным, а не «подвинули, раз красное»:
#   2000 → 2250  пакет UpdateKit: приложение линкует пять его таргетов, +230 КБ кода;
#   2250 → 2460  иконка приложения: AppIcon.icns 141 КБ и два PNG по 10 КБ на темы;
#   2460 → 3640  флаги стран в бандле: 265 SVG на 1060 КБ. Раньше они тянулись
#                с CDN — а CDN в России блокируется, и флаг нужен ровно под VPN.
APP_BASELINE_KB=3640

echo "=== weto $VERSION — сборка ==="

# Версия подставляется только в копию Info.plist внутри staging: отслеживаемые файлы
# сборка не меняет, иначе после каждого релиза остаётся грязное рабочее дерево
# и риск разъезда версии в бинарнике и пакете. Приложение читает версию из Info.plist.
swift build -c release --product WetoMenuBar
swift build -c release --product WetoHelper

rm -rf "$OUT"
mkdir -p "$OUT"

APP="$OUT/_app/Weto.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
cp .build/release/WetoMenuBar "$APP/MacOS/"
cp Resources/Weto-Info.plist "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
                        -c "Set :CFBundleVersion $VERSION" "$APP/Info.plist"
cp Resources/uninstall-weto.sh "$APP/Resources/"
chmod +x "$APP/Resources/uninstall-weto.sh"
# Иконка бандла: Finder и установщик показывают её, внутри приложения иконка
# меняется вместе с темой из PNG в ресурсном бандле дизайн-системы.
cp Resources/AppIcon.icns "$APP/Resources/"

# Ресурсные бандлы лежат в штатном Contents/Resources: только такую раскладку
# codesign умеет пломбировать. Находит их DesignResources, а не Bundle.module,
# который смотрит лишь в корень бандла и в путь .build машины сборки.
for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Resources/"
done

if grep -q "resources:" Package.swift && ! ls -d "$APP/Resources"/*.bundle >/dev/null 2>&1; then
    echo "✗ Package.swift объявляет ресурсы, но в Contents/Resources нет ни одного .bundle" >&2
    exit 1
fi

# Подпись ad-hoc: Developer ID и нотаризация недоступны осознанно (см. README),
# но отказ самой подписи скрывать нельзя — иначе на выходе битый бандл.
if ! codesign --force --sign - --deep "$OUT/_app/Weto.app"; then
    echo "✗ ad-hoc подпись Weto.app не удалась" >&2
    exit 1
fi
echo "  подпись: ad-hoc (без Developer ID и нотаризации)"

ROOT="$OUT/_pkg-root"
SCRIPTS="$OUT/_pkg-scripts"
mkdir -p "$ROOT/Applications" "$ROOT/Library/PrivilegedHelperTools" "$ROOT/Library/LaunchDaemons" "$SCRIPTS"

# Агент автозапуска в payload не входит: его пишет postinstall в домашний каталог
# консольного пользователя — там же, где им управляют приложение и деинсталлятор.
cp -R "$OUT/_app/Weto.app" "$ROOT/Applications/"

# Демон обновления, наоборот, системный: устанавливать PKG может только root.
# LaunchDaemon (не агент) — он один на машину и не привязан к сеансу пользователя.
cp .build/release/WetoHelper "$ROOT/Library/PrivilegedHelperTools/com.weto.helper"
chmod 755 "$ROOT/Library/PrivilegedHelperTools/com.weto.helper"
cp Resources/com.weto.helper.plist "$ROOT/Library/LaunchDaemons/"
chmod 644 "$ROOT/Library/LaunchDaemons/com.weto.helper.plist"
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

# Снимаем карантин и прочие снимаемые атрибуты. Записи ._* в архиве всё равно
# останутся: их создаёт pkgbuild для несбрасываемого com.apple.provenance,
# и это перенос метаданных, а не файлы — на диск при установке они не попадают.
# Обход дерева свой: флага `-r` у `xattr` больше нет — он печатает справку
# в стандартный вывод и не трогает ничего, а `2>/dev/null || true` это прятало.
# Шаг выглядел сделанным и не делался.
find "$ROOT" -print0 | xargs -0 xattr -c 2>/dev/null || true

bash scripts/tests/launch-agent-contract.sh "$ROOT"

# Бюджет размера: документация и прочий вес не должны утекать в бандл незаметно.
APP_SIZE_KB=$(du -sk "$OUT/_app/Weto.app" | awk '{print $1}')
APP_SIZE_LIMIT_KB=$(( APP_BASELINE_KB * 110 / 100 ))
echo "  размер Weto.app: ${APP_SIZE_KB} КБ (базовый ${APP_BASELINE_KB} КБ, предел ${APP_SIZE_LIMIT_KB} КБ)"
if [ "$APP_SIZE_KB" -gt "$APP_SIZE_LIMIT_KB" ]; then
    echo "✗ бандл вырос больше чем на 10% от базового размера" >&2
    exit 1
fi

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

# Список payload снимается один раз в переменную, а не подаётся в `grep -q` пайпом.
# `grep -q` закрывает пайп на первом совпадении, `pkgutil` получает SIGPIPE, и при
# `set -o pipefail` проверка падала на успехе. Пока payload был короткий, grep дочитывал
# его целиком и обрыва не случалось — ловушка ждала первого крупного ресурса.
PAYLOAD="$(pkgutil --payload-files "$OUT/_component.pkg")"

for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] || continue
    name="$(basename "$bundle")"
    if ! grep -qx "./Applications/Weto.app/Contents/Resources/$name" <<< "$PAYLOAD"; then
        echo "✗ $name отсутствует в Contents/Resources внутри пакета — иконок не будет" >&2
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
