//! Уведомление о завершении целей.
//!
//! Порт `KillNotifying` с macOS. Отправляется через `notify-send`, а не через
//! собственный клиент D-Bus: утилита есть в любом рабочем окружении, входит
//! в тот же пакет, что и остальная поддержка уведомлений, и её отсутствие
//! означает, что уведомлений в системе нет вовсе — молчать в этом случае
//! правильнее, чем падать.

pub trait KillNotifying: Send + Sync {
    fn notify(&self, target_names: &[String], reason: &str);
}

pub struct PortalNotifier;

impl PortalNotifier {
    pub fn new() -> PortalNotifier {
        PortalNotifier
    }
}

impl Default for PortalNotifier {
    fn default() -> Self {
        Self::new()
    }
}

impl KillNotifying for PortalNotifier {
    fn notify(&self, target_names: &[String], reason: &str) {
        let targets = if target_names.is_empty() {
            "неизвестная цель".to_string()
        } else {
            target_names.join(", ")
        };

        // Ошибка запуска игнорируется намеренно: уведомление — приятное
        // дополнение, а не часть защиты. Цели уже завершены к этому моменту.
        let _ = std::process::Command::new("notify-send")
            .arg("--app-name=weto")
            .arg("--icon=security-high")
            .arg(format!("Завершено: {targets}"))
            .arg(reason)
            .spawn();
    }
}
