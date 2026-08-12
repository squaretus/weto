//! Окно статуса — порт попапа менюбара.
//!
//! На macOS это попап, привязанный к иконке. Здесь — обычное окно, и это
//! вынужденное отступление: протокол StatusNotifierItem не сообщает координат
//! иконки, а Wayland не позволяет окну позиционировать себя самому. Обойти
//! это нечем, кроме отказа от Wayland.
//!
//! Состав повторяет `StatusPopupView` построчно: шапка со щитом, заголовком
//! и двумя иконками, показания гео, баннер обновления и живые цели. Карточек
//! и крупных кнопок в попапе нет — управление живёт в окне настроек.

use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::{Align, ApplicationWindow, Box as GtkBox, Orientation};

use weto_core::presentation::{self, ShieldState};
use weto_ui::components as ui;
use weto_ui::theme;

use crate::state::AppState;

pub fn build(app: &gtk4::Application, state: Arc<AppState>) -> ApplicationWindow {
    let window = ApplicationWindow::builder()
        .application(app)
        .title("weto")
        .default_width(ui::POPUP_WIDTH)
        .resizable(false)
        .build();
    theme::mark_root(&window);

    let panel = ui::panel();
    panel.set_spacing(ui::SPACE4);
    window.set_child(Some(&panel));

    // --- Шапка: щит, заголовок, проверка, настройки ---
    let header = GtkBox::new(Orientation::Horizontal, ui::SPACE3);
    let shield_holder = GtkBox::new(Orientation::Horizontal, 0);
    let title = ui::status_title("…", ShieldState::Pending);
    title.set_hexpand(true);
    header.append(&shield_holder);
    header.append(&title);

    // Пока проба в полёте, на месте кнопки крутится индикатор: повторное нажатие
    // запроса не порождает — у подтверждающего сервиса лимит.
    let spinner = gtk4::Spinner::new();
    spinner.set_size_request(22, 22);
    spinner.set_visible(false);
    header.append(&spinner);

    let recheck = ui::icon_button("view-refresh-symbolic");
    recheck.set_tooltip_text(Some("Проверить сейчас"));
    header.append(&recheck);

    let settings_button = ui::icon_button("emblem-system-symbolic");
    settings_button.set_tooltip_text(Some("Настройки"));
    header.append(&settings_button);
    panel.append(&header);

    // --- Показания гео ---
    let readout = GtkBox::new(Orientation::Vertical, 2);
    panel.append(&readout);

    // Баннер обновления стоит после показаний и появляется только тогда, когда
    // политика решила показать находку. Тихий исход прячет и его, и окно.
    let banner_slot = GtkBox::new(Orientation::Vertical, 0);
    panel.append(&banner_slot);

    // --- Живые цели: показываются, только когда цели вообще заданы ---
    let targets_slot = GtkBox::new(Orientation::Vertical, ui::SPACE4);
    panel.append(&targets_slot);

    {
        let state = state.clone();
        recheck.connect_clicked(move |_| state.probe_now());
    }
    {
        let app = app.clone();
        let state = state.clone();
        settings_button.connect_clicked(move |_| {
            crate::settings_window::present(&app, state.clone());
        });
    }

    let mut refresh = {
        let state = state.clone();
        let app = app.clone();
        let banner_slot = banner_slot.clone();
        let mut shown_version: Option<String> = None;
        move || {
            let snapshot = state.snapshot();

            let pending = crate::update::shared().and_then(|updates| updates.pending());
            let pending_version = pending.as_ref().map(|info| info.latest_version.clone());
            if pending_version != shown_version {
                clear(&banner_slot);
                if let Some(info) = pending.clone() {
                    let (banner, action) = ui::banner(
                        ui::BannerTone::News,
                        &format!("Доступно обновление {}", info.latest_version),
                        Some("Подробнее"),
                    );
                    if let Some(button) = action {
                        let app = app.clone();
                        button.connect_clicked(move |_| {
                            crate::update_window::present(&app, &info);
                        });
                    }
                    banner_slot.append(&banner);
                }
                shown_version = pending_version;
            }

            if let Some(view) = &snapshot.presentation {
                title.set_text(&view.title);
                for class in ["guarded", "pending", "killed", "disabled"] {
                    title.remove_css_class(class);
                }
                title.add_css_class(theme::shield_class(view.shield));

                clear(&shield_holder);
                shield_holder.append(&ui::shield(view.shield));
            }

            let probing = state.is_probing();
            spinner.set_visible(probing);
            spinner.set_spinning(probing);
            recheck.set_visible(!probing);

            clear(&readout);
            let lines = match &snapshot.report {
                Some(report) => presentation::status_lines(report, &local_time(report.checked_at)),
                None => presentation::status_lines_without_report(),
            };
            for line in lines {
                readout.append(&ui::data_row(&line.key, Some(&line.value)));
            }

            clear(&targets_slot);
            if !state.settings.current().targets.is_empty() {
                targets_slot.append(&ui::divider());
                targets_slot.append(&targets_view(&state, &snapshot));
            }
        }
    };

    refresh();
    // Пол-секунды: чаще незачем — охрана и сама тикает не быстрее, — а реже
    // заметно на глаз после нажатия проверки.
    gtk4::glib::timeout_add_local(std::time::Duration::from_millis(500), move || {
        refresh();
        gtk4::glib::ControlFlow::Continue
    });

    window
}

/// Живые цели пилюлями, а когда их нет — строка с советом. Цвет и совет берём
/// из состояния охраны, а не из самого факта «целей нет»: после срабатывания
/// цели молчат именно потому, что VPN уже выключен.
fn targets_view(
    state: &Arc<AppState>,
    snapshot: &weto_guard::controller::GuardSnapshot,
) -> GtkBox {
    let box_ = GtkBox::new(Orientation::Vertical, ui::SPACE2);

    if !snapshot.running.is_empty() {
        for target in &snapshot.running {
            box_.append(&ui::process_pill(
                &target.display_name,
                Some(&target.path),
                target.extra_process_count(),
            ));
        }
        return box_;
    }

    let notice = presentation::idle_targets(&state.guard_state());

    let row = GtkBox::new(Orientation::Horizontal, ui::SPACE2);
    let glyph = gtk4::Image::from_icon_name(if notice.hint.is_some() {
        "object-select-symbolic"
    } else {
        "action-unavailable-symbolic"
    });
    glyph.set_pixel_size(12);
    row.append(&glyph);

    let text = ui::caption(&notice.text);
    row.append(&text);

    if let Some(hint) = notice.hint {
        let hint_label = ui::caption(&hint);
        hint_label.add_css_class("weto-hint");
        row.append(&hint_label);
    }

    row.set_halign(Align::Start);
    box_.append(&row);
    box_
}

fn clear(container: &GtkBox) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }
}

/// Время пробы в местном поясе. Перевод делает glib: ядру ходить за базой
/// часовых поясов запрещено, поэтому строка приходит туда готовой.
fn local_time(at: std::time::SystemTime) -> String {
    let seconds = at
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    gtk4::glib::DateTime::from_unix_local(seconds)
        .and_then(|time| time.format("%H:%M:%S"))
        .map(|text| text.to_string())
        .unwrap_or_else(|_| "—".to_string())
}
