//! C ABI моста. Его зовёт приложение на C# через `LibraryImport`.
//!
//! Строки в обе стороны — UTF-8 с нулём на конце; строки, отданные мостом,
//! освобождает `weto_free_string`, и только он. Каждая функция обёрнута
//! в `catch_unwind`: паника, пересёкшая границу FFI, — неопределённое
//! поведение, и приложение упало бы без следа. Паника становится ответом
//! `{"ok":false,"error":"…"}` или нулевым указателем.
//!
//! Контракт ответа `weto_command`: `{"ok":true,"value":…}` или
//! `{"ok":false,"error":"текст для пользователя"}`.

use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use serde_json::json;

use weto_config::paths::Paths;
use weto_core::presentation::{backgrounded_notification, terminated_notification};
use weto_sys::notifications::KillNotifying;

use crate::app::WindowsApp;
use crate::command::Command;

/// Уведомление для C#: JSON `{"title":…,"body":…}`. Зовётся с потока охраны —
/// C# сам переносит показ на свой поток.
pub type NotifyCallback = extern "C" fn(context: *mut c_void, json: *const c_char);

#[repr(C)]
pub struct WetoCallbacks {
    pub context: *mut c_void,
    pub notify: Option<NotifyCallback>,
}

pub struct Weto {
    app: WindowsApp,
}

struct CallbackNotifier {
    /// Указатель контекста C# как число: сам указатель не `Send`, а C# обязуется
    /// держать контекст живым до `weto_stop`.
    context: usize,
    notify: Option<NotifyCallback>,
}

impl CallbackNotifier {
    fn send(&self, title: String, body: String) {
        let Some(notify) = self.notify else { return };
        let Ok(text) = CString::new(json!({"title": title, "body": body}).to_string()) else {
            return;
        };
        notify(self.context as *mut c_void, text.as_ptr());
    }
}

impl KillNotifying for CallbackNotifier {
    fn notify(&self, target_names: &[String], reason: &str, killed_count: usize) {
        let text = terminated_notification(target_names, reason, killed_count);
        self.send(text.title, text.body);
    }

    fn notify_backgrounded(&self, target_name: &str) {
        let text = backgrounded_notification(target_name);
        self.send(text.title, text.body);
    }
}

