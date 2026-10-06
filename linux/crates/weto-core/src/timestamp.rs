//! Отметки времени в журнале и выгрузке — строкой ISO 8601 в UTC,
//! а на экране — местным временем (`to_local_display`).
//!
//! `SystemTime` по умолчанию сериализуется объектом `{secs_since_epoch, nanos}`,
//! а macOS пишет `"2026-08-27T13:32:46Z"`. Файл выгрузки читают и человек,
//! и агент, и одному формату у двух реализаций расходиться нельзя: расхождение
//! ловится голден-фикстурой `shared/fixtures/journal-export.json`.
//!
//! Своя арифметика, а не chrono: крейт ядра держит границу «только serde
//! и thiserror», и тянуть зависимость ради одной строки незачем.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Deserializer, Serialize, Serializer};

pub fn to_iso8601(time: SystemTime) -> String {
    let seconds = time
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let days = seconds.div_euclid(86_400);
    let time_of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);

    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        time_of_day / 3600,
        (time_of_day % 3600) / 60,
        time_of_day % 60
    )
}

pub fn from_iso8601(text: &str) -> Option<SystemTime> {
    let bytes = text.as_bytes();
    if bytes.len() < 20 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' {
        return None;
    }

    let number = |from: usize, to: usize| text.get(from..to)?.parse::<i64>().ok();
    let year = number(0, 4)?;
    let month = number(5, 7)?;
    let day = number(8, 10)?;
    let hour = number(11, 13)?;
    let minute = number(14, 16)?;
    let second = number(17, 19)?;

    let seconds = days_from_civil(year, month as u32, day as u32) * 86_400
        + hour * 3600
        + minute * 60
        + second;
    if seconds < 0 {
        return None;
    }
    Some(UNIX_EPOCH + Duration::from_secs(seconds as u64))
}

/// Отметка для глаз — `dd.MM.yyyy HH:mm:ss`, как `JournalRow` на macOS.
///
/// Время местное, но пояс сюда приходит готовым смещением: ядро не знает
/// о системе, а смещение берётся на тот момент, который печатается, —
/// запись, сделанная до перевода часов, иначе показывала бы чужой час.
pub fn to_local_display(time: SystemTime, utc_offset_seconds: i64) -> String {
    let seconds = time
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
        + utc_offset_seconds;

    let days = seconds.div_euclid(86_400);
    let time_of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);

    format!(
        "{day:02}.{month:02}.{year:04} {:02}:{:02}:{:02}",
        time_of_day / 3600,
        (time_of_day % 3600) / 60,
        time_of_day % 60
    )
}

/// Григорианская дата из числа дней с эпохи — алгоритм Хиннанта.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Обратное преобразование — тот же алгоритм в другую сторону.
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = if month > 2 { month - 3 } else { month + 9 } as i64;
    let doy = (153 * mp + 2) / 5 + day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// `#[serde(with = "weto_core::timestamp::iso8601")]`
pub mod iso8601 {
    use super::*;

    pub fn serialize<S: Serializer>(time: &SystemTime, serializer: S) -> Result<S::Ok, S::Error> {
        to_iso8601(*time).serialize(serializer)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<SystemTime, D::Error> {
        let text = String::deserialize(deserializer)?;
        from_iso8601(&text)
            .ok_or_else(|| serde::de::Error::custom(format!("непонятная отметка времени: {text}")))
    }
}

/// То же для необязательного поля.
pub mod iso8601_option {
    use super::*;

    pub fn serialize<S: Serializer>(
        time: &Option<SystemTime>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        match time {
            Some(time) => to_iso8601(*time).serialize(serializer),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Option<SystemTime>, D::Error> {
        let text = Option::<String>::deserialize(deserializer)?;
        match text {
            None => Ok(None),
            Some(text) => from_iso8601(&text).map(Some).ok_or_else(|| {
                serde::de::Error::custom(format!("непонятная отметка времени: {text}"))
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Формат — `dd.MM.yyyy HH:mm:ss` из `JournalRow` на macOS, в местном времени.
    #[test]
    fn local_display_reads_as_on_macos() {
        let at = from_iso8601("2026-10-06T11:03:09Z").unwrap();

        assert_eq!(to_local_display(at, 3 * 3600), "06.10.2026 14:03:09");
        assert_eq!(to_local_display(at, 0), "06.10.2026 11:03:09");
    }

    /// Смещение переносит дату, а не только часы: запись за полночь по UTC
    /// в западном поясе ещё вчерашняя.
    #[test]
    fn local_display_moves_the_date_with_the_offset() {
        let at = from_iso8601("2026-01-01T01:30:00Z").unwrap();

        assert_eq!(to_local_display(at, -5 * 3600), "31.12.2025 20:30:00");
    }
}
