#!/bin/bash
# Rust-часть собирается и тестируется в Linux-контейнере, а не на хосте: она
# опирается на netlink, /proc и GTK4, которых на macOS нет вовсе. Кросс-компиляции
# тут недостаточно — тесты обязаны выполняться на настоящем ядре Linux.
#
#   linux/scripts/dev.sh cargo test --workspace
#   linux/scripts/dev.sh bash scripts/tests/core-boundary-contract.sh
#
# Тестам дизайн-системы нужен дисплей. X-сервер поднимаем сами, а не через
# xvfb-run: тот в контейнере повисает — стартует Xvfb и не запускает команду вовсе.
#
#   linux/scripts/dev.sh bash -c 'Xvfb :99 -screen 0 1280x1024x24 & sleep 2
#                                 DISPLAY=:99 cargo test --workspace'
#
# Образ собирается из linux/scripts/Dockerfile.dev при первом запуске.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${WETO_RUST_IMAGE:-weto-rust-dev}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "=== собираю образ $IMAGE (только в первый раз) ==="
    docker build -q -t "$IMAGE" -f "$REPO/linux/scripts/Dockerfile.dev" "$REPO/linux/scripts"
fi

# Реестр крейтов лежит в именованном томе: пересборки не качают зависимости заново,
# а рабочее дерево остаётся без чужих файлов.
exec docker run --rm -t \
    -v "$REPO":/repo \
    -v weto-cargo-registry:/usr/local/cargo/registry \
    -w /repo/linux \
    "$IMAGE" "$@"
