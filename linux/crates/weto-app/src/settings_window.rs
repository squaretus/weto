//! Окно настроек: две вкладки, как на macOS — «Управление» и «Журнал».

use std::cell::RefCell;
use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::{Align, ApplicationWindow, Box as GtkBox, Orientation, ScrolledWindow, Stack};

use weto_config::settings::Theme;
use weto_core::process::TargetKind;
use weto_ui::components as ui;
use weto_ui::theme;

use crate::state::AppState;

thread_local! {
    /// Окно одно: второе нажатие «Настройки» поднимает существующее,
    /// а не открывает копию.
    static WINDOW: RefCell<Option<ApplicationWindow>> = const { RefCell::new(None) };
}

pub fn present(app: &gtk4::Application, state: Arc<AppState>) {
    WINDOW.with(|slot| {
        if let Some(window) = slot.borrow().as_ref() {
            window.present();
            return;
        }
        let window = build(app, state);
        window.present();
        *slot.borrow_mut() = Some(window);
    });
}

fn build(app: &gtk4::Application, state: Arc<AppState>) -> ApplicationWindow {
    let window = ApplicationWindow::builder()
        .application(app)
        .title("weto — настройки")
        .default_width(ui::WINDOW_WIDTH)
        .default_height(ui::WINDOW_HEIGHT)
        .build();
    theme::mark_root(&window);

    window.connect_close_request(|_| {
        WINDOW.with(|slot| *slot.borrow_mut() = None);
        gtk4::glib::Propagation::Proceed
    });

    let panel = ui::panel();
    window.set_child(Some(&panel));

    // Роль заголовка окна в каноне исполняют сегменты навигации.
    let (segments, buttons) = ui::segments(&["Управление", "Журнал"], 0);
    panel.append(&segments);

    let stack = Stack::new();
    stack.set_vexpand(true);
    stack.add_named(&control_page(state.clone()), Some("control"));
    stack.add_named(&journal_page(state.clone()), Some("journal"));
    panel.append(&stack);

    {
        let stack = stack.clone();
        let state = state.clone();
        buttons[1].connect_toggled(move |button| {
            if button.is_active() {
                state.reload_journal();
                stack.set_visible_child_name("journal");
            } else {
                stack.set_visible_child_name("control");
            }
        });
    }

    window
}

