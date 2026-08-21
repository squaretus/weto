//! Снимок сети — один вопрос к ядру, и проверяется он на живом ядре: подделать
//! поиск маршрута нечем, а именно он решает судьбу целей.
//!
//! Фальшивого sysfs здесь больше нет. Он был нужен, пока в снимке жил список
//! интерфейсов с квалификацией «туннель или нет» — материал для списка выбора
//! туннеля. Выбирается приложение, и от снимка остался признак свежести вердикта.

use weto_core::network::OutgoingRoute;
use weto_sys::network_snapshot::{
    KernelNetworkReader, KernelRouteProbe, NetworkSnapshotReading, RouteProbing,
};

struct FixedRoute(Option<OutgoingRoute>);

impl RouteProbing for FixedRoute {
    fn outgoing_route(&self) -> Option<OutgoingRoute> {
        self.0.clone()
    }
}

#[test]
fn the_snapshot_carries_whatever_the_probe_answered() {
    let route = OutgoingRoute {
        interface: "wg0".to_string(),
        address: "10.7.0.2".to_string(),
    };
    let snapshot =
        KernelNetworkReader::with_probe(Box::new(FixedRoute(Some(route.clone())))).snapshot();

    assert_eq!(snapshot.outgoing, Some(route));
    assert_eq!(snapshot.verdict_fingerprint(), "out=wg0/10.7.0.2");
}

#[test]
fn without_a_route_the_snapshot_is_empty() {
    let snapshot = KernelNetworkReader::with_probe(Box::new(FixedRoute(None))).snapshot();

    assert!(snapshot.outgoing.is_none());
    assert_eq!(snapshot.verdict_fingerprint(), "out=-");
}

/// Проба обязана называть тот же интерфейс, что и само ядро. Подделать это
/// нечем, поэтому тест идёт к настоящей таблице маршрутов.
#[test]
fn the_kernel_probe_agrees_with_the_kernel() {
    // Адрес фиксированный: у пробы по умолчанию адрес гео-сервиса, а в контейнере
    // DNS может не быть вовсе. Проверяется согласие с ядром, а не разрешение имени.
    let Some(probed) = KernelRouteProbe::default().route_to("1.1.1.1") else {
        // Машина без внешнего маршрута — проверять нечего, и это не провал.
        return;
    };

    let reference = std::process::Command::new("ip")
        .args(["route", "get", "1.1.1.1"])
        .output();
    let Ok(reference) = reference else { return };
    let text = String::from_utf8_lossy(&reference.stdout);

    let Some(expected) = text.split_whitespace().skip_while(|w| *w != "dev").nth(1) else {
        return;
    };
    assert_eq!(probed.interface, expected);

    // Локальный адрес обязан принадлежать названному интерфейсу: иначе отпечаток
    // склеивал бы разные состояния сети в одно.
    let owner = if_addrs::get_if_addrs()
        .unwrap()
        .into_iter()
        .find(|i| i.addr.ip().to_string() == probed.address)
        .map(|i| i.name);
    assert_eq!(owner.as_deref(), Some(probed.interface.as_str()));
}
