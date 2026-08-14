#!/bin/bash
# Приложение обязано подниматься без монитора, без трея и без единого
# критического сообщения GTK.
#
# Юнит-тесты этого не видят: они проверяют разбор CSS и сборку отдельных
# виджетов, но не живой цикл событий, где всплывают несовместимые свойства,
# отсутствующие иконки и обращения к виджетам не из главного потока.
#
# Критические сообщения GTK приложение не роняют — оно продолжает работать
# с недорисованным интерфейсом. Именно поэтому их надо ловить машинно.
set -euo pipefail
cd "$(dirname "$0")/../.."

FAKE_HOME="$(mktemp -d)"
LOG="$(mktemp)"
trap 'rm -rf "$FAKE_HOME" "$LOG"' EXIT

cargo build -q -p weto-app
BINARY="$PWD/target/debug/weto"

export HOME="$FAKE_HOME"
export XDG_CONFIG_HOME="$FAKE_HOME/.config"
export XDG_STATE_HOME="$FAKE_HOME/.local/state"
export XDG_CACHE_HOME="$FAKE_HOME/.cache"

# Шины доступности в контейнере нет, и GTK предупреждает об этом сам,
# сам же предлагая ответ. Это свойство окружения, а не приложения:
# на живом рабочем столе шина есть.
export GTK_A11Y=none

echo "=== версия отвечает без дисплея ==="
VERSION="$("$BINARY" --version)"
[ -n "$VERSION" ] || { echo "версия не напечаталась" >&2; exit 1; }
echo "версия: $VERSION"

echo "=== автозапуск — ровно один файл ==="
"$BINARY" --autostart on
COUNT="$(find "$FAKE_HOME/.config/autostart" -name '*.desktop' | wc -l | tr -d ' ')"
[ "$COUNT" -eq 1 ] || { echo "файлов автозапуска: $COUNT" >&2; exit 1; }
"$BINARY" --autostart off
[ ! -e "$FAKE_HOME/.config/autostart/weto.desktop" ] || {
    echo "файл автозапуска остался" >&2; exit 1
}

echo "=== окно поднимается под виртуальным дисплеем ==="
# dbus-run-session нужен трею: без сессионной шины он просто не зарегистрируется,
# и это как раз тот путь, по которому пойдёт ванильный GNOME.
xvfb-run -a dbus-run-session -- bash -c "
    '$BINARY' > '$LOG' 2>&1 &
    APP=\$!
    sleep 4
    if ! kill -0 \$APP 2>/dev/null; then
        echo 'приложение не дожило до четвёртой секунды' >&2
        exit 1
    fi
    kill \$APP
    wait \$APP 2>/dev/null || true
"

echo "=== вывод приложения ==="
cat "$LOG"

if grep -qE 'CRITICAL|WARNING \*\*|assertion .* failed|panicked' "$LOG"; then
    echo "НАРУШЕНИЕ: в выводе есть критические сообщения" >&2
    exit 1
fi

echo "OK: приложение поднимается и работает молча"
