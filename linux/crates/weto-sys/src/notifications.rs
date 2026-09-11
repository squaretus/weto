//! Уведомления охраны.
//!
//! Порт `GuardNotifying` с macOS: две новости — завершённые цели и цель,
//! потерявшая терминал под паузой. Вторую без уведомления не заметить вовсе:
//! процесс просто «пропадает» из терминала.
//!
//! Разговор идёт прямо с `org.freedesktop.Notifications` по сессионной шине,
//! а не через `notify-send`. Причина одна и она же — нажатие: на macOS тап
//! по уведомлению открывает попап, а дочерний `notify-send` рассказать
//! о нажатии не может ничем. Через шину это штатное действие `default`
//! и сигнал `ActionInvoked`, и weto показывает окно статуса ровно как там.
//!
//! Сервер уведомлений действий может не поддерживать (`GetCapabilities`
//! без `actions`) — тогда уведомление уходит без них и остаётся просто
//! сообщением. Шины нет вовсе — уведомлений в системе нет как явления,
//! и молчать правильнее, чем падать.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};

use zbus::blocking::Connection;

use crate::session_bus;

const SERVICE: &str = "org.freedesktop.Notifications";
const PATH: &str = "/org/freedesktop/Notifications";

/// Сколько своих уведомлений помним, чтобы узнать своё нажатие. Больше
/// незачем: сигнал приходит про то, что видно на экране сейчас.
const REMEMBERED: usize = 16;

pub trait KillNotifying: Send + Sync {
    fn notify(&self, target_names: &[String], reason: &str);

    /// Терминальная цель под паузой потеряла терминал: её задание перестало
    /// быть передним, и без уведомления пропажу процесса из терминала
    /// не заметить вовсе. Порт macOS `GuardNotifying.notifyBackgrounded`.
    fn notify_backgrounded(&self, target_name: &str);
}

/// Что делать по нажатию на уведомление. Порт `UserNotificationGuardNotifier.onOpen`:
/// там обработчик ставит приложение один раз на старте, здесь — тоже.
pub type OpenHandler = Arc<dyn Fn() + Send + Sync>;

pub struct DesktopNotifier {
    bus: Option<Connection>,
    /// Сервер умеет действия, и нам есть что по ним делать.
    actionable: bool,
    /// Идентификаторы своих уведомлений: `ActionInvoked` прилетает про все,
    /// включая чужие.
    ours: Arc<Mutex<VecDeque<u32>>>,
}

impl DesktopNotifier {
    pub fn new() -> DesktopNotifier {
        DesktopNotifier::build(None)
    }

    /// То же самое, но нажатие открывает окно статуса.
    pub fn with_open_handler(handler: OpenHandler) -> DesktopNotifier {
        DesktopNotifier::build(Some(handler))
    }

    fn build(handler: Option<OpenHandler>) -> DesktopNotifier {
        let bus = session_bus::session();
        let ours: Arc<Mutex<VecDeque<u32>>> = Arc::new(Mutex::new(VecDeque::new()));

        let actionable = match (&bus, &handler) {
            (Some(bus), Some(_)) => supports_actions(bus),
            _ => false,
        };

        if actionable {
            if let (Some(bus), Some(handler)) = (bus.clone(), handler) {
                listen(bus, ours.clone(), handler);
            }
        }

        DesktopNotifier {
            bus,
            actionable,
            ours,
        }
    }

    /// Отправка уходит на отдельный поток: вызов идёт из такта охраны,
    /// а зависший сервер уведомлений держал бы ответ секундами. Ошибка
    /// игнорируется намеренно — уведомление приятное дополнение,
    /// а не часть защиты.
    fn send(&self, summary: String, body: String) {
        let Some(bus) = self.bus.clone() else {
            return;
        };
        let actions: Vec<String> = if self.actionable {
            vec!["default".to_string(), "Открыть weto".to_string()]
        } else {
            Vec::new()
        };
        let ours = self.ours.clone();

        std::thread::spawn(move || {
            let hints: HashMap<&str, zbus::zvariant::Value> = HashMap::new();
            let reply = bus.call_method(
                Some(SERVICE),
                PATH,
                Some(SERVICE),
                "Notify",
                &(
                    "weto",
                    0u32,
                    "security-high",
                    summary.as_str(),
                    body.as_str(),
                    actions,
                    hints,
                    -1i32,
                ),
            );
            match reply.and_then(|reply| reply.body().deserialize::<u32>()) {
                Ok(id) => {
                    let mut ours = ours.lock().expect("свои уведомления");
                    ours.push_back(id);
                    while ours.len() > REMEMBERED {
                        ours.pop_front();
                    }
                }
                Err(error) => eprintln!("weto: уведомление не ушло: {error}"),
            }
        });
    }
}

impl Default for DesktopNotifier {
    fn default() -> Self {
        Self::new()
    }
}

impl KillNotifying for DesktopNotifier {
    fn notify(&self, target_names: &[String], reason: &str) {
        let targets = if target_names.is_empty() {
            "неизвестная цель".to_string()
        } else {
            target_names.join(", ")
        };
        self.send(format!("Завершено: {targets}"), reason.to_string());
    }

    fn notify_backgrounded(&self, target_name: &str) {
        self.send(
            format!("Weto: {target_name} вернулся в фон"),
            "Процесс на паузе потерял терминал. Откройте терминал и введите fg.".to_string(),
        );
    }
}

fn supports_actions(bus: &Connection) -> bool {
    bus.call_method(Some(SERVICE), PATH, Some(SERVICE), "GetCapabilities", &())
        .and_then(|reply| reply.body().deserialize::<Vec<String>>())
        .map(|capabilities| capabilities.iter().any(|name| name == "actions"))
        .unwrap_or(false)
}

/// Слушает `ActionInvoked` и зовёт обработчик на своих уведомлениях.
///
/// Отдельный поток на всю жизнь процесса: подписка блокирующая, а окно
/// пользователь открывает нажатием в любой момент.
fn listen(bus: Connection, ours: Arc<Mutex<VecDeque<u32>>>, handler: OpenHandler) {
    std::thread::Builder::new()
        .name("weto-notifications".to_string())
        .spawn(move || {
            let proxy = match zbus::blocking::Proxy::new(&bus, SERVICE, PATH, SERVICE) {
                Ok(proxy) => proxy,
                Err(error) => {
                    eprintln!("weto: подписка на уведомления не удалась: {error}");
                    return;
                }
            };
            let signals = match proxy.receive_signal("ActionInvoked") {
                Ok(signals) => signals,
                Err(error) => {
                    eprintln!("weto: подписка на нажатия не удалась: {error}");
                    return;
                }
            };
            for message in signals {
                let Ok((id, _action)) = message.body().deserialize::<(u32, String)>() else {
                    continue;
                };
                let mine = ours.lock().map(|ours| ours.contains(&id)).unwrap_or(false);
                if mine {
                    handler();
                }
            }
        })
        .expect("поток уведомлений не создался");
}
