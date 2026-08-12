#!/bin/bash
# Локальный сервер релизов: позволяет пройти весь путь обновления руками —
# баннер, окно, загрузка, подмена каталога, перезапуск — не публикуя релиз.
#
#   linux/scripts/fake-release.sh 9.9.9
#
# Дальше приложение запускается так (только отладочная сборка):
#   WETO_TEST_RELEASE_API=http://127.0.0.1:8765/release.json \
#   WETO_TEST_RELEASE_ORIGIN=http://127.0.0.1:8765/ \
#   ./target/debug/weto
#
# В релизной сборке обе переменные не читаются вовсе: ветку вырезает `cfg`,
# и заставить приложение скачать обновление мимо GitHub нечем.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-9.9.9}"
PORT="${2:-8765}"
ARCH="$(uname -m)"
SERVE="target/fake-release"
ARCHIVE="weto-$VERSION-$ARCH-linux.tar.zst"

echo "=== собираю «релиз» $VERSION ($ARCH) ==="
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-target}" cargo build --release -p weto-app

rm -rf "$SERVE"
STAGE="$SERVE/weto-$VERSION"
mkdir -p "$STAGE/bin" "$STAGE/share"

cp "${CARGO_TARGET_DIR:-target}/release/weto" "$STAGE/bin/weto"
cp scripts/install.sh scripts/uninstall.sh "$STAGE/"
cp ../shared/icon/dark.icon/Assets/grid.svg "$STAGE/share/weto.svg"
printf '%s' "$VERSION" > "$STAGE/VERSION"

tar --zstd -cf "$SERVE/$ARCHIVE" -C "$SERVE" "weto-$VERSION"
rm -rf "$STAGE"

# Ответ в форме, которую отдаёт GitHub: приложение разбирает именно её,
# поэтому подделывать надо её, а не что-то своё.
cat > "$SERVE/release.json" <<EOF
{
  "tag_name": "v$VERSION",
  "draft": false,
  "prerelease": false,
  "body": "Проверочный релиз $VERSION.\\n\\nСобран из рабочего дерева скриптом fake-release.sh.",
  "assets": [
    {
      "name": "$ARCHIVE",
      "browser_download_url": "http://127.0.0.1:$PORT/$ARCHIVE"
    }
  ]
}
EOF

echo "=== сервер на порту $PORT ==="
echo "запускать приложение так:"
echo
echo "  WETO_TEST_RELEASE_API=http://127.0.0.1:$PORT/release.json \\"
echo "  WETO_TEST_RELEASE_ORIGIN=http://127.0.0.1:$PORT/ \\"
echo "  ${CARGO_TARGET_DIR:-target}/debug/weto"
echo
echo "Ctrl-C — остановить сервер"
cd "$SERVE" && exec python3 -m http.server "$PORT" --bind 127.0.0.1
