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
use weto_core::pause_ceiling::PauseCeiling;
use weto_core::presentation::{target_description, target_fallback_name};
use weto_sys::autostart::Autostart;
use weto_sys::secret_store::{FileSecretStore, SecretStoring};
use weto_sys::target_resolver::{
    applications_dirs, display_name_for, launch_paths_for, locate_with_launch_paths,
    resolve_launch_entry, resolve_launch_target, target_kind_for, LaunchTargetResolver, Resolution,
};
use weto_ui::components as ui;
use weto_ui::theme;

use crate::lifecycle::window_tick;
use crate::state::AppState;

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
        .title("Weto — настройки")
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
    page.append(&maintenance_card(window, state.clone()));
    page.append(&footer(window));

    scroll(&page)
}

// --- Цели -----------------------------------------------------------------

fn targets_card(window: &ApplicationWindow, state: Arc<AppState>) -> GtkBox {
    let holder = GtkBox::new(Orientation::Vertical, ui::SPACE2);

    let card = ui::card("Цели");
    let list = GtkBox::new(Orientation::Vertical, 0);
    card.append(&list);

    // Линию над вводом ставит перерисовка: пока целей нет, над ним одна
    // строка-заглушка, и линия отделяла бы ввод от пустоты.
    let add_row = ui::row(true);
    let entry = ui::entry("Новая цель");
    // Формат ввода — значком в конце поля, а не подписью под карточкой: подпись
    // под карточкой не читалась как относящаяся к полю. Про бандлы здесь
    // не сказано ни слова — на Linux нет каталога, которым можно накрыть
    // процессы разом, и вид цели `appBundle` не переносится.
    ui::entry_hint(
        &entry,
        "Имя команды (nano) или путь (/usr/bin/curl). \
         Дочерние процессы завершаются вместе с родителем.",
    );
    let add = ui::primary_button("Добавить");
    let pick = ui::muted_button("Выбрать…");
    add_row.append(&entry);
    add_row.append(&add);
    add_row.append(&pick);
    card.append(&add_row);

    holder.append(&card);

    // Виджеты карточки перерисовка держит слабо: её зовут кнопки внутри той же
    // строки ввода, и сильная ссылка замкнула бы цикл строка → кнопка →
    // обработчик → перерисовка → строка. Окно уходит, а карточка вместе
    // с состоянием приложения оставалась бы в памяти на каждое открытие настроек.
    let redraw = {
        let state = state.clone();
        let list = list.downgrade();
        let add_row = add_row.downgrade();
        move || {
            let (Some(list), Some(add_row)) = (list.upgrade(), add_row.upgrade()) else {
                return;
            };
            clear(&list);
            let settings = state.settings.current();
            ui::set_divided(&add_row, ui::input_row_divided(settings.targets.len()));

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
                row.append(&ui::data_value(&count.to_string()));

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
        // Поле — слабо: этот же обработчик висит на нём самом.
        let entry = entry.downgrade();
        let redraw = redraw.clone();
        let window = window.downgrade();
        move || {
            let Some(entry) = entry.upgrade() else {
                return;
            };
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

/// Описание цели под именем — что стоит за ней сейчас, а не в момент
/// добавления. Путь спрашивается у границы при каждой перерисовке: обновление
/// инструмента из версионного каталога меняет развёрнутый путь целиком,
/// и запомненный путь показывал бы удалённую версию. Чего на диске нет,
/// то «не найдено» — с подсказкой, что делать, как на macOS. Вид берётся
/// у файла тем же ответом, что и путь: цель, записанная бинарником до того,
/// как вид стали различать, подписана «скрипт», как её и узнаёт охрана.
///
/// Кандидаты те же, что у охраны (`locate_with_launch_paths`): голое имя,
/// которого нет в `PATH` приложения, находится по файлу в `PATH`, запомненному
/// при добавлении, — иначе под целью, которую охрана сторожит, стояло бы
/// «не найдено».
fn resolved_description(target: &weto_config::settings::Target) -> String {
    let found =
        locate_with_launch_paths(&LaunchTargetResolver, &target.entry, &target.launch_paths);
    target_description(
        &target.entry,
        found.as_ref().map_or(target.kind, |found| found.kind),
        found.as_ref().map(|found| found.path.as_str()),
    )
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
        .unwrap_or_else(|| target_fallback_name(text));
    // Голое имя запоминается вместе с файлом в PATH (`~/.local/bin/claude`):
    // охрана разрешает цель заново, и если голого имени в её PATH не окажется,
    // она начнёт с него, а не с развёрнутого пути, устаревающего с обновлением.
    let launch_paths = launch_paths_for(text);
    // Скрипт с шебангом (`qwen` из npm) ядро запускает интерпретатором,
    // и по пути `exe` он не совпал бы ни с одним процессом — его узнают по argv.
    let kind = target_kind_for(text);

    state.settings.edit(|s| {
        s.targets.push(weto_config::settings::Target {
            entry: text.to_string(),
            display_name: name,
            kind,
            path: resolved,
            launch_paths,
        })
    });
}

// --- Сеть и гео -----------------------------------------------------------

fn network_card(window: &ApplicationWindow, state: Arc<AppState>) -> GtkBox {
    let card = ui::card("Сеть и гео");

    // VPN-приложение: та же форма, что цель, — команда или путь. Список туннелей
    // здесь стоял раньше и ушёл вместе с самим выбором туннеля: имена вида utun6
    // и wg0 пользователю ничего не говорят и меняются при переподключении.
    //
    // Строка в двух состояниях, как `NetworkSettingsCard` на macOS: не выбрано —
    // «не выбрано», поле и «Выбрать»; выбрано — имя над описанием справа
    // и корзина. Поле вместо файлового диалога — отступление Linux: команду
    // и путь здесь вводят руками, как у цели.
    let vpn_row = ui::row(true);
    vpn_row.append(&ui::label("VPN-приложение"));
    vpn_row.append(&ui::spacer());

    let unchosen = GtkBox::new(Orientation::Horizontal, ui::SPACE3);
    unchosen.append(&ui::faint_value("не выбрано"));
    let vpn_entry = ui::entry("Команда или путь");
    let vpn_set = ui::primary_button("Выбрать");
    unchosen.append(&vpn_entry);
    unchosen.append(&vpn_set);
    vpn_row.append(&unchosen);

    let chosen = GtkBox::new(Orientation::Horizontal, ui::SPACE3);
    let chosen_text = GtkBox::new(Orientation::Vertical, 2);
    chosen_text.set_valign(gtk4::Align::Center);
    let vpn_name = ui::ink_value("");
    vpn_name.set_xalign(1.0);
    let vpn_description = ui::caption("");
    vpn_description.set_halign(gtk4::Align::End);
    vpn_description.set_xalign(1.0);
    vpn_description.set_selectable(true);
    vpn_description.set_wrap(true);
    vpn_description.set_wrap_mode(gtk4::pango::WrapMode::WordChar);
    chosen_text.append(&vpn_name);
    chosen_text.append(&vpn_description);
    chosen.append(&chosen_text);
    let vpn_clear = ui::icon_button("user-trash-symbolic");
    vpn_clear.set_tooltip_text(Some("Снять выбор"));
    vpn_clear.set_valign(gtk4::Align::Center);
    chosen.append(&vpn_clear);
    vpn_row.append(&chosen);
    card.append(&vpn_row);

    // Состояние строки берётся из настроек при каждом показе: выбор меняют
    // и кнопки этой же строки, и правка конфига снаружи, а описание обязано
    // следовать за версионным путём так же, как у целей.
    //
    // Виджеты строки замыкание держит слабо: кнопки «Выбрать» и корзина живут
    // внутри `unchosen` и `chosen` и сами держат это замыкание, и сильная ссылка
    // отсюда замкнула бы цикл контейнер → кнопка → обработчик → замыкание →
    // контейнер. Окно при этом уходит, а строка вместе с состоянием приложения
    // остаётся в памяти навсегда — на каждое открытие настроек.
    let show: Rc<dyn Fn()> = {
        let state = state.clone();
        let unchosen = unchosen.downgrade();
        let chosen = chosen.downgrade();
        let vpn_name = vpn_name.downgrade();
        let vpn_description = vpn_description.downgrade();
        Rc::new(move || {
            let (Some(unchosen), Some(chosen), Some(vpn_name), Some(vpn_description)) = (
                unchosen.upgrade(),
                chosen.upgrade(),
                vpn_name.upgrade(),
                vpn_description.upgrade(),
            ) else {
                return;
            };
            let app = state.settings.current().vpn_app;
            unchosen.set_visible(app.is_none());
            chosen.set_visible(app.is_some());
            if let Some(app) = app {
                // Текст меняется, только когда изменился: такт идёт дважды
                // в секунду, а подмена снимала бы выделение с описания,
                // которое копируют в обращение.
                let description = resolved_description(&app);
                if vpn_name.text() != app.display_name {
                    vpn_name.set_text(&app.display_name);
                }
                if vpn_description.text() != description {
                    vpn_description.set_text(&description);
                }
            }
        })
    };
    show();

    {
        let show = show.clone();
        window_tick(window, std::time::Duration::from_millis(500), move || {
            show();
            gtk4::glib::ControlFlow::Continue
        });
    }

    {
        let state = state.clone();
        let vpn_entry = vpn_entry.clone();
        let show = show.clone();
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
            // Перерисовка — сама строка: выбор переключает её во второе
            // состояние сразу, а не на следующем такте.
            commit_entry(
                &window,
                &state,
                &show,
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
            show();
        });
    }

    // Подписи строк с полем и с сегментами — одна колонка шириной с самую длинную:
    // поле токена и сегменты таймаута начинаются с одной вертикали. Отступ после
    // колонки — `space5`, как в каноне и на macOS.
    let label_column = gtk4::SizeGroup::new(gtk4::SizeGroupMode::Horizontal);

    // Токен ipinfo.
    let token_row = ui::row(false);
    // Пояснение — после названия: поле обычно заполнено маской, и значок в конце
    // поля, видный только у пустого поля, его бы не показал.
    let token_label = GtkBox::new(Orientation::Horizontal, ui::SPACE2);
    token_label.append(&ui::label("Токен ipinfo"));
    token_label.append(&ui::hint(
        "Ключ ipinfo.io — единственного сервиса, который называет адрес выхода. \
         Без ключа проверять нечем: цели встают на паузу и по таймауту завершаются. \
         Ключ бесплатный: ipinfo.io → Sign Up → Dashboard → API Token. \
         Хранится отдельно от настроек и в выгрузку журнала не попадает.",
    ));
    token_label.set_margin_end(ui::SPACE5 - ui::SPACE3);
    label_column.add_widget(&token_label);
    token_row.append(&token_label);
    let token_entry = ui::entry("Ключ ipinfo.io");
    token_row.append(&token_entry);
    card.append(&token_row);

    // Ошибка — своей строкой под полем, с паддингом строки, как `WetoRow`
    // на macOS.
    let (token_error_row, token_error) = ui::error_row();
    card.append(&token_error_row);

    // Сохранённый токен помнится здесь, а не перечитывается: маска при уходе
    // из поля обязана описывать то, что записано сейчас, а не при открытии окна.
    let path = state.paths.token_file();
    let stored = Rc::new(RefCell::new(
        FileSecretStore::new(path.clone())
            .load()
            .ok()
            .flatten()
            .unwrap_or_default(),
    ));
    token_entry.set_text(&token_field_text(&stored.borrow(), false));

    // Подмена текста при входе в поле и уходе из него — не ввод. `set_text`
    // у поля GTK — это стирание и вставка, и `changed` приходит дважды:
    // первым — с пустой строкой, которую обработчик принял бы за стёртый
    // ключ и записал.
    let replacing = Rc::new(std::cell::Cell::new(false));

    {
        let stored = stored.clone();
        let replacing = replacing.clone();
        token_entry.connect_changed(move |entry| {
            if replacing.get() {
                return;
            }
            // Маска и показ токена при входе в поле — не ввод: сохранять
            // нечего. Решает чистый помощник, здесь только запись.
            let Some(value) = token_to_save(&entry.text(), &stored.borrow()) else {
                return;
            };
            // Токен считается сохранённым только после успешной записи:
            // тихая ошибка выдавала бы его за сохранённый.
            match FileSecretStore::new(path.clone()).save(&value) {
                Ok(()) => {
                    *stored.borrow_mut() = value;
                    ui::set_error(&token_error, None);
                }
                Err(error) => ui::set_error(&token_error, Some(&error.to_string())),
            }
        });
    }

    // В фокусе — сам токен, вне фокуса — маска, как на macOS. Маска, стоявшая
    // в поле и при правке, уходила в файл вместе с дописанным символом:
    // токеном из точек, на который ipinfo отвечает отказом.
    //
    // Поле берётся у контроллера, а не захватывается: контроллер принадлежит
    // полю, и сильная ссылка на поле из его же обработчика замкнула бы цикл.
    let focus = gtk4::EventControllerFocus::new();
    for focused in [true, false] {
        let stored = stored.clone();
        let replacing = replacing.clone();
        let show = move |controller: &gtk4::EventControllerFocus| {
            if let Some(entry) = controller.widget().and_downcast::<gtk4::Entry>() {
                replacing.set(true);
                entry.set_text(&token_field_text(&stored.borrow(), focused));
                replacing.set(false);
            }
        };
        if focused {
            focus.connect_enter(show);
        } else {
            focus.connect_leave(show);
        }
    }
    token_entry.add_controller(focus);

    // Таймаут подтверждения: сколько цели стоят на паузе до завершения.
    // Мимо ревизии: потолок решения политики не меняет, а ревизия обесценила бы
    // вердикт и увела охрану в «Проверку» с пробой.
    let timeout_row = ui::row(false);
    let timeout_label = GtkBox::new(Orientation::Horizontal, ui::SPACE2);
    timeout_label.append(&ui::label("Таймаут"));
    timeout_label.append(&ui::hint(
        "Сколько цели стоят на паузе, если сервисы не подтвердили безопасный выход. \
         Подтверждение пришло — цели продолжают работу, не пришло за это время — \
         завершаются. Отсчёт идёт от начала паузы, новое значение действует сразу, \
         в том числе на текущую паузу.",
    ));
    timeout_label.set_margin_end(ui::SPACE5 - ui::SPACE3);
    label_column.add_widget(&timeout_label);
    timeout_row.append(&timeout_label);
    let current = state.settings.current().pause_ceiling();
    let titles: Vec<String> = PauseCeiling::ALL.iter().map(|c| c.title()).collect();
    let title_refs: Vec<&str> = titles.iter().map(String::as_str).collect();
    let selected = PauseCeiling::ALL
        .iter()
        .position(|c| *c == current)
        .unwrap_or(0);
    let (segments, buttons) = ui::segments(&title_refs, selected);
    segments.set_hexpand(true);
    timeout_row.append(&segments);
    card.append(&timeout_row);

    for (button, ceiling) in buttons.iter().zip(PauseCeiling::ALL) {
        let state = state.clone();
        button.connect_toggled(move |button| {
            if button.is_active() {
                state
                    .settings
                    .edit_untracked(|s| s.pause_ceiling_seconds = ceiling.seconds());
            }
        });
    }

    card
}

/// Что стоит в поле токена. В фокусе — сам токен: его правят, и правка
/// маски сохраняла бы точки. Вне фокуса — маска: хвост токена, а не сам
/// токен, — подтвердить «тот ли ключ» так можно, а подсмотреть через плечо
/// нет. Порт `onChange(of: isTokenFocused)` из `NetworkSettingsCard`.
fn token_field_text(stored: &str, focused: bool) -> String {
    if focused {
        stored.to_string()
    } else {
        mask(stored)
    }
}

/// Что сохранить из поля токена, если сохранять есть что.
///
/// Точка маски в настоящем токене не встречается, поэтому текст с ней — маска
/// или её обломок, а не ввод: так маска не уходит в файл ни целой,
/// ни правленой. Совпавший с записанным текст — показ токена при входе
/// в поле, а не правка.
fn token_to_save(text: &str, stored: &str) -> Option<String> {
    if text.contains(MASK_DOT) {
        return None;
    }
    let value = text.trim();
    (value != stored).then(|| value.to_string())
}

/// Знак маски токена.
const MASK_DOT: char = '•';

fn mask(token: &str) -> String {
    let length = token.chars().count();
    if length == 0 {
        return String::new();
    }
    let dots = |count: usize| MASK_DOT.to_string().repeat(count);
    if length <= 4 {
        return dots(length);
    }
    let tail: String = token.chars().skip(length - 4).collect();
    format!("{}{tail}", dots(length - 4))
}

// --- Списки геоправил -----------------------------------------------------

/// Один builder на обе карточки: чёрный и белый списки отличаются только
/// заголовком и видом списка. Второй экземпляр функции разъехался бы с первым
/// молча, а расходиться им нельзя.
fn geo_list_card(state: Arc<AppState>, kind: GeoListKind, title: &str) -> GtkBox {
    let card = ui::card(title);
    let list = GtkBox::new(Orientation::Vertical, 0);
    card.append(&list);

    // Линию над вводом ставит перерисовка: пока список пуст, над ним одна
    // строка-заглушка, и линия отделяла бы ввод от пустоты.
    let add_row = ui::row(true);
    let entry = ui::entry("Код страны (RU), IP или CIDR");
    // Плейсхолдер исчезает при первом символе, поэтому формат повторён значком.
    ui::entry_hint(
        &entry,
        "Код страны из двух букв (RU), IP-адрес (203.0.113.7) \
         или диапазон CIDR (203.0.113.0/24).",
    );
    let add = ui::primary_button("Добавить");
    add_row.append(&entry);
    add_row.append(&add);
    card.append(&add_row);

    // Отказ — своей строкой под вводом, с паддингом строки, как на macOS.
    let (error_row, error) = ui::error_row();
    card.append(&error_row);

    // Перерисовка через `Rc`, чтобы её могли позвать и кнопки внутри строк,
    // которые она же и создаёт.
    //
    // Себя перерисовка помнит слабо, как и виджеты карточки: сильная ссылка на
    // собственную ячейку — цикл в счётчиках ссылок, который не рвётся никогда,
    // а виджеты держат кнопки той же строки ввода. Ячейку держат обработчики
    // ввода — ровно столько, сколько живёт карточка.
    let redraw: Redraw = Rc::new(RefCell::new(None));
    {
        let state = state.clone();
        let list = list.downgrade();
        let self_ref = Rc::downgrade(&redraw);
        let add_row = add_row.downgrade();
        let draw: Rc<dyn Fn()> = Rc::new(move || {
            let (Some(list), Some(add_row)) = (list.upgrade(), add_row.upgrade()) else {
                return;
            };
            clear(&list);
            let entries = state.settings.current().entries(kind);
            ui::set_divided(&add_row, ui::input_row_divided(entries.len()));

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
                    let draw = again.upgrade().and_then(|slot| slot.borrow().clone());
                    if let Some(draw) = draw {
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
        // Поле — слабо: этот же обработчик висит на нём самом.
        let entry = entry.downgrade();
        let error = error.clone();
        let redraw = redraw.clone();
        move || {
            let Some(entry) = entry.upgrade() else {
                return;
            };
            let text = entry.text().to_string();
            // Разбор и проверка живут в настройках: экрану остаётся показать отказ.
            let mut outcome = Ok(());
            state.settings.edit(|s| outcome = s.add_entry(&text, kind));

            match outcome {
                Ok(()) => {
                    entry.set_text("");
                    ui::set_error(&error, None);
                    redraw();
                }
                Err(failure) => ui::set_error(&error, Some(&failure.to_string())),
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

/// Включена ли автоустановка — у механизма обновления, а без него (тест окна)
/// — в хранилище.
fn auto_install(state: &AppState) -> bool {
    match crate::update::shared() {
        Some(updates) => updates.auto_install(),
        None => {
            weto_update::store::UpdateStore::new(state.paths.state_dir.clone())
                .deferral()
                .auto_install
        }
    }
}

fn maintenance_card(window: &ApplicationWindow, state: Arc<AppState>) -> GtkBox {
    let card = ui::card("Обслуживание");
    let autostart = Autostart::new(&state.paths);

    // Отказ — своей строкой под тумблерами, с паддингом строки, как на macOS.
    let (error_row, error) = ui::error_row();

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
                Ok(()) => ui::set_error(&error, None),
                Err(failure) => ui::set_error(&error, Some(&failure.to_string())),
            }

            // Состояние берём из системы, а не из нажатия: отказ не должен
            // выглядеть успехом.
            switch.set_state(autostart.is_enabled());
            gtk4::glib::Propagation::Stop
        });
    }

    // Автообновление. Та же настройка, что галочка в окне обновления:
    // значение одно (`Updates::auto_install`), и оба места сверяются с ним
    // своим тактом. Включение сразу ставит найденное обновление — как
    // сеттер `isAutoInstallEnabled` на macOS. Линии между тумблерами нет,
    // как в `MaintenanceCard` на macOS: два тумблера читаются одной группой.
    let auto_row = ui::row(true);
    auto_row.append(&ui::label("Обновлять автоматически"));
    auto_row.append(&ui::spacer());
    let auto = ui::toggle();
    auto.set_active(auto_install(&state));
    auto_row.append(&auto);
    card.append(&auto_row);

    {
        let state_dir = state.paths.state_dir.clone();
        auto.connect_state_set(move |_, value| {
            match crate::update::shared() {
                Some(updates) => updates.set_auto_install(value),
                // Механизм обновления не поднят (тест окна) — пишем в хранилище
                // напрямую: настройка от этого не перестаёт быть настройкой.
                None => {
                    weto_update::store::UpdateStore::new(state_dir.clone()).set_auto_install(value)
                }
            }
            gtk4::glib::Propagation::Proceed
        });
    }
    {
        let auto = auto.clone();
        let state = state.clone();
        window_tick(window, std::time::Duration::from_millis(500), move || {
            let stored = auto_install(&state);
            if auto.is_active() != stored {
                auto.set_active(stored);
            }
            gtk4::glib::ControlFlow::Continue
        });
    }

    card.append(&error_row);

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
        ask_to_close(button.root().and_downcast::<gtk4::Window>().as_ref());
    });

    {
        let error = error.clone();
        let state = state.clone();
        uninstall.connect_clicked(move |button| {
            let error = error.clone();
            let state = state.clone();
            confirm(
                button,
                "Удалить Weto?",
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
                                "Эти программы Weto поставил на паузу, и они ещё не продолжились:",
                                &standing_detail(&standing),
                                "Удалить всё равно",
                                "Не удалять и закрыть Weto",
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
        "{}\n\nОхрана уже остановлена и обратно не включится: Weto придётся \
         запустить заново.\n\nЕсли удалить Weto сейчас, вернуть эти программы \
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
        Ok(()) => quit(),
        Err(failure) => {
            // Исход у неудачи тоже один, и это выход. Охрана к этому моменту
            // остановлена необратимо: ворота применения закрыты, фаза сброшена,
            // а тумблера охраны в продукте нет. Оставить окно с текстом ошибки
            // значило бы оставить иконку в трее у приложения, которое уже
            // ничего не охраняет и молчит об этом.
            ui::set_error(error, Some(&failure));

            let dialog = gtk4::AlertDialog::builder()
                .message("Удаление прошло не полностью")
                .detail(format!(
                    "{failure}\n\nWeto закроется: охрана уже остановлена, и продолжать \
                     он не может. Оставшееся удалите вручную."
                ))
                .buttons(["Закрыть"])
                .default_button(0)
                .modal(true)
                .build();
            let parent = error.root().and_downcast::<gtk4::Window>();
            dialog.choose(parent.as_ref(), gtk4::gio::Cancellable::NONE, move |_| {
                quit()
            });
        }
    }
}

/// Выход одной воронкой: `connect_shutdown` вернёт цели из паузы сам.
fn quit() {
    if let Some(app) = gtk4::gio::Application::default() {
        app.quit();
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
        // Enter не нажимает ничего: закрыть или удалить можно только явным нажатием.
        .default_button(-1)
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

thread_local! {
    /// Диалог закрытия уже на экране. Второй «Выход» из трея поднимал бы
    /// вторую копию поверх первой, и отвечать пришлось бы дважды.
    static CLOSE_ASKED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// «Закрыть Weto?» — один диалог на оба входа: кнопку «Закрыть приложение»
/// в «Обслуживании» и пункт «Выход» в трее. На macOS выйти можно только через
/// него, и «Выход» без вопроса снимал бы охрану одним промахом по меню.
///
/// Про «до следующего входа в систему» текст обещать не имеет права:
/// автозапуск по умолчанию выключен, и без него Weto не вернётся никогда.
/// Дословно как на macOS (`MaintenanceCard.confirmClose`).
pub fn close_confirmation() -> gtk4::AlertDialog {
    confirmation(
        "Закрыть Weto?",
        "Приложение завершится и перестанет охранять цели. Настройки, журнал \
         и автозапуск сохранятся: если автозапуск включён, Weto вернётся \
         при следующем входе в систему.",
        "Закрыть",
    )
}

/// Спрашивает «Закрыть Weto?» и выходит по согласию. Окна может не быть
/// вовсе — «Выход» из трея при закрытом окне, — тогда диалог стоит сам по себе.
pub fn ask_to_close(parent: Option<&gtk4::Window>) {
    if CLOSE_ASKED.with(|asked| asked.replace(true)) {
        return;
    }
    close_confirmation().choose(parent, gtk4::gio::Cancellable::NONE, |answer| {
        CLOSE_ASKED.with(|asked| asked.set(false));
        if answer == Ok(0) {
            // Замороженных целей выход не оставляет: SIGCONT шлёт воронка
            // `connect_shutdown`, а не этот диалог — иначе обязательство
            // держалось бы на каждом входе в выход, а закрытие последнего окна
            // проходило бы мимо него.
            quit();
        }
    });
}

/// Диалог подтверждения: «сделать» и «Отмена», Enter и Esc — «Отмена».
/// Enter по привычке не должен делать необратимое; на macOS так же
/// (`makeSafeButtonDefault`).
fn confirmation(title: &str, detail: &str, confirm_title: &str) -> gtk4::AlertDialog {
    gtk4::AlertDialog::builder()
        .message(title)
        .detail(detail)
        .buttons([confirm_title, "Отмена"])
        .cancel_button(1)
        // Enter не нажимает ничего: закрыть или удалить можно только явным нажатием.
        .default_button(-1)
        .modal(true)
        .build()
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
    let window = anchor.root().and_downcast::<gtk4::Window>();
    confirmation(title, detail, confirm_title).choose(
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
        Destination::Target => "Weto будет охранять именно его",
        Destination::VpnApp => "по нему Weto и поймёт, запущен ли VPN-клиент",
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

fn footer(window: &ApplicationWindow) -> GtkBox {
    let footer = GtkBox::new(Orientation::Horizontal, ui::SPACE3);
    footer.set_margin_top(ui::SPACE2);

    let github = ui::link_button("github");
    github.set_tooltip_text(Some(crate::update::REPOSITORY_URL));
    footer.append(&github);
    footer.append(&ui::spacer());

    let version = ui::caption(&format!("версия {}", crate::update::current_version()));
    footer.append(&version);

    // Плитка только проверяет или показывает найденное: установка запускается
    // из окна обновления. Ручная проверка игнорирует пропуск и отсрочку —
    // другого способа вернуть пропущенную версию нет.
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

    // Найденная версия открывает окно, а не проверяет заново: на macOS
    // повторная проверка заканчивается тем же окном, здесь — без похода в сеть.
    //
    // Приложение берётся у корня кнопки, а не у захваченного окна: сильная
    // ссылка на окно в обработчике его же виджета держала бы окно в памяти
    // после закрытия (`window_release.rs`).
    {
        check.connect_clicked(move |button| {
            let Some(updates) = crate::update::shared() else {
                return;
            };
            match updates.found() {
                Some(info) => {
                    let app = button
                        .root()
                        .and_downcast::<gtk4::Window>()
                        .and_then(|window| window.application());
                    if let Some(app) = app {
                        crate::update_window::present(&app, &info);
                    }
                }
                None => {
                    updates.check_now();
                    // Неактивна сразу, а не со следующего такта: второе нажатие
                    // в эти полсекунды начинать нечего.
                    button.set_sensitive(false);
                }
            }
        });
    }

    // Состояние плитки — из исхода проверки, как `SettingsFooter` на macOS:
    // неактивна, пока идут проверка или установка; подсказка называет исход;
    // иконка и имя для диктора говорят, что нажатие покажет обновление.
    {
        let check = check.clone();
        let mut shown: Option<(bool, String)> = None;
        let mut refresh = move || {
            let Some(updates) = crate::update::shared() else {
                return;
            };
            // Активность ставится каждый такт: нажатие гасит плитку само,
            // и проверка, ответившая быстрее такта, иначе оставила бы её
            // погашенной навсегда.
            check.set_sensitive(!updates.is_busy());

            let state = updates.state();
            let installing = updates.progress().as_update_progress().is_in_flight();
            let offers = crate::update::footer_shows_update(&state, updates.pending().is_some());
            let view = (offers, crate::update::footer_hint(&state, installing));
            if shown.as_ref() == Some(&view) {
                return;
            }
            let (offers, hint) = &view;
            check.set_tooltip_text(Some(hint));
            check.set_icon_name(if *offers {
                "software-update-available-symbolic"
            } else {
                "view-refresh-symbolic"
            });
            check.update_property(&[gtk4::accessible::Property::Label(if *offers {
                "Показать обновление"
            } else {
                "Проверить обновления"
            })]);
            shown = Some(view);
        };
        refresh();
        window_tick(window, std::time::Duration::from_millis(500), move || {
            refresh();
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

    // Ряд из двух кнопок: выгрузка рядом с очисткой, как на macOS. Линии над
    // ним нет — его отделяет от записей отступ, а не разделитель строк.
    let buttons = ui::action_row();
    buttons.set_margin_top(ui::SPACE3);
    let export_button = ui::muted_button("Выгрузить журнал");
    export_button.set_hexpand(true);
    let clear_button = ui::destructive_button("Очистить журнал");
    clear_button.set_hexpand(true);
    buttons.append(&export_button);
    buttons.append(&clear_button);
    card.append(&buttons);

    // Слабо по той же причине, что у карточек настроек: перерисовку зовёт
    // кнопка очистки, которую перерисовка сама прячет и показывает.
    let redraw = {
        let state = state.clone();
        let list = list.downgrade();
        let clear_button = clear_button.downgrade();
        move || {
            let (Some(list), Some(clear_button)) = (list.upgrade(), clear_button.upgrade()) else {
                return;
            };
            clear(&list);
            let journal = state.journal();
            let entries = journal.entries();

            // Выгрузка доступна всегда, а не только когда есть завершения:
            // ради «нажал проверить, и ничего не произошло» журнал проверок
            // и заведён, а завершений в этом случае нет вовсе. Да и пустая
            // выгрузка не бесполезна — в ней настройки и версии. Очищать же
            // пустой журнал нечего.
            clear_button.set_visible(!entries.is_empty());

            if entries.is_empty() {
                let row = ui::row(true);
                row.append(&ui::caption("Срабатываний не было"));
                list.append(&row);
                return;
            }

            // Свежие сверху: журнал так и хранится, разворачивать нечего.
            // Линия стоит между записями, а не над первой.
            let visible = entries.iter().take(weto_config::journal::VISIBLE_LIMIT);
            for (index, event) in visible.enumerate() {
                if index > 0 {
                    list.append(&ui::divider());
                }
                list.append(&ui::journal_row(
                    &event.title(),
                    &event.summary_text(),
                    event.resolution_line().as_deref(),
                    &event.diagnostics_text(&local_timestamp(event.at)),
                ));
            }

            if let Some(text) = weto_config::journal::visible_limit_caption(entries.len()) {
                let row = ui::row(true);
                row.append(&ui::caption(&text));
                list.append(&row);
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
                report_export_failure(&window, "не удалось собрать файл журнала");
                return;
            };

            let dialog = gtk4::FileDialog::builder()
                .title("Выгрузка журнала Weto")
                .initial_name(weto_config::export::JournalExport::file_name(&stamp_now()))
                .build();

            let parent = window.clone();
            dialog.save(Some(&window), gtk4::gio::Cancellable::NONE, move |result| {
                // Отмена — не ошибка: пользователь передумал.
                let Ok(file) = result else { return };
                let Some(path) = file.path() else { return };
                if let Err(error) = std::fs::write(&path, &text) {
                    report_export_failure(&parent, &error.to_string());
                }
            });
        });
    }

    page.append(&card);
    page.append(&footer(window));
    scroll(&page)
}

/// Местное время записи для строки показаний.
///
/// Смещение берётся на момент самой записи, а не на «сейчас»: запись, сделанная
/// до перевода часов, иначе показывала бы чужой час. Пояс знает GLib, ядро
/// получает готовое смещение — системы оно не касается.
fn local_timestamp(at: std::time::SystemTime) -> String {
    let seconds = at
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or_default();
    let offset = gtk4::glib::DateTime::from_unix_local(seconds)
        .map(|local| local.utc_offset().as_seconds())
        .unwrap_or_default();
    weto_core::timestamp::to_local_display(at, offset)
}

/// Неудавшаяся выгрузка — диалогом, как `NSAlert` на macOS: в терминал,
/// куда она писалась раньше, пользователь приложения из трея не смотрит,
/// и выглядело это как «нажал — ничего не произошло».
fn report_export_failure(window: &ApplicationWindow, failure: &str) {
    let dialog = gtk4::AlertDialog::builder()
        .message("Журнал не выгрузился")
        .detail(failure)
        .buttons(["OK"])
        .default_button(0)
        .modal(true)
        .build();
    dialog.show(Some(window));
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
        .unwrap_or_else(|| target_fallback_name(text));
    // Файл в PATH запоминается по той же причине, что у цели, и вид
    // определяется так же: VPN-клиент-скрипт, записанный бинарником, читался бы
    // закрытым всегда — а это завершение целей.
    let launch_paths = launch_paths_for(text);
    let kind = target_kind_for(text);

    state.settings.edit(|s| {
        s.set_vpn_app(Some(weto_config::settings::Target {
            entry: text.to_string(),
            display_name: name,
            kind,
            path: resolved,
            launch_paths,
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

#[cfg(test)]
mod token_field_tests {
    use super::{token_field_text, token_to_save};

    /// В фокусе поле показывает сам токен — его правят, — а вне фокуса маску:
    /// подтвердить «тот ли ключ» по хвосту можно, подсмотреть через плечо — нет.
    /// Как `onChange(of: isTokenFocused)` в `NetworkSettingsCard` на macOS.
    #[test]
    fn the_field_shows_the_token_only_while_focused() {
        assert_eq!(token_field_text("abcd1234efgh", true), "abcd1234efgh");
        assert_eq!(token_field_text("abcd1234efgh", false), "••••••••efgh");
        assert_eq!(token_field_text("abc", false), "•••");
        assert_eq!(token_field_text("", false), "");
        assert_eq!(token_field_text("", true), "");
    }

    /// Маска — не ввод: ни она сама, ни правленая маска не сохраняются. Раньше
    /// маска стояла в поле и в фокусе, и дописанный к ней символ уходил в файл
    /// токеном из точек — ipinfo отвечал отказом, а цели вставали на паузу.
    #[test]
    fn the_mask_is_never_saved() {
        let stored = "abcd1234efgh";
        assert_eq!(token_to_save("••••••••efgh", stored), None);
        assert_eq!(token_to_save("••••••••efghX", stored), None);
        assert_eq!(token_to_save("••••••••efg", stored), None);
    }

    /// Сохраняется только настоящая правка: показ токена при входе в поле
    /// записью не является, а пробелы по краям — частая добыча копирования.
    #[test]
    fn only_a_real_edit_is_saved() {
        let stored = "abcd1234efgh";
        assert_eq!(token_to_save(stored, stored), None);
        assert_eq!(
            token_to_save(" newtoken42 ", stored),
            Some("newtoken42".to_string())
        );
        // Стёртое поле — тоже правка: пользователь убирает ключ.
        assert_eq!(token_to_save("", stored), Some(String::new()));
        // Пустое поле при пустом токене — нечего сохранять.
        assert_eq!(token_to_save("", ""), None);
    }
}
