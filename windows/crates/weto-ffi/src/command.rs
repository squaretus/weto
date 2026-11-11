//! Команды интерфейса: правки настроек и действия, которые C# передаёт мосту.
//!
//! Правки настроек идут тем же путём, что у окна Linux: правка, меняющая
//! решение политики, поднимает ревизию (`SharedSettings::edit`), потолок паузы
//! и тема — нет (`edit_untracked` у потолка; тема решения не меняет, но окно
//! Linux поднимает ревизию и на ней, и расходиться незачем). Отказы — тексты
//! тех же ошибок (`TargetEntryError`, `GeoListEntryError`), что видит
//! пользователь на других платформах.
//!
//! Действия, которым нужна охрана или система (проверка, журнал, автозапуск),
//! исполняет приложение; здесь — только их форма и чистые правки настроек.

use serde::Deserialize;

use weto_config::settings::{GeoListKind, Settings, Target, Theme};
use weto_core::pause_ceiling::PauseCeiling;
use weto_guard::shared_settings::SharedSettings;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(
    tag = "command",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Command {
    ProbeNow,
    AddTarget {
        entry: String,
        display_name: Option<String>,
    },
    RemoveTarget {
        entry: String,
    },
    SetVpnApp {
        entry: String,
        display_name: Option<String>,
    },
    ClearVpnApp,
    AddGeoEntry {
        text: String,
        list: GeoList,
    },
    RemoveGeoEntry {
        entry: String,
        list: GeoList,
    },
    SetPauseCeiling {
        seconds: u64,
    },
    SetTheme {
        theme: ThemeChoice,
    },
    SetToken {
        token: String,
    },
    ClearToken,
    SetAutostart {
        enabled: bool,
    },
    ExportJournal {
        path: String,
    },
    ClearJournal,
    ConfirmResumed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GeoList {
    Blocked,
    Allowed,
}

impl From<GeoList> for GeoListKind {
    fn from(list: GeoList) -> GeoListKind {
        match list {
            GeoList::Blocked => GeoListKind::Blocked,
            GeoList::Allowed => GeoListKind::Allowed,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ThemeChoice {
    Dark,
    Light,
}

impl From<ThemeChoice> for Theme {
    fn from(theme: ThemeChoice) -> Theme {
        match theme {
            ThemeChoice::Dark => Theme::Dark,
            ThemeChoice::Light => Theme::Light,
        }
    }
}

/// Итог правки настроек: `None` — команда не о настройках, её исполняет
/// приложение; `Some(Err(текст))` — отказ, который окно покажет пользователю.
pub type SettingsOutcome = Option<Result<(), String>>;

/// Правка настроек по команде. `build_target` собирает запись цели
/// или VPN-приложения (на Windows — `weto_sys_windows::target_resolver::settings_target_now`),
/// параметром — чтобы тесты не зависели от `PATH` машины.
pub fn apply_to_settings(
    command: &Command,
    settings: &SharedSettings,
    build_target: &dyn Fn(&str, Option<String>) -> Target,
) -> SettingsOutcome {
    let outcome = match command {
        Command::AddTarget {
            entry,
            display_name,
        } => {
            let entry = entry.trim();
            if entry.is_empty() {
                return Some(Ok(()));
            }
            let target = build_target(entry, display_name.clone());
            // Отказ (повтор, само VPN-приложение) проверяется до правки:
            // правки без новой цели не бывает, и ревизия впустую не поднимается.
            if let Err(error) = settings.current().add_target(target.clone()) {
                return Some(Err(error.to_string()));
            }
            settings.edit(|s| {
                let _ = s.add_target(target);
            });
            Ok(())
        }
        Command::RemoveTarget { entry } => {
            settings.edit(|s| s.targets.retain(|t| &t.entry != entry));
            Ok(())
        }
        Command::SetVpnApp {
            entry,
            display_name,
        } => {
            let entry = entry.trim();
            if entry.is_empty() {
                return Some(Ok(()));
            }
            let app = build_target(entry, display_name.clone());
            settings.edit(|s| s.set_vpn_app(Some(app)));
            Ok(())
        }
        Command::ClearVpnApp => {
            settings.edit(|s| s.set_vpn_app(None));
            Ok(())
        }
        Command::AddGeoEntry { text, list } => {
            let kind = GeoListKind::from(*list);
            let mut probe: Settings = settings.current();
            if let Err(error) = probe.add_entry(text, kind) {
                return Some(Err(error.to_string()));
            }
            settings.edit(|s| {
                let _ = s.add_entry(text, kind);
            });
            Ok(())
        }
        Command::RemoveGeoEntry { entry, list } => {
            let kind = GeoListKind::from(*list);
            settings.edit(|s| s.remove_entry(entry, kind));
            Ok(())
        }
        Command::SetPauseCeiling { seconds } => {
            // Только из четырёх вариантов: чужое число стало бы минутой молча
            // (`from_seconds`), и пользователь увидел бы не то, что выбрал.
            if !PauseCeiling::ALL.iter().any(|c| c.seconds() == *seconds) {
                return Some(Err(format!("потолок паузы {seconds} с не предлагается")));
            }
            settings.edit_untracked(|s| s.pause_ceiling_seconds = *seconds);
            Ok(())
        }
        Command::SetTheme { theme } => {
            let theme = Theme::from(*theme);
            settings.edit(|s| s.theme = theme);
            Ok(())
        }
        _ => return None,
    };
    Some(outcome)
}

#[cfg(test)]
mod tests {
    use super::*;
    use weto_config::paths::Paths;
    use weto_core::process::TargetKind;

    fn target(entry: &str, display_name: Option<String>) -> Target {
        Target {
            entry: entry.to_string(),
            display_name: display_name.unwrap_or_else(|| entry.to_string()),
            kind: TargetKind::Binary,
            path: format!(r"C:\tools\{entry}.exe"),
            launch_paths: vec![entry.to_string()],
        }
    }

    fn settings() -> (tempfile::TempDir, std::sync::Arc<SharedSettings>, Paths) {
        let home = tempfile::tempdir().unwrap();
        let paths = Paths::windows_under(&home.path().join("Roaming"), &home.path().join("Local"));
        let settings = SharedSettings::load(&paths);
        (home, settings, paths)
    }

    fn parse(json: &str) -> Command {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn commands_arrive_as_tagged_camel_case_json() {
        assert_eq!(parse(r#"{"command":"probeNow"}"#), Command::ProbeNow);
        assert_eq!(
            parse(r#"{"command":"addTarget","entry":"claude","displayName":null}"#),
            Command::AddTarget {
                entry: "claude".into(),
                display_name: None
            }
        );
        assert_eq!(
            parse(r#"{"command":"addGeoEntry","text":"RU","list":"blocked"}"#),
            Command::AddGeoEntry {
                text: "RU".into(),
                list: GeoList::Blocked
            }
        );
        assert_eq!(
            parse(r#"{"command":"setPauseCeiling","seconds":300}"#),
            Command::SetPauseCeiling { seconds: 300 }
        );
    }

    #[test]
    fn an_added_target_reaches_the_file_and_bumps_the_revision() {
        let (_home, settings, paths) = settings();
        let revision = settings.current().revision;

        let outcome = apply_to_settings(
            &Command::AddTarget {
                entry: " claude ".into(),
                display_name: None,
            },
            &settings,
            &target,
        );

        assert_eq!(outcome, Some(Ok(())));
        assert_eq!(settings.current().revision, revision + 1);
        let saved = Settings::load(&paths.settings_file()).unwrap();
        assert_eq!(saved.targets[0].entry, "claude");
    }

    #[test]
    fn a_repeated_target_is_refused_without_a_revision() {
        let (_home, settings, _paths) = settings();
        let add = Command::AddTarget {
            entry: "claude".into(),
            display_name: None,
        };
        apply_to_settings(&add, &settings, &target);
        let revision = settings.current().revision;

        let outcome = apply_to_settings(&add, &settings, &target);

        assert!(matches!(outcome, Some(Err(_))), "{outcome:?}");
        assert_eq!(settings.current().revision, revision);
    }

    #[test]
    fn a_bad_geo_entry_is_refused_with_the_shared_text() {
        let (_home, settings, _paths) = settings();

        let outcome = apply_to_settings(
            &Command::AddGeoEntry {
                text: "   ".into(),
                list: GeoList::Blocked,
            },
            &settings,
            &target,
        );

        assert_eq!(
            outcome,
            Some(Err("введите код страны, IP-адрес или диапазон".to_string()))
        );
    }

    #[test]
    fn the_pause_ceiling_is_one_of_four_and_keeps_the_revision() {
        let (_home, settings, _paths) = settings();
        let revision = settings.current().revision;

        assert_eq!(
            apply_to_settings(
                &Command::SetPauseCeiling { seconds: 600 },
                &settings,
                &target
            ),
            Some(Ok(()))
        );
        assert_eq!(settings.current().pause_ceiling_seconds, 600);
        assert_eq!(
            settings.current().revision,
            revision,
            "вердикт не обесценивается"
        );
        assert!(matches!(
            apply_to_settings(&Command::SetPauseCeiling { seconds: 7 }, &settings, &target),
            Some(Err(_))
        ));
    }

    #[test]
    fn system_actions_are_left_to_the_app() {
        let (_home, settings, _paths) = settings();

        assert_eq!(
            apply_to_settings(&Command::ProbeNow, &settings, &target),
            None
        );
        assert_eq!(
            apply_to_settings(&Command::SetToken { token: "x".into() }, &settings, &target),
            None
        );
    }
}
