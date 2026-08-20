//! Политика охраны: единственное место, где решается судьба целей.
//!
//! Порт `GuardPolicy` из macOS-версии. Порядок проверок здесь задаёт сразу две
//! вещи — приоритет причины, которую увидит пользователь, и экономию запросов
//! в сеть. Менять его нельзя, не поменяв фикстуры в `shared/fixtures/`, а значит
//! и поведение обеих платформ разом. Так и задумано.

use std::collections::HashSet;

use crate::geo::GeoOutcome;
use crate::ip::IpRange;
use crate::network::VpnStatus;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuardConfig {
    /// Идентификатор выбранного VPN: имя интерфейса на Linux, UUID сервиса
    /// на macOS. Для политики это непрозрачная строка.
    pub vpn_id: Option<String>,
    pub blocked_countries: HashSet<String>,
    pub blocked_ip_ranges: Vec<IpRange>,
    pub targets: Vec<String>,
}

impl GuardConfig {
    pub fn has_targets(&self) -> bool {
        !self.targets.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuardSignals {
    pub is_enabled: bool,
    pub vpn: VpnStatus,
    pub geo: GeoOutcome,
    pub config: GuardConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnsafeReason {
    VerificationPending,
    VpnNotConfigured,
    VpnDown,
    VpnNotPrimary,
    GeoUnavailable(String),
    BlacklistedIp(String),
    BlockedCountry { code: String, source: String },
    ConfirmationUnavailable,
    CountryConflict { primary: String, confirmed: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GuardDecision {
    Safe,
    Kill(UnsafeReason),
}

/// Решение на время, пока локальные основания исчерпаны, а свежего гео-вердикта
/// ещё нет.
///
/// Это окно обязано быть fail-closed: иначе цели живут все секунды, что идёт
/// запрос к ipinfo и подтверждающим сервисам.
pub fn pending_verification(is_enabled: bool, config: &GuardConfig) -> GuardDecision {
    if !is_enabled || !config.has_targets() {
        return GuardDecision::Safe;
    }
    GuardDecision::Kill(UnsafeReason::VerificationPending)
}

/// Основания, видные без обращения в сеть.
///
/// `None` означает «локальных оснований нет, нужен сетевой вердикт». Падение
/// туннеля видно из netlink мгновенно, поэтому в сеть идём только тогда, когда
/// здесь ничего не нашлось.
pub fn decide_local(
    is_enabled: bool,
    vpn: VpnStatus,
    config: &GuardConfig,
) -> Option<GuardDecision> {
    if !is_enabled || !config.has_targets() {
        return Some(GuardDecision::Safe);
    }
    if config.vpn_id.is_none() {
        return Some(GuardDecision::Kill(UnsafeReason::VpnNotConfigured));
    }

    match vpn {
        VpnStatus::NotConfigured => Some(GuardDecision::Kill(UnsafeReason::VpnNotConfigured)),
        VpnStatus::Down => Some(GuardDecision::Kill(UnsafeReason::VpnDown)),
        VpnStatus::Up { is_primary } => {
            if is_primary {
                None
            } else {
                Some(GuardDecision::Kill(UnsafeReason::VpnNotPrimary))
            }
        }
    }
}

pub fn decide(signals: &GuardSignals) -> GuardDecision {
    if let Some(local) = decide_local(signals.is_enabled, signals.vpn, &signals.config) {
        return local;
    }

    let Some(reading) = signals.geo.reading() else {
        let detail = match &signals.geo {
            GeoOutcome::Unavailable(detail) => detail.clone(),
            GeoOutcome::Resolved(_) | GeoOutcome::Degraded { .. } => unreachable!(),
        };
        return GuardDecision::Kill(UnsafeReason::GeoUnavailable(detail));
    };

    if signals
        .config
        .blocked_ip_ranges
        .iter()
        .any(|range| range.contains(&reading.ip))
    {
        return GuardDecision::Kill(UnsafeReason::BlacklistedIp(reading.ip.clone()));
    }

    let blocked: HashSet<String> = signals
        .config
        .blocked_countries
        .iter()
        .map(|c| c.to_uppercase())
        .collect();
    let primary = reading.primary_country.to_uppercase();

    if blocked.contains(&primary) {
        return GuardDecision::Kill(UnsafeReason::BlockedCountry {
            code: primary,
            source: "ipinfo".to_string(),
        });
    }

    // Fail-closed строгий: отсутствие подтверждения завершает цели, даже когда
    // ipinfo уверенно назвал безопасную страну. Осознанное решение владельца.
    let Some(confirmed_raw) = &reading.confirmed_country else {
        return GuardDecision::Kill(UnsafeReason::ConfirmationUnavailable);
    };
    let confirmed = confirmed_raw.to_uppercase();

    if blocked.contains(&confirmed) {
        return GuardDecision::Kill(UnsafeReason::BlockedCountry {
            code: confirmed,
            source: reading
                .confirm_source
                .map(|s| s.name().to_string())
                .unwrap_or_else(|| "confirm".to_string()),
        });
    }

    if primary != confirmed {
        return GuardDecision::Kill(UnsafeReason::CountryConflict { primary, confirmed });
    }

    GuardDecision::Safe
}
