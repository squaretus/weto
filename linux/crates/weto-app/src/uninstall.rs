//! Удаление приложения по кнопке в настройках.
//!
//! Ничего своего эта кнопка не удаляет: она запускает тот же `uninstall.sh`,
//! что лежит рядом с установленной версией и вызывается из терминала. Иначе
//! путей удаления стало бы два, и разошлись бы они молча.
//!
//! Молчание за успех не выдаётся — как на macOS, где неполное удаление
//! показывают отдельным окном: пользователь иначе считал бы систему чистой,
//! а следы остались бы на диске.

use std::path::PathBuf;

/// Путь к деинсталлятору: `<каталог версии>/share/uninstall.sh`.
/// Исполняемый файл лежит в `<каталог версии>/bin/weto`.
fn script() -> Option<PathBuf> {
    let executable = std::env::current_exe().ok()?;
    let version_dir = executable.parent()?.parent()?;
    let script = version_dir.join("share/uninstall.sh");
    script.is_file().then_some(script)
}

pub fn run() -> Result<(), String> {
    let Some(script) = script() else {
        return Err("не найден деинсталлятор рядом с установленной версией — \
             запустите uninstall.sh вручную"
            .to_string());
    };

    let output = std::process::Command::new("bash")
        .arg(&script)
        .output()
        .map_err(|error| format!("не запустить деинсталлятор: {error}"))?;

    if output.status.success() {
        return Ok(());
    }

    let details = String::from_utf8_lossy(&output.stderr);
    let details = details.trim();
    Err(if details.is_empty() {
        "удаление прошло не полностью".to_string()
    } else {
        format!("удаление прошло не полностью: {details}")
    })
}
