#!/bin/bash
# Собирает из `.icon`-бандлов всё, что нужно приложению:
#   - PNG на 256 пт для рантайма (иконка приложения меняется вместе с темой),
#   - AppIcon.icns из тёмного варианта для самого бандла и Finder.
#
# Запускать после правки shared/icon/*.icon (в Icon Composer или руками):
#   bash macos/scripts/build-icon.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# Исходники иконки общие для платформ и лежат вне macos/: Linux-сборка рисует
# из того же grid.svg и тех же заливок свои PNG. Генератор при этом макосный —
# render-icon.swift тянет AppKit, а iconutil бывает только здесь.
ICON_SRC="../shared/icon"
RUNTIME_DIR="Sources/WetoDesign/Resources"
RUNTIME_SIZE=256

echo "=== weto — сборка иконки ==="

# Рантайм: две картинки, по одной на тему. 256 пт хватает и попапу, и диалогу
# обновления (52 пт), а вес в бандле проверяет бюджет размера в build.sh.
for theme in dark light; do
    swift scripts/render-icon.swift "$ICON_SRC/${theme}.icon" \
        "$RUNTIME_DIR/app-icon-${theme}.png" "$RUNTIME_SIZE"
done

# Бандл: .icns собирается из тёмного варианта — Finder показывает одну иконку,
# и это та же, что видна в тёмной теме приложения.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    swift scripts/render-icon.swift "$ICON_SRC/dark.icon" "$ICONSET/icon_${size}x${size}.png" "$size"
    swift scripts/render-icon.swift "$ICON_SRC/dark.icon" "$ICONSET/icon_${size}x${size}@2x.png" "$((size * 2))"
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"

echo "✓ Готово: $RUNTIME_DIR/app-icon-{dark,light}.png, Resources/AppIcon.icns"
