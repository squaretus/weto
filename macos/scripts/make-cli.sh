#!/bin/bash
# Терминальная версия: один бинарник weto с ad-hoc подписью и архив для релиза.
#
# Запуск: macos/scripts/make-cli.sh [debug|release] [версия]   (по умолчанию release, dev)
# Результат: macos/.build/cli/weto
#            macos/.build/release_build/cli/weto-cli-<версия>-macos-arm64.tar.gz
#            (архив — только с версией: релизный workflow, установочный скрипт
#            и `weto update` ищут его по этому точному имени; внутри один файл `weto`)
#
# Версия вшивается в бинарник секцией __TEXT,__info_plist: у одиночного
# исполняемого файла нет бандла, а `Bundle.main.infoDictionary` читает именно
# эту секцию. Отслеживаемые файлы сборка не правит. Идентификатора бандла
# в секции нет намеренно: он совпал бы с именем набора настроек `com.weto.cli`,
# а `UserDefaults` отказывается работать с набором, названным как свой бандл.
#
# Бинарник копируется из каталога сборки намеренно: сервис launchd, поставленный
# на путь внутри .build, сломался бы при первой же пересборке. Для сервиса
# кладите копию в постоянное место (например, /usr/local/bin) и ставьте оттуда.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

CONFIG="${1:-release}"
VERSION="${2:-dev}"
OUT=".build/cli"
ARCHIVE_DIR=".build/release_build/cli"

case "$CONFIG" in
    release|debug) ;;
    *)
        echo "✗ конфигурация — debug или release, а не «$CONFIG»" >&2
        exit 2
        ;;
esac

mkdir -p "$OUT"
INFO="$PROJECT_DIR/$OUT/Info.plist"
cat > "$INFO" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>weto</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
</dict>
</plist>
PLIST

LINK_INFO=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$INFO")
swift build -c "$CONFIG" --product weto "${LINK_INFO[@]}"
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

# Временный файл и переименование: копия поверх работающего бинарника
# не должна оставить его наполовину переписанным.
cp "$BUILD_DIR/weto" "$OUT/weto.tmp"
mv -f "$OUT/weto.tmp" "$OUT/weto"

if ! codesign --force --sign - "$OUT/weto"; then
    echo "✗ ad-hoc подпись weto не удалась" >&2
    exit 1
fi

echo "✓ Готово: $OUT/weto ($CONFIG, версия $VERSION, подпись ad-hoc)"

if [ "$VERSION" = "dev" ]; then
    echo "  архив релиза не собран: без версии его имя не определено"
    exit 0
fi

# Имя ассета называет arm64 — другой архитектуры в архиве быть не должно.
if ! lipo -archs "$OUT/weto" | tr ' ' '\n' | grep -qx arm64; then
    echo "✗ weto собран не под arm64 ($(lipo -archs "$OUT/weto")) — архив с таким именем был бы ложью" >&2
    exit 1
fi

mkdir -p "$ARCHIVE_DIR"
ARCHIVE="$ARCHIVE_DIR/weto-cli-$VERSION-macos-arm64.tar.gz"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$OUT/weto" "$STAGE/weto"
# Ровно один файл `weto` в корне архива: без `._weto` (AppleDouble от copyfile)
# и без расширенных атрибутов — `weto update` и установщик принимают только такой.
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -czf "$ARCHIVE.tmp" -C "$STAGE" weto
mv -f "$ARCHIVE.tmp" "$ARCHIVE"

ENTRIES="$(tar -tzf "$ARCHIVE")"
if [ "$ENTRIES" != "weto" ]; then
    echo "✗ в архиве не один файл weto: $ENTRIES" >&2
    exit 1
fi

echo "✓ Архив: $ARCHIVE ($(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1))"
