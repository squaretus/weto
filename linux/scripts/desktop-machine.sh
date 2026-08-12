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
# kwin назван явно: ставим без рекомендаций, а оконный менеджер у kde-plasma-desktop
# именно в них. Без него сеанс поднимается наполовину — обои и панель есть,
# рисовать окна некому, и снаружи это выглядит вечной загрузкой.
if orb -m "$MACHINE" bash -lc 'command -v pacman >/dev/null'; then
    run 'pacman -Syu --noconfirm --needed \
            plasma-desktop kwin tigervnc xorg-xauth \
            gtk4 openssl zstd wireguard-tools iproute2 \
            libnotify base-devel git curl nano'
else
    run 'export DEBIAN_FRONTEND=noninteractive
         apt-get update
         apt-get install -y --no-install-recommends \
            kde-plasma-desktop plasma-desktop kwin-x11 \
            tigervnc-standalone-server xauth dbus-x11 \
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

say "убираю прежние сеансы"
# Каждый перезапуск VNC оставляет осиротевший Plasma: его X-сервер умер, а сам он
# живёт и мешает следующему. Бьём по имени процесса (`pkill -x`), а не по командной
# строке: `pkill -f` находит и этот самый шелл, потому что искомые слова есть
# в нём самом, — так сеанс убивает себя вместо цели.
user_run 'for name in weto kscreenlocker_g plasmashell kwin_x11 ksmserver \
                      plasma_session startplasma-x11 Xtigervnc vncserver; do
              pkill -u "$USER" -x -9 "$name" 2>/dev/null || true
          done
          sleep 3
          pkill -u "$USER" -x -9 dbus-daemon 2>/dev/null || true
          rm -rf /tmp/.X11-unix/X* /tmp/.X*-lock /tmp/tigervnc.* 2>/dev/null || true
          rm -f ~/.vnc/*.pid ~/.vnc/*.log 2>/dev/null || true' || true

say "настраиваю VNC"
user_run 'mkdir -p ~/.vnc ~/.config
    cat > ~/.vnc/xstartup <<"XSTART"
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session startplasma-x11
XSTART
    chmod +x ~/.vnc/xstartup
    cat > ~/.config/kscreenlockerrc <<"LOCKER"
[Daemon]
Autolock=false
LockOnResume=false
LockOnStart=false
LOCKER
    vncserver -kill :1 >/dev/null 2>&1 || true'

# Пароль VNC нужен клиенту macOS: с сервером без авторизации «Общий экран»
# не соединяется вовсе, хотя сервер при этом исправен (рукопожатие проходит
# до кадрового буфера). Пароль VNC — сущность отдельная от пароля пользователя.
#
# Утилиты `vncpasswd` в Ubuntu 24.04 нет ни под одним именем — в пакетах tigervnc
# её просто не поставляют. Формат файла открытый: восемь байт пароля, зашифрованных
# DES с общеизвестным ключом. `-provider legacy` обязателен: в OpenSSL 3 DES уехал
# в legacy-провайдер, и без него команда молча отдаёт текст ошибки вместо шифротекста.
user_run 'printf "weto\0\0\0\0" \
            | openssl enc -provider legacy -provider default \
                          -des-ecb -K e84ad660c4721ae0 -nopad > ~/.vnc/passwd
          chmod 600 ~/.vnc/passwd
          test -s ~/.vnc/passwd'

# Отдельным вызовом и с паузой: прежняя сессия завершается не мгновенно,
# и запуск в той же команде натыкается на ещё живой дисплей — сервер тогда
# поднимается и тут же выходит.
sleep 2
user_run "vncserver :1 -geometry ${WETO_VNC_GEOMETRY:-1600x1000} -depth 24 \
              -localhost yes -SecurityTypes VncAuth -rfbauth ~/.vnc/passwd >/dev/null 2>&1"

# Экран блокировки KDE всё равно всплывает на старте сеанса, невзирая на настройку.
# Пароля у пользователя OrbStack нет вовсе, так что сквозь него не пройти;
# снятый один раз он не возвращается — проверено.
sleep 12
user_run 'pkill -u "$USER" -x kscreenlocker_g 2>/dev/null || true' >/dev/null 2>&1 || true

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

Пароль VNC: weto

Он нужен клиенту macOS — с сервером без авторизации «Общий экран» не соединяется.
Пароля пользователя Linux при этом нет вовсе, sudo в машине работает без него.

Если туннель отвалился:
    ssh -f -N -L $VNC_PORT:127.0.0.1:5901 $MACHINE@orb

Если вместо рабочего стола висит заставка — всплыл экран блокировки:
    orb -m $MACHINE bash -lc 'pkill -x kscreenlocker_g'

Внутри машины:
    orb -m $MACHINE                 # шелл, weto уже в PATH
    orb -m $MACHINE -u root bash    # root для туннеля wg0

Сценарий проверки — linux/docs/desktop-testing.md
EOF
