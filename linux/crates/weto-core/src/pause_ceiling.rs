//! Потолок паузы — сколько цели могут стоять, ожидая подтверждения, до завершения
//! с уликой «подтверждение не получено». Порт `PauseCeiling` из macOS: четыре
//! значения, умолчание — минута, с которой жили установки до появления выбора.

use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PauseCeiling {
    #[default]
    OneMinute,
    TwoMinutes,
    FiveMinutes,
    TenMinutes,
}

impl PauseCeiling {
    /// Порядок — порядок сегментов в настройках.
    pub const ALL: [PauseCeiling; 4] = [
        PauseCeiling::OneMinute,
        PauseCeiling::TwoMinutes,
        PauseCeiling::FiveMinutes,
        PauseCeiling::TenMinutes,
    ];

    pub fn seconds(self) -> u64 {
        match self {
            PauseCeiling::OneMinute => 60,
            PauseCeiling::TwoMinutes => 120,
            PauseCeiling::FiveMinutes => 300,
            PauseCeiling::TenMinutes => 600,
        }
    }

    pub fn duration(self) -> Duration {
        Duration::from_secs(self.seconds())
    }

    /// Подпись сегмента в настройках.
    pub fn title(self) -> String {
        duration_text(self.duration())
    }

    /// Незнакомое значение — чужая версия или ручная правка TOML — читается как
    /// минута: охрана без потолка не работает, а выдумывать другой нельзя.
    pub fn from_seconds(seconds: u64) -> PauseCeiling {
        PauseCeiling::ALL
            .into_iter()
            .find(|ceiling| ceiling.seconds() == seconds)
            .unwrap_or_default()
    }
}

/// «5 мин» для целых минут, «90 с» для остального. Тот же текст, что
/// `PauseCeiling.durationText` на macOS.
pub fn duration_text(duration: Duration) -> String {
    let whole = duration.as_secs();
    if whole >= 60 && whole % 60 == 0 {
        format!("{} мин", whole / 60)
    } else {
        format!("{whole} с")
    }
}

/// Отсчёт до потолка: больше минуты — «4:59», последняя минута — «43 с».
/// Секунды приходят уже округлёнными вверх. Порт `WetoPauseBadge.remainingText`.
pub fn countdown_text(seconds: u64) -> String {
    if seconds > 60 {
        format!("{}:{:02}", seconds / 60, seconds % 60)
    } else {
        format!("{seconds} с")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_choices_are_one_two_five_and_ten_minutes_in_that_order() {
        let seconds: Vec<u64> = PauseCeiling::ALL.iter().map(|c| c.seconds()).collect();
        assert_eq!(seconds, vec![60, 120, 300, 600]);
        let titles: Vec<String> = PauseCeiling::ALL.iter().map(|c| c.title()).collect();
        assert_eq!(titles, vec!["1 мин", "2 мин", "5 мин", "10 мин"]);
    }

    /// Установка, жившая с жёсткой минутой, обязана открыться с ней же.
    #[test]
    fn an_unknown_value_falls_back_to_one_minute() {
        assert_eq!(PauseCeiling::default(), PauseCeiling::OneMinute);
        assert_eq!(PauseCeiling::from_seconds(90), PauseCeiling::OneMinute);
        assert_eq!(PauseCeiling::from_seconds(0), PauseCeiling::OneMinute);
        assert_eq!(PauseCeiling::from_seconds(300), PauseCeiling::FiveMinutes);
    }

    #[test]
    fn duration_text_names_whole_minutes_and_falls_back_to_seconds() {
        assert_eq!(duration_text(Duration::from_secs(60)), "1 мин");
        assert_eq!(duration_text(Duration::from_secs(600)), "10 мин");
        assert_eq!(duration_text(Duration::from_secs(90)), "90 с");
        assert_eq!(duration_text(Duration::from_secs(30)), "30 с");
    }

    /// Больше минуты — минуты и секунды: «599 с» не читается.
    #[test]
    fn countdown_switches_to_minutes_above_one_minute() {
        assert_eq!(countdown_text(600), "10:00");
        assert_eq!(countdown_text(299), "4:59");
        assert_eq!(countdown_text(61), "1:01");
        assert_eq!(countdown_text(60), "60 с");
        assert_eq!(countdown_text(0), "0 с");
    }
}