fn control_page(state: Arc<AppState>) -> GtkBox {
    let page = GtkBox::new(Orientation::Vertical, ui::SPACE3);
    let settings = state.settings.current();

    // --- Охрана ---
    let guard_card = ui::card("Охрана");

    let enabled_row = ui::row(true);
    enabled_row.append(&ui::label("Охрана включена"));
    let spacer = GtkBox::new(Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    enabled_row.append(&spacer);
    let enabled = ui::toggle();
    enabled.set_active(settings.is_enabled);
    enabled_row.append(&enabled);
    guard_card.append(&enabled_row);

    // Побочные эффекты висят на сеттере привязки, а не на сигнале изменения
    // синхронизируемого состояния: на macOS обратный порядок стоил приложению
    // самозавершения при каждом открытии настроек.
    {
        let state = state.clone();
        enabled.connect_state_set(move |_, value| {
            state.settings.edit(|s| s.is_enabled = value);
            gtk4::glib::Propagation::Proceed
        });
    }

    let vpn_row = ui::row(false);
    vpn_row.append(&ui::label("Туннель"));
    let vpn_spacer = GtkBox::new(Orientation::Horizontal, 0);
    vpn_spacer.set_hexpand(true);
    vpn_row.append(&vpn_spacer);
    let vpn_picker = gtk4::DropDown::from_strings(&[]);
    vpn_row.append(&vpn_picker);
    guard_card.append(&vpn_row);

    // Пустой список объясняется словами, а не молчанием: это прямое следствие
    // выбранной модели — интерфейса не существует, пока туннель не поднимали.
    let vpn_hint = ui::caption("Туннель появится в списке после первого подключения");
    vpn_hint.set_halign(Align::Start);
    guard_card.append(&vpn_hint);

    // Список туннелей приходит из снимка сети и меняется на глазах: туннель
    // поднимают уже при открытых настройках. Перестраивается он только когда
    // состав изменился — иначе выбор пользователя сбрасывался бы дважды в секунду.
    {
        let state = state.clone();
        let picker = vpn_picker.clone();
        let hint = vpn_hint.clone();
        let mut known: Vec<String> = Vec::new();
        let mut applying = false;

        let mut refresh = move || {
            let candidates = state.snapshot().vpn_candidates;
            let chosen = state.settings.current().vpn_interface;

            if candidates != known {
                let items: Vec<&str> = candidates.iter().map(String::as_str).collect();
                applying = true;
                picker.set_model(Some(&gtk4::StringList::new(&items)));
                known = candidates.clone();
                applying = false;
            }
            hint.set_visible(candidates.is_empty());

            if let Some(index) = chosen
                .as_ref()
                .and_then(|name| candidates.iter().position(|c| c == name))
            {
                if picker.selected() != index as u32 && !applying {
                    picker.set_selected(index as u32);
                }
            }
        };
        refresh();

        gtk4::glib::timeout_add_local(std::time::Duration::from_millis(500), move || {
            refresh();
            gtk4::glib::ControlFlow::Continue
        });
    }

    {
        let state = state.clone();
        vpn_picker.connect_selected_notify(move |picker| {
            let Some(model) = picker.model() else { return };
            let Some(list) = model.downcast_ref::<gtk4::StringList>() else {
                return;
            };
            let Some(name) = list.string(picker.selected()) else {
                return;
            };
            let name = name.to_string();

            // Правка поднимает ревизию и обесценивает прежний вердикт:
            // смена туннеля обязана заново пройти проверку, а не наследовать
            // «безопасно» от предыдущего.
            if state.settings.current().vpn_interface.as_deref() != Some(name.as_str()) {
                state.settings.edit(|s| s.vpn_interface = Some(name));
            }
        });
    }

    let notify_row = ui::row(false);
    notify_row.append(&ui::label("Уведомлять о завершении"));
    let notify_spacer = GtkBox::new(Orientation::Horizontal, 0);
    notify_spacer.set_hexpand(true);
    notify_row.append(&notify_spacer);
    let notify = ui::toggle();
    notify.set_active(settings.notify_on_kill);
    notify_row.append(&notify);
    guard_card.append(&notify_row);

    {
        let state = state.clone();
        notify.connect_state_set(move |_, value| {
            state.settings.edit(|s| s.notify_on_kill = value);
            state.set_notify(value);
            gtk4::glib::Propagation::Proceed
        });
    }

    page.append(&guard_card);

    // --- Цели ---
    let targets_card = ui::card("Цели");
    let targets_list = GtkBox::new(Orientation::Vertical, 0);
    targets_card.append(&targets_list);

    let add_row = GtkBox::new(Orientation::Horizontal, ui::SPACE2);
    let target_entry = ui::entry("Путь к программе или скрипту");
    let add = ui::primary_button("Добавить");
    add_row.append(&target_entry);
    add_row.append(&add);
    targets_card.append(&add_row);
    page.append(&targets_card);

    let redraw_targets = {
        let state = state.clone();
        let targets_list = targets_list.clone();
        move || {
            while let Some(child) = targets_list.first_child() {
                targets_list.remove(&child);
            }
            let settings = state.settings.current();
            if settings.targets.is_empty() {
                targets_list.append(&ui::caption("Целей пока нет"));
                return;
            }
            for (index, target) in settings.targets.iter().enumerate() {
                let row = ui::row(index == 0);
                let text = GtkBox::new(Orientation::Vertical, 0);
                text.set_hexpand(true);
                text.append(&ui::label(&target.display_name));
                text.append(&ui::caption(&target.path));
                row.append(&text);

                let remove = ui::icon_button("user-trash-symbolic");
                row.append(&remove);
                targets_list.append(&row);

                let state = state.clone();
                let entry = target.entry.clone();
                remove.connect_clicked(move |_| {
                    state
                        .settings
                        .edit(|s| s.targets.retain(|t| t.entry != entry));
                });
            }
        }
    };
    redraw_targets();

    {
        let state = state.clone();
        let entry = target_entry.clone();
        let redraw = redraw_targets.clone();
        add.connect_clicked(move |_| {
            let text = entry.text().to_string();
            if text.trim().is_empty() {
                return;
            }
            // Путь разворачивается сразу: цель обязана храниться разрешённой,
            // иначе матчер не узнает процесс, запущенный через симлинк в PATH.
            let resolved = std::fs::canonicalize(text.trim())
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|_| text.trim().to_string());
            let name = resolved.rsplit('/').next().unwrap_or(&resolved).to_string();

            state.settings.edit(|s| {
                s.targets.push(weto_config::settings::Target {
                    entry: text.trim().to_string(),
                    display_name: name,
                    kind: TargetKind::Binary,
                    path: resolved,
                    launch_paths: vec![text.trim().to_string()],
                })
            });
            entry.set_text("");
            redraw();
        });
    }

    // --- Тема ---
    let theme_card = ui::card("Оформление");
    let theme_row = ui::row(true);
    theme_row.append(&ui::label("Тема"));
    let theme_spacer = GtkBox::new(Orientation::Horizontal, 0);
    theme_spacer.set_hexpand(true);
    theme_row.append(&theme_spacer);
    let (theme_segments, theme_buttons) = ui::segments(
        &["Тёмная", "Светлая"],
        if settings.theme == Theme::Light { 1 } else { 0 },
    );
    theme_row.append(&theme_segments);
    theme_card.append(&theme_row);
    page.append(&theme_card);

    {
        let state = state.clone();
        theme_buttons[1].connect_toggled(move |button| {
            let theme = if button.is_active() {
                Theme::Light
            } else {
                Theme::Dark
            };
            state.settings.edit(|s| s.theme = theme);
            crate::apply_theme(theme);
        });
    }

    page
}

fn journal_page(state: Arc<AppState>) -> ScrolledWindow {
    let list = GtkBox::new(Orientation::Vertical, 0);
    let journal = state.journal();

    if journal.entries().is_empty() {
        list.append(&ui::caption("Записей пока нет"));
    } else {
        // Свежие сверху: журнал читают, чтобы понять, что случилось только что.
        for event in journal.entries().iter().rev() {
            list.append(&ui::journal_row(
                &event.targets_text(),
                &event.summary_text(),
                &диагностика(event),
            ));
        }
    }

    ScrolledWindow::builder()
        .child(&list)
        .vexpand(true)
        .hscrollbar_policy(gtk4::PolicyType::Never)
        .build()
}

fn диагностика(event: &weto_config::journal::KillEvent) -> String {
    let mut parts = Vec::new();
    if let Some(ip) = &event.ip {
        parts.push(format!("IP: {ip}"));
    }
    if let Some(country) = &event.country {
        parts.push(format!("ipinfo: {country}"));
    }
    if let (Some(source), Some(country)) = (&event.confirm_source, &event.confirmed_country) {
        parts.push(format!("{source}: {country}"));
    }
    parts.push(format!(
        "pid: {}",
        event
            .killed_pids
            .iter()
            .map(|p| p.to_string())
            .collect::<Vec<_>>()
            .join(", ")
    ));
    parts.join(" · ")
}
