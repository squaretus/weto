//! Снимок сети — один вопрос к ядру, и проверяется он на живом ядре: подделать
//! поиск маршрута нечем, а именно он решает судьбу целей.
//!
//! Фальшивого sysfs здесь больше нет. Он был нужен, пока в снимке жил список
//! интерфейсов с квалификацией «туннель или нет» — материал для списка выбора
//! туннеля. Выбирается приложение, и от снимка остался признак свежести вердикта.

use weto_core::network::OutgoingRoute;
use weto_sys::network_snapshot::{
    InterfaceListing, KernelInterfaces, KernelNetworkReader, KernelRouteProbe,
    NetworkSnapshotReading, RouteProbing,
};

struct FixedRoute(Option<OutgoingRoute>);

impl RouteProbing for FixedRoute {
    fn outgoing_route(&self) -> Option<OutgoingRoute> {
        self.0.clone()
    }
}

struct FixedInterfaces(Vec<&'static str>);

impl InterfaceListing for FixedInterfaces {
    fn up_interfaces(&self) -> Vec<String> {
        self.0.iter().map(|name| name.to_string()).collect()
    }
}

/// Поднятые интерфейсы едут в снимке рядом с носителем, но отпечаток они
/// не меняют: второй VPN рядом с рабочим не повод обесценивать вердикт.
#[test]
fn the_snapshot_carries_the_up_interfaces_outside_the_fingerprint() {
    let route = OutgoingRoute {
        interface: "wg0".to_string(),
        address: "10.7.0.2".to_string(),
    };
    let snapshot = KernelNetworkReader::with_sources(
        Box::new(FixedRoute(Some(route))),
        Box::new(FixedInterfaces(vec!["lo", "eth0", "wg0"])),
    )
    .snapshot();

    assert_eq!(snapshot.up_interfaces, ["lo", "eth0", "wg0"]);
    assert_eq!(snapshot.verdict_fingerprint(), "out=wg0/10.7.0.2");
}

/// На живом ядре петля поднята всегда, и имя в списке ровно одно, сколько бы
/// адресов у интерфейса ни было.
#[test]
fn the_kernel_lists_the_loopback_once() {
    let names = KernelInterfaces.up_interfaces();

    assert_eq!(
        names.iter().filter(|name| *name == "lo").count(),
        1,
        "{names:?}"
    );
}

/// Выключенный интерфейс в список не попадает. Поднимать и ронять настоящие
/// интерфейсы тест без `CAP_NET_ADMIN` не может, поэтому сверяется с тем,
/// что ядро само называет выключенным в sysfs.
#[test]
fn an_interface_that_is_down_is_not_listed() {
    let names = KernelInterfaces.up_interfaces();
    let Ok(entries) = std::fs::read_dir("/sys/class/net") else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let operstate = std::fs::read_to_string(entry.path().join("operstate")).unwrap_or_default();
        let flags = std::fs::read_to_string(entry.path().join("flags")).unwrap_or_default();
        let flags = u32::from_str_radix(flags.trim().trim_start_matches("0x"), 16).unwrap_or(0);
        if flags & 0x1 == 0 && operstate.trim() == "down" {
            assert!(
                !names.contains(&name),
                "выключенный {name} в списке: {names:?}"
            );
        }
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
