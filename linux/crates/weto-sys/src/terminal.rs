//! Подъём терминала, в котором сидит стоящая цель.
//!
//! Порт макосного `TerminalLocating`. Там окно поднимает `NSRunningApplication`
//! у процесса, владеющего бандлом; здесь — `org.freedesktop.Application.Activate`
//! по имени на шине. Внешних инструментов (`wmctrl`, `xdotool`) граница
//! не запускает: зависимость, которой может не быть в системе, хуже честного
//! отсутствия кнопки.
//!
//! Решение «который из предков и есть терминал» живёт в ядре
//! (`weto_core::terminal::choose`), а граница отвечает на два вопроса, которые
//! без системы не решаются: кто этот предок по ярлыку `.desktop` и владеет ли
//! он именем на шине, за которым лежит интерфейс приложения.
//!
//! Чего механизм не умеет — не умеет по устройству рабочего стола, а не по
//! недосмотру: эмулятор, не выходящий на сессионную шину (xterm, alacritty,
//! kitty, foot, xfce4-terminal, mate-terminal, terminator), поднять нечем,
//! и кнопки у такой цели не будет. Подсказка про `fg` остаётся: она и есть
//! ответ пользователю.

use std::collections::HashMap;
use std::sync::OnceLock;

use weto_core::process::ProcessSnapshot;
use weto_core::terminal::{self, TerminalCandidate, TerminalHost};

use crate::desktop_entries::DesktopIndex;
use crate::session_bus;

const DBUS_SERVICE: &str = "org.freedesktop.DBus";
const DBUS_PATH: &str = "/org/freedesktop/DBus";
const APPLICATION_INTERFACE: &str = "org.freedesktop.Application";

pub trait TerminalActivating: Send + Sync {
    /// Кто держит терминал этого процесса и можно ли его поднять.
    fn locate(&self, pid: i32, processes: &[ProcessSnapshot]) -> Option<TerminalHost>;

    /// Поднять окно. `false` — поднимать нечем; отправка сама по себе успехом
    /// не считается только в этом смысле: ответа приложения мы не ждём.
    fn activate(&self, host: &TerminalHost) -> bool;
}

pub struct DesktopTerminalActivator {
    index: OnceLock<DesktopIndex>,
}

impl DesktopTerminalActivator {
    /// Индекс ярлыков читается лениво, при первом вопросе: это сотни файлов
    /// в `/usr/share/applications`, а вопрос задаётся только у цели, потерявшей
    /// терминал под паузой. Платить за него каждым запуском незачем.
    pub fn new() -> DesktopTerminalActivator {
        DesktopTerminalActivator {
            index: OnceLock::new(),
        }
    }

    pub fn with_index(index: DesktopIndex) -> DesktopTerminalActivator {
        let slot = OnceLock::new();
        let _ = slot.set(index);
        DesktopTerminalActivator { index: slot }
    }

    fn index(&self) -> &DesktopIndex {
        self.index.get_or_init(DesktopIndex::load)
    }

    /// Кому из процессов принадлежат общеизвестные имена на шине.
    ///
    /// Спрашивается целиком, потому что обратного вопроса у шины нет: имя
    /// по процессу не ищется, ищется процесс по имени. Список коротким не
    /// назвать (полторы-две сотни имён в живой сессии), поэтому обход идёт
    /// один раз на вызов, а интерфейс держит ответ в кэше — стоящая цель
    /// не меняет терминала.
    fn owners(&self) -> HashMap<i32, Vec<String>> {
        let mut owners: HashMap<i32, Vec<String>> = HashMap::new();
        let Some(bus) = session_bus::session() else {
            return owners;
        };

        let Ok(reply) = bus.call_method(
            Some(DBUS_SERVICE),
            DBUS_PATH,
            Some(DBUS_SERVICE),
            "ListNames",
            &(),
        ) else {
            return owners;
        };
        let Ok(names) = reply.body().deserialize::<Vec<String>>() else {
            return owners;
        };

        for name in names {
            // Уникальные имена (`:1.42`) поднять нельзя: путь объекта берётся
            // из общеизвестного имени, и у уникального его попросту нет.
            if name.starts_with(':') || name == DBUS_SERVICE {
                continue;
            }
            let Ok(reply) = bus.call_method(
                Some(DBUS_SERVICE),
                DBUS_PATH,
                Some(DBUS_SERVICE),
                "GetConnectionUnixProcessID",
                &(name.as_str(),),
            ) else {
                continue;
            };
            if let Ok(pid) = reply.body().deserialize::<u32>() {
                owners.entry(pid as i32).or_default().push(name);
            }
        }
        owners
    }

    /// Лежит ли за именем интерфейс приложения.
    ///
    /// Спрашивается интроспекцией, а не `DBusActivatable=true` из ярлыка:
    /// флаг говорит лишь о праве шины **запустить** приложение, а нам нужно
    /// поднять уже работающее. У gnome-terminal флага в ярлыке нет вовсе,
    /// а интерфейс его сервер экспортирует — как всякий GApplication.
    fn exports_application(&self, name: &str) -> bool {
        let Some(path) = terminal::object_path_for(name) else {
            return false;
        };
        let Some(bus) = session_bus::session() else {
            return false;
        };
        let Ok(reply) = bus.call_method(
            Some(name),
            path.as_str(),
            Some("org.freedesktop.DBus.Introspectable"),
            "Introspect",
            &(),
        ) else {
            return false;
        };
        reply
            .body()
            .deserialize::<String>()
            .map(|xml| xml.contains(APPLICATION_INTERFACE))
            .unwrap_or(false)
    }
}

impl Default for DesktopTerminalActivator {
    fn default() -> Self {
        Self::new()
    }
}

impl TerminalActivating for DesktopTerminalActivator {
    fn locate(&self, pid: i32, processes: &[ProcessSnapshot]) -> Option<TerminalHost> {
        let walk = terminal::ancestry(pid, processes);
        if walk.is_empty() {
            return None;
        }

        let owners = self.owners();
        let candidates: Vec<TerminalCandidate> = walk
            .iter()
            .map(|process| {
                let program = terminal::program_name(&process.executable_path).to_string();
                let entry = self.index().find(&program);
                let bus_names = owners
                    .get(&process.pid)
                    .map(|names| {
                        names
                            .iter()
                            .filter(|name| self.exports_application(name))
                            .cloned()
                            .collect()
                    })
                    .unwrap_or_default();

                TerminalCandidate {
                    pid: process.pid,
                    program,
                    desktop_id: entry.map(|entry| entry.desktop_id.clone()),
                    is_terminal_emulator: entry.is_some_and(|entry| entry.is_terminal_emulator),
                    bus_names,
                }
            })
            .collect();

        terminal::choose(&candidates)
    }

    fn activate(&self, host: &TerminalHost) -> bool {
        let (Some(name), Some(path)) = (host.bus_name.clone(), host.object_path.clone()) else {
            return false;
        };
        let Some(bus) = session_bus::session() else {
            return false;
        };

        // Вызов уходит на отдельный поток: нажатие идёт из главного цикла GTK,
        // а зависшее приложение держало бы ответ по умолчанию 25 секунд —
        // всё это время окно weto стояло бы колом.
        std::thread::spawn(move || {
            let platform_data: HashMap<&str, zbus::zvariant::Value> = HashMap::new();
            if let Err(error) = bus.call_method(
                Some(name.as_str()),
                path.as_str(),
                Some(APPLICATION_INTERFACE),
                "Activate",
                &(platform_data,),
            ) {
                eprintln!("weto: терминал не поднялся ({name}): {error}");
            }
        });
        true
    }
}
