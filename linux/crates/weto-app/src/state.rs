//! Общее состояние приложения.
//!
//! Охрана живёт в отдельном потоке и делится результатом через снимок под
//! мьютексом. UI читает снимок по таймеру главного цикла GTK: событийная
//! рассылка между потоками здесь ничего бы не дала, а стоила бы каналов
//! и лишних состояний.
//!
//! Цикл охраны и писатели журналов живут в `weto_guard::runtime`: их же берёт
//! терминальная версия, у которой GTK нет. Здесь — только то, что принадлежит
//! окну: общие настройки, терминал стоящей цели, нажатия на уведомление.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use weto_config::checks::CheckLog;
use weto_config::journal::Journal;
use weto_config::paths::Paths;
use weto_config::settings::{Settings, Theme};
use weto_core::terminal::TerminalHost;
use weto_guard::controller::{GuardController, GuardSnapshot, SettingsProviding};
use weto_guard::runtime::{os_version, spawn_guard, system_controller, CheckWriter, JournalWriter};
use weto_sys::network_events::NetlinkEventSource;
use weto_sys::notifications::DesktopNotifier;
use weto_sys::process_registry::{ProcRegistry, ProcessRegistryReading};
use weto_sys::secret_store::{FileSecretStore, SecretStoring};
use weto_sys::terminal::{DesktopTerminalActivator, TerminalActivating};

/// Настройки читаются из файла при каждом обращении охраны — так правка
/// из окна настроек применяется к следующему же тику без всякой рассылки.
pub struct SharedSettings {
    path: std::path::PathBuf,
    cached: Mutex<Settings>,
}

impl SharedSettings {
    pub fn load(paths: &Paths) -> Arc<SharedSettings> {
        let path = paths.settings_file();
        let cached = Settings::load(&path).unwrap_or_default();
        Arc::new(SharedSettings {
            path,
            cached: Mutex::new(cached),
        })
    }

    pub fn current(&self) -> Settings {
        self.cached.lock().expect("настройки").clone()
    }

    /// Правка всегда поднимает ревизию: по ней охрана понимает, что прежний
    /// вердикт больше не свеж.
    pub fn edit(&self, change: impl FnOnce(&mut Settings)) {
        let mut settings = self.cached.lock().expect("настройки");
        change(&mut settings);
        settings.revision += 1;
        if let Err(error) = settings.save(&self.path) {
            eprintln!("weto: настройки не сохранились: {error}");
        }
    }

    /// Правка без ревизии — для того, что решения политики не меняет. Ревизия
    /// обесценивает вердикт, и смена потолка паузы уводила бы охрану
    /// в «Проверку» с пробой.
    pub fn edit_untracked(&self, change: impl FnOnce(&mut Settings)) {
        let mut settings = self.cached.lock().expect("настройки");
        change(&mut settings);
        if let Err(error) = settings.save(&self.path) {
            eprintln!("weto: настройки не сохранились: {error}");
        }
    }
}

/// Обёртка ради правила сирот: и трейт, и `Arc` объявлены не здесь,
/// поэтому реализовать одно для другого напрямую нельзя.
struct SettingsSource(Arc<SharedSettings>);

impl SettingsProviding for SettingsSource {
    fn settings(&self) -> Settings {
        self.0.current()
    }
}

pub struct AppState {
    pub paths: Paths,
    pub settings: Arc<SharedSettings>,
    controller: Arc<GuardController>,
    journal: Arc<Mutex<Journal>>,
    /// Журнал проверок — рядом с журналом завершений и отдельным файлом.
    checks: Arc<Mutex<CheckLog>>,
    /// Кто поднимет терминал цели, ушедшей в фон под паузой, и чем.
    terminal: Box<dyn TerminalActivating>,
    /// Свой обход `/proc` для интерфейса: охрана свой снимок наружу не отдаёт,
    /// а обход стоит пару миллисекунд и случается только у стоящей цели.
    registry: Box<dyn ProcessRegistryReading>,
    /// Нажатия на уведомление. Поток уведомлений кладёт сюда просьбу показать
    /// окно, главный цикл забирает её своим тактом: окна из чужого потока
    /// не открывают.
    open_requests: Mutex<std::sync::mpsc::Receiver<()>>,
}

