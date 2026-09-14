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
#
# Копий проверяется три, и каждая держит свою беду:
#   * под которой снесли каталог версии — `readlink -f` отвечает на такой
#     /proc/<pid>/exe пустой строкой, и копия не совпадала ни с чем;
#   * обычная — обязана быть завершена;
#   * названная в WETO_UNINSTALL_SKIP_PID — обязана выжить: это вызывающий GUI,
#     и убить его значит унести с собой сообщение о неудачном удалении.
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

# Зомби живым не считается: фоновое задание ждёт жатвы у самого контракта,
# а вопрос здесь — работает ли копия.
alive() {
    local state
    state="$(awk '/^State:/ {print $2}' "/proc/$1/status" 2>/dev/null || true)"
    [ -n "$state" ] && [ "$state" != "Z" ]
}

# Подмена бинарника идёт последней: проверка версии и тумблер автозапуска
# к этому моменту уже отработали на настоящем weto.
echo "=== деинсталлятор находит копию, под которой снесли каталог версии ==="
cp /bin/sleep "$FAKE_HOME/.local/share/weto/$VERSION/bin/weto"
"$FAKE_HOME/.local/bin/weto" 60 &
DELETED_PID=$!
sleep 0.3
# Так выглядит повторный прогон удаления и прогон после вычистки старой версии
# обновлением: процесс живёт, а каталога под ним уже нет. Сносится именно
# каталог целиком, а не один файл: с уцелевшими родителями `readlink -f`
# отвечает «… (deleted)» и совпадение находит, и проверка ничего не стоила бы.
# Без них он отвечает пустой строкой — и копия переживала удаление,
# воссоздавая снесённые каталоги.
rm -rf "$FAKE_HOME/.local/share/weto/$VERSION"
bash "$UNPACKED/weto-$VERSION/uninstall.sh"
if alive "$DELETED_PID"; then
    echo "копия без каталога версии пережила удаление (pid $DELETED_PID)" >&2
    kill -9 "$DELETED_PID" 2>/dev/null || true
    exit 1
fi

echo "=== переустановка: дальше проверяется удаление при живых копиях ==="
bash "$UNPACKED/weto-$VERSION/install.sh"

echo "=== деинсталлятор находит работающую копию и щадит названную в WETO_UNINSTALL_SKIP_PID ==="
cp /bin/sleep "$FAKE_HOME/.local/share/weto/$VERSION/bin/weto"
"$FAKE_HOME/.local/bin/weto" 60 &
FAKE_PID=$!
# Вторая копия — за вызывающий GUI: кнопка «Удалить приложение…» зовёт скрипт
# синхронно из самого приложения, и без пропуска деинсталлятор убивал бы того,
# кто его позвал, — вместе с сообщением о неудачном удалении.
"$FAKE_HOME/.local/bin/weto" 60 &
SKIP_PID=$!
sleep 0.3

echo "=== удаление ==="
WETO_UNINSTALL_SKIP_PID="$SKIP_PID" bash "$UNPACKED/weto-$VERSION/uninstall.sh"

if alive "$FAKE_PID"; then
    echo "работающая копия пережила удаление (pid $FAKE_PID)" >&2
    kill -9 "$FAKE_PID" 2>/dev/null || true
    kill -9 "$SKIP_PID" 2>/dev/null || true
    exit 1
fi

if ! alive "$SKIP_PID"; then
    echo "названный в WETO_UNINSTALL_SKIP_PID процесс не пережил удаление (pid $SKIP_PID)" >&2
    exit 1
fi
kill -9 "$SKIP_PID" 2>/dev/null || true

LEFT="$(find "$FAKE_HOME" -name '*weto*' -not -path "$UNPACKED/*" | wc -l | tr -d ' ')"
if [ "$LEFT" -ne 0 ]; then
    echo "НАРУШЕНИЕ: после удаления осталось файлов: $LEFT" >&2
    find "$FAKE_HOME" -name '*weto*' -not -path "$UNPACKED/*" >&2
    exit 1
fi

echo "OK: установщик и деинсталлятор сходятся"
