//! Окно статуса — порт попапа менюбара.
//!
//! На macOS это попап, привязанный к иконке. Здесь — обычное окно, и это
//! вынужденное отступление: протокол StatusNotifierItem не сообщает координат
//! иконки, а Wayland не позволяет окну позиционировать себя самому. Обойти
//! это нечем, кроме отказа от Wayland.
//!
//! Содержимое повторяет канон полностью: щит, заголовок статуса, строки гео,
//! живые цели пилюлями, кнопка проверки.

use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::{Align, ApplicationWindow, Box as GtkBox, Orientation, ScrolledWindow};

use weto_core::geo::SourceOutcome;
use weto_core::presentation::ShieldState;
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
    window.set_child(Some(&panel));

    // Баннер обновления стоит выше статуса и появляется только тогда, когда
    // политика решила показать находку. Тихий исход прячет и его, и окно.
    let banner_slot = GtkBox::new(Orientation::Vertical, 0);
    panel.append(&banner_slot);

    // Строка статуса: щит и заголовок обновляются на месте, а не пересобираются,
    // иначе окно дёргалось бы каждые полсекунды.
    let header = GtkBox::new(Orientation::Horizontal, ui::SPACE3);
    let shield_holder = GtkBox::new(Orientation::Horizontal, 0);
    let text = GtkBox::new(Orientation::Vertical, 0);
    text.set_hexpand(true);
    let title = ui::status_title("…", ShieldState::Pending);
    let subtitle = ui::caption("");
    subtitle.set_wrap(true);
    text.append(&title);
    text.append(&subtitle);
    header.append(&shield_holder);
    header.append(&text);
    panel.append(&header);

    // Карточка гео.
    let geo_card = ui::card("Подключение");
    let geo_rows = GtkBox::new(Orientation::Vertical, ui::SPACE1);
    geo_card.append(&geo_rows);
    panel.append(&geo_card);

    // Карточка живых целей.
    let targets_card = ui::card("Живые цели");
    let targets_box = GtkBox::new(Orientation::Vertical, ui::SPACE2);
    let targets_scroll = ScrolledWindow::builder()
        .child(&targets_box)
        .min_content_height(0)
        .max_content_height(220)
        .propagate_natural_height(true)
        .hscrollbar_policy(gtk4::PolicyType::Never)
        .build();
    targets_card.append(&targets_scroll);
    panel.append(&targets_card);

    // Действия.
    let actions = GtkBox::new(Orientation::Horizontal, ui::SPACE2);
    let check = ui::primary_button("Проверить");
    check.set_hexpand(true);
    let settings_button = ui::muted_button("Настройки");
    settings_button.set_hexpand(true);
    actions.append(&check);
    actions.append(&settings_button);
    panel.append(&actions);

    {
        let state = state.clone();
        check.connect_clicked(move |_| state.probe_now());
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
                while let Some(child) = banner_slot.first_child() {
                    banner_slot.remove(&child);
                }
                if let Some(info) = pending.clone() {
                    let (banner, action) = ui::banner(
                        ui::BannerTone::News,
                        &format!("Доступно обновление {}", info.latest_version),
                        Some("Обновить"),
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

            if let Some(presentation) = &snapshot.presentation {
                title.set_text(&presentation.title);
                subtitle.set_text(&presentation.subtitle);
                for class in ["guarded", "pending", "killed", "disabled"] {
                    title.remove_css_class(class);
                }
                title.add_css_class(theme::shield_class(presentation.shield));

                while let Some(child) = shield_holder.first_child() {
                    shield_holder.remove(&child);
                }
                shield_holder.append(&ui::shield(presentation.shield));
            }

            while let Some(child) = geo_rows.first_child() {
                geo_rows.remove(&child);
            }
            match &snapshot.report {
                Some(report) => {
                    geo_rows.append(&ui::data_row("IP", report.ip.as_deref()));
                    geo_rows.append(&ui::data_row(
                        "ipinfo",
                        source_text(&report.ipinfo).as_deref(),
                    ));
                    let confirm_key = report
                        .confirm_source
                        .map(|source| source.name())
                        .unwrap_or("подтверждение");
                    geo_rows.append(&ui::data_row(
                        confirm_key,
                        source_text(&report.confirmation).as_deref(),
                    ));
                }
                None => {
                    geo_rows.append(&ui::data_row("IP", None));
                }
            }

            while let Some(child) = targets_box.first_child() {
                targets_box.remove(&child);
            }
            if snapshot.running.is_empty() {
                let empty = ui::caption("Ни одна цель не запущена");
                empty.set_halign(Align::Start);
                targets_box.append(&empty);
            } else {
                for target in &snapshot.running {
                    targets_box.append(&ui::process_pill(
                        &target.display_name,
                        Some(&target.path),
                        target.extra_process_count(),
                    ));
                }
            }
        }
    };

    refresh();
    // Пол-секунды: чаще незачем — охрана и сама тикает не быстрее, — а реже
    // заметно на глаз после нажатия «Проверить».
    gtk4::glib::timeout_add_local(std::time::Duration::from_millis(500), move || {
        refresh();
        gtk4::glib::ControlFlow::Continue
    });

    window
}

/// Недоступное значение — короткое тире; так в каноне, и прочерков другого
/// вида в интерфейсе нет.
fn source_text(outcome: &SourceOutcome) -> Option<String> {
    match outcome {
        SourceOutcome::Answered(country) => Some(country.clone()),
        SourceOutcome::Failed(failure) => Some(failure.display_text()),
        SourceOutcome::NotRequested => None,
    }
}
