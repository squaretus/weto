//! Адаптеры к системе.
//!
//! Каждый прячется за трейтом: только на этой границе тесты и подменяют
//! что-либо. Внутренние типы не подменяются никогда — правило унаследовано
//! от `WetoSystem` на macOS, где оно уже доказало свою пользу.

pub mod autostart;
pub mod desktop_entries;
pub mod geo_probe;
pub mod network_events;
pub mod network_snapshot;
pub mod notifications;
pub mod process_registry;
pub mod process_signaler;
pub mod secret_store;
pub mod session_bus;
pub mod target_resolver;
pub mod terminal;
