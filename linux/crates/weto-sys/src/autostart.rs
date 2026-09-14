//! Автозапуск сессии.
//!
//! XDG autostart, а не systemd user unit: это точный аналог LaunchAgent
//! по смыслу (запуск вместе с сессией пользователя) и работает в окружениях
//! без systemd.
//!
//! Автозапуск живёт ровно одним файлом — правило перенесено с macOS дословно.
//! Там его нарушение приводило к паре расходящихся заданий, которые
//! перезапускали друг друга.
//!
//! В ярлык едет стабильный путь запуска (`paths.launcher`), а не `current_exe`:
//! на Linux он уже разрешён через `/proc/self/exe` и потому версионный —
//! `~/.local/share/weto/<версия>/bin/weto`. Установщик держит на диске текущую
//! версию и одну предыдущую, так что после первого обновления сессия поднимала
//! бы старую копию, а после второго — ничего вовсе: каталог версии удалён,
//! и защиты после перезагрузки нет. Переписывать ярлык при обновлении некому.
//! Тот же путь пишет в свой ярлык установщик (`Exec=$HOME/.local/bin/weto`),
//! и расходиться этим двум местам нельзя.

use std::path::PathBuf;

use weto_config::paths::Paths;

#[derive(Debug, thiserror::Error)]
pub enum AutostartError {
    #[error("не включить автозапуск: {0}")]
    Enable(String),
    #[error("не выключить автозапуск: {0}")]
    Disable(String),
}

pub struct Autostart {
    file: PathBuf,
    executable: PathBuf,
}

impl Autostart {
    pub fn new(paths: &Paths) -> Autostart {
        Autostart {
            file: paths.config_dir.parent().map_or_else(
                || PathBuf::from("autostart/weto.desktop"),
                |config| config.join("autostart/weto.desktop"),
            ),
            executable: paths.launcher.clone(),
        }
    }

    /// Для тестов: и файл ярлыка, и путь запуска задаются напрямую.
    pub fn rooted(file: PathBuf, executable: PathBuf) -> Autostart {
        Autostart { file, executable }
    }

    pub fn is_enabled(&self) -> bool {
        self.file.exists()
    }

    pub fn enable(&self) -> Result<(), AutostartError> {
        let executable = self.executable.to_string_lossy().into_owned();

        if let Some(parent) = self.file.parent() {
            std::fs::create_dir_all(parent).map_err(|e| AutostartError::Enable(e.to_string()))?;
        }

        let entry = format!(
            "[Desktop Entry]\n\
             Type=Application\n\
             Name=weto\n\
             Comment=Завершает цели, когда трафик идёт мимо VPN\n\
             Exec={executable}\n\
             Icon=weto\n\
             Terminal=false\n\
             X-GNOME-Autostart-enabled=true\n"
        );

        std::fs::write(&self.file, entry).map_err(|e| AutostartError::Enable(e.to_string()))
    }

    pub fn disable(&self) -> Result<(), AutostartError> {
        match std::fs::remove_file(&self.file) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(AutostartError::Disable(error.to_string())),
        }
    }
}
