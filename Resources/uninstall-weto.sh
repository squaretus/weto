#!/bin/bash
# Полное удаление weto. Дублирует кнопку «Удалить приложение…» в настройках —
# нужен на случай, когда приложение не запускается.
echo "Удаление weto..."

CURRENT_UID=$(id -u "$USER")
launchctl bootout gui/"$CURRENT_UID"/com.weto.app 2>/dev/null || true
killall WetoMenuBar 2>/dev/null || true
sleep 1

sudo rm -f /Library/LaunchAgents/com.weto.app.plist
rm -f "$HOME/Library/LaunchAgents/com.weto.app.plist"
sudo rm -rf /Applications/Weto.app

rm -f "$HOME/Library/Preferences/com.weto.shared.plist"
rm -rf "$HOME/Library/Caches/com.weto.app"
security delete-generic-password -s com.weto.ipinfo -a token 2>/dev/null || true

tccutil reset All com.weto.app 2>/dev/null || true
sudo pkgutil --forget com.weto.pkg 2>/dev/null || true

echo "weto удалён."
