#!/bin/bash
# Проба маршрута обязана переживать policy routing.
#
# wg-quick не кладёт маршрут по умолчанию в главную таблицу: он заводит свою
# (51820) и правило `ip rule`. Дамп `/proc/net/route` в такой раскладке покажет
# старый маршрут через Ethernet, и охрана решит, что «VPN не держит маршрут
# по умолчанию», — то есть завершит цели при полностью исправном VPN.
#
# Контракт воспроизводит раскладку и требует, чтобы проба назвала туннель.
# Нужны права root и iproute2; запускать в контейнере с --cap-add=NET_ADMIN
# или на CI-раннере под sudo.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ "$(id -u)" -ne 0 ]; then
    echo "нужны права root: контракт создаёт интерфейс и правила маршрутизации" >&2
    exit 2
fi

IFACE="wetotest0"
TABLE=51820

cleanup() {
    ip rule del not fwmark "$TABLE" table "$TABLE" priority 32764 2>/dev/null || true
    ip link del "$IFACE" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

ip link add dev "$IFACE" type dummy
ip addr add 10.99.0.2/24 dev "$IFACE"
ip link set "$IFACE" up
ip route add default dev "$IFACE" table "$TABLE"
ip rule add not fwmark "$TABLE" table "$TABLE" priority 32764

MAIN="$(ip route show table main | awk '/^default/ {print $NF; exit}')"
KERNEL="$(ip route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1); exit}')"
# Адрес передаём явно: у пробы по умолчанию адрес гео-сервиса, а в контейнере
# DNS может не быть — сверять надо один и тот же адрес, а не два разных.
PROBED="$(cargo run -q --example route_owner -p weto-sys -- 1.1.1.1)"

echo "главная таблица: ${MAIN:-нет}"
echo "выбор ядра:      $KERNEL"
echo "ответ пробы:     $PROBED"

if [ "$KERNEL" != "$IFACE" ]; then
    echo "ОШИБКА: ядро не выбрало $IFACE — раскладка теста не воспроизвелась" >&2
    exit 1
fi

if [ "$PROBED" != "$KERNEL" ]; then
    echo "НАРУШЕНИЕ: проба назвала «$PROBED», ядро выпускает трафик через «$KERNEL»" >&2
    exit 1
fi

if [ "$MAIN" = "$IFACE" ]; then
    echo "ВНИМАНИЕ: главная таблица тоже указывает на туннель — контракт ничего не проверил" >&2
    exit 1
fi

echo "OK: проба следует за ядром, а не за главной таблицей"
