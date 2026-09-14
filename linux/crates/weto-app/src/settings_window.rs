//! Окно настроек — порт `SettingsWindow` с macOS.
//!
//! Состав и порядок карточек повторяют оригинал: «Цели», «Сеть и гео»,
//! «Чёрный список», «Белый список», «Внешний вид», «Обслуживание», а под ними подвал со ссылкой,
//! версией и проверкой обновлений. Вторая вкладка — журнал.
//!
//! Тумблера охраны здесь нет, и это не упущение: на macOS его нет тоже.
//! Поле `is_enabled` в настройках существует, но наружу не выведено ни там, ни тут.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::{ApplicationWindow, Box as GtkBox, Orientation, ScrolledWindow, Stack};

use weto_config::settings::{GeoListKind, Theme};
use weto_core::process::TargetKind;
use weto_sys::autostart::Autostart;
use weto_sys::secret_store::{FileSecretStore, SecretStoring};
use weto_sys::target_resolver::{
    applications_dirs, display_name_for, resolve_launch_entry, resolve_launch_target, Resolution,
};
use weto_ui::components as ui;
use weto_ui::theme;

use crate::state::AppState;
use weto_app::lifecycle::window_tick;

/// Минимальная высота окна. Ниже неё сегменты навигации и первая карточка
/// начинают резаться, а прокрутке нечего показывать. Это не `WINDOW_HEIGHT`:
/// то — рост по умолчанию, этот — пол, ниже которого окно не сужается.
const MIN_WINDOW_HEIGHT: i32 = 480;

/// Перерисовка, которую могут позвать и виджеты, ею же созданные: кнопка
/// удаления живёт внутри строки, а строки пересобираются целиком.
type Redraw = Rc<RefCell<Option<Rc<dyn Fn()>>>>;

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
    // «Размер по умолчанию» — просьба, а не размер: тайловый композитор
    // (Hyprland и прочие) выдаёт окну всю ячейку и `default_width`
    // не спрашивает, а `resizable(false)` там тоже ничего не гарантирует.
    // Поэтому ширину держит само содержимое — `ui::content_column` ниже, —
    // а окну остаётся минимум, ниже которого карточки начали бы резаться.
    window.set_size_request(ui::WINDOW_WIDTH, MIN_WINDOW_HEIGHT);
    theme::mark_root(&window);

    window.connect_close_request(|_| {
        WINDOW.with(|slot| *slot.borrow_mut() = None);
        gtk4::glib::Propagation::Proceed
    });

    let panel = ui::panel();
    // Панель едет в колонку фиксированной ширины: растянули окно — колонка
    // осталась своей ширины и встала по центру, а не разъехалась подписями
    // к одному краю и контролами к другому.
    window.set_child(Some(&ui::content_column(&panel)));

    // Роль заголовка окна в каноне исполняют сегменты навигации.
    let (segments, buttons) = ui::segments(&["Настройки", "Журнал"], 0);
    panel.append(&segments);

    let stack = Stack::new();
    stack.set_vexpand(true);
    stack.add_named(&settings_page(&window, state.clone()), Some("settings"));
    stack.add_named(&journal_page(&window, state.clone()), Some("journal"));
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

