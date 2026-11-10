#!/bin/bash
# Сборка приложения Weto для Windows на раннере (Git Bash):
#   windows/scripts/build.sh <версия> <x86_64|aarch64>
# Rust-мост (release, CRT статически), иконки из shared/icon, затем
# dotnet publish self-contained под архитектуру → windows/app/out/<arch>/
# и установщик Inno Setup → windows/app/out/release_build/
# weto-<версия>-<arch>-windows-setup.exe (Inno Setup 6 стоит на раннерах GitHub).
set -euo pipefail

VERSION="${1:?версия}"
ARCH="${2:?архитектура: x86_64 или aarch64}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$ARCH" in
    x86_64) TRIPLE=x86_64-pc-windows-msvc; RID=win-x64; PLATFORM=x64 ;;
    aarch64) TRIPLE=aarch64-pc-windows-msvc; RID=win-arm64; PLATFORM=ARM64 ;;
    *) echo "неизвестная архитектура: $ARCH" >&2; exit 2 ;;
esac

cd "$ROOT/crates"
rustup target add "$TRIPLE" >/dev/null
# Версия зашивается в мост: по ней проверка обновлений сравнивает релизы.
WETO_VERSION="$VERSION" cargo build --release -p weto-ffi --target "$TRIPLE"
cargo run --release -q -p weto-icons -- "$ROOT/app/Weto/Assets"

cd "$ROOT/app"
dotnet publish Weto/Weto.csproj -c Release -r "$RID" -p:Platform="$PLATFORM" \
    -p:Version="$VERSION" --self-contained -o "out/$ARCH"
echo "→ $ROOT/app/out/$ARCH/Weto.exe"

ISCC="${ISCC:-/c/Program Files (x86)/Inno Setup 6/ISCC.exe}"
mkdir -p "$ROOT/app/out/release_build"
# MSYS_NO_PATHCONV: иначе Git Bash принял бы ключи /D… за пути и переписал их.
MSYS_NO_PATHCONV=1 "$ISCC" /Q \
    "/DAppVersion=$VERSION" "/DArch=$ARCH" \
    "/DSourceDir=$(cygpath -w "$ROOT/app/out/$ARCH")" \
    "/DOutputDir=$(cygpath -w "$ROOT/app/out/release_build")" \
    "$(cygpath -w "$ROOT/installer/weto.iss")"
echo "→ $ROOT/app/out/release_build/weto-$VERSION-$ARCH-windows-setup.exe"
