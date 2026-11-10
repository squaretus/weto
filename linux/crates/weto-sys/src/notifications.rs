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

#[cfg(target_os = "linux")]
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
#[cfg(target_os = "linux")]
use std::sync::Mutex;

#[cfg(target_os = "linux")]
use zbus::blocking::Connection;

#[cfg(target_os = "linux")]
use crate::session_bus;

#[cfg(target_os = "linux")]
const SERVICE: &str = "org.freedesktop.Notifications";
#[cfg(target_os = "linux")]
const PATH: &str = "/org/freedesktop/Notifications";

/// Сколько своих уведомлений помним, чтобы узнать своё нажатие. Больше
/// незачем: сигнал приходит про то, что видно на экране сейчас.
#[cfg(target_os = "linux")]
const REMEMBERED: usize = 16;

pub trait KillNotifying: Send + Sync {
    /// Цели прохода («claude ×34», «codex»), причина и число процессов,
    /// завершённых этим проходом. Порт macOS `GuardNotifying.notifyTerminated`.
    fn notify(&self, target_names: &[String], reason: &str, killed_count: usize);

    /// Терминальная цель под паузой потеряла терминал: её задание перестало
    /// быть передним, и без уведомления пропажу процесса из терминала
    /// не заметить вовсе. Порт macOS `GuardNotifying.notifyBackgrounded`.
    fn notify_backgrounded(&self, target_name: &str);
}

/// Что делать по нажатию на уведомление. Порт `UserNotificationGuardNotifier.onOpen`:
/// там обработчик ставит приложение один раз на старте, здесь — тоже.
pub type OpenHandler = Arc<dyn Fn() + Send + Sync>;

#[cfg(target_os = "linux")]
pub struct DesktopNotifier {
    bus: Option<Connection>,
    /// Сервер умеет действия, и нам есть что по ним делать.
    actionable: bool,
    /// Идентификаторы своих уведомлений: `ActionInvoked` прилетает про все,
    /// включая чужие.
    ours: Arc<Mutex<VecDeque<u32>>>,
}

#[cfg(target_os = "linux")]
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
            vec!["default".to_string(), "Открыть Weto".to_string()]
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
                    // Имя приложения сервер показывает в шапке уведомления:
                    // это текст интерфейса, и пишется он «Weto».
                    "Weto",
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

#[cfg(target_os = "linux")]
impl Default for DesktopNotifier {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(target_os = "linux")]
impl KillNotifying for DesktopNotifier {
    /// Дословно как на macOS (`UserNotificationGuardNotifier.notifyTerminated`
    /// с текстом из `GuardVM.terminateTargets`): заголовок общий, а цели,
    /// причина и число — в тексте. Число — процессы, а не цели: «claude ×34»
    /// это тридцать четыре завершённых процесса.
    fn notify(&self, target_names: &[String], reason: &str, killed_count: usize) {
        self.send(
            "Weto: процессы завершены".to_string(),
            format!(
                "{}: {reason}. Завершено процессов: {killed_count}.",
                target_names.join(", ")
            ),
        );
    }

    fn notify_backgrounded(&self, target_name: &str) {
        self.send(
            format!("Weto: {target_name} вернулся в фон"),
            "Процесс на паузе потерял терминал. Когда пауза снимется, Weto вернёт его сам или подскажет, что ввести.".to_string(),
        );
    }
}

#[cfg(target_os = "linux")]
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
#[cfg(target_os = "linux")]
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
