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

# Базовый размер собранного бинарника в КБ, после strip. Превышение больше
# чем на 15% валит сборку: так замечается случайно залинкованная отладочная
# информация или заехавшая в бинарник крупная зависимость.
#
# База своя на каждую архитектуру: один и тот же код даёт на x86_64 и aarch64
# заметно разные числа, и общая цифра проверяла бы одну из них наугад.
#
# История правок — чтобы рост был осознанным:
#   8400 / aarch64  первая релизная сборка: GTK4, ureq с rustls, resvg, ksni.
#  10311 / x86_64   самообновление (tar, zstd, filetime, xattr — распаковать
#   9670 / aarch64  релиз без них нечем) и порт интерфейса под macOS: пять
#                   карточек настроек, разрешение целей через ярлык и запускатор.
case "$ARCH" in
    x86_64)  BINARY_BASELINE_KB=10311 ;;
    aarch64) BINARY_BASELINE_KB=9670 ;;
    *)
        # Молча пропустить проверку нельзя: она бы выглядела сделанной.
        echo "нет базы размера для архитектуры $ARCH — снимите её и впишите выше" >&2
        exit 1
        ;;
esac

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

