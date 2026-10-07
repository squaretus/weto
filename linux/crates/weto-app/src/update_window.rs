//! Окно обновления — порт `UpdateDialogView` и `UpdateWindowPresenter` с macOS.
//!
//! Одно окно на два состояния: предложение обновиться и ход установки. Что
//! показывать, решает `UpdateDialogModel` из `weto-update`, вёрстка только
//! рисует. Ответов три, и это три разных решения: «Обновить» ставит сейчас,
//! «Напомнить позже» откладывает разговор на выбранный срок, «Пропустить
//! версию» молчит до версии выше. Четвёртого, снимающего пропуск, нет: его
//! снимает ручная проверка в подвале настроек.
//!
//! Заметок релиза здесь нет — решение владельца: на macOS их нет тоже.

use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use gtk4::prelude::*;
use gtk4::{Align, ApplicationWindow, Box as GtkBox, Label, Orientation, ProgressBar};

use weto_ui::components as ui;
use weto_ui::theme;
use weto_update::dialog::{release_page, UpdateDialogModel};
use weto_update::policy::{RemindInterval, UpdateInfo};
use weto_update::strings::UpdateStrings;

use crate::lifecycle::window_tick;
use crate::update::{shared, APP_NAME, RELEASES_URL};

/// Сторона иконки приложения — как `frame(width: 52, height: 52)` на macOS.
pub const ICON_SIZE: i32 = 52;

/// Зазор ряда кнопок. Между соседями стоит распорка с тем же наименьшим
/// размером, поэтому наименьший промежуток — три таких зазора: два у ящика
/// и сама распорка. На шаге 9 это 27 — те же промежутки, что выходят
/// на macOS при ширине окна 513.
const ROW_SPACING: i32 = ui::SPACE3;

/// Поля окна — `.weto-update-dialog { padding: space5 }` в стилях.
const PADDING: i32 = ui::SPACE5;

/// Ширина окна, при которой ряд кнопок помещается целиком, — порт
/// `UpdateDialogView.minimumWidth(fittingButtons:)`.
///
/// Число не на глаз, а из замера живых кнопок: смена подписи или стиля
/// пилюли иначе тихо выносит последнюю кнопку за край. Свободной ширины
/// сверх этого нет, поэтому распорки делят ровно наименьшие промежутки.
pub fn dialog_width(button_widths: &[i32]) -> i32 {
    let Some((first, rest)) = button_widths.split_first() else {
        return 0;
    };
    let per_gap = ROW_SPACING * 3;
    rest.iter()
        .fold(*first, |width, next| width + per_gap + next)
        + PADDING * 2
}

struct Shown {
    window: ApplicationWindow,
    info: Rc<RefCell<UpdateInfo>>,
}

thread_local! {
    static WINDOW: RefCell<Option<Shown>> = const { RefCell::new(None) };
}

/// Показывает окно; уже открытое поднимается и узнаёт о новой находке.
pub fn present(app: &gtk4::Application, info: &UpdateInfo) {
    let existing = WINDOW.with(|slot| {
        slot.borrow().as_ref().map(|shown| {
            *shown.info.borrow_mut() = info.clone();
            shown.window.clone()
        })
    });
    if let Some(window) = existing {
        window.present();
        return;
    }

    let info = Rc::new(RefCell::new(info.clone()));
    let window = build(app, info.clone());
    WINDOW.with(|slot| {
        *slot.borrow_mut() = Some(Shown {
            window: window.clone(),
            info,
        })
    });
    window.present();
}

/// Закрытие ответом — пропуском или отсрочкой. Окно уходит из слота раньше,
/// чем закрывается: обработчик закрытия отличает ответ от крестика именно
/// по этому.
fn close() {
    let shown = WINDOW.with(|slot| slot.borrow_mut().take());
    if let Some(shown) = shown {
        shown.window.close();
    }
}

