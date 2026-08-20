//! Снимок сети сведён к одному вопросу: через кого ядро выпускает вердиктный
//! запрос.
//!
//! Списка интерфейсов здесь больше нет. Он был нужен, пока пользователь выбирал
//! туннель: имена вроде `utun6`/`wg0` шли в список выбора, а квалификация
//! «туннель или нет» решала, кого туда пускать. Выбирается приложение, поэтому
//! от снимка остался только признак свежести вердикта.

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
        }
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
