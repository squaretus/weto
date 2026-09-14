#!/bin/bash
# Установщик и деинсталлятор обязаны сходиться.
#
# На macOS расхождение уже случалось: после удаления оставался живой демон.
# Здесь оно ловится машинно — контракт ставит артефакт во временный $HOME,
# проверяет раскладку и требует, чтобы после удаления не осталось ни одного
# файла weto.
#
# Проверяется и завершение работающей копии: она переживала удаление и тут же
# воссоздавала снесённые каталоги, потому что деинсталлятор искал её по пути
# через current, а запускают её через симлинк в ~/.local/bin. Запущенная копия
# здесь — подменённый sleep: честно ровно то, что и проверяется, — имя процесса
# weto, запуск через $BIN/weto и файл под $DATA/weto/.
set -euo pipefail
cd "$(dirname "$0")/../.."

ARCHIVE="${1:?использование: install-contract.sh <архив> <версия>}"
VERSION="${2:?использование: install-contract.sh <архив> <версия>}"

FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT

export HOME="$FAKE_HOME"
export XDG_DATA_HOME="$FAKE_HOME/.local/share"
export XDG_CONFIG_HOME="$FAKE_HOME/.config"
export XDG_STATE_HOME="$FAKE_HOME/.local/state"
export XDG_CACHE_HOME="$FAKE_HOME/.cache"
export PATH="$FAKE_HOME/.local/bin:$PATH"

UNPACKED="$FAKE_HOME/unpacked"
mkdir -p "$UNPACKED"
tar --zstd -xf "$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")" -C "$UNPACKED"

echo "=== установка ==="
bash "$UNPACKED/weto-$VERSION/install.sh"

for path in \
    ".local/share/weto/$VERSION/bin/weto" \
    ".local/share/weto/current" \
    ".local/bin/weto" \
    ".local/share/applications/weto.desktop"
do
    [ -e "$FAKE_HOME/$path" ] || { echo "НЕТ: $path" >&2; exit 1; }
done

echo "=== версия совпадает с тегом ==="
REPORTED="$("$FAKE_HOME/.local/bin/weto" --version)"
[ "$REPORTED" = "$VERSION" ] || {
    echo "бинарник сообщает «$REPORTED», ожидалось «$VERSION»" >&2
    exit 1
}

echo "=== current указывает на установленную версию ==="
RESOLVED="$(readlink -f "$FAKE_HOME/.local/share/weto/current")"
[ "$RESOLVED" = "$FAKE_HOME/.local/share/weto/$VERSION" ] || {
    echo "current ведёт в $RESOLVED" >&2
    exit 1
}

echo "=== автозапуск — ровно один файл ==="
"$FAKE_HOME/.local/bin/weto" --autostart on
COUNT="$(find "$FAKE_HOME/.config/autostart" -name '*.desktop' | wc -l | tr -d ' ')"
[ "$COUNT" -eq 1 ] || { echo "файлов автозапуска: $COUNT" >&2; exit 1; }
"$FAKE_HOME/.local/bin/weto" --autostart off
[ ! -e "$FAKE_HOME/.config/autostart/weto.desktop" ] || {
    echo "файл автозапуска остался" >&2; exit 1
}

# Подмена бинарника идёт последней: проверка версии и тумблер автозапуска
# к этому моменту уже отработали на настоящем weto.
echo "=== деинсталлятор находит работающую копию ==="
cp /bin/sleep "$FAKE_HOME/.local/share/weto/$VERSION/bin/weto"
"$FAKE_HOME/.local/bin/weto" 60 &
FAKE_PID=$!
sleep 0.3

echo "=== удаление ==="
bash "$UNPACKED/weto-$VERSION/uninstall.sh"

# Зомби живым не считается: фоновое задание ждёт жатвы у самого контракта,
# а вопрос здесь — работает ли копия.
STATE="$(awk '/^State:/ {print $2}' "/proc/$FAKE_PID/status" 2>/dev/null || true)"
if [ -n "$STATE" ] && [ "$STATE" != "Z" ]; then
    echo "работающая копия пережила удаление (pid $FAKE_PID, состояние $STATE)" >&2
    kill -9 "$FAKE_PID" 2>/dev/null || true
    exit 1
fi

LEFT="$(find "$FAKE_HOME" -name '*weto*' -not -path "$UNPACKED/*" | wc -l | tr -d ' ')"
if [ "$LEFT" -ne 0 ]; then
    echo "НАРУШЕНИЕ: после удаления осталось файлов: $LEFT" >&2
    find "$FAKE_HOME" -name '*weto*' -not -path "$UNPACKED/*" >&2
    exit 1
fi

echo "OK: установщик и деинсталлятор сходятся"
