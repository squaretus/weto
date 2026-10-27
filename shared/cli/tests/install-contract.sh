#!/usr/bin/env bash
# Контракт установщика терминальной версии (`shared/cli/install.sh`).
#
# Релиз подделывается каталогом и отдаётся через file://, бинарник — скриптом,
# который записывает, с чем его вызвали. Проверяется то, ради чего установщик
# существует: ставит ровно сверенный с SHA256SUMS файл, ставит сервис, повторный
# запуск идёт поверх, а повреждённый архив не устанавливается вовсе.
#
#   bash shared/cli/tests/install-contract.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$HERE/../install.sh"
command -v curl >/dev/null || { echo "нужен curl (file:// умеет только он)"; exit 1; }

case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Linux/amd64) SUFFIX="-linux-x86_64.tar.gz" ;;
    Linux/aarch64 | Linux/arm64) SUFFIX="-linux-aarch64.tar.gz" ;;
    Darwin/arm64) SUFFIX="-macos-arm64.tar.gz" ;;
    *) echo "пропуск: $(uname -sm) установщиком не поддерживается"; exit 0 ;;
esac

if command -v sha256sum >/dev/null; then hash_of() { sha256sum "$1" | cut -d' ' -f1; }
else hash_of() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
FAILURES=0

check() {
    local name="$1"; shift
    if "$@"; then echo "  ✓ $name"; else echo "  ✗ $name"; FAILURES=$((FAILURES + 1)); fi
}

# Релиз версии $1 в $ROOT/releases: архив с подставным weto и SHA256SUMS.
# Лишний архив чужой платформы лежит рядом — установщик обязан выбрать свой.
make_release() {
    local version="$1" dir="$ROOT/releases/download/v$1"
    mkdir -p "$dir/stage"
    cat > "$dir/stage/weto" <<EOF
#!/bin/sh
echo "\$*" >> "\${WETO_TEST_LOG:?}"
[ "\$1" = version ] && echo "weto $version"
exit 0
EOF
    chmod +x "$dir/stage/weto"
    tar -czf "$dir/weto-cli-$version$SUFFIX" -C "$dir/stage" weto
    printf 'not-a-real-archive' > "$dir/weto-cli-$version-other-arch.tar.gz"
    printf 'pkg' > "$dir/Weto-$version.pkg"
    rm -rf "$dir/stage"
    (cd "$dir" && for file in *; do printf '%s  %s\n' "$(hash_of "$file")" "$file"; done > SHA256SUMS)
}

# «Последний релиз» — то же, что /latest/download на GitHub.
publish_latest() {
    rm -rf "$ROOT/releases/latest"
    mkdir -p "$ROOT/releases/latest"
    cp -R "$ROOT/releases/download/v$1" "$ROOT/releases/latest/download"
}

run_installer() {
    WETO_BASE_URL="file://$ROOT/releases" WETO_PREFIX="$ROOT/bin" WETO_REQUIRE_ROOT=0 \
        WETO_TEST_LOG="$ROOT/calls.log" bash "$INSTALLER" "$@"
}

make_release 0.2.0
make_release 0.3.0
publish_latest 0.3.0

echo "Последний релиз ставится и ставит сервис"
: > "$ROOT/calls.log"
run_installer > "$ROOT/out.txt" 2>&1
check "бинарник на месте и исполняемый" test -x "$ROOT/bin/weto"
check "поставлен архив последнего релиза" grep -q 'weto 0.3.0' "$ROOT/out.txt"
check "сервис поставлен командой самого weto" grep -qx 'service install' "$ROOT/calls.log"
check "временного файла рядом не осталось" test ! -e "$ROOT/bin/.weto.new"
check "подсказка про настройку напечатана" grep -q 'sudo weto target add' "$ROOT/out.txt"

echo "Конкретная версия ставится поверх"
: > "$ROOT/calls.log"
WETO_VERSION=0.2.0 run_installer > "$ROOT/out.txt" 2>&1
check "стоит 0.2.0" grep -q 'weto 0.2.0' "$ROOT/out.txt"
check "сервис поставлен повторно" grep -qx 'service install' "$ROOT/calls.log"

echo "WETO_NO_SERVICE=1 ставит только бинарник"
: > "$ROOT/calls.log"
WETO_NO_SERVICE=1 run_installer > "$ROOT/out.txt" 2>&1
check "сервис не трогали" bash -c "! grep -q 'service' '$ROOT/calls.log'"

echo "Повреждённый архив не устанавливается"
BEFORE="$(hash_of "$ROOT/bin/weto")"
printf 'x' >> "$ROOT/releases/latest/download/weto-cli-0.3.0$SUFFIX"
if run_installer > "$ROOT/out.txt" 2>&1; then STATUS=0; else STATUS=$?; fi
check "установщик отказал" test "$STATUS" -ne 0
check "причина названа" grep -q 'контрольная сумма' "$ROOT/out.txt"
check "прежний бинарник не тронут" test "$(hash_of "$ROOT/bin/weto")" = "$BEFORE"

echo "Нет релиза — понятный отказ"
if WETO_VERSION=9.9.9 run_installer > "$ROOT/out.txt" 2>&1; then STATUS=0; else STATUS=$?; fi
check "установщик отказал" test "$STATUS" -ne 0
check "сказано, чего нет" grep -q 'нет такого релиза' "$ROOT/out.txt"

echo "Без root не начинает"
if WETO_BASE_URL="file://$ROOT/releases" WETO_PREFIX="$ROOT/bin" bash "$INSTALLER" > "$ROOT/out.txt" 2>&1; then
    STATUS=0
else
    STATUS=$?
fi
if [ "$(id -u)" -ne 0 ]; then
    check "отказ без root" test "$STATUS" -ne 0
    check "подсказка с sudo" grep -q 'sudo bash' "$ROOT/out.txt"
fi

if [ "$FAILURES" -ne 0 ]; then
    echo "провалено проверок: $FAILURES"
    exit 1
fi
echo "OK: установщик терминальной версии"
