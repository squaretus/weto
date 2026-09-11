//! Уведомление о завершении целей.
//!
//! Порт `KillNotifying` с macOS. Отправляется через `notify-send`, а не через
//! собственный клиент D-Bus: утилита есть в любом рабочем окружении, входит
//! в тот же пакет, что и остальная поддержка уведомлений, и её отсутствие
//! означает, что уведомлений в системе нет вовсе — молчать в этом случае
//! правильнее, чем падать.

pub trait KillNotifying: Send + Sync {
    fn notify(&self, target_names: &[String], reason: &str);

    /// Терминальная цель под паузой потеряла терминал: её задание перестало
    /// быть передним, и без уведомления пропажу процесса из терминала
    /// не заметить вовсе. Порт macOS `GuardNotifying.notifyBackgrounded`.
    fn notify_backgrounded(&self, target_name: &str);
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

    fn notify_backgrounded(&self, target_name: &str) {
        // Тот же путь, тот же приятный-но-необязательный характер: ошибка
        // запуска `notify-send` не блокирует ничего, весь смысл сообщения —
        // вернуть пользователю процесс, который сам по себе не пропал.
        let _ = std::process::Command::new("notify-send")
            .arg("--app-name=weto")
            .arg("--icon=security-high")
            .arg(format!("Weto: {target_name} вернулся в фон"))
            .arg("Процесс на паузе потерял терминал. Откройте терминал и введите fg.")
            .spawn();
    }
}
