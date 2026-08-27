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

# Его LaunchDaemon в payload не входит — ровно как агент автозапуска. installer
# перезаписывает файлы payload на каждой установке, а Background Task Management
# держит выданное разрешение за записью, привязанной к файлу: пересозданный файл
# означает новую запись и вопрос про фоновую работу после каждого обновления.
# Пишет его postinstall, и только когда содержимое действительно изменилось.
if [ -e "$STAGE/Library/LaunchDaemons/com.weto.helper.plist" ]; then
    fail "payload содержит LaunchDaemon демона — его должен писать postinstall"
fi
if [ -d "$STAGE/Library/LaunchDaemons" ] && [ -n "$(ls -A "$STAGE/Library/LaunchDaemons")" ]; then
    fail "payload содержит непустой /Library/LaunchDaemons"
fi
grep -q 'MachServices' scripts/postinstall \
    || fail "postinstall не пишет MachService демона обновления"

grep -q 'bootstrap system' scripts/postinstall \
    || fail "postinstall не загружает демон в системный домен"
grep -q 'bootout system/com.weto.helper' scripts/preinstall \
    || fail "preinstall не выгружает демон перед подменой файлов"
grep -q 'bootout system/com.weto.helper' Resources/uninstall-weto.sh \
    || fail "деинсталлятор не выгружает демон"

# 2в. Резидентность: копию, поднятую launchd, система усыпляет автозавершением,
#     как только у приложения не остаётся окон. Отказ обязан быть и в бандле,
#     и в коде — иначе охрана исчезает после установки и после каждого входа.
APP_PLIST="$STAGE/Applications/Weto.app/Contents/Info.plist"
for key in NSSupportsAutomaticTermination NSSupportsSuddenTermination; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP_PLIST" 2>/dev/null || echo "нет ключа")"
    [ "$value" = "false" ] \
        || fail "в Info.plist бандла $key = $value, ожидалось false"
done

grep -q 'disableAutomaticTermination' Sources/WetoMenuBar/WetoMenuBarApp.swift \
    || fail "приложение не отказывается от автозавершения при старте"
grep -q 'disableSuddenTermination' Sources/WetoMenuBar/WetoMenuBarApp.swift \
    || fail "приложение не отказывается от внезапного завершения при старте"

# 3. postinstall пишет агент в домашний каталог консольного пользователя
#    и грузит его в его же графическом сеансе.
grep -q 'NFSHomeDirectory' scripts/postinstall \
    || fail "postinstall не спрашивает домашний каталог у системы"
grep -q 'Library/LaunchAgents' scripts/postinstall \
    || fail "postinstall не пишет агент в Library/LaunchAgents пользователя"
grep -q 'asuser' scripts/postinstall \
    || fail "postinstall не использует launchctl asuser для сеанса пользователя"
grep -q 'bootstrap' scripts/postinstall \
    || fail "postinstall не загружает агент через bootstrap"
grep -q 'pgrep' scripts/postinstall \
    && fail "postinstall не должен проверять запуск через pgrep"

# 4. Нет активного графического сеанса — установка обязана упасть, а не молчать.
grep -q 'Не найден пользователь графического сеанса' scripts/postinstall \
    || fail "postinstall не сообщает об отсутствии графического сеанса"

# 5. Удаляет агент пользователя только деинсталлятор.
#
#    preinstall задание выгружает — иначе launchd с `KeepAlive` поднимет копию
#    посреди подмены бандла, — но файл оставляет на месте: за файлом держится
#    запись Background Task Management с выданным разрешением на фоновую работу.
#    Идемпотентность установки проверяет отдельный контракт,
#    scripts/tests/install-idempotency-contract.sh.
grep -q 'bootout' scripts/preinstall \
    || fail "preinstall не выгружает задание перед подменой бандла"
grep -qE '(rm|unlink).*LaunchAgents/\$LABEL\.plist' scripts/preinstall \
    && fail "preinstall удаляет агент пользователя — macOS спросит разрешение на фоновую работу заново"

grep -q 'Library/LaunchAgents/\$LABEL.plist' Resources/uninstall-weto.sh \
    || fail "деинсталлятор не удаляет агент пользователя"
grep -q '/Library/LaunchAgents/\$LABEL.plist' Resources/uninstall-weto.sh \
    || fail "деинсталлятор не удаляет системный агент прежних версий"
grep -q 'bootout' Resources/uninstall-weto.sh \
    || fail "деинсталлятор не выгружает задание перед удалением файла"

# Файлы, которые больше не приходят из payload, обязан убирать деинсталлятор сам:
# в receipt пакета их нет, и pkgutil --forget о них ничего не знает.
grep -q 'rm -f /Library/LaunchDaemons/com.weto.helper.plist' Resources/uninstall-weto.sh \
    || fail "деинсталлятор не удаляет LaunchDaemon демона обновления"

echo "✓ контракт автозапуска соблюдён"
