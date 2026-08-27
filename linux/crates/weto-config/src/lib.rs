//! Настройки и журнал.
//!
//! Раскладка по XDG: настройки в `$XDG_CONFIG_HOME/weto/config.toml`, журнал
//! в `$XDG_STATE_HOME/weto/journal.json`, кэш в `$XDG_CACHE_HOME/weto`.
//! Токен ipinfo сюда не попадает — он в отдельном хранилище с правами `0600`.

pub mod export;
pub mod journal;
pub mod paths;
pub mod settings;
