#!/bin/bash
# weto-core обязан оставаться свободным от I/O.
#
# Список запрещённых крейтов — не вкусовщина: каждый тянет за собой async-рантайм
# или системный API, после чего основная масса тестов перестаёт быть синхронной
# и свободной от моков. На macOS тот же инвариант держит WetoCore, и там он уже
# доказал свою пользу: 277 тестов ядра не знают ни про сеть, ни про процессы.
set -euo pipefail
cd "$(dirname "$0")/../.."

FORBIDDEN="tokio zbus reqwest rtnetlink netlink-packet-route netlink-sys procfs gtk4 rustix nix secret-service"

DEPS="$(cargo tree --package weto-core --edges normal --prefix none --no-dedupe \
        | awk 'NF {print $1}' | sort -u)"

violations=0
for crate in $FORBIDDEN; do
    if printf '%s\n' "$DEPS" | grep -qx "$crate"; then
        echo "НАРУШЕНИЕ: weto-core зависит от $crate" >&2
        violations=1
    fi
done

[ "$violations" -eq 0 ] || exit 1
echo "OK: границы weto-core чисты ($(printf '%s\n' "$DEPS" | wc -l | tr -d ' ') крейтов в графе)"
