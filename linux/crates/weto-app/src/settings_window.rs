//! Окно настроек — порт `SettingsWindow` с macOS.
//!
//! Состав и порядок карточек повторяют оригинал: «Цели», «Сеть и гео»,
//! «Чёрный список», «Внешний вид», «Обслуживание», а под ними подвал со ссылкой,
//! версией и проверкой обновлений. Вторая вкладка — журнал.
//!
//! Тумблера охраны здесь нет, и это не упущение: на macOS его нет тоже.
//! Поле `is_enabled` в настройках существует, но наружу не выведено ни там, ни тут.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::{ApplicationWindow, Box as GtkBox, Orientation, ScrolledWindow, Stack};

use weto_config::settings::{Theme, POLL_INTERVAL_OPTIONS};
use weto_core::process::TargetKind;
use weto_sys::autostart::Autostart;
use weto_sys::secret_store::{FileSecretStore, SecretStoring};
use weto_ui::components as ui;
use weto_ui::theme;

use crate::state::AppState;

const NOT_SELECTED: &str = "Не выбран";

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
    let (segments, buttons) = ui::segments(&["Настройки", "Журнал"], 0);
    panel.append(&segments);

    let stack = Stack::new();
    stack.set_vexpand(true);
    stack.add_named(&settings_page(&window, state.clone()), Some("settings"));
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
                stack.set_visible_child_name("settings");
            }
        });
    }

    window
}

/// Страница настроек: пять карточек и подвал, всё под прокруткой.
fn settings_page(window: &ApplicationWindow, state: Arc<AppState>) -> ScrolledWindow {
    let page = GtkBox::new(Orientation::Vertical, ui::SPACE3);

    page.append(&targets_card(window, state.clone()));
    page.append(&network_card(state.clone()));
    page.append(&blacklist_card(state.clone()));
    page.append(&appearance_card(state.clone()));
    page.append(&maintenance_card(state.clone()));
    page.append(&footer(state.clone()));

    scroll(&page)
}

// --- Цели -----------------------------------------------------------------

