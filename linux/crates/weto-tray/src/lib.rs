//! Иконка в трее через StatusNotifierItem.
//!
//! # Чего здесь нет и почему
//!
//! Попапа, привязанного к иконке. Протокол SNI не сообщает координат иконки,
//! а Wayland не позволяет окну позиционировать себя самому, — привязать панель
//! к иконке нечем, кроме отказа от Wayland. Поэтому левый клик открывает окно
//! статуса, а место выбирает композитор.
//!
//! Правый клик показывает нативное меню: его рисует панель, а не мы, и потому
//! дизайн-система на него не распространяется — и не должна.

pub mod icon;
pub mod service;

use std::sync::mpsc::Sender;

use weto_core::presentation::ShieldState;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayEvent {
    /// Левый клик по иконке.
    Activate,
    CheckNow,
    OpenSettings,
    Quit,
}

pub struct WetoTray {
    state: ShieldState,
    title: String,
    events: Sender<TrayEvent>,
}

impl WetoTray {
    pub fn new(events: Sender<TrayEvent>) -> WetoTray {
        WetoTray {
            state: ShieldState::Pending,
            title: "Проверка подключения".to_string(),
            events,
        }
    }

    pub fn set_status(&mut self, state: ShieldState, title: &str) {
        self.state = state;
        self.title = title.to_string();
    }

    fn send(&self, event: TrayEvent) {
        // Приёмник исчезает только вместе с приложением; молчание здесь
        // означает, что показывать уже нечего.
        let _ = self.events.send(event);
    }
}

impl ksni::Tray for WetoTray {
    fn id(&self) -> String {
        "com.weto.app".to_string()
    }

    fn title(&self) -> String {
        self.title.clone()
    }

    /// Подсказка повторяет заголовок статуса: панель показывает её при наведении,
    /// и это единственное место, где текст статуса виден без открытия окна.
    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip {
            title: "weto".to_string(),
            description: self.title.clone(),
            icon_name: String::new(),
            icon_pixmap: Vec::new(),
        }
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        let pixmap = icon::render(self.state, icon::TRAY_SIZE);
        vec![ksni::Icon {
            width: pixmap.width,
            height: pixmap.height,
            data: pixmap.argb,
        }]
    }

    fn activate(&mut self, _x: i32, _y: i32) {
        self.send(TrayEvent::Activate);
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::{MenuItem, StandardItem};

        vec![
            StandardItem {
                label: "Проверить сейчас".into(),
                activate: Box::new(|tray: &mut WetoTray| tray.send(TrayEvent::CheckNow)),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Настройки".into(),
                activate: Box::new(|tray: &mut WetoTray| tray.send(TrayEvent::OpenSettings)),
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            StandardItem {
                label: "Выход".into(),
                activate: Box::new(|tray: &mut WetoTray| tray.send(TrayEvent::Quit)),
                ..Default::default()
            }
            .into(),
        ]
    }
}
