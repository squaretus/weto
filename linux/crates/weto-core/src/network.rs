//! Снимок сети и статус выбранного туннеля.
//!
//! На macOS охрана выбирает *сетевой сервис* по UUID и проверяет, что он поднят
//! и держит маршрут по умолчанию. В ядре Linux понятия «сетевой сервис» нет —
//! эквивалент здесь интерфейс, и его имя же служит стабильным идентификатором.
//!
//! Что именно считать туннелем, решает граница системы (`weto-sys`), а не этот
//! модуль: признак приходит уже вычисленным. Причина та же, что на macOS —
//! выводить туннель из имени нельзя, «VPN» пользователь напишет на чём угодно.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetworkInterfaceSnapshot {
    pub name: String,
    pub index: u32,
    /// IFF_UP и IFF_RUNNING одновременно: поднятый, но не несущий линк
    /// интерфейс охрану не устраивает.
    pub is_up: bool,
    pub is_tunnel: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetworkSnapshot {
    pub interfaces: Vec<NetworkInterfaceSnapshot>,
    /// Интерфейс, через который уходит маршрут по умолчанию с наименьшей метрикой.
    pub default_route_interface: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum VpnStatus {
    NotConfigured,
    Down,
    #[serde(rename_all = "camelCase")]
    Up {
        is_primary: bool,
    },
}

impl NetworkSnapshot {
    /// Отпечаток снимка: меняется, как только меняется состав интерфейсов,
    /// их состояние, квалификация или владелец маршрута по умолчанию.
    ///
    /// По нему видно, устарел ли прежний сетевой вердикт. Сравнивать снимки
    /// целиком на горячем пути дороже, а нужен именно дешёвый признак свежести.
    pub fn fingerprint(&self) -> String {
        let mut parts: Vec<String> = self
            .interfaces
            .iter()
            .map(|i| {
                format!(
                    "{}:{}:{}",
                    i.name,
                    if i.is_up { "up" } else { "down" },
                    if i.is_tunnel { "vpn" } else { "net" }
                )
            })
            .collect();
        parts.sort();
        parts.push(format!(
            "primary={}",
            self.default_route_interface.as_deref().unwrap_or("-")
        ));
        parts.join("|")
    }

    /// Кандидаты в VPN — только туннели, отсортированные по имени.
    pub fn vpn_candidates(&self) -> Vec<&NetworkInterfaceSnapshot> {
        let mut candidates: Vec<&NetworkInterfaceSnapshot> =
            self.interfaces.iter().filter(|i| i.is_tunnel).collect();
        candidates.sort_by(|a, b| a.name.cmp(&b.name));
        candidates
    }

    pub fn interface(&self, name: &str) -> Option<&NetworkInterfaceSnapshot> {
        self.interfaces.iter().find(|i| i.name == name)
    }
}

/// Статус выбранного туннеля.
///
/// Незнакомое имя — `Down`, а не «неизвестно»: тот же выбор, что на macOS,
/// и он fail-closed. Интерфейс, потерявший квалификацию туннеля (или вписанный
/// в настройки руками), тоже `Down` — иначе Ethernet сойдёт за VPN.
pub fn resolve_vpn_status(snapshot: &NetworkSnapshot, chosen: Option<&str>) -> VpnStatus {
    let Some(name) = chosen else {
        return VpnStatus::NotConfigured;
    };

    let Some(interface) = snapshot.interface(name) else {
        return VpnStatus::Down;
    };

    if !interface.is_tunnel || !interface.is_up {
        return VpnStatus::Down;
    }

    VpnStatus::Up {
        is_primary: snapshot.default_route_interface.as_deref() == Some(name),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(interfaces: &[(&str, bool, bool)], default_route: Option<&str>) -> NetworkSnapshot {
        NetworkSnapshot {
            interfaces: interfaces
                .iter()
                .enumerate()
                .map(
                    |(index, (name, is_up, is_tunnel))| NetworkInterfaceSnapshot {
                        name: (*name).to_string(),
                        index: index as u32 + 1,
                        is_up: *is_up,
                        is_tunnel: *is_tunnel,
                    },
                )
                .collect(),
            default_route_interface: default_route.map(str::to_string),
        }
    }

    #[test]
    fn unknown_interface_is_treated_as_down() {
        let s = snapshot(&[("eth0", true, false)], Some("eth0"));
        assert_eq!(resolve_vpn_status(&s, Some("wg0")), VpnStatus::Down);
    }

    #[test]
    fn interface_that_is_not_a_tunnel_is_never_up() {
        let s = snapshot(&[("eth0", true, false)], Some("eth0"));
        assert_eq!(resolve_vpn_status(&s, Some("eth0")), VpnStatus::Down);
    }

    #[test]
    fn tunnel_without_the_default_route_is_not_primary() {
        let s = snapshot(&[("wg0", true, true), ("eth0", true, false)], Some("eth0"));
        assert_eq!(
            resolve_vpn_status(&s, Some("wg0")),
            VpnStatus::Up { is_primary: false }
        );
    }

    #[test]
    fn tunnel_holding_the_default_route_is_primary() {
        let s = snapshot(&[("wg0", true, true)], Some("wg0"));
        assert_eq!(
            resolve_vpn_status(&s, Some("wg0")),
            VpnStatus::Up { is_primary: true }
        );
    }

    #[test]
    fn downed_tunnel_is_down_even_while_it_still_owns_the_route() {
        let s = snapshot(&[("wg0", false, true)], Some("wg0"));
        assert_eq!(resolve_vpn_status(&s, Some("wg0")), VpnStatus::Down);
    }

    #[test]
    fn without_a_choice_the_status_is_not_configured() {
        let s = snapshot(&[("wg0", true, true)], Some("wg0"));
        assert_eq!(resolve_vpn_status(&s, None), VpnStatus::NotConfigured);
    }

    #[test]
    fn fingerprint_changes_when_the_route_owner_changes() {
        let a = snapshot(&[("wg0", true, true), ("eth0", true, false)], Some("wg0"));
        let b = snapshot(&[("wg0", true, true), ("eth0", true, false)], Some("eth0"));
        assert_ne!(a.fingerprint(), b.fingerprint());
    }

    #[test]
    fn fingerprint_changes_when_a_tunnel_goes_down() {
        let a = snapshot(&[("wg0", true, true)], Some("wg0"));
        let b = snapshot(&[("wg0", false, true)], Some("wg0"));
        assert_ne!(a.fingerprint(), b.fingerprint());
    }

    #[test]
    fn fingerprint_ignores_the_order_of_interfaces() {
        let a = snapshot(&[("wg0", true, true), ("eth0", true, false)], Some("wg0"));
        let b = snapshot(&[("eth0", true, false), ("wg0", true, true)], Some("wg0"));
        assert_eq!(a.fingerprint(), b.fingerprint());
    }

    #[test]
    fn only_tunnels_are_offered_as_candidates_and_they_are_sorted() {
        let s = snapshot(
            &[
                ("tun0", true, true),
                ("eth0", true, false),
                ("wg0", true, true),
            ],
            None,
        );
        let names: Vec<&str> = s.vpn_candidates().iter().map(|i| i.name.as_str()).collect();
        assert_eq!(names, vec!["tun0", "wg0"]);
    }

    /// Туннель, поднятый впервые, обязан попадать в список сразу — иначе
    /// пользователь не сможет его выбрать в настройках.
    #[test]
    fn a_tunnel_that_is_down_is_still_a_candidate() {
        let s = snapshot(&[("wg0", false, true)], None);
        assert_eq!(s.vpn_candidates().len(), 1);
    }
}
