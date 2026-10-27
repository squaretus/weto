//! Снимок сети сведён к одному вопросу: через кого ядро выпускает вердиктный
//! запрос.
//!
//! Рядом с носителем трафика снимок несёт имена поднятых интерфейсов — только
//! ради VPN-туннеля терминальной версии: на сервере VPN поднимает `wg-quick`
//! или systemd-юнит без всякого приложения, и следить там можно лишь
//! за интерфейсом. В отпечаток вердикта этот список не входит (см.
//! `verdict_fingerprint`): квалификации «туннель или нет» в нём тоже нет —
//! имя называет пользователь.

use serde::{Deserialize, Serialize};

/// Носитель трафика: имя интерфейса и локальный адрес, который ядро выберет
/// источником. Адрес входит в отпечаток вместе с именем — туннель умеет сохранить
/// имя и сменить адрес, и это смена состояния сети.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutgoingRoute {
    pub interface: String,
    pub address: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct NetworkSnapshot {
    pub outgoing: Option<OutgoingRoute>,
    /// Имена интерфейсов, поднятых и несущих связь (`IFF_UP` и `IFF_RUNNING`).
    /// Нужны одному вопросу — жив ли выбранный туннель. В отпечаток не входят:
    /// второй VPN, рвущий связь рядом с рабочим, менял бы его и стоил бы
    /// пользователю целей. Умолчание «пусто» читает данные, записанные до поля.
    #[serde(default)]
    pub up_interfaces: Vec<String>,
}

/// Состояние VPN-приложения — того, что выбрал пользователь.
///
/// Выбирается приложение, а не туннель, потому что вопрос «какой из `utunN` твой»
/// пользователю задать нельзя: имена ничего не значат и меняются при каждом
/// переподключении. Вопрос «какое приложение поднимает тебе VPN» — отвечаемый.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum VpnAppStatus {
    NotChosen,
    NotRunning,
    Running,
}

/// Состояние VPN-туннеля — интерфейса, который пользователь назвал сам.
///
/// Только терминальная версия: на сервере VPN поднимает `wg-quick` или юнит
/// systemd, процесса-приложения нет, а имя интерфейса стабильно — его и пишут
/// в конфигурации. В окне настроек выбор туннеля не появляется: там вопрос
/// «какой из `utunN` твой» пользователю задать нельзя.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum VpnTunnelStatus {
    NotChosen,
    /// Интерфейса нет среди поднятых.
    Down,
    /// Поднят, но ядро выпускает вердиктный запрос через другой интерфейс.
    Bypassed {
        via: String,
    },
    /// Трафик идёт через туннель — или наружу не идёт вовсе, и тогда отвечает гео.
    Carrying,
}

/// Статус туннеля по снимку прохода. Чистая функция: имя приходит из настроек,
/// снимок — от границы, и решает она одна на обеих платформах одинаково.
///
/// Нет носителя вовсе — не «мимо туннеля»: наружу не выходит ничего, утечки нет,
/// и отвечает на это гео (проба не дозовётся, и будет пауза).
pub fn tunnel_status(chosen: Option<&str>, snapshot: &NetworkSnapshot) -> VpnTunnelStatus {
    let Some(tunnel) = chosen else {
        return VpnTunnelStatus::NotChosen;
    };
    if !snapshot.up_interfaces.iter().any(|name| name == tunnel) {
        return VpnTunnelStatus::Down;
    }
    match &snapshot.outgoing {
        Some(route) if route.interface != tunnel => VpnTunnelStatus::Bypassed {
            via: route.interface.clone(),
        },
        _ => VpnTunnelStatus::Carrying,
    }
}

