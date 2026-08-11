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

use std::net::UdpSocket;
use std::path::{Path, PathBuf};

use weto_core::network::{NetworkInterfaceSnapshot, NetworkSnapshot};

pub trait NetworkSnapshotReading: Send + Sync {
    fn snapshot(&self) -> NetworkSnapshot;
}

/// Кто выпускает трафик наружу. Отдельным трейтом, потому что подделать
/// таблицу маршрутов в тесте нельзя, а проверить остальную сборку снимка нужно.
pub trait RouteProbing: Send + Sync {
    fn outgoing_interface(&self) -> Option<String>;
}

/// Адреса, к которым «ходит» проба. Пакеты не отправляются: `connect` на UDP —
/// операция чисто локальная. Адреса публичных резолверов взяты как заведомо
/// маршрутизируемые снаружи; отвечать они не обязаны.
const PROBE_V4: &str = "1.1.1.1:53";
const PROBE_V6: &str = "[2606:4700:4700::1111]:53";

pub struct KernelRouteProbe;

impl RouteProbing for KernelRouteProbe {
    fn outgoing_interface(&self) -> Option<String> {
        interface_for(PROBE_V4, "0.0.0.0:0").or_else(|| interface_for(PROBE_V6, "[::]:0"))
    }
}

fn interface_for(target: &str, bind: &str) -> Option<String> {
    let socket = UdpSocket::bind(bind).ok()?;
    socket.connect(target).ok()?;
    let local = socket.local_addr().ok()?.ip();

    if_addrs::get_if_addrs()
        .ok()?
        .into_iter()
        .find(|interface| interface.addr.ip() == local)
        .map(|interface| interface.name)
}

pub struct SysfsNetworkReader {
    sys_root: PathBuf,
    route_probe: Box<dyn RouteProbing>,
}

impl SysfsNetworkReader {
    pub fn new() -> SysfsNetworkReader {
        SysfsNetworkReader {
            sys_root: PathBuf::from("/sys/class/net"),
            route_probe: Box::new(KernelRouteProbe),
        }
    }

    pub fn with_parts(sys_root: PathBuf, route_probe: Box<dyn RouteProbing>) -> SysfsNetworkReader {
        SysfsNetworkReader {
            sys_root,
            route_probe,
        }
    }
}

impl Default for SysfsNetworkReader {
    fn default() -> Self {
        Self::new()
    }
}

impl NetworkSnapshotReading for SysfsNetworkReader {
    fn snapshot(&self) -> NetworkSnapshot {
        let mut interfaces: Vec<NetworkInterfaceSnapshot> = std::fs::read_dir(&self.sys_root)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|entry| {
                let name = entry.file_name().to_str()?.to_string();
                let dir = entry.path();
                Some(NetworkInterfaceSnapshot {
                    index: read_number(&dir.join("ifindex")).unwrap_or(0) as u32,
                    is_up: is_up(&dir),
                    is_tunnel: is_tunnel(&dir),
                    name,
                })
            })
            .collect();
        interfaces.sort_by(|a, b| a.name.cmp(&b.name));

        NetworkSnapshot {
            interfaces,
            default_route_interface: self.route_probe.outgoing_interface(),
        }
    }
}

/// IFF_UP, и только он.
///
/// IFF_RUNNING в sysfs не отражается (проверено: у работающего eth0 флаги
/// `0x1003`, бита `0x40` там нет), а для туннелей понятие «несёт линк» и вовсе
/// не определено — у wireguard и tun `operstate` обычно `unknown`. На вопрос
/// «идёт ли через него трафик» отвечает проба маршрута, и отвечает достовернее.
fn is_up(dir: &Path) -> bool {
    read_flags(&dir.join("flags"))
        .map(|f| f & 0x1 != 0)
        .unwrap_or(false)
}

/// Квалификация туннеля по данным ядра. Имя в ней не участвует: «VPN»
/// пользователь напишет на чём угодно, включая Wi-Fi.
fn is_tunnel(dir: &Path) -> bool {
    // Драйвер объявляет себя сам — самый надёжный признак.
    if let Ok(uevent) = std::fs::read_to_string(dir.join("uevent")) {
        for line in uevent.lines() {
            if let Some(devtype) = line.strip_prefix("DEVTYPE=") {
                if matches!(devtype, "wireguard" | "tun" | "vti" | "gre" | "ipip") {
                    return true;
                }
            }
        }
    }

    // TUN/TAP: openvpn и всё, что живёт через /dev/net/tun.
    if dir.join("tun_flags").exists() {
        return true;
    }

    // ARPHRD: NONE у wireguard и tun, отдельные значения у ip-туннелей.
    matches!(
        read_number(&dir.join("type")),
        Some(65534) | Some(768) | Some(769) | Some(776) | Some(778) | Some(823)
    )
}

fn read_number(path: &Path) -> Option<i64> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

fn read_flags(path: &Path) -> Option<u32> {
    let text = std::fs::read_to_string(path).ok()?;
    let trimmed = text.trim();
    let digits = trimmed.strip_prefix("0x").unwrap_or(trimmed);
    u32::from_str_radix(digits, 16).ok()
}