fn targets_card(window: &ApplicationWindow, state: Arc<AppState>) -> GtkBox {
    let holder = GtkBox::new(Orientation::Vertical, ui::SPACE2);

    let card = ui::card("Цели");
    let list = GtkBox::new(Orientation::Vertical, 0);
    card.append(&list);

    let add_row = ui::row(false);
    let entry = ui::entry("Новая цель");
    let add = ui::primary_button("Добавить");
    let pick = ui::muted_button("Выбрать…");
    add_row.append(&entry);
    add_row.append(&add);
    add_row.append(&pick);
    card.append(&add_row);

    holder.append(&card);

    // Подпись под карточкой, а не внутри: так в каноне. Про бандлы здесь
    // не сказано ни слова — на Linux нет каталога, которым можно накрыть
    // процессы разом, и вид цели `appBundle` не переносится.
    let hint = ui::caption(
        "Имя команды (nano) или путь (/usr/bin/curl). \
         Дочерние процессы завершаются вместе с родителем.",
    );
    hint.set_wrap(true);
    hint.set_xalign(0.0);
    holder.append(&hint);

    let redraw = {
        let state = state.clone();
        let list = list.clone();
        move || {
            clear(&list);
            let settings = state.settings.current();

            if settings.targets.is_empty() {
                let row = ui::row(true);
                row.append(&ui::caption("Цели не выбраны — охрана ничего не завершает"));
                list.append(&row);
                return;
            }

            let running = state.snapshot().running;

            for (index, target) in settings.targets.iter().enumerate() {
                let row = ui::row(index > 0);

                let text = GtkBox::new(Orientation::Vertical, 2);
                text.set_hexpand(true);
                text.append(&ui::label(&target.display_name));
                let path = ui::caption(&resolved_description(target));
                path.set_selectable(true);
                path.set_wrap(true);
                path.set_xalign(0.0);
                text.append(&path);
                row.append(&text);

                let count: usize = running
                    .iter()
                    .filter(|r| r.entry == target.entry)
                    .map(|r| r.process_count)
                    .sum();
                row.append(&ui::value(&count.to_string()));

                let remove = ui::icon_button("user-trash-symbolic");
                remove.set_tooltip_text(Some("Удалить цель"));
                row.append(&remove);
                list.append(&row);

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
    redraw();

    // Кнопка «Добавить» неактивна, пока поле пустое: так на macOS.
    add.set_sensitive(false);
    {
        let add = add.clone();
        entry.connect_changed(move |entry| {
            add.set_sensitive(!entry.text().trim().is_empty());
        });
    }

    let commit = {
        let state = state.clone();
        let entry = entry.clone();
        let redraw = redraw.clone();
        move || {
            let text = entry.text().to_string();
            let text = text.trim().to_string();
            if text.is_empty() {
                return;
            }
            add_target(&state, &text);
            entry.set_text("");
            redraw();
        }
    };

    {
        let commit = commit.clone();
        add.connect_clicked(move |_| commit());
    }
    {
        let commit = commit.clone();
        entry.connect_activate(move |_| commit());
    }

    {
        let state = state.clone();
        let redraw = redraw.clone();
        let window = window.clone();
        pick.connect_clicked(move |_| {
            let dialog = gtk4::FileDialog::builder().title("Выбрать цель").build();

            let state = state.clone();
            let redraw = redraw.clone();
            dialog.open_multiple(
                Some(&window),
                gtk4::gio::Cancellable::NONE,
                move |result| {
                    // Отмена — не ошибка: пользователь передумал, и говорить
                    // ему об этом нечего.
                    let Ok(files) = result else { return };
                    for index in 0..files.n_items() {
                        if let Some(path) = files
                            .item(index)
                            .and_downcast::<gtk4::gio::File>()
                            .and_then(|file| file.path())
                        {
                            add_target(&state, &path.to_string_lossy());
                        }
                    }
                    redraw();
                },
            );
        });
    }

    // Счётчик живых процессов меняется сам по себе: цель запускают уже при
    // открытых настройках. Перерисовка раз в секунду — дешевле, чем рассылка.
    {
        let redraw = redraw.clone();
        gtk4::glib::timeout_add_local(std::time::Duration::from_millis(1000), move || {
            redraw();
            gtk4::glib::ControlFlow::Continue
        });
    }

    holder
}

/// Описание цели под именем. Вида `appBundle` на Linux нет, поэтому и строки
/// «приложение:» здесь не бывает.
fn resolved_description(target: &weto_config::settings::Target) -> String {
    let kind = match target.kind {
        TargetKind::Binary => "бинарник",
        TargetKind::Script => "скрипт",
    };
    format!("{kind}: {}", target.path)
}

fn add_target(state: &Arc<AppState>, text: &str) {
    let text = text.trim();
    if text.is_empty() || state.settings.current().targets.iter().any(|t| t.entry == text) {
        return;
    }

    // Путь разворачивается сразу: цель обязана храниться разрешённой,
    // иначе матчер не узнает процесс, запущенный через симлинк в PATH.
    let resolved = std::fs::canonicalize(text)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| text.to_string());
    let name = resolved.rsplit('/').next().unwrap_or(&resolved).to_string();

    state.settings.edit(|s| {
        s.targets.push(weto_config::settings::Target {
            entry: text.to_string(),
            display_name: name,
            kind: TargetKind::Binary,
            path: resolved,
            launch_paths: vec![text.to_string()],
        })
    });
}

// --- Сеть и гео -----------------------------------------------------------

fn network_card(state: Arc<AppState>) -> GtkBox {
    let card = ui::card("Сеть и гео");

    // VPN-сервис.
    let vpn_row = ui::row(true);
    vpn_row.append(&ui::label("VPN-сервис"));
    vpn_row.append(&ui::spacer());
    let picker = gtk4::DropDown::from_strings(&[NOT_SELECTED]);
    vpn_row.append(&picker);
    card.append(&vpn_row);

    // Список туннелей приходит из снимка сети и меняется на глазах: туннель
    // поднимают уже при открытых настройках. Перестраивается он только когда
    // состав изменился — иначе выбор сбрасывался бы дважды в секунду.
    {
        let state = state.clone();
        let picker = picker.clone();
        let mut known: Vec<String> = Vec::new();

        let mut refresh = move || {
            let candidates = state.snapshot().vpn_candidates;
            if candidates != known {
                let mut items = vec![NOT_SELECTED.to_string()];
                items.extend(candidates.iter().cloned());
                let refs: Vec<&str> = items.iter().map(String::as_str).collect();
                picker.set_model(Some(&gtk4::StringList::new(&refs)));
                known = candidates.clone();
            }

            let chosen = state.settings.current().vpn_interface;
            let index = chosen
                .as_ref()
                .and_then(|name| candidates.iter().position(|c| c == name))
                .map(|position| position + 1)
                .unwrap_or(0) as u32;
            if picker.selected() != index {
                picker.set_selected(index);
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
        picker.connect_selected_notify(move |picker| {
            let Some(list) = picker.model().and_downcast::<gtk4::StringList>() else {
                return;
            };
            let Some(name) = list.string(picker.selected()) else {
                return;
            };
            let chosen = (name != NOT_SELECTED).then(|| name.to_string());

            // Правка поднимает ревизию и обесценивает прежний вердикт: смена
            // сервиса обязана заново пройти проверку, а не наследовать «безопасно».
            if state.settings.current().vpn_interface != chosen {
                state.settings.edit(|s| s.vpn_interface = chosen.clone());
            }
        });
    }

    // Токен ipinfo.
    let token_row = ui::row(false);
    token_row.append(&ui::label("Токен ipinfo"));
    let token_entry = ui::entry("Ключ ipinfo.io");
    token_row.append(&token_entry);
    card.append(&token_row);

    let token_error = ui::caption("");
    token_error.add_css_class("weto-error");
    token_error.set_wrap(true);
    token_error.set_xalign(0.0);
    token_error.set_visible(false);
    card.append(&token_error);

    let store = FileSecretStore::new(state.paths.token_file());
    let stored = store.load().ok().flatten().unwrap_or_default();
    token_entry.set_text(&mask(&stored));

    {
        let token_error = token_error.clone();
        let path = state.paths.token_file();
        let masked = mask(&stored);
        token_entry.connect_changed(move |entry| {
            let value = entry.text().to_string();
            // Маска — не ввод: пока её не тронули, сохранять нечего.
            if value == masked {
                return;
            }
            // Токен считается сохранённым только после успешной записи:
            // тихая ошибка выдавала бы его за сохранённый.
            match FileSecretStore::new(path.clone()).save(value.trim()) {
                Ok(()) => token_error.set_visible(false),
                Err(error) => {
                    token_error.set_text(&error.to_string());
                    token_error.set_visible(true);
                }
            }
        });
    }

    // Интервал опроса.
    let interval_box = GtkBox::new(Orientation::Vertical, ui::SPACE2);
    interval_box.add_css_class("weto-row");
    interval_box.add_css_class("divided");
    interval_box.append(&ui::label("Интервал опроса"));

    let titles: Vec<String> = POLL_INTERVAL_OPTIONS
        .iter()
        .map(|seconds| format!("{} с", *seconds as i64))
        .collect();
    let refs: Vec<&str> = titles.iter().map(String::as_str).collect();
    let current = state.settings.current().poll_interval_seconds;
    let selected = POLL_INTERVAL_OPTIONS
        .iter()
        .position(|option| (*option - current).abs() < f64::EPSILON)
        .unwrap_or(0);

    let (interval_segments, interval_buttons) = ui::segments(&refs, selected);
    interval_box.append(&interval_segments);
    card.append(&interval_box);

    for (index, button) in interval_buttons.iter().enumerate() {
        let state = state.clone();
        let seconds = POLL_INTERVAL_OPTIONS[index];
        button.connect_toggled(move |button| {
            if button.is_active() {
                state.settings.edit(|s| s.poll_interval_seconds = seconds);
            }
        });
    }

    card
}

/// Показываем хвост токена, а не сам токен: подтвердить «тот ли ключ» так можно,
/// а подсмотреть через плечо — нет.
fn mask(token: &str) -> String {
    let length = token.chars().count();
    if length == 0 {
        return String::new();
    }
    if length <= 4 {
        return "•".repeat(length);
    }
    let tail: String = token.chars().skip(length - 4).collect();
    format!("{}{tail}", "•".repeat(length - 4))
}

// --- Чёрный список --------------------------------------------------------

fn blacklist_card(state: Arc<AppState>) -> GtkBox {
    let card = ui::card("Чёрный список");
    let list = GtkBox::new(Orientation::Vertical, 0);
    card.append(&list);

    let add_row = ui::row(false);
    let entry = ui::entry("Код страны (RU), IP или CIDR");
    let add = ui::primary_button("Добавить");
    add_row.append(&entry);
    add_row.append(&add);
    card.append(&add_row);

    let error = ui::caption("");
    error.add_css_class("weto-error");
    error.set_wrap(true);
    error.set_xalign(0.0);
    error.set_visible(false);
    card.append(&error);

    // Перерисовка через `Rc`, чтобы её могли позвать и кнопки внутри строк,
    // которые она же и создаёт.
    let redraw: Rc<RefCell<Option<Rc<dyn Fn()>>>> = Rc::new(RefCell::new(None));
    {
        let state = state.clone();
        let list = list.clone();
        let self_ref = redraw.clone();
        let draw: Rc<dyn Fn()> = Rc::new(move || {
            clear(&list);
            let entries = state.settings.current().blocked_entries();

            if entries.is_empty() {
                let row = ui::row(true);
                row.append(&ui::caption("Список пуст"));
                list.append(&row);
                return;
            }

            for (index, blocked) in entries.iter().enumerate() {
                let row = ui::row(index > 0);
                row.append(&ui::label(blocked));
                row.append(&ui::spacer());

                let remove = ui::icon_button("user-trash-symbolic");
                remove.set_tooltip_text(Some("Удалить из списка"));
                row.append(&remove);
                list.append(&row);

                let state = state.clone();
                let blocked = blocked.clone();
                let again = self_ref.clone();
                remove.connect_clicked(move |_| {
                    state.settings.edit(|s| s.remove_blocked_entry(&blocked));
                    if let Some(draw) = again.borrow().clone() {
                        draw();
                    }
                });
            }
        });
        *redraw.borrow_mut() = Some(draw);
    }

    let redraw = {
        let slot = redraw.clone();
        move || {
            let draw = slot.borrow().clone();
            if let Some(draw) = draw {
                draw();
            }
        }
    };
    redraw();

    add.set_sensitive(false);
    {
        let add = add.clone();
        entry.connect_changed(move |entry| {
            add.set_sensitive(!entry.text().trim().is_empty());
        });
    }

    let commit = {
        let state = state.clone();
        let entry = entry.clone();
        let error = error.clone();
        let redraw = redraw.clone();
        move || {
            let text = entry.text().to_string();
            // Разбор и проверка живут в настройках: экрану остаётся показать отказ.
            let mut outcome = Ok(());
            state.settings.edit(|s| outcome = s.add_blocked_entry(&text));

            match outcome {
                Ok(()) => {
                    entry.set_text("");
                    error.set_visible(false);
                    redraw();
                }
                Err(failure) => {
                    error.set_text(&failure.to_string());
                    error.set_visible(true);
                }
            }
        }
    };

    {
        let commit = commit.clone();
        add.connect_clicked(move |_| commit());
    }
    {
        let commit = commit.clone();
        entry.connect_activate(move |_| commit());
    }

    card
}

// --- Внешний вид ----------------------------------------------------------

fn appearance_card(state: Arc<AppState>) -> GtkBox {
    let card = ui::card("Внешний вид");

    let box_ = GtkBox::new(Orientation::Vertical, ui::SPACE2);
    box_.add_css_class("weto-row");
    box_.append(&ui::label("Тема"));

    let theme_now = state.settings.current().theme;
    let (segments, buttons) = ui::segments(
        &["Тёмная", "Светлая"],
        if theme_now == Theme::Light { 1 } else { 0 },
    );
    box_.append(&segments);
    card.append(&box_);

    {
        let state = state.clone();
        buttons[1].connect_toggled(move |button| {
            let theme = if button.is_active() {
                Theme::Light
            } else {
                Theme::Dark
            };
            state.settings.edit(|s| s.theme = theme);
            crate::apply_theme(theme);
        });
    }

    card
}

// --- Обслуживание ---------------------------------------------------------

fn maintenance_card(state: Arc<AppState>) -> GtkBox {
    let card = ui::card("Обслуживание");
    let autostart = Autostart::new(&state.paths);

    let error = ui::caption("");
    error.add_css_class("weto-error");
    error.set_wrap(true);
    error.set_xalign(0.0);
    error.set_visible(false);

    // Автозапуск.
    let launch_row = ui::row(true);
    launch_row.append(&ui::label("Запускать при входе в систему"));
    launch_row.append(&ui::spacer());
    let launch = ui::toggle();
    launch.set_active(autostart.is_enabled());
    launch_row.append(&launch);
    card.append(&launch_row);

    {
        let paths = state.paths.clone();
        let error = error.clone();
        launch.connect_state_set(move |switch, value| {
            let autostart = Autostart::new(&paths);
            let outcome = if value {
                autostart.enable()
            } else {
                autostart.disable()
            };

            match outcome {
                Ok(()) => error.set_visible(false),
                Err(failure) => {
                    error.set_text(&failure.to_string());
                    error.set_visible(true);
                }
            }

            // Состояние берём из системы, а не из нажатия: отказ не должен
            // выглядеть успехом.
            switch.set_state(autostart.is_enabled());
            gtk4::glib::Propagation::Stop
        });
    }

    // Автообновление. Та же настройка, что галочка в окне обновления:
    // хранилище одно, поэтому оба места показывают одно и то же.
    let auto_row = ui::row(false);
    auto_row.append(&ui::label("Обновлять автоматически"));
    auto_row.append(&ui::spacer());
    let auto = ui::toggle();
    auto.set_active(
        weto_update::store::UpdateStore::new(state.paths.state_dir.clone())
            .deferral()
            .auto_install,
    );
    auto_row.append(&auto);
    card.append(&auto_row);

    {
        let state_dir = state.paths.state_dir.clone();
        auto.connect_state_set(move |_, value| {
            weto_update::store::UpdateStore::new(state_dir.clone()).set_auto_install(value);
            gtk4::glib::Propagation::Proceed
        });
    }

    card.append(&error);

    let actions = GtkBox::new(Orientation::Horizontal, ui::SPACE2);
    actions.set_margin_top(ui::SPACE3);
    let close = ui::destructive_button("Закрыть приложение");
    close.set_hexpand(true);
    let uninstall = ui::destructive_button("Удалить приложение…");
    uninstall.set_hexpand(true);
    actions.append(&close);
    actions.append(&uninstall);
    card.append(&actions);

    {
        let state = state.clone();
        close.connect_clicked(move |button| {
            confirm(
                button,
                "Закрыть weto?",
                "Приложение завершится и перестанет охранять цели до следующего входа \
                 в систему. Настройки, журнал и автозапуск сохранятся.",
                "Закрыть",
                {
                    let _state = state.clone();
                    move || {
                        if let Some(app) = gtk4::gio::Application::default() {
                            app.quit();
                        }
                    }
                },
            );
        });
    }

    {
        let error = error.clone();
        uninstall.connect_clicked(move |button| {
            let error = error.clone();
            confirm(
                button,
                "Удалить weto?",
                "Будут удалены приложение, автозапуск, настройки, журнал и токен ipinfo. \
                 Действие необратимо.",
                "Удалить",
                move || {
                    // Приложение не закрывается молча, если что-то не удалилось:
                    // иначе пользователь считал бы систему чистой.
                    match crate::uninstall::run() {
                        Ok(()) => {
                            if let Some(app) = gtk4::gio::Application::default() {
                                app.quit();
                            }
                        }
                        Err(failure) => {
                            error.set_text(&failure);
                            error.set_visible(true);
                        }
                    }
                },
            );
        });
    }

    card
}

/// Подтверждение необратимого действия. На macOS это `NSAlert`, здесь —
/// `AlertDialog`: обе системы просят подтверждение у своего диалога, а не
/// у самодельного окна.
fn confirm(
    anchor: &gtk4::Button,
    title: &str,
    detail: &str,
    confirm_title: &str,
    action: impl Fn() + 'static,
) {
    let dialog = gtk4::AlertDialog::builder()
        .message(title)
        .detail(detail)
        .buttons([confirm_title, "Отмена"])
        .cancel_button(1)
        .default_button(1)
        .modal(true)
        .build();

    let window = anchor.root().and_downcast::<gtk4::Window>();
    dialog.choose(window.as_ref(), gtk4::gio::Cancellable::NONE, move |answer| {
        if answer == Ok(0) {
            action();
        }
    });
}

// --- Подвал ---------------------------------------------------------------

fn footer(state: Arc<AppState>) -> GtkBox {
    let footer = GtkBox::new(Orientation::Horizontal, ui::SPACE3);
    footer.set_margin_top(ui::SPACE2);

    let github = ui::link_button("github");
    github.set_tooltip_text(Some(crate::update::REPOSITORY_URL));
    footer.append(&github);
    footer.append(&ui::spacer());

    let version = ui::caption(&format!("версия {}", crate::update::current_version()));
    footer.append(&version);

    // Кнопка только проверяет: установка запускается из окна обновления.
    // Ручная проверка игнорирует пропуск и отсрочку — другого способа вернуть
    // пропущенную версию нет.
    let check = ui::tile_button("view-refresh-symbolic");
    check.set_tooltip_text(Some("Проверить обновления"));
    footer.append(&check);

    github.connect_clicked(|button| {
        gtk4::UriLauncher::new(crate::update::REPOSITORY_URL).launch(
            button.root().and_downcast::<gtk4::Window>().as_ref(),
            gtk4::gio::Cancellable::NONE,
            |_| {},
        );
    });

    {
        let _state = state.clone();
        check.connect_clicked(move |button| {
            if let Some(updates) = crate::update::shared() {
                updates.check_now();
                button.set_sensitive(false);
            }
        });
    }

    // Кнопка оживает, когда проверка закончилась, и меняет иконку, когда
    // находка есть: тогда она открывает окно обновления, а не проверяет заново.
    {
        let check = check.clone();
        gtk4::glib::timeout_add_local(std::time::Duration::from_millis(500), move || {
            let updates = crate::update::shared();
            let pending = updates.as_ref().and_then(|u| u.pending());
            check.set_sensitive(true);
            check.set_icon_name(if pending.is_some() {
                "software-update-available-symbolic"
            } else {
                "view-refresh-symbolic"
            });
            gtk4::glib::ControlFlow::Continue
        });
    }

    footer
}

// --- Журнал ---------------------------------------------------------------

fn journal_page(state: Arc<AppState>) -> ScrolledWindow {
    let page = GtkBox::new(Orientation::Vertical, ui::SPACE3);

    let card = ui::card("Журнал");
    let list = GtkBox::new(Orientation::Vertical, 0);
    card.append(&list);

    let clear_button = ui::destructive_button("Очистить журнал");
    clear_button.set_hexpand(true);
    clear_button.set_margin_top(ui::SPACE3);
    card.append(&clear_button);

    let redraw = {
        let state = state.clone();
        let list = list.clone();
        let clear_button = clear_button.clone();
        move || {
            clear(&list);
            let journal = state.journal();

            if journal.entries().is_empty() {
                let row = ui::row(true);
                row.append(&ui::caption("Срабатываний не было"));
                list.append(&row);
                clear_button.set_visible(false);
                return;
            }

            clear_button.set_visible(true);
            // Свежие сверху: журнал читают, чтобы понять, что случилось только что.
            for event in journal.entries().iter().rev() {
                list.append(&ui::journal_row(
                    &event.targets_text(),
                    &event.summary_text(),
                    &diagnostics(event),
                ));
            }
        }
    };
    redraw();

    {
        let state = state.clone();
        let redraw = redraw.clone();
        clear_button.connect_clicked(move |_| {
            state.clear_journal();
            redraw();
        });
    }

    page.append(&card);
    page.append(&footer(state));
    scroll(&page)
}

fn diagnostics(event: &weto_config::journal::KillEvent) -> String {
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

// --- Общее ----------------------------------------------------------------

fn scroll(child: &GtkBox) -> ScrolledWindow {
    ScrolledWindow::builder()
        .child(child)
        .vexpand(true)
        .hscrollbar_policy(gtk4::PolicyType::Never)
        .build()
}

fn clear(container: &GtkBox) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }
}
