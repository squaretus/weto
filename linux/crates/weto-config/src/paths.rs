//! Пути XDG.
//!
//! Корень подменяем целиком: контракт установки и тесты работают во временном
//! `$HOME`, и ни один путь не должен просачиваться мимо этой подмены.

use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct Paths {
    pub config_dir: PathBuf,
    pub state_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub data_dir: PathBuf,
    /// Стабильный путь запуска — симлинк, который установщик переставляет
    /// на текущую версию. Каталог `~/.local/bin` берётся буквально, без
    /// XDG-переменной: ровно так его пишет `install.sh` (`BIN="$HOME/.local/bin"`),
    /// и расходиться им нельзя — иначе ярлык и автозапуск ведут в разные места.
    pub launcher: PathBuf,
}

impl Paths {
    /// Из окружения, с уважением к XDG_* и откатом на умолчания спецификации.
    pub fn from_env() -> Paths {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/tmp"));

        Paths {
            config_dir: xdg("XDG_CONFIG_HOME", &home, ".config").join("weto"),
            state_dir: xdg("XDG_STATE_HOME", &home, ".local/state").join("weto"),
            cache_dir: xdg("XDG_CACHE_HOME", &home, ".cache").join("weto"),
            data_dir: xdg("XDG_DATA_HOME", &home, ".local/share").join("weto"),
            launcher: home.join(".local/bin/weto"),
        }
    }

    pub fn rooted(home: PathBuf) -> Paths {
        Paths {
            config_dir: home.join(".config/weto"),
            state_dir: home.join(".local/state/weto"),
            cache_dir: home.join(".cache/weto"),
            data_dir: home.join(".local/share/weto"),
            launcher: home.join(".local/bin/weto"),
        }
    }

    pub fn settings_file(&self) -> PathBuf {
        self.config_dir.join("config.toml")
    }

    pub fn token_file(&self) -> PathBuf {
        self.config_dir.join("token")
    }

    pub fn journal_file(&self) -> PathBuf {
        self.state_dir.join("journal.json")
    }

    /// Журнал проверок подключения — рядом с журналом завершений и отдельным
    /// файлом: это разные вопросы, и одно не должно вытеснять другое.
    pub fn checks_file(&self) -> PathBuf {
        self.state_dir.join("checks.json")
    }

    /// Учёт остановленных процессов. Не журнал, а обязательство: кому weto
    /// послал SIGSTOP и кого обязан вернуть SIGCONT — в том числе после
    /// собственного падения. Путь тот же, что назван каноном.
    pub fn stopped_file(&self) -> PathBuf {
        self.state_dir.join("stopped.json")
    }
}

fn xdg(variable: &str, home: &std::path::Path, fallback: &str) -> PathBuf {
    match std::env::var_os(variable) {
        // Относительный путь в XDG_* спецификация объявляет недействительным.
        Some(value) if PathBuf::from(&value).is_absolute() => PathBuf::from(value),
        _ => home.join(fallback),
    }
}
