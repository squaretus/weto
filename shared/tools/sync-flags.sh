#!/bin/bash
# Раскладывает канонический набор флагов из shared/flags по ресурсам платформ.
#
# Канон один — shared/flags. SwiftPM умеет забирать ресурсы только из каталога
# своего таргета, поэтому для macOS набор копируется; править копию руками нельзя,
# как и сгенерированные PNG иконки.
set -euo pipefail
cd "$(dirname "$0")/../.."

MACOS_FLAGS="macos/Sources/WetoDesign/Flags"

rm -rf "$MACOS_FLAGS"
mkdir -p "$MACOS_FLAGS"
cp shared/flags/*.svg "$MACOS_FLAGS/"

echo "OK: $(ls "$MACOS_FLAGS" | wc -l | tr -d ' ') флагов разложено в $MACOS_FLAGS"
