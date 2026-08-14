//! Автозапуск сессии.
//!
//! XDG autostart, а не systemd user unit: это точный аналог LaunchAgent
//! по смыслу (запуск вместе с сессией пользователя) и работает в окружениях
//! без systemd.
//!
//! Автозапуск живёт ровно одним файлом — правило перенесено с macOS дословно.
//! Там его нарушение приводило к паре расходящихся заданий, которые
//! перезапускали друг друга.

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
}

impl Autostart {
    pub fn new(paths: &Paths) -> Autostart {
        Autostart {
            file: paths.config_dir.parent().map_or_else(
                || PathBuf::from("autostart/weto.desktop"),
                |config| config.join("autostart/weto.desktop"),
            ),
        }
    }

    pub fn rooted(file: PathBuf) -> Autostart {
        Autostart { file }
    }

    pub fn is_enabled(&self) -> bool {
        self.file.exists()
    }

    pub fn enable(&self) -> Result<(), AutostartError> {
        let executable = std::env::current_exe()
            .map_err(|e| AutostartError::Enable(e.to_string()))?
            .to_string_lossy()
            .into_owned();

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
