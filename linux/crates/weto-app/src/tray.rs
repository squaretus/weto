//! Подключение трея к приложению.
//!
//! Трей необязателен: в окружении без него (ванильный GNOME без расширений)
//! регистрация не удастся, и приложение обязано продолжить работу — у него
//! есть второй вход через ярлык и повторный запуск.

use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use gtk4::prelude::*;

use weto_core::presentation::ShieldState;
use weto_tray::TrayEvent;

use crate::state::AppState;

/// Поднимает иконку и подписывает главный цикл на её события.
///
/// Возвращает `false`, если трея в системе нет: это свойство окружения,
/// и говорить о нём стоит один раз в лог, а не диалогом.
pub fn install(app: &gtk4::Application, state: Arc<AppState>) -> bool {
    let (sender, receiver) = mpsc::channel();

    let Some(handle) = weto_tray::service::spawn(sender) else {
        eprintln!("weto: трея в этом окружении нет, работаем через окно и ярлык");
        return false;
    };

    let app = app.clone();
    let mut last: Option<(ShieldState, String)> = None;

    gtk4::glib::timeout_add_local(Duration::from_millis(500), move || {
        pump_events(&receiver, &app, &state);

        // Иконка обновляется только на изменение: каждая правка — сообщение
        // по шине, и слать его дважды в секунду впустую незачем.
        if let Some(presentation) = state.snapshot().presentation {
            let current = (presentation.shield, presentation.title.clone());
            if last.as_ref() != Some(&current) {
                handle.set_status(current.0, &current.1);
                last = Some(current);
            }
        }

        gtk4::glib::ControlFlow::Continue
    });

    true
}

fn pump_events(receiver: &Receiver<TrayEvent>, app: &gtk4::Application, state: &Arc<AppState>) {
    while let Ok(event) = receiver.try_recv() {
        match event {
            TrayEvent::Activate => match app.active_window() {
                Some(window) => window.present(),
                None => crate::status_window::build(app, state.clone()).present(),
            },
            TrayEvent::CheckNow => state.probe_now(),
            TrayEvent::OpenSettings => crate::settings_window::present(app, state.clone()),
            TrayEvent::Quit => app.quit(),
        }
    }
}
