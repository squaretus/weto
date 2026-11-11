//! Удаление Windows-версии — то же обязательство, что на macOS и Linux.
//!
//! Снос идёт деинсталлятором Inno Setup, а он зовёт `Weto.exe --uninstall`
//! до удаления чего-либо. Работающий экземпляр к этому моменту вышел штатно
//! (SIGCONT по учёту отправлен), а здесь обязательство исполняет наблюдение:
//! шесть кругов по 300 мс досылки и перечитывания (`confirm_resumed`), и все
//! ещё стоящие называются пользователю именами и pid. Исходов два, тексты
//! и кнопки общие с другими платформами (`weto_core::presentation`):
//! «Удалить всё равно» и «Не удалять и закрыть Weto». Учёт остановленных
//! (`%LOCALAPPDATA%\weto`) деинсталлятор сносит последним.

use std::time::Duration;

use serde::Serialize;

use weto_config::stopped::StoppedProcess;
use weto_core::presentation::{standing_after_uninstall, uninstall_confirmation, DialogText};

/// Сколько раз удаление переспрашивает про оставшиеся записи учёта и с каким
/// шагом — те же числа, что на macOS (`MaintenanceCard`) и Linux.
pub const RESUME_CONFIRMATIONS: u32 = 6;
pub const RESUME_CONFIRMATION_STEP: Duration = Duration::from_millis(300);

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DialogView {
    pub title: String,
    pub message: String,
    pub confirm: String,
    pub cancel: String,
}

impl From<DialogText> for DialogView {
    fn from(text: DialogText) -> DialogView {
        DialogView {
            title: text.title,
            message: text.message,
            confirm: text.confirm,
            cancel: text.cancel,
        }
    }
}

/// Итог проверки перед сносом: `dialog` — `None`, когда стоящих не осталось
/// и удалять можно молча.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UninstallCheck {
    pub standing: usize,
    pub dialog: Option<DialogView>,
}

/// Подтверждение для кнопки «Удалить приложение…» в окне настроек.
pub fn confirmation() -> DialogView {
    uninstall_confirmation().into()
}

/// Досылает SIGCONT, пока обход не покажет записи идущими, не дольше
/// `RESUME_CONFIRMATIONS` кругов; отдаёт тех, кто так и остался стоять.
pub fn confirm_resumed(
    mut check: impl FnMut() -> Vec<StoppedProcess>,
    mut wait: impl FnMut(Duration),
) -> Vec<StoppedProcess> {
    let mut standing = Vec::new();
    for _ in 0..RESUME_CONFIRMATIONS {
        wait(RESUME_CONFIRMATION_STEP);
        standing = check();
        if standing.is_empty() {
            break;
        }
    }
    standing
}

pub fn check_view(standing: &[StoppedProcess]) -> UninstallCheck {
    let entries: Vec<(String, i32)> = standing
        .iter()
        .map(|entry| (entry.executable_path.clone(), entry.pid))
        .collect();
    UninstallCheck {
        standing: standing.len(),
        dialog: (!standing.is_empty()).then(|| standing_after_uninstall(&entries).into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stopped(pid: i32, path: &str) -> StoppedProcess {
        StoppedProcess {
            pid,
            executable_path: path.to_string(),
            stopped_at: std::time::SystemTime::UNIX_EPOCH,
            is_shell: false,
            target_entry: None,
        }
    }

    /// Поднявшиеся с первой же досылки — дальше не ждём.
    #[test]
    fn resumed_targets_end_the_wait_early() {
        let mut waits = 0;
        let standing = confirm_resumed(Vec::new, |_| waits += 1);
        assert!(standing.is_empty());
        assert_eq!(waits, 1);
    }

    /// Не поднявшиеся за шесть кругов называются, круги не бесконечны.
    #[test]
    fn standing_targets_are_reported_after_six_rounds() {
        let mut checks = 0;
        let standing = confirm_resumed(
            || {
                checks += 1;
                vec![stopped(4242, r"C:\tools\claude.exe")]
            },
            |step| assert_eq!(step, Duration::from_millis(300)),
        );
        assert_eq!(checks, 6);
        assert_eq!(standing.len(), 1);
    }

    #[test]
    fn standing_targets_are_named_with_their_pid() {
        let view = check_view(&[stopped(4242, r"C:\tools\claude.exe")]);
        let dialog = view.dialog.expect("диалога нет");
        assert!(
            dialog.message.contains("claude.exe (pid 4242)"),
            "{}",
            dialog.message
        );
        assert_eq!(view.standing, 1);
    }

    #[test]
    fn nothing_standing_needs_no_dialog() {
        assert_eq!(
            check_view(&[]),
            UninstallCheck {
                standing: 0,
                dialog: None
            }
        );
    }
}