/// Страница настроек: шесть карточек и подвал, всё под прокруткой.
fn settings_page(window: &ApplicationWindow, state: Arc<AppState>) -> ScrolledWindow {
    let page = GtkBox::new(Orientation::Vertical, ui::SPACE3);

    page.append(&targets_card(window, state.clone()));
    page.append(&network_card(window, state.clone()));
    page.append(&geo_list_card(
        state.clone(),
        GeoListKind::Blocked,
        "Чёрный список",
    ));
    page.append(&geo_list_card(
        state.clone(),
        GeoListKind::Allowed,
        "Белый список",
    ));
    page.append(&appearance_card(state.clone()));
    page.append(&maintenance_card(state.clone()));
    page.append(&footer(window, state.clone()));

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
        let window = window.downgrade();
        move || {
            let text = entry.text().to_string();
            let text = text.trim().to_string();
            if text.is_empty() {
                return;
            }
            // Ярлык, вписанный руками, ничем не отличается от выбранного
            // в диалоге: Steam и flatpak одинаково не называют программу,
            // и путь спрашивается на обеих дорогах. Перерисовка едет
            // в счётчике ссылок — запрос пути отвечает уже после конца
            // обработчика.
            let redraw: Rc<dyn Fn()> = Rc::new(redraw.clone());
            // Окно захвачено слабо: обработчик живёт внутри самого окна,
            // и сильная ссылка отсюда замкнула бы цикл окно → кнопка →
            // замыкание → окно. Сборщика циклов у GObject нет, `dispose`
            // не наступал бы никогда, и дерево виджетов утекало бы
            // при каждом открытии настроек.
            let Some(window) = window.upgrade() else {
                return;
            };
            commit_entry(&window, &state, &redraw, &text, Destination::Target);
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
        let window = window.downgrade();
        pick.connect_clicked(move |_| {
            // Окно захвачено слабо: обработчик живёт внутри самого окна,
            // и сильная ссылка отсюда замкнула бы цикл окно → кнопка →
            // замыкание → окно. Сборщика циклов у GObject нет, `dispose`
            // не наступал бы никогда, и дерево виджетов утекало бы
            // при каждом открытии настроек.
            let Some(window) = window.upgrade() else {
                return;
            };
            let dialog = gtk4::FileDialog::builder().title("Выбрать цель").build();

            // Аналог `/Applications`: на macOS панель открывается там, и выбирать
            // приходится из приложений, а не из файловой системы вообще. Здесь
            // приложения представлены ярлыками — из них и выбираем.
            for directory in applications_dirs() {
                if directory.is_dir() {
                    dialog.set_initial_folder(Some(&gtk4::gio::File::for_path(&directory)));
                    break;
                }
            }

            let state = state.clone();
            // Запрос пути живёт дольше самого обработчика — второй диалог
            // отвечает уже после его конца, — поэтому перерисовка едет
            // в счётчике ссылок, а не копией замыкания.
            let redraw: Rc<dyn Fn()> = Rc::new(redraw.clone());
            // Одно окно уходит в родители диалога, второе — внутрь ответа:
            // запрос пути открывает свой диалог и тоже просит родителя.
            let parent = window.clone();
            let window = window.clone();
            dialog.open_multiple(Some(&parent), gtk4::gio::Cancellable::NONE, move |result| {
                // Отмена — не ошибка: пользователь передумал, и говорить
                // ему об этом нечего.
                let Ok(files) = result else { return };
                for index in 0..files.n_items() {
                    let Some(path) = files
                        .item(index)
                        .and_downcast::<gtk4::gio::File>()
                        .and_then(|file| file.path())
                    else {
                        continue;
                    };
                    let chosen = path.to_string_lossy().into_owned();

                    // До настоящей программы не всегда можно добраться честно:
                    // Steam и flatpak заводят её у себя. Догадка означала бы
                    // охрану самого Steam — и падение VPN закрывало бы все игры
                    // разом, — поэтому путь спрашивается у пользователя.
                    commit_entry(&window, &state, &redraw, &chosen, Destination::Target);
                }
                redraw();
            });
        });
    }

    // Счётчик живых процессов меняется сам по себе: цель запускают уже при
    // открытых настройках. Перерисовка раз в секунду — дешевле, чем рассылка.
    {
        let redraw = redraw.clone();
        window_tick(window, std::time::Duration::from_millis(1000), move || {
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

/// Добавление цели с готовым именем.
///
/// Имя приходит снаружи, когда запись и ярлык разошлись: файл программы указал
/// пользователь, а подписана цель обязана быть тем именем, которое он видел
/// в диалоге выбора.
fn add_target_named(state: &Arc<AppState>, text: &str, display_name: Option<String>) {
    let text = text.trim();
    if text.is_empty()
        || state
            .settings
            .current()
            .targets
            .iter()
            .any(|t| t.entry == text)
    {
        return;
    }

    let resolved = resolve_launch_target(text);
    let name = display_name
        .or_else(|| display_name_for(text))
        .unwrap_or_else(|| resolved.rsplit('/').next().unwrap_or(&resolved).to_string());

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

fn network_card(window: &ApplicationWindow, state: Arc<AppState>) -> GtkBox {
    let card = ui::card("Сеть и гео");

    // VPN-приложение: та же форма, что цель, — команда или путь. Список туннелей
    // здесь стоял раньше и ушёл вместе с самим выбором туннеля: имена вида utun6
    // и wg0 пользователю ничего не говорят и меняются при переподключении.
    let vpn_row = ui::row(true);
    vpn_row.append(&ui::label("VPN-приложение"));
    vpn_row.append(&ui::spacer());
    let vpn_value = ui::label("не выбрано");
    vpn_row.append(&vpn_value);
    let vpn_entry = ui::entry("Команда или путь");
    let vpn_set = ui::primary_button("Выбрать");
    let vpn_clear = ui::muted_button("Снять");
    vpn_row.append(&vpn_entry);
    vpn_row.append(&vpn_set);
    vpn_row.append(&vpn_clear);
    card.append(&vpn_row);

    {
        let state = state.clone();
        let vpn_value = vpn_value.clone();
        let show = move || {
            let chosen = state.settings.current().vpn_app;
            vpn_value.set_text(&match chosen {
                Some(app) => format!("{} — {}", app.display_name, resolved_description(&app)),
                None => "не выбрано".to_string(),
            });
        };
        show();

        window_tick(window, std::time::Duration::from_millis(500), move || {
            show();
            gtk4::glib::ControlFlow::Continue
        });
    }

    {
        let state = state.clone();
        let vpn_entry = vpn_entry.clone();
        let window = window.downgrade();
        vpn_set.connect_clicked(move |_| {
            // Окно захвачено слабо: обработчик живёт внутри самого окна,
            // и сильная ссылка отсюда замкнула бы цикл окно → кнопка →
            // замыкание → окно. Сборщика циклов у GObject нет, `dispose`
            // не наступал бы никогда, и дерево виджетов утекало бы
            // при каждом открытии настроек.
            let Some(window) = window.upgrade() else {
                return;
            };

            // Дорога сюда ровно одна и ручная, а цена промаха выше, чем у цели:
            // невыбранное VPN-приложение не значит ничего, а выбранное
            // и не запущенное — доказательство, то есть завершение всех целей.
            // Ярлык flatpak, принятый молча, устроил бы это на ровном месте.
            // Строку статуса обновляет свой таймер, поэтому перерисовывать
            // отсюда нечего.
            let redraw: Rc<dyn Fn()> = Rc::new(|| {});
            commit_entry(
                &window,
                &state,
                &redraw,
                &vpn_entry.text(),
                Destination::VpnApp,
            );
            vpn_entry.set_text("");
        });
    }

    {
        let state = state.clone();
        vpn_clear.connect_clicked(move |_| {
            state.settings.edit(|s| s.set_vpn_app(None));
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

// --- Списки геоправил -----------------------------------------------------

/// Один builder на обе карточки: чёрный и белый списки отличаются только
/// заголовком и видом списка. Второй экземпляр функции разъехался бы с первым
/// молча, а расходиться им нельзя.
fn geo_list_card(state: Arc<AppState>, kind: GeoListKind, title: &str) -> GtkBox {
    let card = ui::card(title);
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
    let redraw: Redraw = Rc::new(RefCell::new(None));
    {
        let state = state.clone();
        let list = list.clone();
        let self_ref = redraw.clone();
        let draw: Rc<dyn Fn()> = Rc::new(move || {
            clear(&list);
            let entries = state.settings.current().entries(kind);

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
                    state.settings.edit(|s| s.remove_entry(&blocked, kind));
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
            state.settings.edit(|s| outcome = s.add_entry(&text, kind));

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

    close.connect_clicked(move |button| {
        confirm(
            button,
            "Закрыть weto?",
            // Про «до следующего входа в систему» текст обещать не имеет права:
            // автозапуск по умолчанию выключен, и без него weto не вернётся
            // никогда. Дословно как на macOS.
            "Приложение завершится и перестанет охранять цели. Настройки, журнал \
             и автозапуск сохранятся: если автозапуск включён, weto вернётся \
             при следующем входе в систему.",
            "Закрыть",
            || {
                // Замороженных целей выход не оставляет: SIGCONT шлёт воронка
                // `connect_shutdown`, а не эта кнопка — иначе обязательство
                // держалось бы на трёх кнопках, а закрытие последнего окна
                // проходило бы мимо него.
                if let Some(app) = gtk4::gio::Application::default() {
                    app.quit();
                }
            },
        );
    });

    {
        let error = error.clone();
        let state = state.clone();
        uninstall.connect_clicked(move |button| {
            let error = error.clone();
            let state = state.clone();
            confirm(
                button,
                "Удалить weto?",
                "Будут удалены приложение, автозапуск, настройки, журнал и токен ipinfo. \
                 Действие необратимо.",
                "Удалить",
                {
                    let anchor = button.clone();
                    move || {
                        // Единственное место, где выход зовут руками: порядок
                        // важен. Стоящие цели продолжаются раньше удаления —
                        // вместе с учётом исчезает и последний, кто помнит, кому
                        // должен SIGCONT, а воронка отработала бы уже после него.
                        // Повтор безвреден: вызов идемпотентен, и второй раз
                        // на выходе не находит в учёте ничего.
                        state.shutdown();

                        // И только здесь обязательство исполняет наблюдение,
                        // а не отправка: всюду ещё запись, которую выход
                        // не разрешил, достаётся следующему запуску, а после
                        // удаления его не будет вовсе. Не поднявшихся удаление
                        // называет пользователю, а не сносит поверх них молча:
                        // вернуть их будет уже некому.
                        let anchor = anchor.clone();
                        let error = error.clone();
                        confirm_resumed(state.clone(), move |standing| {
                            if standing.is_empty() {
                                remove_weto(&error);
                                return;
                            }

                            let error = error.clone();
                            ask_two_ways(
                                &anchor,
                                "Эти программы weto поставил на паузу, и они ещё не продолжились:",
                                &standing_detail(&standing),
                                "Удалить всё равно",
                                "Не удалять и закрыть weto",
                                move || remove_weto(&error),
                                || {
                                    // Второй исход — выход, а не «ничего
                                    // не делать». Охрана к этому моменту
                                    // остановлена необратимо: ворота применения
                                    // закрыты, фаза сброшена, а тумблера охраны
                                    // в продукте нет. Прежняя «Отмена»
                                    // оставляла в трее weto, который ничего
                                    // не охраняет и молчит об этом, —
                                    // на Linux ещё и надолго, потому что
                                    // приложение держит себя само.
                                    if let Some(app) = gtk4::gio::Application::default() {
                                        app.quit();
                                    }
                                },
                            );
                        });
                    }
                },
            );
        });
    }

    card
}

/// Сколько раз удаление переспрашивает ядро про оставшиеся записи учёта и с каким
/// шагом. Потолок — около двух секунд: SIGCONT, которому суждено дойти, доходит
/// с первой же досылки, а держать пользователя на кнопке дольше незачем. Те же
/// числа на macOS (`MaintenanceCard`).
const RESUME_CONFIRMATIONS: u32 = 6;
const RESUME_CONFIRMATION_STEP: std::time::Duration = std::time::Duration::from_millis(300);

/// Досылает SIGCONT оставшимся записям учёта, пока обход не покажет их идущими,
/// и отдаёт тех, кто так и остался стоять.
///
/// Главный поток при этом не стоит: отсчёт идёт тем же `timeout_add_local`, что
/// и остальные отложенные дела окна. Ждать циклом здесь значило бы заморозить
/// интерфейс ровно на то время, за которое цели и должны подняться.
fn confirm_resumed(
    state: Arc<AppState>,
    finish: impl Fn(Vec<weto_config::stopped::StoppedProcess>) + 'static,
) {
    let left = Rc::new(RefCell::new(RESUME_CONFIRMATIONS));
    gtk4::glib::timeout_add_local(RESUME_CONFIRMATION_STEP, move || {
        let standing = state.confirm_resumed();
        let mut left = left.borrow_mut();
        *left -= 1;
        if standing.is_empty() || *left == 0 {
            finish(standing);
            return gtk4::glib::ControlFlow::Break;
        }
        gtk4::glib::ControlFlow::Continue
    });
}

/// Пояснение к диалогу об оставшихся стоять. Дословно совпадает с macOS
/// (`MaintenanceCard.askToUninstallAnyway`) — тексты и набор кнопок у диалогов
/// общие для платформ.
///
/// Про остановленную охрану сказано прямо, и это не вежливость: к этому моменту
/// выход уже случился, обратно охрана не включится, а тумблера у неё нет. Молчи
/// диалог об этом, «не удалять» означало бы weto в трее, который ничего
/// не сторожит, — и пользователь узнал бы об этом только по погибшей цели.
fn standing_detail(standing: &[weto_config::stopped::StoppedProcess]) -> String {
    format!(
        "{}\n\nОхрана уже остановлена и обратно не включится: weto придётся \
         запустить заново.\n\nЕсли удалить weto сейчас, вернуть эти программы \
         будет некому — только командой fg в их терминале. Если не удалять, \
         их разберёт следующий запуск: учёт остановленных цел.",
        standing_list(standing)
    )
}

/// Имена и pid тех, кто остался стоять, — одной строкой на диалог. Имя берётся
/// из пути учёта: цель, снятая с охраны между делом, по имени не находится,
/// а бинарник честнее пустой строки.
fn standing_list(standing: &[weto_config::stopped::StoppedProcess]) -> String {
    standing
        .iter()
        .map(|entry| {
            let name = entry
                .executable_path
                .rsplit('/')
                .next()
                .unwrap_or(&entry.executable_path);
            format!("{name} (pid {})", entry.pid)
        })
        .collect::<Vec<String>>()
        .join(", ")
}

/// Собственно снос: тот же `uninstall.sh`, что и из терминала. Приложение
/// не закрывается молча, если что-то не удалилось, — иначе пользователь
/// считал бы систему чистой.
fn remove_weto(error: &gtk4::Label) {
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
}

/// Диалог, у которого определены оба исхода, а не «сделать» и «ничего
/// не делать»: обе кнопки что-то делают, и уйти из него в неопределённость
/// нельзя. Esc уводит во второй исход — он для того и назван вслух.
fn ask_two_ways(
    anchor: &gtk4::Button,
    title: &str,
    detail: &str,
    confirm_title: &str,
    alternative_title: &str,
    confirm_action: impl Fn() + 'static,
    alternative_action: impl Fn() + 'static,
) {
    let dialog = gtk4::AlertDialog::builder()
        .message(title)
        .detail(detail)
        .buttons([confirm_title, alternative_title])
        .cancel_button(1)
        .default_button(1)
        .modal(true)
        .build();

    let window = anchor.root().and_downcast::<gtk4::Window>();
    dialog.choose(
        window.as_ref(),
        gtk4::gio::Cancellable::NONE,
        move |answer| {
            if answer == Ok(0) {
                confirm_action();
            } else {
                alternative_action();
            }
        },
    );
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
    dialog.choose(
        window.as_ref(),
        gtk4::gio::Cancellable::NONE,
        move |answer| {
            if answer == Ok(0) {
                action();
            }
        },
    );
}

/// Куда уедет запись, когда путь наконец известен.
#[derive(Clone, Copy)]
enum Destination {
    /// Цель под охраной.
    Target,
    /// VPN-приложение.
    VpnApp,
}

impl Destination {
    fn commit(self, state: &Arc<AppState>, entry: &str, display_name: Option<String>) {
        match self {
            Destination::Target => add_target_named(state, entry, display_name),
            Destination::VpnApp => set_vpn_app_named(state, entry, display_name),
        }
    }
}

/// Запись, добавленная любой из дорог: с запросом пути там, где честно
/// разрешить её нечем.
///
/// Дорог три — ручной ввод цели, файловый выбор цели и поле VPN-приложения, —
/// и вопрос обязан звучать на каждой. Проглоченный молча `NeedsPath` оставляет
/// запись, не совпадающую ни с одним процессом: цель в списке выглядит живой
/// и при падении VPN не завершается. У VPN-приложения цена выше: невыбранное
/// не значит ничего, а **выбранное и не запущенное — это доказательство**,
/// то есть завершение всех целей разом. Ярлык flatpak у VPN-клиента —
/// не экзотика.
fn commit_entry(
    window: &ApplicationWindow,
    state: &Arc<AppState>,
    redraw: &Rc<dyn Fn()>,
    entry: &str,
    destination: Destination,
) {
    let entry = entry.trim();
    if entry.is_empty() {
        return;
    }

    match resolve_launch_entry(entry) {
        Resolution::Resolved(_) => {
            destination.commit(state, entry, None);
            redraw();
        }
        Resolution::NeedsPath { launcher } => {
            ask_for_program_path(window, state, redraw, entry, &launcher, destination)
        }
    }
}

/// Запрос файла программы, когда ярлык ведёт к чужому запускатору.
///
/// Отказаться добавить запись нельзя — пользователь её выбрал, — а угадать
/// нечем: программу заводит Steam или flatpak, и её файл в ярлыке не назван.
/// Поэтому спрашиваем прямо, а имя остаётся тем, которое стояло в ярлыке: иначе
/// в списке появилась бы строка, в которой пользователь свой выбор не узнает.
fn ask_for_program_path(
    window: &ApplicationWindow,
    state: &Arc<AppState>,
    redraw: &Rc<dyn Fn()>,
    entry: &str,
    launcher: &str,
    destination: Destination,
) {
    let name = display_name_for(entry);
    let title = name
        .clone()
        .unwrap_or_else(|| entry.rsplit('/').next().unwrap_or(entry).to_string());

    // Что weto сделает с файлом, у цели и у VPN-приложения разное: одну он
    // охраняет, за вторым следит. Общая часть — что без файла не выйдет ни то,
    // ни другое.
    let purpose = match destination {
        Destination::Target => "weto будет охранять именно его",
        Destination::VpnApp => "по нему weto и поймёт, запущен ли VPN-клиент",
    };
    let dialog = gtk4::AlertDialog::builder()
        .message("Нужен файл программы")
        .detail(format!(
            "«{title}» запускается через {launcher}, и какой процесс окажется \
             программой, из ярлыка не следует. Укажите файл программы — {purpose}."
        ))
        .buttons(["Указать файл", "Отмена"])
        .cancel_button(1)
        .default_button(0)
        .modal(true)
        .build();

    let parent = window.clone();
    let window = window.clone();
    let state = state.clone();
    let redraw = redraw.clone();
    dialog.choose(Some(&parent), gtk4::gio::Cancellable::NONE, move |answer| {
        // Отмена — не ошибка: цель просто не добавлена, и говорить об этом
        // пользователю нечего.
        if answer != Ok(0) {
            return;
        }

        let picker = gtk4::FileDialog::builder().title("Файл программы").build();
        // Ярлыки тут не помогут — за ними мы и пришли, — а программы живут
        // где угодно, чаще всего в домашнем каталоге.
        if let Some(home) = std::env::var_os("HOME") {
            picker.set_initial_folder(Some(&gtk4::gio::File::for_path(home)));
        }

        picker.open(Some(&window), gtk4::gio::Cancellable::NONE, move |result| {
            let Some(path) = result.ok().and_then(|file| file.path()) else {
                return;
            };
            destination.commit(&state, &path.to_string_lossy(), name);
            redraw();
        });
    });
}

// --- Подвал ---------------------------------------------------------------

fn footer(window: &ApplicationWindow, state: Arc<AppState>) -> GtkBox {
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
        window_tick(window, std::time::Duration::from_millis(500), move || {
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

fn journal_page(window: &ApplicationWindow, state: Arc<AppState>) -> ScrolledWindow {
    let page = GtkBox::new(Orientation::Vertical, ui::SPACE3);

    let card = ui::card("Журнал");
    let list = GtkBox::new(Orientation::Vertical, 0);
    card.append(&list);

    // Ряд из двух кнопок: выгрузка рядом с очисткой, как на macOS.
    let buttons = ui::row(false);
    buttons.set_margin_top(ui::SPACE3);
    let export_button = ui::muted_button("Выгрузить журнал");
    export_button.set_hexpand(true);
    let clear_button = ui::destructive_button("Очистить журнал");
    clear_button.set_hexpand(true);
    buttons.append(&export_button);
    buttons.append(&clear_button);
    card.append(&buttons);

    let redraw = {
        let state = state.clone();
        let list = list.clone();
        let clear_button = clear_button.clone();
        let export_button = export_button.clone();
        move || {
            clear(&list);
            let journal = state.journal();

            if journal.entries().is_empty() {
                let row = ui::row(true);
                row.append(&ui::caption("Срабатываний не было"));
                list.append(&row);
                clear_button.set_visible(false);
                export_button.set_visible(false);
                return;
            }

            clear_button.set_visible(true);
            export_button.set_visible(true);
            // Свежие сверху: журнал так и хранится, разворачивать нечего.
            for event in journal.entries() {
                list.append(&ui::journal_row(
                    &event.title(),
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

    // Выгрузка в файл, а не в буфер обмена: файл прикладывают к переписке,
    // а сотня записей с сырыми ответами сервисов в буфере нечитаема.
    {
        let state = state.clone();
        let window = window.downgrade();
        export_button.connect_clicked(move |_| {
            // Окно захвачено слабо: обработчик живёт внутри самого окна,
            // и сильная ссылка отсюда замкнула бы цикл окно → кнопка →
            // замыкание → окно. Сборщика циклов у GObject нет, `dispose`
            // не наступал бы никогда, и дерево виджетов утекало бы
            // при каждом открытии настроек.
            let Some(window) = window.upgrade() else {
                return;
            };
            let Some(text) = state.export_journal() else {
                return;
            };

            let dialog = gtk4::FileDialog::builder()
                .title("Выгрузка журнала weto")
                .initial_name(weto_config::export::JournalExport::file_name(&stamp_now()))
                .build();

            dialog.save(Some(&window), gtk4::gio::Cancellable::NONE, move |result| {
                // Отмена — не ошибка: пользователь передумал.
                let Ok(file) = result else { return };
                let Some(path) = file.path() else { return };
                if let Err(error) = std::fs::write(&path, &text) {
                    eprintln!("weto: журнал не выгрузился: {error}");
                }
            });
        });
    }

    page.append(&card);
    page.append(&footer(window, state));
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
    // Чем процесс попал под охрану: потомок называет родителя, шелл объясняет,
    // что целью он не был вовсе, а стоял ради её терминала.
    if let Some(basis) = event.matched_by.detail_text(event.parent_pid) {
        parts.push(basis);
    }
    if let Some(resolution) = &event.resolution_text {
        parts.push(format!("итог: {resolution}"));
    }
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

/// Выбор VPN-приложения с готовым именем.
///
/// Разрешается тем же путём, что цель: через симлинки и `PATH`, — иначе
/// правило, записанное «как введено», не совпало бы с процессом. Имя приходит
/// снаружи, когда запись и ярлык разошлись: файл программы указал пользователь,
/// а подписано приложение обязано быть тем именем, которое он видел в ярлыке.
fn set_vpn_app_named(state: &Arc<AppState>, text: &str, display_name: Option<String>) {
    let text = text.trim();
    if text.is_empty() {
        return;
    }

    let resolved = resolve_launch_target(text);
    let name = display_name
        .or_else(|| display_name_for(text))
        .unwrap_or_else(|| resolved.rsplit('/').next().unwrap_or(&resolved).to_string());

    state.settings.edit(|s| {
        s.set_vpn_app(Some(weto_config::settings::Target {
            entry: text.to_string(),
            display_name: name,
            kind: TargetKind::Binary,
            path: resolved,
            launch_paths: vec![text.to_string()],
        }))
    });
}

/// Отметка времени для имени файла — с точностью до минуты и без пробелов,
/// чтобы файл можно было приложить куда угодно, не переименовывая.
///
/// Считается вручную из unix-времени: тянуть chrono ради одной строки незачем,
/// а часового пояса у имени файла и не должно быть — UTC однозначен.
fn stamp_now() -> String {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default();

    let days = seconds / 86_400;
    let minute_of_day = (seconds % 86_400) / 60;
    let (year, month, day) = civil_from_days(days as i64);
    format!(
        "{year:04}-{month:02}-{day:02}-{:02}{:02}",
        minute_of_day / 60,
        minute_of_day % 60
    )
}

/// Григорианская дата из числа дней с эпохи — алгоритм Хиннанта.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}
