#!/bin/bash
# Поднимает машину OrbStack с рабочим столом и установленным weto —
# чтобы проверять и глазами, и функционально в одном сеансе.
#
#   linux/scripts/desktop-machine.sh ubuntu:noble weto-ubuntu
#   linux/scripts/desktop-machine.sh arch         weto-arch
#
# Почему KDE: у него StatusNotifierItem родной, без плагинов и расширений,
# и это одна из двух целевых сред. На GNOME трей живёт через расширение,
# и проверять на нём стоит отдельно — как раз тот случай, ради которого
# в приложении есть второй вход.
#
# Почему amd64: релиз выпускается под x86_64, и проверять надо его.
# Машина запустится через Rosetta и будет медленнее, но честнее.
set -euo pipefail

DISTRO="${1:-ubuntu:noble}"
MACHINE="${2:-weto-desktop}"
ARCH="${WETO_MACHINE_ARCH:-amd64}"
VNC_PORT="${WETO_VNC_PORT:-5901}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

say() { printf '\n=== %s ===\n' "$1"; }

if ! orbctl list 2>/dev/null | awk '{print $1}' | grep -qx "$MACHINE"; then
    say "создаю машину $MACHINE ($DISTRO, $ARCH)"
    orbctl create -a "$ARCH" "$DISTRO" "$MACHINE"
else
    say "машина $MACHINE уже есть"
    orbctl start "$MACHINE" 2>/dev/null || true
fi

run() { orb -m "$MACHINE" -u root bash -lc "$1"; }
user_run() { orb -m "$MACHINE" bash -lc "$1"; }

say "ставлю рабочий стол и зависимости"
if orb -m "$MACHINE" bash -lc 'command -v pacman >/dev/null'; then
    run 'pacman -Syu --noconfirm --needed \
            plasma-desktop tigervnc xorg-xauth \
            gtk4 openssl zstd wireguard-tools iproute2 \
            libnotify base-devel git curl nano'
else
    run 'export DEBIAN_FRONTEND=noninteractive
         apt-get update
         apt-get install -y --no-install-recommends \
            kde-plasma-desktop tigervnc-standalone-server xauth dbus-x11 \
            libgtk-4-dev libssl-dev pkg-config zstd \
            wireguard-tools iproute2 libnotify-bin \
            build-essential curl git nano'
fi

# Пол проекта — Rust 1.82, а в репозиториях дистрибутивов он бывает старше.
say "проверяю тулчейн"
if ! user_run 'command -v cargo >/dev/null && cargo --version | awk "{print \$2}" | awk -F. "\$2 >= 82 {exit 0} {exit 1}"'; then
    user_run 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path'
fi

say "собираю weto из рабочего дерева"
# Отдельный каталог сборки: в linux/target лежат артефакты другой архитектуры,
# собранные на Mac, и мешать их нельзя.
user_run "source \$HOME/.cargo/env 2>/dev/null || true
          cd '$REPO/linux'
          CARGO_TARGET_DIR=\$HOME/weto-target cargo build --release -p weto-app"

say "ставлю в домашний каталог машины"
user_run "set -e
    VERSION=\$(date +0.%Y%m%d.%H%M)
    STAGE=\$HOME/weto-stage/weto-\$VERSION
    rm -rf \$HOME/weto-stage && mkdir -p \$STAGE/bin \$STAGE/share
    cp \$HOME/weto-target/release/weto \$STAGE/bin/weto
    cp '$REPO/linux/scripts/install.sh' '$REPO/linux/scripts/uninstall.sh' \$STAGE/
    cp '$REPO/shared/icon/dark.icon/Assets/grid.svg' \$STAGE/share/weto.svg
    printf '%s' \$VERSION > \$STAGE/VERSION
    bash \$STAGE/install.sh"

say "настраиваю VNC"
# Пароля нет намеренно: в tigervnc из Ubuntu 24.04 утилиты vncpasswd просто нет
# (проверено — в пакетах её не поставляют), а сервер слушает только localhost
# машины и достижим исключительно через ssh-туннель. Пароль поверх туннеля
# добавил бы шаг, но не защиту.
user_run 'mkdir -p ~/.vnc
    cat > ~/.vnc/xstartup <<"XSTART"
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session startplasma-x11
XSTART
    chmod +x ~/.vnc/xstartup
    vncserver -kill :1 >/dev/null 2>&1 || true'

# Отдельным вызовом и с паузой: прежняя сессия завершается не мгновенно,
# и запуск в той же команде натыкается на ещё живой дисплей — сервер тогда
# поднимается и тут же выходит.
sleep 2
user_run "vncserver :1 -geometry ${WETO_VNC_GEOMETRY:-1600x1000} -depth 24 \
              -localhost yes -SecurityTypes None >/dev/null 2>&1"

say "поднимаю ssh-туннель"
# Порты машин OrbStack с Mac напрямую недоступны: не отвечает ни имя, ни адрес,
# ни ICMP — при пустых правилах фильтрации внутри машины. Единственный путь
# внутрь — ssh, и он же снимает вопрос о пароле.
pkill -f "$VNC_PORT:127.0.0.1:5901" 2>/dev/null || true
sleep 1
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    -f -N -L "$VNC_PORT:127.0.0.1:5901" "$MACHINE@orb" >/dev/null 2>&1

say "готово"
cat <<EOF
Подключение с Mac (туннель уже поднят):

    open vnc://127.0.0.1:$VNC_PORT

Пароля нет: сервер слушает только localhost машины, снаружи туда хода нет.

Если туннель отвалился:
    ssh -f -N -L $VNC_PORT:127.0.0.1:5901 $MACHINE@orb

Внутри машины:
    orb -m $MACHINE                 # шелл, weto уже в PATH
    orb -m $MACHINE -u root bash    # root для туннеля wg0

Сценарий проверки — linux/docs/desktop-testing.md
EOF
