#!/bin/bash
# Сборка Linux-артефактов: tar.zst приложения с бинарником, установщиком
# и иконкой — и отдельно tar.gz терминальной версии с одним бинарником weto.
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

# Терминальная версия — своим архивом и в своём каталоге: релизный workflow
# и установщик берут `release_build/cli/weto-cli-<версия>-linux-<arch>.tar.gz`,
# а обновление самой терминальной версии ищет ассет по этому же точному имени.
# gzip, а не zstd: на сервере zstd может не оказаться.
#
# Бинарник статический (musl): сервер — не рабочая машина, и glibc там бывает
# старше той, с которой собирал раннер (бинарник с ubuntu-24.04 требует
# GLIBC_2.39 и на Debian 12 или Ubuntu 22.04 не запускается). TLS у ureq —
# rustls, libssl не нужна. Нужны цель `<arch>-unknown-linux-musl` у rustup
# и musl-gcc (пакет musl-tools): им собираются C-части ring и zstd.
# Cargo-бинарник называется weto-cli (имя weto занято приложением с окном),
# в архив он кладётся под именем weto.
CLI_OUT="$OUT/cli"
CLI_TARGET="$ARCH-unknown-linux-musl"
CLI_ARCHIVE="$CLI_OUT/weto-cli-$VERSION-linux-$ARCH.tar.gz"
CLI_STAGE="$CLI_OUT/stage"

echo "=== weto (терминальная версия) $VERSION ($CLI_TARGET) ==="

mkdir -p "$CLI_STAGE"
WETO_VERSION="$VERSION" cargo build --release -p weto-cli --target "$CLI_TARGET"

cp "target/$CLI_TARGET/release/weto-cli" "$CLI_STAGE/weto"
strip "$CLI_STAGE/weto" 2>/dev/null || true

# Динамический бинарник сюда попасть не должен: он молча сломался бы
# на первом же сервере со старой glibc.
LDD="$(ldd "$CLI_STAGE/weto" 2>&1 || true)"
case "$LDD" in
    *"not a dynamic executable"*|*"statically linked"*) ;;
    *)
        echo "weto собран динамическим:" >&2
        echo "$LDD" >&2
        exit 1
        ;;
esac

tar -czf "$CLI_ARCHIVE" --owner=0 --group=0 -C "$CLI_STAGE" weto
rm -rf "$CLI_STAGE"
echo "архив: $CLI_ARCHIVE"
