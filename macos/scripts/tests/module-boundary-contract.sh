#!/bin/bash
# Границы модулей: что кому разрешено импортировать.
#
# Аналог `linux/scripts/tests/core-boundary-contract.sh`, только там граф
# зависимостей отдаёт cargo, а здесь единственный источник правды — сами
# импорты. Проверка нужна потому, что тёплый кэш модулей SwiftPM прячет
# незаявленную зависимость: `swift build` в рабочем дереве проходит, а чистая
# сборка падает с «no such module». Именно так и уехало чтение флагов
# из `WetoDesign` в `WetoSystem`.
#
# Запуск: bash scripts/tests/module-boundary-contract.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

status=0

# Разрешённые импорты по модулю. Всё остальное — нарушение слоя, даже если
# компилятор согласен: направление зависимостей здесь важнее удобства.
check() {
    local module="$1" allowed="$2"
    local actual
    actual="$(grep -rh '^import ' "Sources/$module" | awk '{print $2}' | sort -u)"

    while read -r name; do
        [ -n "$name" ] || continue
        if ! grep -qx -- "$name" <<< "$allowed"; then
            echo "✗ $module импортирует $name — этого слою не разрешено" >&2
            status=1
        fi
    done <<< "$actual"
}

# Ядро не знает о системе вовсе: ни сети, ни файлов, ни UI. Самая дорогая
# ошибка проекта — нарушить это, потому что вместе с импортом в ядро приезжают
# моки и асинхронность.
check WetoCore "$(printf '%s\n' Darwin Foundation UpdateKitCore)"

# Дизайн-система не знает о состоянии приложения: она рисует и отдаёт ресурсы.
check WetoDesign "$(printf '%s\n' AppKit Foundation SwiftUI)"

# Граница системы: адаптеры к macOS. UI-модули ей не нужны — и от `WetoShared`
# направление зависимости строго одностороннее.
check WetoSystem "$(printf '%s\n' AppKit Darwin Foundation Network Security SystemConfiguration WetoCore)"

# Состояние и фасады для UI. Единственное, чего здесь быть не должно, —
# знание о точке входа.
check WetoShared "$(printf '%s\n' AppKit Darwin Foundation Observation SwiftUI UpdateKit UpdateKitCore UpdateKitUI UserNotifications WetoCore WetoDesign WetoSystem)"

# `URLSession` в ядре — тот же запрет, но по имени типа: импорт `Foundation`
# законен, а сетевой запрос из ядра — нет.
if grep -rn 'URLSession' Sources/WetoCore >/dev/null 2>&1; then
    echo "✗ WetoCore обращается к URLSession — сеть живёт только в WetoSystem" >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "OK: границы модулей соблюдены"
fi
exit "$status"
