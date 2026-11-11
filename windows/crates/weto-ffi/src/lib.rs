//! Мост Windows-версии weto к приложению на C#.
//!
//! Всё состояние приложения живёт здесь, в Rust: настройки, охрана, журналы.
//! Интерфейс на C# получает готовую модель экрана (`view`) и передаёт нажатия
//! командами (`command`). Граница — узкий C ABI на JSON (`abi`, только Windows).

#[cfg(windows)]
pub mod abi;
#[cfg(windows)]
pub mod app;
pub mod command;
pub mod view;
