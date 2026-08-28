#!/bin/bash
# Кнопка «удалить приложение» и uninstall-weto.sh обязаны снимать одно и то же.
#
# Путей удаления на macOS два: кнопка в настройках идёт через `Maintenance`,
# терминальный путь — через скрипт в бандле. Разойтись молча им проще всего:
# ровно так после «удалить полностью» на диске оставались и само приложение,
# и журналы. Контракт держит списки рядом.
#
# Запуск: bash scripts/tests/uninstall-parity-contract.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

SCRIPT="Resources/uninstall-weto.sh"
MAINTENANCE="Sources/WetoShared/Maintenance.swift"
CONFIGURATION="Sources/WetoCore/WetoUpdate.swift"
HELPER="Packages/UpdateKit/Sources/UpdateKitHelper/UpdaterHelperService.swift"

fail() {
    echo "✗ $1" >&2
    exit 1
}

# Каждый ресурс проверяется дважды: что его снимает скрипт и что его снимает
# кнопка. Для кнопки ищется не упоминание имени, а заданное значение — иначе
# проверка проходит на объявлении поля, которому ничего не присвоено.
check() {
    local human="$1" in_script="$2" file="$3" in_button="$4"
    grep -q "$in_script" "$SCRIPT" || fail "скрипт удаления перестал снимать $human"
    grep -qE "$in_button" "$file" || fail "кнопка удаления не снимает $human"
}

check "агент автозапуска" 'LaunchAgents/\$LABEL.plist' \
    "$MAINTENANCE" 'agent\.disable\(\)'
check "журналы" 'Application Support/weto' \
    "$MAINTENANCE" 'journalsDirectory, as: \.removeJournals'
check "кэш флагов" 'Caches/com.weto.app' \
    "$MAINTENANCE" 'cachesDirectory, as: \.removeCaches'
check "настройки" 'Preferences/com.weto.shared.plist' \
    "$MAINTENANCE" 'removePersistentDomain'
check "токен ipinfo" 'delete-generic-password' \
    "$MAINTENANCE" 'secrets\.write\(nil'
check "LaunchDaemon демона" 'LaunchDaemons/com.weto.helper.plist' \
    "$CONFIGURATION" 'daemonPlistPath: "/Library/LaunchDaemons/'
check "бинарник демона" 'PrivilegedHelperTools/com.weto.helper' \
    "$CONFIGURATION" 'daemonBinaryPath: "/Library/PrivilegedHelperTools/'
check "рабочий каталог демона" '/var/db/weto' \
    "$CONFIGURATION" 'additionalUninstallPaths: \["/var/db/weto"\]'
check "само приложение" '/Applications/Weto.app' \
    "$CONFIGURATION" 'installedAppPath: "/Applications/Weto.app"'
check "чек установки пакета" 'pkgutil --forget' \
    "$CONFIGURATION" 'packageIdentifier: "com.weto.pkg"'

# Мало объявить пути в конфигурации — демон обязан их снимать.
for field in installedAppPath daemonPlistPath daemonBinaryPath \
             workingDirectory additionalUninstallPaths; do
    grep -q "configuration.$field" "$HELPER" \
        || fail "демон не снимает configuration.$field"
done
grep -q 'configuration.packageIdentifier' "$HELPER" \
    || fail "демон не забывает чек установки пакета"

# Бандл принадлежит root: приложение, пытавшееся снести его само, упиралось
# в права и молчало об отказе. Результат обязан проверяться, а не предполагаться.
grep -q 'fileManager.fileExists(atPath: bundlePath)' "$MAINTENANCE" \
    || fail "удаление не проверяет, что бандл действительно исчез"
grep -qE 'rm -rf.*Applications' "$MAINTENANCE" \
    && fail "приложение снова пытается удалить свой бандл само — прав на это нет"

echo "✓ оба пути удаления снимают одно и то же"
