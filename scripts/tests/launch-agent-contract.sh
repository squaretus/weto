#!/bin/bash
# Контракт автозапуска: установщик, приложение и удаление обязаны работать
# с одним и тем же файлом агента в домашнем каталоге пользователя.
#
# Запуск: bash scripts/tests/launch-agent-contract.sh <путь к payload-root>
set -euo pipefail

STAGE="${1:?укажите каталог payload (например .build/release_build/_pkg-root)}"
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

fail() {
    echo "✗ $1" >&2
    exit 1
}

# 1. Системный агент не пакуется вовсе.
if [ -e "$STAGE/Library/LaunchAgents/com.weto.app.plist" ]; then
    fail "payload содержит системный агент /Library/LaunchAgents/com.weto.app.plist"
fi
if [ -d "$STAGE/Library/LaunchAgents" ] && [ -n "$(ls -A "$STAGE/Library/LaunchAgents")" ]; then
    fail "payload содержит непустой /Library/LaunchAgents"
fi

# 2. Само приложение на месте и исполняемо.
[ -x "$STAGE/Applications/Weto.app/Contents/MacOS/WetoMenuBar" ] \
    || fail "в payload нет исполняемого $STAGE/Applications/Weto.app/Contents/MacOS/WetoMenuBar"

# 2б. Демон обновления, наоборот, системный: без него автообновление невозможно.
[ -x "$STAGE/Library/PrivilegedHelperTools/com.weto.helper" ] \
    || fail "в payload нет демона обновления"
[ -f "$STAGE/Library/LaunchDaemons/com.weto.helper.plist" ] \
    || fail "в payload нет LaunchDaemon демона обновления"
grep -q 'com.weto.helper' "$STAGE/Library/LaunchDaemons/com.weto.helper.plist" \
    || fail "в plist демона нет его MachService"

grep -q 'launchctl bootstrap system' scripts/postinstall \
    || fail "postinstall не загружает демон в системный домен"
grep -q 'bootout system/com.weto.helper' scripts/preinstall \
    || fail "preinstall не выгружает демон перед подменой файлов"
grep -q 'bootout system/com.weto.helper' Resources/uninstall-weto.sh \
    || fail "деинсталлятор не выгружает демон"

# 3. postinstall пишет агент в домашний каталог консольного пользователя
#    и грузит его в его же графическом сеансе.
grep -q 'NFSHomeDirectory' scripts/postinstall \
    || fail "postinstall не спрашивает домашний каталог у системы"
grep -q 'Library/LaunchAgents' scripts/postinstall \
    || fail "postinstall не пишет агент в Library/LaunchAgents пользователя"
grep -q 'launchctl asuser' scripts/postinstall \
    || fail "postinstall не использует launchctl asuser для сеанса пользователя"
grep -q 'bootstrap' scripts/postinstall \
    || fail "postinstall не загружает агент через bootstrap"
grep -q 'pgrep' scripts/postinstall \
    && fail "postinstall не должен проверять запуск через pgrep"

# 4. Нет активного графического сеанса — установка обязана упасть, а не молчать.
grep -q 'Не найден пользователь графического сеанса' scripts/postinstall \
    || fail "postinstall не сообщает об отсутствии графического сеанса"

# 5. preinstall и деинсталлятор снимают тот же самый агент, включая наследие
#    прежних версий в /Library/LaunchAgents.
for script in scripts/preinstall Resources/uninstall-weto.sh; do
    grep -q 'Library/LaunchAgents/\$LABEL.plist' "$script" \
        || fail "$script не удаляет агент пользователя"
    grep -q '/Library/LaunchAgents/\$LABEL.plist' "$script" \
        || fail "$script не удаляет системный агент прежних версий"
    grep -q 'bootout' "$script" \
        || fail "$script не выгружает задание перед удалением файла"
done

echo "✓ контракт автозапуска соблюдён"
