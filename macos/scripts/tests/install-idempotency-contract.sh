#!/bin/bash
# Повторная установка не пересоздаёт файлы фоновых элементов.
#
# Background Task Management держит выданное разрешение за конкретной записью,
# а запись — за файлом в LaunchAgents/LaunchDaemons. Удалили файл и написали
# заново — разрешение относилось к записи, которой больше нет, и macOS показывает
# «Weto добавила элементы, которые могут работать в фоне» после каждого обновления.
#
# Выгрузка задания (`bootout`) при этом остаётся: без неё launchd с `KeepAlive`
# поднимет копию приложения прямо посреди подмены бандла. Выгружать задание
# и удалять его файл — разные вещи, и BTM держится за файл.
#
# Запуск: bash scripts/tests/install-idempotency-contract.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

fail() {
    echo "✗ $1" >&2
    exit 1
}

# Песочница повторяет раскладку установленной системы: и payload, и домашний
# каталог пользователя графического сеанса.
mkdir -p "$SANDBOX/Applications/Weto.app/Contents/MacOS" \
         "$SANDBOX/Library/PrivilegedHelperTools" \
         "$SANDBOX/Library/LaunchDaemons" \
         "$SANDBOX/home/Library/LaunchAgents" \
         "$SANDBOX/bin"

printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/Applications/Weto.app/Contents/MacOS/WetoMenuBar"
printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/Library/PrivilegedHelperTools/com.weto.helper"
chmod +x "$SANDBOX/Applications/Weto.app/Contents/MacOS/WetoMenuBar" \
         "$SANDBOX/Library/PrivilegedHelperTools/com.weto.helper"

# launchctl подменяется журналирующей заглушкой: контракт проверяет файлы,
# а не поведение launchd.
cat > "$SANDBOX/bin/launchctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$WETO_LAUNCHCTL_LOG"
exit 0
STUB
chmod +x "$SANDBOX/bin/launchctl"

AGENT_PLIST="$SANDBOX/home/Library/LaunchAgents/com.weto.app.plist"
DAEMON_PLIST="$SANDBOX/Library/LaunchDaemons/com.weto.helper.plist"

export WETO_INSTALL_ROOT="$SANDBOX"
export WETO_INSTALL_HOME="$SANDBOX/home"
export WETO_CONSOLE_USER="$(id -un)"
export WETO_LAUNCHCTL="$SANDBOX/bin/launchctl"
export WETO_CHOWN="/usr/bin/true"
export WETO_KILLALL="/usr/bin/true"
export WETO_LAUNCHCTL_LOG="$SANDBOX/launchctl.log"
: > "$WETO_LAUNCHCTL_LOG"

identity() {
    # Инода, время правки и размер: пересозданный файл меняет иноду, даже если
    # содержимое совпало байт в байт.
    /usr/bin/stat -f '%i %m %z' "$1"
}

echo "=== первая установка ==="
bash scripts/preinstall >/dev/null || fail "preinstall упал на первой установке"
bash scripts/postinstall >/dev/null || fail "postinstall упал на первой установке"

[ -f "$AGENT_PLIST" ] || fail "postinstall не создал агент автозапуска"
[ -f "$DAEMON_PLIST" ] || fail "postinstall не создал LaunchDaemon демона обновления"

AGENT_BEFORE="$(identity "$AGENT_PLIST")"
DAEMON_BEFORE="$(identity "$DAEMON_PLIST")"

# Секунда паузы: `stat -f %m` отдаёт целые секунды, и правка внутри той же
# секунды прошла бы незамеченной.
sleep 1

echo "=== обновление: preinstall ==="
bash scripts/preinstall >/dev/null || fail "preinstall упал на обновлении"

[ -f "$AGENT_PLIST" ] \
    || fail "preinstall удалил агент автозапуска — BTM заведёт новую запись и спросит разрешение заново"
[ "$AGENT_BEFORE" = "$(identity "$AGENT_PLIST")" ] \
    || fail "preinstall тронул файл агента: было «$AGENT_BEFORE», стало «$(identity "$AGENT_PLIST")»"

echo "=== обновление: postinstall ==="
bash scripts/postinstall >/dev/null || fail "postinstall упал на обновлении"

AGENT_AFTER="$(identity "$AGENT_PLIST")"
DAEMON_AFTER="$(identity "$DAEMON_PLIST")"

[ "$AGENT_BEFORE" = "$AGENT_AFTER" ] \
    || fail "агент пересоздан при обновлении: было «$AGENT_BEFORE», стало «$AGENT_AFTER»"
[ "$DAEMON_BEFORE" = "$DAEMON_AFTER" ] \
    || fail "LaunchDaemon пересоздан при обновлении: было «$DAEMON_BEFORE», стало «$DAEMON_AFTER»"

# Идемпотентности нельзя добиться, не написав ничего вовсе: содержимое обязано
# указывать на установленное.
grep -q "$SANDBOX/Applications/Weto.app/Contents/MacOS/WetoMenuBar" "$AGENT_PLIST" \
    || fail "агент не указывает на установленный бинарник"
grep -q "com.weto.helper" "$DAEMON_PLIST" \
    || fail "в plist демона нет его MachService"

# Сменился путь к бинарнику — файл обязан обновиться, иначе автозапуск указывает
# в пустоту. Проверка ровно противоположная предыдущим: «не трогать» относится
# только к совпадающему содержимому.
mkdir -p "$SANDBOX/moved/Applications/Weto.app/Contents/MacOS" \
         "$SANDBOX/moved/Library/PrivilegedHelperTools" \
         "$SANDBOX/moved/Library/LaunchDaemons"
cp "$SANDBOX/Applications/Weto.app/Contents/MacOS/WetoMenuBar" \
   "$SANDBOX/moved/Applications/Weto.app/Contents/MacOS/WetoMenuBar"
cp "$SANDBOX/Library/PrivilegedHelperTools/com.weto.helper" \
   "$SANDBOX/moved/Library/PrivilegedHelperTools/com.weto.helper"
sleep 1
WETO_INSTALL_ROOT="$SANDBOX/moved" WETO_INSTALL_HOME="$SANDBOX/home" \
    bash scripts/postinstall >/dev/null || fail "postinstall упал при смене пути бандла"
grep -q "$SANDBOX/moved/Applications/Weto.app/Contents/MacOS/WetoMenuBar" "$AGENT_PLIST" \
    || fail "postinstall не переписал агент при смене пути к бинарнику"

echo "✓ повторная установка не пересоздаёт фоновые элементы"
