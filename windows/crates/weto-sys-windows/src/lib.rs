//! Адаптеры weto к Windows.
//!
//! Каждый реализует трейт из `weto-sys` — ту же границу, что у Linux-адаптеров,
//! и только на ней тесты что-либо подменяют. Охрана, политика и журналы общие
//! (`linux/crates`), здесь — только то, чем Windows отличается.
//!
//! Чистая часть (`process_table`, `target_resolver`) собирается и тестируется
//! на любой системе; вызовы Windows API — под `cfg(windows)`, их проверяют
//! тесты на раннерах Windows.

pub mod process_table;
pub mod shortcut;
pub mod target_resolver;

#[cfg(windows)]
pub mod autostart;
#[cfg(windows)]
pub mod clock;
#[cfg(windows)]
pub mod interfaces;
#[cfg(windows)]
pub mod network_events;
#[cfg(windows)]
mod ntdll;
#[cfg(windows)]
pub mod power;
#[cfg(windows)]
pub mod process_registry;
#[cfg(windows)]
pub mod process_signaler;
#[cfg(windows)]
pub mod secret_store;
#[cfg(windows)]
mod wide;
