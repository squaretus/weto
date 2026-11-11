//! Общее состояние приложения.
//!
//! Охрана живёт в отдельном потоке и делится результатом через снимок под
//! мьютексом. UI читает снимок по таймеру главного цикла GTK: событийная
//! рассылка между потоками здесь ничего бы не дала, а стоила бы каналов
//! и лишних состояний.
//!
//! Цикл охраны и писатели журналов живут в `weto_guard::runtime`: их же берёт
//! терминальная версия, у которой GTK нет. Общие настройки (`SharedSettings`) —
//! там же: их берёт и мост Windows-версии. Здесь — только то, что принадлежит
//! окну: терминал стоящей цели, нажатия на уведомление.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use weto_config::checks::CheckLog;
use weto_config::journal::Journal;
use weto_config::paths::Paths;
use weto_config::settings::Theme;
use weto_core::terminal::TerminalHost;
use weto_guard::controller::{GuardController, GuardSnapshot};
use weto_guard::runtime::{os_version, spawn_guard, system_controller, CheckWriter, JournalWriter};
use weto_guard::shared_settings::{SettingsSource, SharedSettings};
use weto_sys::network_events::NetlinkEventSource;
use weto_sys::notifications::DesktopNotifier;
use weto_sys::process_registry::{ProcRegistry, ProcessRegistryReading};
use weto_sys::secret_store::{FileSecretStore, SecretStoring};
use weto_sys::terminal::{DesktopTerminalActivator, TerminalActivating};

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

    /// Кто держит терминал цели и можно ли его поднять. Ответ спрашивается
    /// на живом снимке `/proc` и на живой шине.
    pub fn terminal_for(&self, pid: i32) -> Option<TerminalHost> {
        self.terminal.locate(pid, &self.registry.snapshot())
    }

    /// Показать пользователю терминал цели, которую не удалось вернуть:
    /// найти её окно самому — задача не для человека.
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
        let state = self.clone();
        spawn_guard(
            self.controller.clone(),
            Box::new(NetlinkEventSource),
            move |_| state.raise_terminals_of_failed_returns(),
        );
    }

    /// Кнопка «Вернуть в терминал». Запуск tmux идёт на дорожке охраны, а не здесь:
    /// нажатие приходит из главного цикла GTK.
    pub fn return_to_terminal(&self, pid: i32) {
        self.controller.return_to_terminal(pid);
    }

    /// Нажатие не вернуло цель: подсказка отправляет в терминал — поднимаем его.
    /// Своим потоком: ответ на вопрос «кто терминал» стоит обхода `/proc` и разговора с шиной,
    /// а такт охраны ждать этого не должен.
    fn raise_terminals_of_failed_returns(self: &Arc<Self>) {
        let failed = self.controller.take_failed_returns();
        if failed.is_empty() {
            return;
        }
        let state = self.clone();
        std::thread::spawn(move || {
            for pid in failed {
                state.show_terminal(pid);
            }
        });
    }
}
