#!/usr/bin/env bash
# Установка терминальной версии weto одной командой:
#
#   curl -fsSL https://github.com/squaretus/weto/releases/latest/download/install.sh | sudo bash
#   wget -qO-  https://github.com/squaretus/weto/releases/latest/download/install.sh | sudo bash
#
# Скрипт общий для Linux и macOS: определяет систему и архитектуру, берёт из релиза
# архив `weto-cli-<версия>-<система>-<архитектура>.tar.gz`, сверяет его с `SHA256SUMS`
# того же релиза, кладёт бинарник в /usr/local/bin/weto и ставит сервис охраны всей
# машины (`weto service install` от root). Повторный запуск — та же установка поверх:
# так же им ставится конкретная версия или возвращается прежняя.
#
# Переменные окружения:
#   WETO_VERSION     версия вида 0.3.0 вместо последней
#   WETO_PREFIX      каталог бинарника (по умолчанию /usr/local/bin)
#   WETO_NO_SERVICE  1 — не ставить сервис, только бинарник
#   WETO_BASE_URL    откуда брать релизы (по умолчанию страница релизов на GitHub);
#                    тесты подставляют сюда file://
#   WETO_REQUIRE_ROOT 0 — не требовать root (только для тестов установщика)

set -euo pipefail

BASE_URL="${WETO_BASE_URL:-https://github.com/squaretus/weto/releases}"
PREFIX="${WETO_PREFIX:-/usr/local/bin}"
VERSION="${WETO_VERSION:-}"
NO_SERVICE="${WETO_NO_SERVICE:-0}"
REQUIRE_ROOT="${WETO_REQUIRE_ROOT:-1}"
INSTALL_COMMAND="curl -fsSL https://github.com/squaretus/weto/releases/latest/download/install.sh | sudo bash"

say() { printf '%s\n' "$*"; }
fail() { printf 'weto: %s\n' "$*" >&2; exit 1; }

# Охрана ставится на всю машину: сервис под root останавливает процессы любых
# пользователей, а настройки лежат в системных каталогах. Без root половина шагов
# упала бы посередине — проверяем до первого скачивания.
if [ "$REQUIRE_ROOT" != "0" ] && [ "$(id -u)" -ne 0 ]; then
    fail "нужны права root: $INSTALL_COMMAND"
fi

case "$(uname -s)" in
    Linux) SYSTEM="linux" ;;
    Darwin) SYSTEM="macos" ;;
    *) fail "система $(uname -s) не поддерживается: только Linux и macOS" ;;
esac

MACHINE="$(uname -m)"
case "$SYSTEM/$MACHINE" in
    linux/x86_64 | linux/amd64) ARCH="x86_64" ;;
    linux/aarch64 | linux/arm64) ARCH="aarch64" ;;
    macos/arm64) ARCH="arm64" ;;
    macos/x86_64) fail "на macOS weto работает только на Apple Silicon" ;;
    *) fail "архитектура $MACHINE не поддерживается" ;;
esac

# curl есть на macOS всегда, на серверах Linux — почти всегда; wget — запасной путь.
if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -q -O "$2" "$1"; }
else
    fail "нужен curl или wget"
fi

if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
    fail "нужен sha256sum или shasum, чтобы проверить скачанное"
fi

if [ -n "$VERSION" ]; then
    VERSION="${VERSION#v}"
    RELEASE_URL="$BASE_URL/download/v$VERSION"
else
    # «Последний релиз» GitHub отдаёт перенаправлением, без обращения к API:
    # у API лимит на анонимные запросы, а у страницы загрузки — нет.
    RELEASE_URL="$BASE_URL/latest/download"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say "weto: скачиваю список контрольных сумм…"
fetch "$RELEASE_URL/SHA256SUMS" "$WORK/SHA256SUMS" \
    || fail "не скачать SHA256SUMS из $RELEASE_URL — нет такого релиза или нет сети"

# Имя архива берём из SHA256SUMS: в нём есть номер версии, которого
# «последний релиз» заранее не знает.
SUFFIX="-$SYSTEM-$ARCH.tar.gz"
LINE="$(grep -E "  weto-cli-[0-9]+\.[0-9]+\.[0-9]+${SUFFIX//./\\.}\$" "$WORK/SHA256SUMS" | head -n 1 || true)"
[ -n "$LINE" ] || fail "в релизе нет терминальной версии для $SYSTEM $ARCH"
EXPECTED="${LINE%%  *}"
ASSET="${LINE#*  }"

say "weto: скачиваю $ASSET…"
fetch "$RELEASE_URL/$ASSET" "$WORK/$ASSET" || fail "не скачать $ASSET"

ACTUAL="$(sha256 "$WORK/$ASSET")"
[ "$ACTUAL" = "$EXPECTED" ] \
    || fail "контрольная сумма $ASSET не совпала с SHA256SUMS — файл повреждён или подменён, ничего не установлено"

mkdir -p "$WORK/unpacked"
tar -xzf "$WORK/$ASSET" -C "$WORK/unpacked"
[ -f "$WORK/unpacked/weto" ] || fail "в архиве $ASSET нет файла weto"

# Замена атомарная: новый файл пишется рядом и встаёт на место переименованием,
# поэтому работающий сервис ни в какой момент не видит половины бинарника.
mkdir -p "$PREFIX"
cp "$WORK/unpacked/weto" "$PREFIX/.weto.new"
chmod 0755 "$PREFIX/.weto.new"
if [ "$SYSTEM" = "macos" ]; then
    # curl карантин не ставит, но архив мог прийти и другим путём.
    xattr -d com.apple.quarantine "$PREFIX/.weto.new" 2>/dev/null || true
fi
mv -f "$PREFIX/.weto.new" "$PREFIX/weto"
say "weto: установлен $PREFIX/weto ($("$PREFIX/weto" version 2>/dev/null || echo "${ASSET%"$SUFFIX"}"))"

# Приложение weto с интерфейсом на Linux кладёт свою команду `weto` в ~/.local/bin,
# и у пользователя она стоит в PATH раньше /usr/local/bin. Охраны две не бывает,
# но перепутать команды можно — предупреждаем.
OWNER="${SUDO_USER:-}"
if [ "$SYSTEM" = "linux" ] && [ -n "$OWNER" ]; then
    OWNER_HOME="$(getent passwd "$OWNER" 2>/dev/null | cut -d: -f6 || true)"
    if [ -n "$OWNER_HOME" ] && [ -e "$OWNER_HOME/.local/bin/weto" ]; then
        say "weto: внимание — у $OWNER есть приложение weto с интерфейсом ($OWNER_HOME/.local/bin/weto);"
        say "      без sudo команда «weto» может вызвать его. Две охраны над одними целями мешают"
        say "      друг другу — закройте приложение, пока работает охрана всей машины."
    fi
fi

if [ "$NO_SERVICE" = "1" ]; then
    say "weto: сервис не ставлю (WETO_NO_SERVICE=1). Запустить: sudo weto service install"
else
    "$PREFIX/weto" service install
fi

cat <<'NEXT'

Дальше — настройка (всё через sudo: охрана стоит на всю машину):

  sudo weto token set                          ключ ipinfo, без него нечем проверить выход
  sudo weto target add claude                  что останавливать: имя команды или путь
  sudo weto vpn set wg0                        через какой VPN обязан идти трафик
  sudo weto blacklist add RU                   откуда выход запрещён
  weto status                                  что сейчас делает охрана

Справка — weto help, обновление — sudo weto update.
NEXT
