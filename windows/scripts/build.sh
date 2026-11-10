#!/bin/bash
# Сборка приложения Weto для Windows на раннере (Git Bash):
#   windows/scripts/build.sh <версия> <x86_64|aarch64>
# Rust-мост (release, CRT статически), иконки из shared/icon, затем
# dotnet publish self-contained под архитектуру → windows/app/out/<arch>/.
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
cargo build --release -p weto-ffi --target "$TRIPLE"
cargo run --release -q -p weto-icons -- "$ROOT/app/Weto/Assets"

cd "$ROOT/app"
dotnet publish Weto/Weto.csproj -c Release -r "$RID" -p:Platform="$PLATFORM" \
    -p:Version="$VERSION" --self-contained -o "out/$ARCH"
echo "→ $ROOT/app/out/$ARCH/Weto.exe"
