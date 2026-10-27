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

/// Имя каталога приложения с окном.
pub const APP_DIR: &str = "weto";

/// Имя каталога терминальной версии. Хранилище у неё своё целиком: окно
/// никогда не видит туннеля, а две установки не путают учёт остановленных.
pub const CLI_DIR: &str = "weto-cli";

impl Paths {
    /// Из окружения, с уважением к XDG_* и откатом на умолчания спецификации.
    pub fn from_env() -> Paths {
        Paths::from_env_named(APP_DIR)
    }

    /// То же для другого имени каталога: `weto` — приложение, `weto-cli` —
    /// терминальная версия. Переменные XDG уважаются одинаково.
    pub fn from_env_named(dir: &str) -> Paths {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/tmp"));

        Paths {
            config_dir: xdg("XDG_CONFIG_HOME", &home, ".config").join(dir),
            state_dir: xdg("XDG_STATE_HOME", &home, ".local/state").join(dir),
            cache_dir: xdg("XDG_CACHE_HOME", &home, ".cache").join(dir),
            data_dir: xdg("XDG_DATA_HOME", &home, ".local/share").join(dir),
            launcher: home.join(".local/bin").join(dir),
        }
    }

    /// Системное хранилище терминальной версии, запущенной от root: настройки
    /// и токен — `/etc/weto`, журналы, учёт и статус — `/var/lib/weto`.
    ///
    /// Выбирается эффективным uid, а не `$HOME`: `sudo` сохраняет `HOME`
    /// по-разному в разных дистрибутивах, а systemd не задаёт его вовсе —
    /// команда и охрана под юнитом обязаны прийти в одно и то же место.
    pub fn system() -> Paths {
        Paths::system_under(std::path::Path::new("/"))
    }

    /// То же под другим корнем — для тестов: системные каталоги настоящей
    /// машины тест не трогает.
    pub fn system_under(root: &std::path::Path) -> Paths {
        Paths {
            config_dir: root.join("etc").join(APP_DIR),
            state_dir: root.join("var/lib").join(APP_DIR),
            cache_dir: root.join("var/cache").join(APP_DIR),
            data_dir: root.join("var/lib").join(APP_DIR),
            launcher: root.join("usr/local/bin").join(APP_DIR),
        }
    }

    pub fn rooted(home: PathBuf) -> Paths {
        Paths::rooted_named(home, APP_DIR)
    }

    pub fn rooted_named(home: PathBuf, dir: &str) -> Paths {
        Paths {
            config_dir: home.join(".config").join(dir),
            state_dir: home.join(".local/state").join(dir),
            cache_dir: home.join(".cache").join(dir),
            data_dir: home.join(".local/share").join(dir),
            launcher: home.join(".local/bin").join(dir),
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

    /// Файл статуса терминальной версии: работающая охрана пишет его раз
    /// в секунду, `weto status` читает. У приложения его нет — там статус
    /// показывает окно.
    pub fn status_file(&self) -> PathBuf {
        self.state_dir.join("status.json")
    }

    /// Замок единственного экземпляра охраны терминальной версии (`flock`).
    pub fn run_lock_file(&self) -> PathBuf {
        self.state_dir.join("run.lock")
    }
}

fn xdg(variable: &str, home: &std::path::Path, fallback: &str) -> PathBuf {
    match std::env::var_os(variable) {
        // Относительный путь в XDG_* спецификация объявляет недействительным.
        Some(value) if PathBuf::from(&value).is_absolute() => PathBuf::from(value),
        _ => home.join(fallback),
    }
}
