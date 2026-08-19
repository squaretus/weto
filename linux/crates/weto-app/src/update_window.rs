//! Окно обновления: версия, заметки релиза, три ответа.
//!
//! Порт `UpdateKitUI`. Три кнопки — не набор на выбор, а три разных решения:
//! «Обновить» ставит сейчас, «Позже» откладывает разговор, «Пропустить»
//! молчит до версии выше. Четвёртой, снимающей пропуск, нет: его снимает
//! ручная проверка, и этого достаточно.

use std::cell::RefCell;
use std::time::Duration;

use gtk4::prelude::*;
use gtk4::{ApplicationWindow, Box as GtkBox, Orientation, ProgressBar, ScrolledWindow};

use weto_ui::components as ui;
use weto_ui::theme;
use weto_update::policy::UpdateInfo;

use crate::update::{shared, Progress};

thread_local! {
    static WINDOW: RefCell<Option<ApplicationWindow>> = const { RefCell::new(None) };
}

pub fn present(app: &gtk4::Application, info: &UpdateInfo) {
    WINDOW.with(|slot| {
        if let Some(window) = slot.borrow().as_ref() {
            window.present();
            return;
        }
        let window = build(app, info);
        window.present();
        *slot.borrow_mut() = Some(window);
    });
}

fn close() {
    WINDOW.with(|slot| {
        if let Some(window) = slot.borrow_mut().take() {
            window.close();
        }
    });
}

fn build(app: &gtk4::Application, info: &UpdateInfo) -> ApplicationWindow {
    let window = ApplicationWindow::builder()
        .application(app)
        .title("weto — обновление")
        .default_width(ui::POPUP_WIDTH + 60)
        .modal(false)
        .build();
    theme::mark_root(&window);

    window.connect_close_request(|_| {
        WINDOW.with(|slot| *slot.borrow_mut() = None);
        gtk4::glib::Propagation::Proceed
    });

    let panel = ui::panel();
    window.set_child(Some(&panel));

    let card = ui::card("Доступна новая версия");

    let version_row = ui::row(true);
    version_row.append(&ui::label(&format!("weto {}", info.latest_version)));
    let spacer = GtkBox::new(Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    version_row.append(&spacer);
    version_row.append(&ui::value(&format!(
        "установлена {}",
        crate::update::current_version()
    )));
    card.append(&version_row);

    if let Some(notes) = info.release_notes.as_ref().filter(|n| !n.trim().is_empty()) {
        let notes_label = ui::caption(notes.trim());
        notes_label.set_wrap(true);
        notes_label.set_selectable(true);

        let scroll = ScrolledWindow::builder()
            .child(&notes_label)
            .max_content_height(200)
            .propagate_natural_height(true)
            .hscrollbar_policy(gtk4::PolicyType::Never)
            .build();
        card.append(&scroll);
    }

    panel.append(&card);

    // Шкала честна только на загрузке: распаковка быстрая, и притворяться,
    // что мы знаем её ход, незачем.
    let progress = ProgressBar::new();
    progress.set_visible(false);
    panel.append(&progress);

    let status = ui::caption("");
    status.set_visible(false);
    panel.append(&status);

    // Порядок и заполнение ряда — как на macOS: слева отказ от версии, справа
    // главное действие. Ширину делит `action_row`, высоту — общий токен пилюли.
    let actions = ui::action_row();
    let skip = ui::muted_button("Пропустить эту версию");
    let later = ui::muted_button("Позже");
    let update = ui::primary_button("Обновить");
    for button in [&skip, &later, &update] {
        actions.append(button);
    }
    panel.append(&actions);

    {
        let info = info.clone();
        let progress = progress.clone();
        let status = status.clone();
        let actions = actions.clone();
        update.connect_clicked(move |_| {
            let Some(updates) = shared() else { return };
            updates.install(&info);

            actions.set_visible(false);
            progress.set_visible(true);
            status.set_visible(true);
            status.set_text("Скачивание…");

            let progress = progress.clone();
            let status = status.clone();
            gtk4::glib::timeout_add_local(Duration::from_millis(200), move || {
                let Some(updates) = shared() else {
                    return gtk4::glib::ControlFlow::Break;
                };
                match updates.progress() {
                    Progress::Running(fraction) => {
                        progress.set_fraction(fraction as f64);
                        gtk4::glib::ControlFlow::Continue
                    }
                    // Успех не отчитывается словами: приложение перезапускается,
                    // и окно исчезает вместе со старым процессом.
                    Progress::Installed => gtk4::glib::ControlFlow::Break,
                    Progress::Failed(reason) => {
                        progress.set_visible(false);
                        status.set_text(&format!("Не удалось: {reason}"));
                        gtk4::glib::ControlFlow::Break
                    }
                    Progress::Idle => gtk4::glib::ControlFlow::Continue,
                }
            });
        });
    }

    later.connect_clicked(move |_| {
        if let Some(updates) = shared() {
            updates.remind_later();
        }
        close();
    });

    {
        let version = info.latest_version.clone();
        skip.connect_clicked(move |_| {
            if let Some(updates) = shared() {
                updates.skip(&version);
            }
            close();
        });
    }

    window
}