impl AppState {
    pub fn new(paths: Paths) -> Arc<AppState> {
        let settings = SharedSettings::load(&paths);
        let journal = Arc::new(Mutex::new(Journal::load(&paths.journal_file())));
        let checks = Arc::new(Mutex::new(CheckLog::load(&paths.checks_file())));

        // Нажатие на уведомление открывает окно статуса — то же самое делает
        // тап по уведомлению на macOS. Обработчик ставится один раз на старте
        // и больше не меняется.
        let (open_sender, open_requests) = std::sync::mpsc::channel();
        let open_sender = Mutex::new(open_sender);
        let notifier = DesktopNotifier::with_open_handler(Arc::new(move || {
            if let Ok(sender) = open_sender.lock() {
                let _ = sender.send(());
            }
        }));

        let writer = JournalWriter::new(paths.clone(), journal.clone(), Box::new(notifier));

        let controller = Arc::new(system_controller(
            &paths,
            Box::new(SettingsSource(settings.clone())),
            Box::new(writer),
            Box::new(CheckWriter::new(paths.clone(), checks.clone())),
        ));

        Arc::new(AppState {
            paths,
            settings,
            controller,
            journal,
            checks,
            terminal: Box::new(DesktopTerminalActivator::new()),
            registry: Box::new(ProcRegistry::new()),
            open_requests: Mutex::new(open_requests),
        })
    }

    pub fn snapshot(&self) -> GuardSnapshot {
        self.controller.snapshot()
    }

    /// Сколько цели ещё могут стоять. `None` — не стоят. Строка «что дальше»
    /// в объяснении статуса читает часы отсюда, а не сама.
    pub fn remaining_pause(&self) -> Option<Duration> {
        self.controller.remaining_pause()
    }

    /// Кто держит терминал стоящей цели и можно ли его поднять.
    ///
    /// Ответ спрашивается на живом снимке `/proc` и на живой шине, поэтому
    /// интерфейс держит его в кэше: пока цель стоит, терминала она не меняет.
    pub fn terminal_for(&self, pid: i32) -> Option<TerminalHost> {
        self.terminal.locate(pid, &self.registry.snapshot())
    }

    /// Показать пользователю терминал стоящей цели: под паузой процесс
    /// не отвечает, и найти его окно самому — задача не для человека.
    /// Порт macOS `GuardVM.showTerminal(for:)`.
    pub fn show_terminal(&self, pid: i32) -> bool {
        match self.terminal_for(pid) {
            Some(host) => self.terminal.activate(&host),
            None => false,
        }
    }

    /// Просил ли пользователь показать окно нажатием на уведомление.
    /// Копятся они по одному вопросу, поэтому очередь вычерпывается разом.
    pub fn take_open_request(&self) -> bool {
        let Ok(requests) = self.open_requests.lock() else {
            return false;
        };
        let mut asked = false;
        while requests.try_recv().is_ok() {
            asked = true;
        }
        asked
    }

    pub fn journal(&self) -> Journal {
        self.journal.lock().expect("журнал").clone()
    }

    /// Журнал для разбора: события вместе с настройками момента и версиями.
    ///
    /// Токен в файл не попадает — только признак, задан ли он: без этого
    /// отказ ipinfo в трассах не объяснить.
    pub fn export_journal(&self) -> Option<String> {
        let settings = self.settings.current();
        // Токен спрашивается у хранилища, а в файл уходит только признак:
        // выгрузка отправляется в переписку.
        let has_token = FileSecretStore::new(self.paths.token_file())
            .load()
            .ok()
            .flatten()
            .is_some_and(|token| !token.is_empty());
        let events = self.journal().entries().to_vec();
        let checks = self
            .checks
            .lock()
            .expect("журнал проверок")
            .entries()
            .to_vec();

        let export = weto_config::export::JournalExport::build(
            &settings,
            events,
            checks,
            has_token,
            std::time::SystemTime::now(),
            os_version(),
        );
        match export.encoded() {
            Ok(text) => Some(text),
            Err(error) => {
                eprintln!("weto: журнал не собрался: {error}");
                None
            }
        }
    }

