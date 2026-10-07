//! Ход обновления в фазах — порт `UpdateProgress` из UpdateKitCore.
//!
//! Установщик здесь знает только долю скачанного, а приложение — свой
//! `Progress`; баннер и окно говорят фазами macOS, и перевести одно в другое
//! обязано одно место, а не каждая вёрстка по-своему.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdatePhase {
    Idle,
    Checking,
    Downloading,
    Installing,
    Failed,
}

#[derive(Debug, Clone, PartialEq)]
pub struct UpdateProgress {
    pub phase: UpdatePhase,
    /// Доля скачанного, значима только на загрузке.
    pub fraction: f64,
    pub failure: Option<String>,
}

impl UpdateProgress {
    pub fn new(phase: UpdatePhase, fraction: f64, failure: Option<String>) -> UpdateProgress {
        UpdateProgress {
            phase,
            fraction: fraction.clamp(0.0, 1.0),
            failure,
        }
    }

    pub fn idle() -> UpdateProgress {
        UpdateProgress::new(UpdatePhase::Idle, 0.0, None)
    }

    /// Идёт работа: проверка, загрузка или установка. Пока так, действия
    /// у баннера нет — на его месте индикатор.
    pub fn is_in_flight(&self) -> bool {
        matches!(
            self.phase,
            UpdatePhase::Checking | UpdatePhase::Downloading | UpdatePhase::Installing
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// В полёте — проверка, загрузка и установка: на месте кнопки «Подробнее»
    /// в это время крутится индикатор. Простой и отказ — не полёт.
    #[test]
    fn checking_downloading_and_installing_are_in_flight() {
        assert!(UpdateProgress::new(UpdatePhase::Checking, 0.0, None).is_in_flight());
        assert!(UpdateProgress::new(UpdatePhase::Downloading, 0.4, None).is_in_flight());
        assert!(UpdateProgress::new(UpdatePhase::Installing, 1.0, None).is_in_flight());
        assert!(!UpdateProgress::idle().is_in_flight());
        assert!(
            !UpdateProgress::new(UpdatePhase::Failed, 0.0, Some("нет сети".into())).is_in_flight()
        );
    }

    /// Доля зажимается в [0, 1], как у `UpdateProgress` на macOS: проценты
    /// баннера не уходят ни в минус, ни за сотню.
    #[test]
    fn the_fraction_is_clamped() {
        assert_eq!(
            UpdateProgress::new(UpdatePhase::Downloading, 1.7, None).fraction,
            1.0
        );
        assert_eq!(
            UpdateProgress::new(UpdatePhase::Downloading, -0.2, None).fraction,
            0.0
        );
    }
}
