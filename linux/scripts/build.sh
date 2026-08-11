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

# Базовый размер собранного бинарника в КБ. Превышение больше чем на 15% валит
# сборку: так замечается случайно залинкованная отладочная информация или
# заехавшая в бинарник крупная зависимость.
# История правок базы — чтобы рост был осознанным:
#   8400  первая релизная сборка: GTK4, ureq с rustls, resvg, ksni.
BINARY_BASELINE_KB=8400

echo "=== weto $VERSION ($ARCH) ==="

rm -rf "$OUT"
mkdir -p "$STAGE/bin" "$STAGE/share"

WETO_VERSION="$VERSION" cargo build --release -p weto-app

cp target/release/weto "$STAGE/bin/weto"
strip "$STAGE/bin/weto" 2>/dev/null || true

SIZE_KB=$(( $(stat -c %s "$STAGE/bin/weto") / 1024 ))
LIMIT_KB=$(( BINARY_BASELINE_KB * 115 / 100 ))
echo "размер бинарника: ${SIZE_KB} КБ (база ${BINARY_BASELINE_KB}, предел ${LIMIT_KB})"
if [ "$SIZE_KB" -gt "$LIMIT_KB" ]; then
    echo "ОШИБКА: бинарник вырос больше чем на 15% — разберитесь, за счёт чего" >&2
    exit 1
fi

cp scripts/install.sh scripts/uninstall.sh "$STAGE/"
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh"
printf '%s' "$VERSION" > "$STAGE/VERSION"
cp ../shared/icon/dark.icon/Assets/grid.svg "$STAGE/share/weto.svg"

tar --zstd -cf "$ARCHIVE" -C "$OUT" "weto-$VERSION"
echo "архив: $ARCHIVE"

# Подпись ставится только при наличии ключа: локальная сборка не обязана
# его иметь, а падать из-за этого ей незачем.
if [ -n "${MINISIGN_SECRET_KEY:-}" ]; then
    KEY_FILE="$(mktemp)"
    trap 'rm -f "$KEY_FILE"' EXIT
    printf '%s' "$MINISIGN_SECRET_KEY" > "$KEY_FILE"
    printf '%s\n' "${MINISIGN_PASSWORD:-}" | minisign -S -s "$KEY_FILE" -m "$ARCHIVE"
    echo "подпись: $ARCHIVE.minisig"
else
    echo "ключа подписи нет — архив не подписан (для локальной сборки это норма)"
fi
