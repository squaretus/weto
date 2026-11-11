//! Мост целиком через C ABI — так, как его зовёт C#: поднять, прочитать экраны,
//! отдать команды, остановить. Профиль подменён временным каталогом: настройки
//! и журналы раннера тест не трогает.
//!
//! Идёт на раннерах Windows; на других системах файла нет.
#![cfg(windows)]

use std::ffi::{c_char, c_void, CStr, CString};

use serde_json::Value;
use weto_ffi::abi::{
    weto_command, weto_free_string, weto_start, weto_stop, weto_view, WetoCallbacks,
};

extern "C" fn ignore(_: *mut c_void, _: *const c_char) {}

fn answer(pointer: *mut c_char) -> Value {
    assert!(!pointer.is_null(), "мост вернул нулевой указатель");
    // SAFETY: строка от моста, освобождается его же функцией ровно раз.
    let value = unsafe { serde_json::from_str(CStr::from_ptr(pointer).to_str().unwrap()).unwrap() };
    unsafe { weto_free_string(pointer) };
    value
}

#[test]
fn the_bridge_starts_shows_screens_takes_commands_and_stops() {
    let profile = tempfile::tempdir().unwrap();
    // Один тест в файле: переменные процесса меняются до запуска моста
    // и ни с кем не делятся.
    std::env::set_var("APPDATA", profile.path().join("Roaming"));
    std::env::set_var("LOCALAPPDATA", profile.path().join("Local"));

    let weto = weto_start(WetoCallbacks {
        context: std::ptr::null_mut(),
        notify: Some(ignore),
    });
    assert!(!weto.is_null(), "мост не поднялся");

    let status_kind = CString::new("status").unwrap();
    let settings_kind = CString::new("settings").unwrap();
    // SAFETY: указатель от weto_start, строки с нулём на конце.
    unsafe {
        let status = answer(weto_view(weto, status_kind.as_ptr()));
        assert!(status["title"].is_string(), "{status}");
        assert!(status["readout"].is_array(), "{status}");

        let add =
            CString::new(r#"{"command":"addGeoEntry","text":"RU","list":"blocked"}"#).unwrap();
        assert_eq!(answer(weto_command(weto, add.as_ptr()))["ok"], true);

        let bad =
            CString::new(r#"{"command":"addGeoEntry","text":"  ","list":"blocked"}"#).unwrap();
        let refused = answer(weto_command(weto, bad.as_ptr()));
        assert_eq!(refused["ok"], false);
        assert_eq!(
            refused["error"],
            "введите код страны, IP-адрес или диапазон"
        );

        let garbage = CString::new("{не json").unwrap();
        assert_eq!(answer(weto_command(weto, garbage.as_ptr()))["ok"], false);

        let settings = answer(weto_view(weto, settings_kind.as_ptr()));
        assert_eq!(settings["blocked"], serde_json::json!(["RU"]));

        let journal_kind = CString::new("journal").unwrap();
        let journal = answer(weto_view(weto, journal_kind.as_ptr()));
        assert_eq!(journal["rows"], serde_json::json!([]), "{journal}");

        let unknown = CString::new("journal-of-everything").unwrap();
        assert!(weto_view(weto, unknown.as_ptr()).is_null());

        weto_stop(weto);
    }

    let saved = std::fs::read_to_string(profile.path().join(r"Roaming\weto\config.toml")).unwrap();
    assert!(saved.contains("RU"), "правка не дошла до файла: {saved}");
}
