#!/bin/bash
set -u
echo "Удаление weto..."

LABEL="com.weto.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Порядок: сначала выгрузка задания, потом удаление его файла и бандла.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
killall WetoMenuBar 2>/dev/null || true
sleep 1

rm -f "$PLIST"

# Агент прежних версий жил в системном каталоге — без sudo его не убрать.
if [ -f "/Library/LaunchAgents/$LABEL.plist" ]; then
    sudo rm -f "/Library/LaunchAgents/$LABEL.plist"
fi

# Демон обновления и его рабочий каталог.
sudo launchctl bootout system/com.weto.helper 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.weto.helper.plist
sudo rm -f /Library/PrivilegedHelperTools/com.weto.helper
sudo rm -rf /var/db/weto

sudo rm -rf /Applications/Weto.app

rm -f "$HOME/Library/Preferences/com.weto.shared.plist"
rm -rf "$HOME/Library/Caches/com.weto.app"
# Журнал завершений: с переездом из plist настроек он живёт отдельным файлом.
rm -rf "$HOME/Library/Application Support/weto"
security delete-generic-password -s com.weto.ipinfo -a token 2>/dev/null || true

tccutil reset All "$LABEL" 2>/dev/null || true
sudo pkgutil --forget com.weto.pkg 2>/dev/null || true

echo "weto удалён."