impl NetworkSnapshot {
    /// Отпечаток снимка: по нему видно, устарел ли прежний сетевой вердикт.
    ///
    /// Входит ровно то, от чего вердикт зависит: интерфейс, через который уходит
    /// вердиктный запрос, и его локальный адрес. Чужих интерфейсов в отпечатке нет
    /// вовсе — второй VPN, живущий рядом и переподключающийся сам, маршрут
    /// не забирает, и обесценивать вердикт ему нечем.
    ///
    /// `-` означает «наружу никто не выпускает или адрес гео-сервиса ещё
    /// не разрешён»: состояние, в котором вердикта быть не может.
    pub fn verdict_fingerprint(&self) -> String {
        match &self.outgoing {
            Some(route) => format!("out={}/{}", route.interface, route.address),
            None => "out=-".to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(interface: Option<&str>, address: &str) -> NetworkSnapshot {
        NetworkSnapshot {
            outgoing: interface.map(|name| OutgoingRoute {
                interface: name.to_string(),
                address: address.to_string(),
            }),
            up_interfaces: Vec::new(),
        }
    }

    fn with_up(mut snapshot: NetworkSnapshot, names: &[&str]) -> NetworkSnapshot {
        snapshot.up_interfaces = names.iter().map(|name| name.to_string()).collect();
        snapshot
    }

    /// Список поднятых интерфейсов в отпечаток не входит: второй VPN рядом
    /// с рабочим, поднявшийся или упавший, вердикт обесценивать не вправе.
    #[test]
    fn the_up_interfaces_do_not_enter_the_fingerprint() {
        let base = snapshot(Some("wg0"), "10.7.0.2");
        assert_eq!(
            base.verdict_fingerprint(),
            with_up(base.clone(), &["lo", "eth0", "wg0", "utun9"]).verdict_fingerprint()
        );
    }

    /// Снимок, записанный до поля, читается с пустым списком.
    #[test]
    fn a_snapshot_without_up_interfaces_still_reads() {
        let read: NetworkSnapshot =
            serde_json::from_str(r#"{"outgoing":{"interface":"wg0","address":"10.7.0.2"}}"#)
                .expect("старая форма обязана читаться");
        assert!(read.up_interfaces.is_empty());
    }

    #[test]
    fn no_chosen_tunnel_is_not_chosen() {
        let snap = with_up(snapshot(Some("eth0"), "192.168.1.10"), &["eth0"]);
        assert_eq!(tunnel_status(None, &snap), VpnTunnelStatus::NotChosen);
    }

    #[test]
    fn a_tunnel_missing_from_the_up_interfaces_is_down() {
        let snap = with_up(snapshot(Some("eth0"), "192.168.1.10"), &["lo", "eth0"]);
        assert_eq!(tunnel_status(Some("wg0"), &snap), VpnTunnelStatus::Down);
    }

    /// Поднят, но трафик выпускает другой интерфейс: туннель есть, защиты нет.
    #[test]
    fn a_tunnel_that_is_up_while_traffic_leaves_elsewhere_is_bypassed() {
        let snap = with_up(snapshot(Some("eth0"), "192.168.1.10"), &["eth0", "wg0"]);
        assert_eq!(
            tunnel_status(Some("wg0"), &snap),
            VpnTunnelStatus::Bypassed {
                via: "eth0".to_string()
            }
        );
    }

    #[test]
    fn a_tunnel_carrying_the_traffic_is_carrying() {
        let snap = with_up(snapshot(Some("wg0"), "10.7.0.2"), &["eth0", "wg0"]);
        assert_eq!(tunnel_status(Some("wg0"), &snap), VpnTunnelStatus::Carrying);
    }

    /// Наружу не выпускает никто — утечки нет, отвечает гео.
    #[test]
    fn a_tunnel_up_with_no_outgoing_route_is_carrying() {
        let snap = with_up(snapshot(None, ""), &["wg0"]);
        assert_eq!(tunnel_status(Some("wg0"), &snap), VpnTunnelStatus::Carrying);
    }

    #[test]
    fn the_traffic_moving_to_another_interface_changes_the_fingerprint() {
        assert_ne!(
            snapshot(Some("wg0"), "10.7.0.2").verdict_fingerprint(),
            snapshot(Some("eth0"), "192.168.1.10").verdict_fingerprint()
        );
    }

    /// Туннель умеет переподключиться, сохранив имя интерфейса, и получить другой
    /// адрес. Для вердикта это смена состояния сети.
    #[test]
    fn the_same_interface_with_a_new_address_changes_the_fingerprint() {
        assert_ne!(
            snapshot(Some("wg0"), "10.7.0.2").verdict_fingerprint(),
            snapshot(Some("wg0"), "10.8.0.2").verdict_fingerprint()
        );
    }

    #[test]
    fn no_outgoing_route_is_its_own_state() {
        assert_eq!(snapshot(None, "").verdict_fingerprint(), "out=-");
    }
}
