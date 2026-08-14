//! Снимок сети проверяется на фальшивом sysfs, а проба маршрута — на живом ядре.
//!
//! Разделение не случайно: раскладку файлов подделать можно и нужно, а вот
//! поиск маршрута подделать нечем — и именно он решает судьбу целей.

use std::fs;
use std::path::Path;

use weto_sys::network_snapshot::{
    KernelRouteProbe, NetworkSnapshotReading, RouteProbing, SysfsNetworkReader,
};

fn make_interface(root: &Path, name: &str, flags: &str, kind: Kind) {
    let dir = root.join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("flags"), format!("{flags}\n")).unwrap();
    fs::write(dir.join("ifindex"), "3\n").unwrap();

    match kind {
        Kind::Ethernet => {
            fs::write(dir.join("type"), "1\n").unwrap();
            fs::write(dir.join("uevent"), "INTERFACE=eth0\n").unwrap();
        }
        Kind::WireGuard => {
            fs::write(dir.join("type"), "65534\n").unwrap();
            fs::write(dir.join("uevent"), "DEVTYPE=wireguard\nINTERFACE=wg0\n").unwrap();
        }
        Kind::TunTap => {
            fs::write(dir.join("type"), "1\n").unwrap();
            fs::write(dir.join("uevent"), "INTERFACE=tun0\n").unwrap();
            fs::write(dir.join("tun_flags"), "0x0001\n").unwrap();
        }
        Kind::IpTunnel => {
            fs::write(dir.join("type"), "768\n").unwrap();
            fs::write(dir.join("uevent"), "INTERFACE=sit0\n").unwrap();
        }
    }
}

enum Kind {
    Ethernet,
    WireGuard,
    TunTap,
    IpTunnel,
}

struct FixedRoute(Option<&'static str>);

impl RouteProbing for FixedRoute {
    fn outgoing_interface(&self) -> Option<String> {
        self.0.map(str::to_string)
    }
}

fn reader(root: &Path, route: Option<&'static str>) -> SysfsNetworkReader {
    SysfsNetworkReader::with_parts(root.into(), Box::new(FixedRoute(route)))
}

/// Имя в квалификации не участвует — иначе Wi-Fi, названный «VPN», сошёл бы
/// за туннель, а `wg-quick` с именем `home` не сошёл бы.
#[test]
fn tunnels_are_recognised_by_the_kernel_not_by_their_name() {
    let tmp = tempfile::tempdir().unwrap();
    make_interface(tmp.path(), "wg0", "0x83", Kind::WireGuard);
    make_interface(tmp.path(), "tun0", "0x1043", Kind::TunTap);
    make_interface(tmp.path(), "sit0", "0x80", Kind::IpTunnel);
    make_interface(tmp.path(), "VPN", "0x1003", Kind::Ethernet);

    let snapshot = reader(tmp.path(), None).snapshot();
    let names: Vec<&str> = snapshot
        .vpn_candidates()
        .iter()
        .map(|i| i.name.as_str())
        .collect();

    assert_eq!(names, vec!["sit0", "tun0", "wg0"]);
    assert!(!snapshot.interface("VPN").unwrap().is_tunnel);
}

/// Значения флагов сняты с живого ядра: у работающего eth0 они `0x1003`,
/// у поднятого туннеля `0x83`, у опущенного `0x82`. Бит IFF_RUNNING (`0x40`)
/// в sysfs не появляется ни у кого, поэтому смотреть на него нельзя.
#[test]
fn up_is_decided_by_the_iff_up_bit_alone() {
    let tmp = tempfile::tempdir().unwrap();
    make_interface(tmp.path(), "wg0", "0x83", Kind::WireGuard);
    make_interface(tmp.path(), "wg1", "0x82", Kind::WireGuard);
    make_interface(tmp.path(), "eth0", "0x1003", Kind::Ethernet);

    let snapshot = reader(tmp.path(), None).snapshot();
    assert!(snapshot.interface("wg0").unwrap().is_up);
    assert!(!snapshot.interface("wg1").unwrap().is_up);
    assert!(snapshot.interface("eth0").unwrap().is_up);
}

#[test]
fn interface_without_readable_files_does_not_break_the_snapshot() {
    let tmp = tempfile::tempdir().unwrap();
    make_interface(tmp.path(), "eth0", "0x1003", Kind::Ethernet);
    fs::create_dir_all(tmp.path().join("ghost")).unwrap();

    let snapshot = reader(tmp.path(), None).snapshot();
    assert_eq!(snapshot.interfaces.len(), 2);
    assert!(!snapshot.interface("ghost").unwrap().is_up);
    assert!(!snapshot.interface("ghost").unwrap().is_tunnel);
}

#[test]
fn missing_sysfs_root_yields_an_empty_snapshot() {
    let snapshot = reader(Path::new("/несуществующий/sys"), None).snapshot();
    assert!(snapshot.interfaces.is_empty());
}

#[test]
fn the_route_owner_comes_from_the_probe_and_lands_in_the_fingerprint() {
    let tmp = tempfile::tempdir().unwrap();
    make_interface(tmp.path(), "wg0", "0x83", Kind::WireGuard);
    make_interface(tmp.path(), "eth0", "0x1003", Kind::Ethernet);

    let through_tunnel = reader(tmp.path(), Some("wg0")).snapshot();
    let through_ethernet = reader(tmp.path(), Some("eth0")).snapshot();

    assert_eq!(
        through_tunnel.default_route_interface.as_deref(),
        Some("wg0")
    );
    assert_ne!(
        through_tunnel.fingerprint(),
        through_ethernet.fingerprint(),
        "смена владельца маршрута обязана обесценивать прежний вердикт"
    );
}

/// Проба обязана называть тот же интерфейс, что и само ядро. Подделать это
/// нечем, поэтому тест идёт к настоящей таблице маршрутов.
#[test]
fn the_kernel_probe_agrees_with_the_kernel() {
    let Some(probed) = KernelRouteProbe.outgoing_interface() else {
        // Машина без внешнего маршрута — проверять нечего, и это не провал.
        return;
    };

    let reference = std::process::Command::new("ip")
        .args(["route", "get", "1.1.1.1"])
        .output()
        .expect("iproute2 обязан быть в окружении разработки");
    let text = String::from_utf8_lossy(&reference.stdout);
    let expected = text
        .split_whitespace()
        .skip_while(|word| *word != "dev")
        .nth(1)
        .expect("в ответе ip route get есть dev");

    assert_eq!(probed, expected, "полный вывод: {text}");
}

/// Живой снимок обязан видеть хотя бы петлевой интерфейс: если sysfs читается
/// не так, как устроен на самом деле, это вскроется здесь, а не у пользователя.
#[test]
fn the_real_sysfs_yields_a_usable_snapshot() {
    let snapshot = SysfsNetworkReader::new().snapshot();
    let loopback = snapshot
        .interface("lo")
        .expect("петлевой интерфейс есть всегда");

    assert!(loopback.is_up);
    assert!(!loopback.is_tunnel, "lo туннелем не является");
    assert!(loopback.index > 0, "ifindex обязан читаться");
}