    /// Очистка журнала — и в памяти, и на диске: иначе записи вернулись бы
    /// при следующем чтении файла.
    pub fn clear_journal(&self) {
        let mut journal = self.journal.lock().expect("журнал");
        journal.clear();
        if let Err(error) = journal.save(&self.paths.journal_file()) {
            eprintln!("weto: журнал не очистился: {error}");
        }
    }

    pub fn reload_journal(&self) {
        let fresh = Journal::load(&self.paths.journal_file());
        *self.journal.lock().expect("журнал") = fresh;
    }

    pub fn theme(&self) -> Theme {
        self.settings.current().theme
    }

    /// Крутится ли индикатор на месте кнопки проверки: спрашиваем у охраны —
    /// дорожка пробы у неё одна, и второго признака «в полёте» заводить незачем.
    pub fn is_probing(&self) -> bool {
        self.controller.is_probing()
    }

    /// Проверка по кнопке. Главный поток она не держит: HTTP уходит на дорожку
    /// пробы, а здесь остаётся то же, что делает такт, — обход `/proc` в пару
    /// миллисекунд. Повторное нажатие в полёте запроса второго не порождает:
    /// у подтверждающего сервиса лимит.
    pub fn probe_now(&self) {
        self.controller.probe_now();
    }

    /// Штатный выход: замороженных целей не оставляем.
    ///
    /// Наблюдать последствия SIGCONT уже нечем — такта больше не будет, — поэтому
    /// запись, которую сигнал не разрешил, остаётся в учёте и достаётся
    /// восстановлению при следующем запуске, а журнал пишет «не подтверждено»,
    /// а не «возобновлено».
    pub fn shutdown(&self) {
        self.controller.shutdown();
    }

    /// Досылает SIGCONT оставшимся записям учёта и возвращает тех, кого обход
    /// всё ещё показывает стоящими. Нужно ровно удалению: всюду ещё запись,
    /// которую выход не разрешил, достаётся следующему запуску, а после
    /// удаления его не будет — учёт исчезает вместе с приложением.
    pub fn confirm_resumed(&self) -> Vec<weto_config::stopped::StoppedProcess> {
        self.controller.confirm_resumed()
    }

    /// Охрана стартует при запуске процесса, а не при первом открытии окна.
    ///
    /// На macOS это правило появилось потому, что `MenuBarExtra` создаёт
    /// содержимое лениво и защиты не было бы, пока пользователь не откроет меню.
    /// Здесь та же ловушка ждала бы с окном, которое может не открыться никогда.
    pub fn start_guard(self: &Arc<Self>) {
        spawn_guard(
            self.controller.clone(),
            Box::new(NetlinkEventSource),
            |_| {},
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Потолок паузы правится мимо ревизии: ревизия обесценивает вердикт,
    /// и смена потолка уводила бы охрану в «Проверку» с пробой.
    #[test]
    fn an_untracked_edit_is_saved_but_does_not_bump_the_revision() {
        let home = std::env::temp_dir().join(format!(
            "weto-state-untracked-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let paths = weto_config::paths::Paths::rooted(home.clone());
        let settings = SharedSettings::load(&paths);
        let revision = settings.current().revision;

        settings.edit_untracked(|s| s.pause_ceiling_seconds = 600);

        assert_eq!(settings.current().revision, revision);
        assert_eq!(settings.current().pause_ceiling_seconds, 600);
        assert_eq!(
            Settings::load(&paths.settings_file())
                .unwrap()
                .pause_ceiling_seconds,
            600,
            "правка дошла до файла"
        );
        let _ = std::fs::remove_dir_all(home);
    }
}
