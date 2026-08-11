#!/bin/bash
# Установка weto в домашний каталог пользователя.
#
# Прав root не требуется нигде: цели завершаются в своём же uid, состояние сети
# читается без привилегий, а всё, что кладётся на диск, лежит под $HOME.
# Отсюда же и обновление без polkit: подменить каталог в своём доме приложение
# может само.
set -euo pipefail

SOURCE="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$SOURCE/VERSION")"

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
TARGET="$DATA/weto/$VERSION"
BIN="$HOME/.local/bin"

echo "=== weto $VERSION ==="

# Пол GTK — 4.14 (Ubuntu 24.04 LTS). Сказать об этом надо здесь и понятно,
# а не оставлять пользователя с приложением, которое не стартует.
if command -v pkg-config >/dev/null 2>&1; then
    if ! pkg-config --atleast-version=4.14 gtk4 2>/dev/null; then
        HAVE="$(pkg-config --modversion gtk4 2>/dev/null || echo 'не найден')"
        echo "Нужен GTK4 не ниже 4.14, в системе: $HAVE" >&2
        echo "Ubuntu: sudo apt install libgtk-4-1 · Arch: sudo pacman -S gtk4" >&2
        exit 1
    fi
fi

rm -rf "$TARGET"
mkdir -p "$TARGET/bin" "$TARGET/share" "$BIN"
cp "$SOURCE/bin/weto" "$TARGET/bin/weto"
chmod 755 "$TARGET/bin/weto"
cp "$SOURCE/install.sh" "$SOURCE/uninstall.sh" "$SOURCE/VERSION" "$TARGET/share/"

# Симлинк current переставляется атомарно: между снятием старого и созданием
# нового не должно быть мгновения, когда приложения нет на диске.
ln -sfn "$TARGET" "$DATA/weto/current.tmp"
mv -T "$DATA/weto/current.tmp" "$DATA/weto/current"
ln -sfn "$DATA/weto/current/bin/weto" "$BIN/weto"

# Ярлык — второй вход в приложение помимо трея. В окружении без трея
# (ванильный GNOME) он единственный.
mkdir -p "$DATA/applications" "$DATA/icons/hicolor/scalable/apps"
cat > "$DATA/applications/weto.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=weto
Comment=Завершает цели, когда трафик идёт мимо VPN
Exec=$BIN/weto
Icon=weto
Terminal=false
Categories=Utility;Security;
StartupNotify=false
EOF

if [ -f "$SOURCE/share/weto.svg" ]; then
    cp "$SOURCE/share/weto.svg" "$DATA/icons/hicolor/scalable/apps/weto.svg"
fi

# Прежние версии не копятся: держим текущую и одну предыдущую — на случай,
# если новая не стартует.
mapfile -t OLD < <(find "$DATA/weto" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | grep -v "^$VERSION$" | sort -V | head -n -1)
for version in "${OLD[@]:-}"; do
    [ -n "$version" ] && rm -rf "$DATA/weto/$version"
done

update-desktop-database "$DATA/applications" 2>/dev/null || true

echo "Установлено: $TARGET"
echo "Запуск:      weto"

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "Внимание: $BIN не в \$PATH — добавьте его, иначе команда weto не найдётся" >&2 ;;
esac