fn build(app: &gtk4::Application, info: Rc<RefCell<UpdateInfo>>) -> ApplicationWindow {
    let strings = UpdateStrings::new(APP_NAME);

    let window = ApplicationWindow::builder()
        .application(app)
        .title(strings.progress_title())
        .modal(false)
        .build();
    theme::mark_root(&window);

    // Закрытие крестиком равно «напомнить позже»: молчаливое закрытие
    // не должно означать «больше никогда». Закрытие ответом сюда тоже
    // приходит, но окна в слоте к этому мигу уже нет.
    window.connect_close_request(|_| {
        let closed_by_user = WINDOW.with(|slot| slot.borrow_mut().take()).is_some();
        if closed_by_user {
            if let Some(updates) = shared() {
                updates.dismiss();
            }
        }
        gtk4::glib::Propagation::Proceed
    });

    let root = GtkBox::new(Orientation::Vertical, ui::SPACE5);
    root.add_css_class("weto-update-dialog");
    window.set_child(Some(&root));

    // Ряд кнопок идёт во всю ширину окна, а не внутри колонки с текстом:
    // в колонке ему осталась бы ширина минус иконка.
    let header = GtkBox::new(Orientation::Horizontal, ui::SPACE4);
    header.append(&app_icon());

    let column = GtkBox::new(Orientation::Vertical, ui::SPACE3);
    column.set_hexpand(true);

    let title = Label::new(None);
    title.add_css_class("weto-status-title");
    title.add_css_class("ink");
    title.set_halign(Align::Start);
    title.set_xalign(0.0);
    title.set_wrap(true);
    column.append(&title);

    let detail = ui::value("");
    detail.set_halign(Align::Start);
    detail.set_xalign(0.0);
    detail.set_wrap(true);
    column.append(&detail);

    let bar = ProgressBar::new();
    bar.set_visible(false);
    column.append(&bar);

    let auto = ui::checkbox(strings.auto_install_toggle());
    auto.set_active(shared().is_some_and(|updates| updates.auto_install()));
    column.append(&auto);

    header.append(&column);
    root.append(&header);

    // Свободная ширина делится между кнопками поровну — по распорке на каждый
    // промежуток. С одной распоркой ряд читался как две группы.
    let buttons = GtkBox::new(Orientation::Horizontal, ROW_SPACING);
    buttons.set_valign(Align::Center);

    let skip = ui::muted_button(strings.skip());
    let titles: Vec<&str> = RemindInterval::ALL
        .iter()
        .map(|interval| strings.remind_title(*interval))
        .collect();
    let (remind, remind_items) = ui::menu_button(strings.remind_later(), &titles);
    let install = ui::primary_button(strings.install());
    let release = ui::muted_button(strings.open_release_page());
    let (gap_before_remind, gap_before_install, gap_before_release) = (gap(), gap(), gap());

    buttons.append(&skip);
    buttons.append(&gap_before_remind);
    buttons.append(&remind);
    buttons.append(&gap_before_install);
    buttons.append(&install);
    buttons.append(&gap_before_release);
    buttons.append(&release);
    root.append(&buttons);

    // Ширина — из замера живых кнопок, а не с потолка: они уже в окне
    // и получили стили, поэтому замер видит настоящие пилюли.
    let widths: Vec<i32> = [
        skip.upcast_ref::<gtk4::Widget>(),
        remind.upcast_ref(),
        install.upcast_ref(),
    ]
    .iter()
    .map(|button| button.measure(Orientation::Horizontal, -1).1)
    .collect();
    window.set_default_size(dialog_width(&widths), -1);

    {
        let info = info.clone();
        install.connect_clicked(move |_| {
            if let Some(updates) = shared() {
                updates.install(&info.borrow());
            }
        });
    }

    for (item, interval) in remind_items.iter().zip(RemindInterval::ALL) {
        item.connect_clicked(move |_| {
            if let Some(updates) = shared() {
                updates.remind_later(interval);
            }
            close();
        });
    }

    {
        let info = info.clone();
        skip.connect_clicked(move |_| {
            let version = info.borrow().latest_version.clone();
            if let Some(updates) = shared() {
                updates.skip(&version);
            }
            close();
        });
    }

    {
        let info = info.clone();
        release.connect_clicked(move |button| {
            let Some(address) = release_page(Some(&info.borrow()), RELEASES_URL) else {
                return;
            };
            gtk4::UriLauncher::new(&address).launch(
                button.root().and_downcast::<gtk4::Window>().as_ref(),
                gtk4::gio::Cancellable::NONE,
                |_| {},
            );
        });
    }

    auto.connect_toggled(|check| {
        if let Some(updates) = shared() {
            updates.set_auto_install(check.is_active());
        }
    });

    let view = View {
        title,
        detail,
        bar,
        auto,
        choice: vec![
            skip.upcast(),
            gap_before_remind,
            remind.upcast(),
            gap_before_install,
            install.upcast(),
        ],
        release: vec![gap_before_release, release.upcast()],
    };
    let mut shown: Option<UpdateDialogModel> = None;
    let mut refresh = move || {
        let Some(updates) = shared() else { return };
        let model =
            UpdateDialogModel::make(Some(&info.borrow()), &updates.update_progress(), &strings);
        view.render(&model, shown.as_ref());
        shown = Some(model);

        // Галочка и тумблер «Обслуживания» — одна настройка: правка в одном
        // месте видна в другом на следующем такте.
        if view.auto.is_active() != updates.auto_install() {
            view.auto.set_active(updates.auto_install());
        }
    };
    refresh();
    window_tick(&window, Duration::from_millis(200), move || {
        refresh();
        gtk4::glib::ControlFlow::Continue
    });

    window
}

