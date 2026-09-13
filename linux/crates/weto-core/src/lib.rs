//! Чистая логика охраны: ноль I/O.
//!
//! Зеркало макосного `WetoCore`. Здесь живут политика, снимки, матчинг процессов,
//! разбор ответов гео-сервисов и презентация статуса — всё, что решается
//! вычислением, без обращения к сети, процессам и файловой системе.
//!
//! Инвариант границ проверяется `scripts/tests/core-boundary-contract.sh`.

pub mod check;
pub mod diagnostics;
pub mod episode;
pub mod geo;
pub mod guard_machine;
pub mod ip;
pub mod launcher;
pub mod network;
pub mod pause_plan;
pub mod policy;
pub mod presentation;
pub mod process;
pub mod terminal;
pub mod timestamp;
