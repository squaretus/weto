//! Формулировки для человека: причина завершения, заголовок статуса, тексты
//! журнала.
//!
//! Живёт в ядре, а не в UI: это чистое вычисление из состояния, и тестируется
//! оно синхронно, без единого виджета. Порт `UnsafeReason.displayText`
//! и `StatusPresentation` с macOS — тексты обязаны совпадать на обеих
//! платформах дословно.

use crate::policy::{GuardDecision, UnsafeReason};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShieldState {
    /// Охрана выключена или целей нет.
    Disabled,
    /// Всё сошлось, цели живут.
    Guarded,
    /// Вердикта пока нет: цели завершены до выяснения.
    Pending,
    /// Цели завершены по установленной причине.
    Killed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusPresentation {
    pub title: String,
    pub subtitle: String,
    pub shield: ShieldState,
}

impl UnsafeReason {
    pub fn display_text(&self) -> String {
        match self {
            UnsafeReason::VerificationPending => "Подключение ещё не проверено".to_string(),
            UnsafeReason::VpnNotConfigured => "VPN-сервис не выбран в настройках".to_string(),
            UnsafeReason::VpnDown => "VPN не поднят".to_string(),
            UnsafeReason::VpnNotPrimary => "VPN поднят, но трафик идёт мимо него".to_string(),
            UnsafeReason::GeoUnavailable(detail) => {
                format!("Не удалось определить внешний адрес: {detail}")
            }
            UnsafeReason::BlacklistedIp(ip) => format!("Адрес {ip} в чёрном списке"),
            UnsafeReason::BlockedCountry { code, source } => {
                format!("Обнаружена страна {code} по данным {source}")
            }
            UnsafeReason::ConfirmationUnavailable => {
                "Подтверждающие сервисы недоступны".to_string()
            }
            UnsafeReason::CountryConflict { primary, confirmed } => {
                format!("Расхождение стран: ipinfo — {primary}, подтверждение — {confirmed}")
            }
        }
    }

    /// Заголовок статуса называет отказавший сервис поимённо.
    ///
    /// «Ipinfo недоступен» говорит пользователю, что чинить; «Сервис недоступен»
    /// не говорит ничего. Разница дешёвая, а польза ежедневная.
    pub fn status_title(&self) -> &'static str {
        match self {
            UnsafeReason::VerificationPending => "Проверка подключения",
            UnsafeReason::GeoUnavailable(_) => "Ipinfo недоступен",
            UnsafeReason::ConfirmationUnavailable => "Подтверждение недоступно",
            _ => "Цели завершены",
        }
    }

    /// Отличает «мы ослепли» от «мы точно в плохой стране». Первое —
    /// деградация сервиса, второе — сработавшая защита; выглядеть они должны
    /// по-разному, хотя цели завершаются в обоих случаях.
    pub fn is_degraded_rather_than_blocked(&self) -> bool {
        matches!(
            self,
            UnsafeReason::ConfirmationUnavailable | UnsafeReason::GeoUnavailable(_)
        )
    }
}

/// Состояние охраны в терминах, которые нужны экрану.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuardState {
    pub is_enabled: bool,
    pub has_targets: bool,
    pub decision: GuardDecision,
    /// Страна, которую показываем, даже когда вердикта нет.
    pub country: Option<String>,
}

pub fn status_presentation(state: &GuardState) -> StatusPresentation {
    if !state.is_enabled {
        return StatusPresentation {
            title: "Охрана выключена".to_string(),
            subtitle: "Цели не отслеживаются".to_string(),
            shield: ShieldState::Disabled,
        };
    }

    if !state.has_targets {
        return StatusPresentation {
            title: "Целей нет".to_string(),
            subtitle: "Добавьте приложение или команду".to_string(),
            shield: ShieldState::Disabled,
        };
    }

    match &state.decision {
        GuardDecision::Safe => StatusPresentation {
            title: "На страже".to_string(),
            subtitle: match &state.country {
                Some(country) => format!("Трафик идёт через VPN, страна {country}"),
                None => "Трафик идёт через VPN".to_string(),
            },
            shield: ShieldState::Guarded,
        },
        GuardDecision::Kill(reason) => StatusPresentation {
            title: reason.status_title().to_string(),
            subtitle: reason.display_text(),
            shield: match reason {
                UnsafeReason::VerificationPending => ShieldState::Pending,
                _ => ShieldState::Killed,
            },
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(decision: GuardDecision) -> GuardState {
        GuardState {
            is_enabled: true,
            has_targets: true,
            decision,
            country: Some("NL".to_string()),
        }
    }

    /// Цвет щита никогда не единственный носитель смысла: рядом всегда текст.
    #[test]
    fn every_state_has_words_not_just_a_colour() {
        let guarded = status_presentation(&state(GuardDecision::Safe));
        let killed = status_presentation(&state(GuardDecision::Kill(UnsafeReason::VpnDown)));

        assert_eq!(guarded.title, "На страже");
        assert_eq!(killed.title, "Цели завершены");
        assert!(!guarded.subtitle.is_empty() && !killed.subtitle.is_empty());
    }

    #[test]
    fn the_failing_service_is_named_in_the_title() {
        let presentation = status_presentation(&state(GuardDecision::Kill(
            UnsafeReason::GeoUnavailable("таймаут запроса".into()),
        )));

        assert_eq!(presentation.title, "Ipinfo недоступен");
        assert_ne!(presentation.title, "Сервис недоступен");
        assert!(presentation.subtitle.contains("таймаут запроса"));
    }

    /// Ожидание проверки — не то же, что сработавшая защита: цели завершены
    /// в обоих случаях, но объяснять их надо по-разному.
    #[test]
    fn pending_verification_looks_different_from_a_blocked_country() {
        let pending = status_presentation(&state(GuardDecision::Kill(
            UnsafeReason::VerificationPending,
        )));
        let blocked =
            status_presentation(&state(GuardDecision::Kill(UnsafeReason::BlockedCountry {
                code: "RU".into(),
                source: "ipinfo".into(),
            })));

        assert_eq!(pending.shield, ShieldState::Pending);
        assert_eq!(blocked.shield, ShieldState::Killed);
        assert_eq!(pending.title, "Проверка подключения");
    }

    #[test]
    fn disabled_guard_and_empty_targets_are_told_apart() {
        let disabled = status_presentation(&GuardState {
            is_enabled: false,
            ..state(GuardDecision::Safe)
        });
        let targetless = status_presentation(&GuardState {
            has_targets: false,
            ..state(GuardDecision::Safe)
        });

        assert_eq!(disabled.title, "Охрана выключена");
        assert_eq!(targetless.title, "Целей нет");
        assert_eq!(disabled.shield, ShieldState::Disabled);
    }

    #[test]
    fn degradation_is_told_apart_from_a_working_block() {
        assert!(UnsafeReason::ConfirmationUnavailable.is_degraded_rather_than_blocked());
        assert!(UnsafeReason::GeoUnavailable("x".into()).is_degraded_rather_than_blocked());
        assert!(!UnsafeReason::BlockedCountry {
            code: "RU".into(),
            source: "ipinfo".into()
        }
        .is_degraded_rather_than_blocked());
    }

    #[test]
    fn country_is_shown_when_it_is_known() {
        let with_country = status_presentation(&state(GuardDecision::Safe));
        let without = status_presentation(&GuardState {
            country: None,
            ..state(GuardDecision::Safe)
        });

        assert!(with_country.subtitle.contains("NL"));
        assert_eq!(without.subtitle, "Трафик идёт через VPN");
    }
}
