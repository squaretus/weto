# Ручная проверка охраны на живой машине

Netlink и таблицу маршрутов подделать нечем, поэтому часть проверок выполняется
руками на настоящем ядре. Автоматика покрывает всё остальное:

```bash
linux/scripts/dev.sh cargo test --workspace          # 109 тестов
linux/scripts/dev.sh bash scripts/tests/core-boundary-contract.sh
```

Два контракта требуют прав root — они создают интерфейсы и правила маршрутизации:

```bash
docker run --rm -t --cap-add=NET_ADMIN -v "$PWD":/repo \
    -v weto-cargo-registry:/usr/local/cargo/registry -w /repo/linux weto-rust-dev \
    bash scripts/tests/policy-routing-contract.sh

docker run --rm -t --cap-add=NET_ADMIN -v "$PWD":/repo \
    -v weto-cargo-registry:/usr/local/cargo/registry -w /repo/linux weto-rust-dev \
    bash scripts/tests/netlink-events-contract.sh
```

## Что проверено автоматикой

| Проверка | Где |
|---|---|
| Политика совпадает с macOS на 27 случаях | `weto-core/tests/policy_fixtures.rs` + Swift-двойник |
| Реестр процессов читает настоящий `/proc` | `weto-sys/tests/process_registry.rs` |
| Снимок сети читает настоящий sysfs | `weto-sys/tests/network_snapshot.rs` |
| Проба маршрута совпадает с `ip route get` | там же |
| Проба переживает policy routing `wg-quick` | `policy-routing-contract.sh` |
| Реакция на смену сети — единицы миллисекунд | `netlink-events-contract.sh` |

## Что нужно проверить руками

Настоящий туннель WireGuard — единственное, чего нет ни в контейнере, ни в тестах:
модуля ядра там нет, а dummy-интерфейс не даёт ни `DEVTYPE=wireguard`, ни настоящего
поведения при разрыве.

### 1. Туннель опознаётся как туннель

```bash
sudo ip link add dev wg0 type wireguard
sudo ip link set wg0 up
cargo run -p wetod -- --dump-network
```

Ожидание: `wg0` в списке с пометкой «туннель — да». Если пометки нет, смотреть
`/sys/class/net/wg0/uevent`: квалификация опирается на `DEVTYPE`, `tun_flags`
и `type`, и ни на что больше.

### 2. Проба видит страну

Задать токен ipinfo и выбранный интерфейс:

```bash
mkdir -p ~/.config/weto && chmod 700 ~/.config/weto
printf '%s' "<токен>" > ~/.config/weto/token && chmod 600 ~/.config/weto/token
cat > ~/.config/weto/config.toml <<'EOF'
is_enabled = true
vpn_interface = "wg0"
blocked_countries = ["RU"]
blocked_ip_ranges = []
theme = "dark"
notify_on_kill = true
revision = 1

[[targets]]
entry = "/usr/bin/nano"
display_name = "nano"
kind = "binary"
path = "/usr/bin/nano"
EOF

cargo run -p wetod -- --check
```

Ожидание: названы обе страны и адрес. Без токена — только справочная страна
от geojs, а решение остаётся `VerificationPending`: это и есть fail-closed.

### 3. Цель умирает вместе с туннелем

В одном терминале:

```bash
cargo run -p wetod -- --watch
```

В другом запустить `nano`, дождаться строки «на страже», затем:

```bash
sudo ip link set wg0 down
```

Ожидание: `nano` завершается меньше чем за секунду, в выводе появляется
«небезопасно: VPN не поднят». Замер: разрыв туннеля порождает событие netlink
за единицы миллисекунд, дальше идёт один обход `/proc` и `SIGTERM`.

### 4. Скриптовая цель ловится по командной строке

Проверить на чём-нибудь с shebang (`npx`, любой скрипт на Node):

```bash
readlink -f "$(command -v npx)"    # путь, который надо вписать в цель
```

Ожидание: процесс завершается, хотя `/proc/<pid>/exe` указывает на интерпретатор,
а соседние процессы того же интерпретатора живут.