/// Поднять приложение и охрану. Нулевой указатель — не поднялось.
#[no_mangle]
pub extern "C" fn weto_start(callbacks: WetoCallbacks) -> *mut Weto {
    catch_unwind(AssertUnwindSafe(|| {
        let notifier = CallbackNotifier {
            context: callbacks.context as usize,
            notify: callbacks.notify,
        };
        let app = WindowsApp::new(Paths::from_windows_env(), Box::new(notifier));
        app.start();
        Box::into_raw(Box::new(Weto { app }))
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Модель экрана: `kind` — `"status"`, `"settings"`, `"journal"` или `"update"`. Нулевой указатель —
/// неизвестный вид или сбой.
///
/// # Safety
/// `weto` — указатель из `weto_start`, ещё не отданный `weto_stop`;
/// `kind` — строка UTF-8 с нулём на конце.
#[no_mangle]
pub unsafe extern "C" fn weto_view(weto: *const Weto, kind: *const c_char) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(weto), Some(kind)) = (weto.as_ref(), text(kind)) else {
            return std::ptr::null_mut();
        };
        let json = match kind.as_str() {
            "status" => serde_json::to_string(&weto.app.status()),
            "settings" => serde_json::to_string(&weto.app.settings()),
            "journal" => serde_json::to_string(&weto.app.journal()),
            "update" => serde_json::to_string(&weto.app.update()),
            "update-sample" => serde_json::to_string(&crate::update::sample_update()),
            "uninstall-confirmation" => serde_json::to_string(&crate::uninstall::confirmation()),
            "status-sample" => {
                serde_json::to_string(&crate::view::sample_status(std::time::SystemTime::now()))
            }
            _ => return std::ptr::null_mut(),
        };
        json.ok().map_or(std::ptr::null_mut(), owned)
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Исполнить команду (JSON, см. `command::Command`). Ответ всегда есть.
///
/// # Safety
/// Как у `weto_view`; `json` — строка UTF-8 с нулём на конце.
#[no_mangle]
pub unsafe extern "C" fn weto_command(weto: *const Weto, json: *const c_char) -> *mut c_char {
    let answer = catch_unwind(AssertUnwindSafe(|| {
        let Some(weto) = weto.as_ref() else {
            return json!({"ok": false, "error": "мост не поднят"});
        };
        let command: Command = match text(json).map(|text| serde_json::from_str(&text)) {
            Some(Ok(command)) => command,
            Some(Err(error)) => {
                return json!({"ok": false, "error": format!("команда не разобрана: {error}")})
            }
            None => return json!({"ok": false, "error": "команда не строка UTF-8"}),
        };
        match weto.app.command(command) {
            Ok(value) => json!({"ok": true, "value": value}),
            Err(error) => json!({"ok": false, "error": error}),
        }
    }))
    .unwrap_or_else(|_| json!({"ok": false, "error": "сбой внутри Weto"}));
    owned(answer.to_string())
}

/// Освободить строку, отданную мостом.
///
/// # Safety
/// `text` — нулевой указатель или строка из `weto_view`/`weto_command`,
/// ещё не освобождённая.
#[no_mangle]
pub unsafe extern "C" fn weto_free_string(text: *mut c_char) {
    if !text.is_null() {
        drop(CString::from_raw(text));
    }
}

/// Штатный выход: SIGCONT по учёту (продолжить стоящие цели) и конец охраны.
/// После вызова указатель недействителен.
///
/// # Safety
/// `weto` — указатель из `weto_start`, отдаётся сюда ровно раз.
#[no_mangle]
pub unsafe extern "C" fn weto_stop(weto: *mut Weto) {
    if weto.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let weto = Box::from_raw(weto);
        weto.app.shutdown();
    }));
}

/// Уведомлять при удалении некого: окна нет, охрана не запускалась.
struct Silent;

impl KillNotifying for Silent {
    fn notify(&self, _: &[String], _: &str, _: usize) {}
    fn notify_backgrounded(&self, _: &str) {}
}

/// Проверка перед сносом (`Weto.exe --uninstall`): охрана не запускается,
/// стоящие по учёту продолжаются, оставшиеся называются. Ответ —
/// `{"standing":N,"dialog":{title,message,confirm,cancel}|null}`; нулевой
/// указатель — сбой, и деинсталлятор удаление отменит.
#[no_mangle]
pub extern "C" fn weto_uninstall_check() -> *mut c_char {
    catch_unwind(|| {
        let app = WindowsApp::new(Paths::from_windows_env(), Box::new(Silent));
        serde_json::to_string(&app.uninstall_check())
            .ok()
            .map_or(std::ptr::null_mut(), owned)
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Снос токена и автозапуска (`Weto.exe --uninstall-cleanup`). Ответ —
/// `{"ok":true}` или `{"ok":false,"error":…}`.
#[no_mangle]
pub extern "C" fn weto_uninstall_cleanup() -> *mut c_char {
    let answer = catch_unwind(|| {
        let app = WindowsApp::new(Paths::from_windows_env(), Box::new(Silent));
        match app.uninstall_cleanup() {
            Ok(()) => json!({"ok": true}),
            Err(error) => json!({"ok": false, "error": error}),
        }
    })
    .unwrap_or_else(|_| json!({"ok": false, "error": "сбой внутри Weto"}));
    owned(answer.to_string())
}

unsafe fn text(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    CStr::from_ptr(pointer).to_str().ok().map(str::to_string)
}

fn owned(text: String) -> *mut c_char {
    CString::new(text).map_or(std::ptr::null_mut(), CString::into_raw)
}
