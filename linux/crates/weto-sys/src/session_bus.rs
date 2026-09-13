//! Одно соединение с сессионной шиной на весь процесс.
//!
//! Шина нужна двоим — уведомлениям и подъёму терминала, — и второе соединение
//! им ничего не даёт: `zbus::blocking::Connection` клонируется и делится
//! сокетом. Соединение ленивое и переспрашиваемое: сессионная шина может
//! подняться позже нас (автозапуск), и один неудачный ответ на старте не должен
//! оставлять приложение без уведомлений до перезапуска.

use std::sync::Mutex;
use std::time::Duration;

use zbus::blocking::connection::Builder;
use zbus::blocking::Connection;

/// Потолок ожидания ответа. Умолчание zbus — 25 секунд, а спрашиваем мы шину
/// из главного цикла GTK: зависшее приложение держало бы окно weto колом
/// почти полминуты. Три секунды — заведомо больше любого живого ответа.
const METHOD_TIMEOUT: Duration = Duration::from_secs(3);

static BUS: Mutex<Option<Connection>> = Mutex::new(None);

pub fn session() -> Option<Connection> {
    let mut slot = BUS.lock().ok()?;
    if slot.is_none() {
        match Builder::session().and_then(|builder| builder.method_timeout(METHOD_TIMEOUT).build())
        {
            Ok(connection) => *slot = Some(connection),
            // Шины нет вовсе — окружение без рабочего стола. Это не отказ:
            // уведомления и подъём окна там не существуют как явление.
            Err(_) => return None,
        }
    }
    slot.clone()
}
