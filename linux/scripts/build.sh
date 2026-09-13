#!/bin/bash
# Сборка Linux-артефакта: tar.zst с бинарником, установщиком и иконкой.
#
# Версия приходит аргументом и в отслеживаемые файлы не попадает — то же
# правило, что на macOS: релизная сборка не правит репозиторий.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?использование: build.sh X.Y.Z}"
ARCH="$(uname -m)"
OUT="target/release_build"
STAGE="$OUT/weto-$VERSION"
ARCHIVE="$OUT/weto-$VERSION-$ARCH-linux.tar.zst"

echo "=== weto $VERSION ($ARCH) ==="

rm -rf "$OUT"
mkdir -p "$STAGE/bin" "$STAGE/share"

WETO_VERSION="$VERSION" cargo build --release -p weto-app

cp target/release/weto "$STAGE/bin/weto"
strip "$STAGE/bin/weto" 2>/dev/null || true

cp scripts/install.sh scripts/uninstall.sh "$STAGE/"
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh"
printf '%s' "$VERSION" > "$STAGE/VERSION"
cp ../shared/icon/dark.icon/Assets/grid.svg "$STAGE/share/weto.svg"

tar --zstd -cf "$ARCHIVE" -C "$OUT" "weto-$VERSION"
echo "архив: $ARCHIVE"

