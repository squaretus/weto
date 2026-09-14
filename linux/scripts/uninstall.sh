#!/bin/bash
# Удаление weto.
#
# Снимает ровно то, что ставил установщик, плюс состояние приложения.
# Расхождение установщика и деинсталлятора на macOS уже случалось — после
# удаления оставался живой демон, — поэтому здесь оно проверяется машинно
# контрактом install-contract.sh.
set -u

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
BIN="$HOME/.local/bin"

echo "Удаление weto..."

# Работающая копия завершается: иначе она перепишет настройки, которые
# мы вот-вот удалим, и воссоздаст каталоги, которые мы удаляем.
#
# Матчить по командной строке нельзя: процесс запускают через $BIN/weto,
# а искали путь через current — и pkill молча не находил ничего. Имя
# процесса плюс проверка, что это именно наш файл, ошибиться не дают.
for pid in $(pgrep -x weto 2>/dev/null || true); do
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    case "$exe" in
        "$DATA/weto/"*) kill "$pid" 2>/dev/null || true ;;
    esac
done
sleep 1

rm -f "$BIN/weto"
rm -rf "$DATA/weto"
rm -f "$DATA/applications/weto.desktop"
rm -f "$DATA/icons/hicolor/scalable/apps/weto.svg"
rm -f "$CONFIG/autostart/weto.desktop"
rm -rf "$CONFIG/weto"
rm -rf "$STATE/weto"
rm -rf "$CACHE/weto"

# Токен мог уехать в Secret Service, если он в системе есть.
command -v secret-tool >/dev/null 2>&1 && \
    secret-tool clear service weto account ipinfo 2>/dev/null || true

update-desktop-database "$DATA/applications" 2>/dev/null || true

echo "weto удалён."
