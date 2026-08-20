//! Снимок сети: список интерфейсов из sysfs плюс ответ на вопрос, через кого
//! ядро реально выпускает трафик наружу.
//!
//! # Почему не дамп маршрутов
//!
//! Очевидный способ — прочитать `/proc/net/route` и найти строку с нулевым
//! адресом назначения. Он неверен, и это проверено на живом ядре:
//!
//! ```text
//! # раскладка, которую делает wg-quick
//! ip route add default dev wg0 table 51820
//! ip rule add not fwmark 51820 table 51820 priority 32764
//!
//! ip route show table main | grep default   # default via 192.168.215.1 dev eth0
//! ip route get 1.1.1.1                      # 1.1.1.1 dev wg0 table 51820
//! ```
//!
//! Главная таблица показывает старый маршрут, а ядро выпускает трафик через
//! туннель. Дамп сказал бы «VPN не держит маршрут по умолчанию» и охрана
//! завершила бы цели при полностью исправном VPN — то есть ровно тот отказ,
//! ради предотвращения которого приложение и написано.
//!
//! Поэтому спрашиваем не таблицу, а само ядро: UDP-сокет, `connect` на публичный
//! адрес и `getsockname`. `connect` для UDP не отправляет ни байта — он лишь
//! заставляет ядро выполнить полный поиск маршрута с учётом правил и вернуть
//! выбранный локальный адрес. Остаётся сопоставить адрес с интерфейсом.
//!
//! # Почему адрес назначения — хост ipinfo
//!
//! Фиксированный публичный адрес не годится: клиенты исключают отдельные адреса
//! из туннеля. На живой машине владельца `1.1.1.1` уведён в обычный интерфейс
//! отдельным маршрутом, и проба по нему объявляла бы исправный туннель нерабочим.
//! Спрашивать надо про тот адрес, до которого реально пойдёт вердиктный запрос.

use std::net::{ToSocketAddrs, UdpSocket};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use weto_core::network::{NetworkSnapshot, OutgoingRoute};

pub trait NetworkSnapshotReading: Send + Sync {
    fn snapshot(&self) -> NetworkSnapshot;
}

/// Кто выпускает трафик наружу. Отдельным трейтом, потому что подделать
/// таблицу маршрутов в тесте нельзя, а проверить остальную сборку снимка нужно.
pub trait RouteProbing: Send + Sync {
    fn outgoing_route(&self) -> Option<OutgoingRoute>;
}

/// Хост, до которого «ходит» проба, — тот же, у которого спрашивается вердикт.
/// Держится рядом с адресами гео-сервисов: поменяется endpoint — поменяется и он.
pub const PROBE_HOST: &str = "v4.api.ipinfo.io";

/// Как часто разрешать имя заново, пока адреса нет. Разрешение блокирует поток,
/// а снимок снимается каждый тик, поэтому в штатном режиме DNS не спрашивается вовсе.
const RESOLVE_RETRY: Duration = Duration::from_secs(30);

pub struct KernelRouteProbe {
    host: String,
    state: Mutex<ResolvedDestination>,
}

#[derive(Default)]
struct ResolvedDestination {
    address: Option<String>,
    last_attempt: Option<Instant>,
}

impl Default for KernelRouteProbe {
    fn default() -> Self {
        KernelRouteProbe::new(PROBE_HOST)
    }
}

impl KernelRouteProbe {
    pub fn new(host: &str) -> KernelRouteProbe {
        KernelRouteProbe {
            host: host.to_string(),
            state: Mutex::new(ResolvedDestination::default()),
        }
    }

    /// Маршрут до заданного адреса. Открыто наружу ради живых проверок: контракт
    /// `policy-routing-contract.sh` сверяет ответ пробы с `ip route get` по тому же
    /// адресу, и подставлять туда DNS-зависимый хост нельзя — в контейнере его нет.
    pub fn route_to(&self, destination: &str) -> Option<OutgoingRoute> {
        route_to(destination, "0.0.0.0:0").or_else(|| route_to(destination, "[::]:0"))
    }

    /// Последний известный адрес назначения. Моргнувший резольвер не должен
    /// объявлять вердикт несвежим, поэтому прошлый адрес переживает отказ DNS.
    pub fn destination(&self) -> Option<String> {
        let mut state = self.state.lock().expect("адрес пробы");
        if let Some(known) = state.address.clone() {
            return Some(known);
        }

        let due = state
            .last_attempt
            .map(|at| at.elapsed() >= RESOLVE_RETRY)
            .unwrap_or(true);
        if !due {
            return None;
        }

        state.last_attempt = Some(Instant::now());
        let resolved = resolve(&self.host);
        state.address = resolved.clone();
        resolved
    }
}

impl RouteProbing for KernelRouteProbe {
    fn outgoing_route(&self) -> Option<OutgoingRoute> {
        self.route_to(&self.destination()?)
    }
}

/// Имя в адрес. IPv4 предпочитается: у ipinfo для вердикта используется
/// именно `v4.api.ipinfo.io`.
fn resolve(host: &str) -> Option<String> {
    let mut fallback = None;
    for address in (host, 53).to_socket_addrs().ok()? {
        if address.is_ipv4() {
            return Some(address.ip().to_string());
        }
        fallback = fallback.or_else(|| Some(address.ip().to_string()));
    }
    fallback
}

fn route_to(destination: &str, bind: &str) -> Option<OutgoingRoute> {
    let socket = UdpSocket::bind(bind).ok()?;
    socket.connect((destination, 53)).ok()?;
    let local = socket.local_addr().ok()?.ip();

    if_addrs::get_if_addrs()
        .ok()?
        .into_iter()
        .find(|interface| interface.addr.ip() == local)
        .map(|interface| OutgoingRoute {
            interface: interface.name,
            address: local.to_string(),
        })
}

/// Читатель снимка: один вопрос к ядру и ничего больше.
///
/// Раньше здесь читался `/sys/class/net`: состав интерфейсов, их флаги и `DEVTYPE`
/// для квалификации «туннель или нет». Всё это было нужно списку выбора туннеля.
/// Выбирается приложение, поэтому от снимка остался признак свежести вердикта.
pub struct KernelNetworkReader {
    route_probe: Box<dyn RouteProbing>,
}

impl KernelNetworkReader {
    pub fn new() -> KernelNetworkReader {
        KernelNetworkReader {
            route_probe: Box::new(KernelRouteProbe::default()),
        }
    }

    pub fn with_probe(route_probe: Box<dyn RouteProbing>) -> KernelNetworkReader {
        KernelNetworkReader { route_probe }
    }
}

impl Default for KernelNetworkReader {
    fn default() -> Self {
        KernelNetworkReader::new()
    }
}

impl NetworkSnapshotReading for KernelNetworkReader {
    fn snapshot(&self) -> NetworkSnapshot {
        NetworkSnapshot {
            outgoing: self.route_probe.outgoing_route(),
        }
    }
}