struct View {
    title: Label,
    detail: Label,
    bar: ProgressBar,
    auto: gtk4::CheckButton,
    /// «Пропустить версию», «Напомнить позже», «Обновить» и распорки между ними.
    choice: Vec<gtk4::Widget>,
    /// «Открыть страницу релиза» и распорка перед ней.
    release: Vec<gtk4::Widget>,
}

impl View {
    /// Тексты и видимость меняются только на смену модели: ряд кнопок,
    /// пересобранный посреди нажатия, нажатия бы не получил. Полоса же
    /// без доли идёт каждый такт — это её способ сказать «работаю».
    fn render(&self, model: &UpdateDialogModel, shown: Option<&UpdateDialogModel>) {
        if shown != Some(model) {
            self.title.set_text(&model.title);
            self.detail.set_text(&model.detail);
            self.bar.set_visible(model.shows_progress);
            self.auto.set_visible(model.shows_choice_buttons);
            for widget in &self.choice {
                widget.set_visible(model.shows_choice_buttons);
            }
            for widget in &self.release {
                widget.set_visible(model.shows_release_page_button);
            }
        }
        match model.fraction {
            Some(fraction) => self.bar.set_fraction(fraction),
            // Распаковка хода не отдаёт — полоса честно неопределённая.
            None if model.shows_progress => self.bar.pulse(),
            None => {}
        }
    }
}

/// Распорка между кнопками: съедает свободную ширину и не уже `ROW_SPACING`.
fn gap() -> gtk4::Widget {
    let gap = ui::spacer();
    gap.set_size_request(ROW_SPACING, -1);
    gap.upcast()
}

/// Иконка приложения под текущую тему — та же картинка, что `WetoAppIcon`
/// на macOS, из тех же исходников. Рисуется вдвое крупнее показа: на экране
/// с масштабом 2 она иначе вышла бы мыльной.
fn app_icon() -> gtk4::Image {
    let light = crate::current_theme() == theme::Theme::Light;
    let side = ICON_SIZE * 2;
    let picture = weto_tray::icon::app_icon(light, side as u32);
    let bytes = gtk4::glib::Bytes::from_owned(picture.rgba);
    let texture = gtk4::gdk::MemoryTexture::new(
        side,
        side,
        gtk4::gdk::MemoryFormat::R8g8b8a8Premultiplied,
        &bytes,
        side as usize * 4,
    );

    let image = gtk4::Image::from_paintable(Some(&texture));
    image.set_pixel_size(ICON_SIZE);
    image.set_valign(Align::Start);
    image.add_css_class("weto-app-icon");
    image
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Порт `minimumWidth`: кнопки целиком, между соседями — по три зазора,
    /// по краям — поля окна.
    #[test]
    fn the_window_is_as_wide_as_its_buttons_and_gaps() {
        assert_eq!(dialog_width(&[]), 0);
        assert_eq!(dialog_width(&[100]), 100 + 36);
        assert_eq!(dialog_width(&[100, 120, 80]), 100 + 27 + 120 + 27 + 80 + 36);
    }
}
