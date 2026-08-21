#!/bin/bash
# Контракт релизной сборки: она не трогает отслеживаемые файлы, кладёт версию
# в бандл и не тащит в payload документацию.
#
# Запуск: bash scripts/tests/build-artifact-contract.sh [версия]
# Скрипт делает настоящую сборку, поэтому его удобно запускать в отдельном
# worktree или копии репозитория.
set -euo pipefail

VERSION="${1:-9.9.9}"
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

PKG=".build/release_build/Weto-$VERSION.pkg"

fail() {
    echo "✗ $1" >&2
    exit 1
}

# Сравниваем контрольные суммы до и после: так проверяется именно сборка,
# а не состояние рабочего дерева (в нём могут быть чьи-то незакоммиченные правки).
VERSIONED_FILES=(Sources/WetoCore/Constants.swift Resources/Weto-Info.plist)
BEFORE="$(md5 -q "${VERSIONED_FILES[@]}")"

scripts/build.sh "$VERSION" > /dev/null

AFTER="$(md5 -q "${VERSIONED_FILES[@]}")"
[ "$BEFORE" = "$AFTER" ] || fail "сборка изменила отслеживаемые файлы версии"

# 2. Пакет собран.
[ -f "$PKG" ] || fail "пакет $PKG не собран"

# 3. В payload нет документации и картинок.
# Payload снимается в переменную: `grep -q` закрыл бы пайп на первом совпадении,
# `pkgutil` получил бы SIGPIPE, и при `set -o pipefail` проверка сообщила бы «чисто»
# именно тогда, когда документация в payload есть.
PAYLOAD="$(pkgutil --payload-files "$PKG" 2>/dev/null || true)"
if grep -q 'docs/' <<< "$PAYLOAD"; then
    fail "в payload попала документация"
fi

# 4. Версия оказалась в Info.plist приложения, а не только в имени файла.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pkgutil --expand-full "$PKG" "$WORK/pkg" > /dev/null
APP_PLIST="$(find "$WORK/pkg" -path '*/Weto.app/Contents/Info.plist' | head -1)"
[ -n "$APP_PLIST" ] || fail "в payload нет Weto.app/Contents/Info.plist"

BUNDLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
[ "$BUNDLED_VERSION" = "$VERSION" ] \
    || fail "в бандле версия $BUNDLED_VERSION, а собирали $VERSION"

echo "✓ контракт релизной сборки соблюдён (версия $VERSION, дерево чистое)"
