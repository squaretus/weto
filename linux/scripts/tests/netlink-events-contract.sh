#!/bin/bash
# Падение туннеля обязано замечаться мгновенно, а не очередным тиком охраны.
#
# На macOS это делает NWPathMonitor. Здесь — подписка на netlink. Контракт
# поднимает интерфейс и требует, чтобы событие пришло меньше чем за 200 мс:
# штатный тик идёт раз в пять секунд, и всё это время трафик шёл бы мимо VPN.
#
# Время считается от момента, когда сеть дёрнули, а не от старта слушателя:
# иначе в «реакцию» попадёт запуск процесса и открытие сокета.
#
# Нужны права root и iproute2.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ "$(id -u)" -ne 0 ]; then
    echo "нужны права root: контракт поднимает и удаляет интерфейс" >&2
    exit 2
fi

IFACE="wetoevt0"
BUDGET_MS=200
PIPE="$(mktemp -u)"

cleanup() {
    ip link del "$IFACE" 2>/dev/null || true
    rm -f "$PIPE"
}
trap cleanup EXIT
cleanup

# Сборка до запуска слушателя: иначе в бюджет попадёт компиляция.
cargo build -q --example watch_network -p weto-sys

mkfifo "$PIPE"
cargo run -q --example watch_network -p weto-sys -- 3000 > "$PIPE" &
WATCHER=$!

exec 3< "$PIPE"
read -r LINE <&3
[ "$LINE" = "ready" ] || { echo "слушатель не сообщил о готовности" >&2; exit 1; }

STARTED="$(date +%s%N)"
ip link add dev "$IFACE" type dummy
ip link set "$IFACE" up

if ! read -r -t 3 LINE <&3 || [ "$LINE" != "event" ]; then
    echo "НАРУШЕНИЕ: событие о поднятии интерфейса не пришло" >&2
    exit 1
fi
ELAPSED_MS=$(( ($(date +%s%N) - STARTED) / 1000000 ))
wait "$WATCHER"

echo "реакция: ${ELAPSED_MS} мс"

if [ "$ELAPSED_MS" -gt "$BUDGET_MS" ]; then
    echo "НАРУШЕНИЕ: ${ELAPSED_MS} мс дольше бюджета ${BUDGET_MS} мс" >&2
    exit 1
fi

echo "OK: сеть уведомляет охрану мгновенно"
