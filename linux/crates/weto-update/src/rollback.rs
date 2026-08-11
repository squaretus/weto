//! Откат, если новая версия не стартует.
//!
//! Страховка, которой на macOS нет и не надо: там пакет проверяет установщик
//! системы до применения. Здесь установщик — мы сами, и проверить работоспособность
//! новой версии можно только одним способом — попробовать её запустить.

use std::path::PathBuf;

use crate::layout::Layout;
use crate::version::Version;

/// Двух попыток достаточно: одна может сорваться по случайной причине —
/// не поднялся композитор, не отдалась шина. Две подряд означают, что дело
/// в самой версии.
const ATTEMPT_LIMIT: u32 = 2;

pub struct LaunchMarker {
    file: PathBuf,
}

impl LaunchMarker {
    pub fn new(state_dir: PathBuf) -> LaunchMarker {
        LaunchMarker {
            file: state_dir.join("launch-attempt"),
        }
    }

    fn attempts(&self) -> u32 {
        std::fs::read_to_string(&self.file)
            .ok()
            .and_then(|text| text.trim().parse().ok())
            .unwrap_or(0)
    }

    /// Ставится до создания окон.
    pub fn mark(&self) -> std::io::Result<()> {
        if let Some(parent) = self.file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&self.file, (self.attempts() + 1).to_string())
    }

    /// Снимается, когда интерфейс поднялся: с этого момента версия считается
    /// рабочей.
    pub fn clear(&self) -> std::io::Result<()> {
        match std::fs::remove_file(&self.file) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    }

    pub fn should_roll_back(&self) -> bool {
        self.attempts() >= ATTEMPT_LIMIT
    }
}

/// Возвращает версию, на которую откатились, или `None`, если откат не нужен
/// либо возвращаться некуда.
pub fn roll_back_if_needed(layout: &Layout, marker: &LaunchMarker) -> Option<Version> {
    if !marker.should_roll_back() {
        return None;
    }
    let previous = layout.previous_version()?;
    layout.activate(&previous).ok()?;
    let _ = marker.clear();
    Some(previous)
}
