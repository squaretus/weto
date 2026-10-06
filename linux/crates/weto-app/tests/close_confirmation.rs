//! Подтверждение «Закрыть Weto?» — одно на два входа: кнопку «Закрыть
//! приложение» в «Обслуживании» и пункт «Выход» в трее.
//!
//! Отдельным файлом, потому что отдельным процессом: GTK инициализируется
//! один раз и ровно из одного потока, а раннер пускает тесты параллельно.

use weto_app::settings_window::close_confirmation;

/// Тексты дословно с macOS (`MaintenanceCard.confirmClose`), имя — «Weto».
/// Enter нажимает «Отмена», а не «Закрыть»: Enter по привычке не должен снимать
/// охрану, и на macOS после правки так же. Esc — тоже «Отмена».
#[test]
fn the_close_confirmation_matches_macos_and_defaults_to_cancel() {
    gtk4::init().expect("тесту нужен дисплей: Xvfb не поднят");

    let dialog = close_confirmation();

    assert_eq!(dialog.message(), "Закрыть Weto?");
    assert_eq!(
        dialog.detail(),
        "Приложение завершится и перестанет охранять цели. Настройки, журнал \
         и автозапуск сохранятся: если автозапуск включён, Weto вернётся \
         при следующем входе в систему."
    );
    let buttons: Vec<String> = dialog
        .buttons()
        .iter()
        .map(|title| title.to_string())
        .collect();
    assert_eq!(buttons, vec!["Закрыть".to_string(), "Отмена".to_string()]);
    assert_eq!(dialog.default_button(), 1, "Enter обязан нажимать «Отмена»");
    assert_eq!(dialog.cancel_button(), 1, "Esc обязан нажимать «Отмена»");
    assert!(dialog.is_modal());
}
