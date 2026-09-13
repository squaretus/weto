//! Применение решения к процессам: пауза, продолжение, завершение.
//!
//! Один обход `/proc` на такт: и отбор целей, и список живых сеансов, и план
//! паузы строятся из одного снимка. Второй обход стоил бы столько же, сколько
//! первый, а данные успели бы разъехаться.
//!
//! Порт `macos/Sources/WetoShared/ProcessEnforcer.swift`. Отсюда же ведётся учёт
//! остановленных (`stopped.json`): обязательство «вернуть из паузы» снимает
//! наблюдение, а не отправка сигнала, и держать его может только тот, кто видит
//! и сигналы, и обход.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::SystemTime;

use weto_config::stopped::{StoppedLedger, StoppedProcess};
use weto_core::pause_plan::{self, PausePlan};
use weto_core::process::{
    running_targets, MatchBasis, MatchedProcess, ProcessSnapshot, RunningTarget, TargetRule,
};
use weto_sys::process_registry::ProcessRegistryReading;
use weto_sys::process_signaler::{ProcessSignal, ProcessSignaling, SignalResult};

/// Один обход процессов вместе с правилами, по которым его разбирают.
pub struct Scan {
    pub processes: Vec<ProcessSnapshot>,
    pub rules: Vec<TargetRule>,
}

impl Scan {
    pub fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }
}

pub struct EnforcementResult {
    pub killed: Vec<MatchedProcess>,
    pub running: Vec<RunningTarget>,
}

/// Итог паузы одного прохода.
#[derive(Default)]
pub struct PauseOutcome {
    pub plan: PausePlan,
    /// Цели, остановленные этим проходом: без шеллов и без уже стоявших. Ожившая
    /// запись учёта сюда входит — её остановили заново, и это событие.
    pub fresh: Vec<MatchedProcess>,
    /// Шеллы, остановленные ради терминала своей цели. Целями они не являются,
    /// но SIGSTOP получили — и журнал обязан объяснить каждый SIGSTOP, поэтому
    /// они приезжают готовой записью: имя цели, родитель, путь и `MatchBasis::Shell`.
    pub fresh_shells: Vec<MatchedProcess>,
    pub results: Vec<SignalResult>,
    /// Всё, что под правилами прямо сейчас, — включая стоящих с прошлых проходов.
    /// По нему видно, кто из стоящих больше не существует или перестал быть целью.
    pub matched: Vec<MatchedProcess>,
}

/// Итог продолжения. Обязательство «вернуть из паузы» снимает не отправка
/// сигнала, а наблюдение: `kill(SIGCONT)` возвращает 0 и для цели, у которой шелл
/// уже забрал терминал, — она просыпается, тут же читает tty, получает SIGTTIN
/// и встаёт обратно. Учёт, вычеркнутый по факту отправки, оставлял такую цель
/// замороженной навсегда, а журнал писал «возобновлено».
#[derive(Default)]
pub struct ResumeOutcome {
    /// Что сказало ядро на каждый посланный SIGCONT.
    pub results: Vec<SignalResult>,
    /// Обязательство снято наблюдением: процесса больше нет (или его pid достался
    /// другому) либо ядро показало его идущим.
    pub released: Vec<i32>,
    /// Остались в учёте: ядро всё ещё показывает их стоящими.
    pub unresolved: Vec<StoppedProcess>,
}

impl ResumeOutcome {
    pub fn is_complete(&self) -> bool {
        self.unresolved.is_empty()
    }
}

/// Итог освобождения: записи, держать которые больше нечем, получили SIGCONT.
///
/// Цель, снятая пользователем с охраны, — уже не наше дело, и держать её до исхода
/// эпизода weto права не имеет. Обязательство при этом снимается, как и везде,
/// наблюдением: `freed` — кому сигнал ушёл, `released` — кого обход показал идущим
/// или исчезнувшим, и только они ушли из учёта.
#[derive(Default)]
pub struct ReleaseOutcome {
    pub results: Vec<SignalResult>,
    /// Записи, которым этот проход послал SIGCONT: под охраной их больше нет.
    pub freed: Vec<StoppedProcess>,
    /// Из учёта ушли по наблюдению, а не по факту отправки сигнала.
    pub released: Vec<i32>,
}

impl ReleaseOutcome {
    pub fn is_empty(&self) -> bool {
        self.freed.is_empty()
    }
}

pub struct ProcessEnforcer {
    registry: Box<dyn ProcessRegistryReading>,
    signaler: Box<dyn ProcessSignaling>,
    ledger: Mutex<StoppedLedger>,
    ledger_path: PathBuf,
    ledger_was_corrupted: bool,
}

impl ProcessEnforcer {
    pub fn new(
        registry: Box<dyn ProcessRegistryReading>,
        signaler: Box<dyn ProcessSignaling>,
        ledger_path: PathBuf,
    ) -> ProcessEnforcer {
        let ledger = StoppedLedger::load(&ledger_path);
        ProcessEnforcer {
            registry,
            signaler,
            ledger_was_corrupted: ledger.started_from_corrupted_file(),
            ledger: Mutex::new(ledger),
            ledger_path,
        }
    }

    /// Учёт остановленных на старте не прочитался: обязательство «вернуть
    /// SIGCONT» в этот запуск выполнено не было, и сказать об этом некому,
    /// кроме журнала проверок.
    pub fn ledger_was_corrupted(&self) -> bool {
        self.ledger_was_corrupted
    }

    pub fn ledger_is_empty(&self) -> bool {
        self.ledger
            .lock()
            .expect("учёт остановленных")
            .pids()
            .is_empty()
    }

    /// Один обход процессов на событие.
    pub fn scan(&self, rules: &[TargetRule]) -> Scan {
        if rules.is_empty() {
            return Scan {
                processes: Vec::new(),
                rules: Vec::new(),
            };
        }
        Scan {
            processes: self.registry.snapshot(),
            rules: rules.to_vec(),
        }
    }

    /// Живые цели без единого сигнала — для экрана.
    pub fn running(&self, rules: &[TargetRule]) -> Vec<RunningTarget> {
        if rules.is_empty() {
            return Vec::new();
        }
        running_targets(&self.registry.snapshot(), rules)
    }

    pub fn running_in(&self, scan: &Scan) -> Vec<RunningTarget> {
        if scan.is_empty() {
            return Vec::new();
        }
        running_targets(&scan.processes, &scan.rules)
    }

    /// Живо ли хоть одно совпадение с правилом. Нужен для VPN-приложения:
    /// его запущенность и есть локальное основание вердикта, а завершать его
    /// нельзя — поэтому отдельный вопрос, а не часть применения решения.
    pub fn is_running(&self, rule: &TargetRule) -> bool {
        !weto_core::process::matches(&self.registry.snapshot(), std::slice::from_ref(rule))
            .is_empty()
    }

    /// То же самое по обходу, который у прохода уже есть.
    ///
    /// Обход на применение один, и это не только про цену: второй снимок описывал
    /// бы другой момент, а статус VPN-приложения — та же улика, что и список целей,
    /// и разъезжаться им нельзя. Свой обход остаётся ровно там, где прохода
    /// не было вовсе: `scan()` без правил не обходит ничего, и по пустому списку
    /// запущенное приложение выглядело бы закрытым.
    pub fn is_running_in(&self, rule: &TargetRule, scan: &Scan) -> bool {
        if scan.processes.is_empty() {
            return self.is_running(rule);
        }
        !weto_core::process::matches(&scan.processes, std::slice::from_ref(rule)).is_empty()
    }

    /// Пауза: SIGSTOP тем, кого в учёте ещё нет, в порядке плана.
    ///
    /// Под паузой обход идёт каждые 250 мс, и ребёнок, родившийся между снимком
    /// и сигналом, доловится следующим проходом.
    pub fn pause(&self, scan: &Scan) -> PauseOutcome {
        if scan.is_empty() {
            return PauseOutcome::default();
        }
        let matched = weto_core::process::matches(&scan.processes, &scan.rules);
        let by_pid: HashMap<i32, &ProcessSnapshot> =
            scan.processes.iter().map(|p| (p.pid, p)).collect();

        // pid, доставшийся от переиспользования, не значит «тот же процесс, что
        // мы остановили»: сравнение идёт по паре «pid + путь». И записи мало:
        // учёт держит обязательство до наблюдения, так что в нём остаётся и цель,
        // которой SIGCONT уже дошёл. Стоит она или нет — видно у ядра.
        let known: HashSet<(i32, String)> = self
            .ledger
            .lock()
            .expect("учёт остановленных")
            .entries()
            .iter()
            .map(|entry| (entry.pid, entry.executable_path.clone()))
            .collect();
        let already_stopped = |pid: i32| -> bool {
            by_pid.get(&pid).is_some_and(|process| {
                process.is_stopped && known.contains(&(pid, process.executable_path.clone()))
            })
        };

        let pending: Vec<MatchedProcess> = matched
            .iter()
            .filter(|process| !already_stopped(process.pid))
            .cloned()
            .collect();
        // Останавливать некого — но кто под правилами, знать всё равно нужно:
        // ровно этот проход и обнаруживает, что стоящая цель умерла сама.
        if pending.is_empty() {
            return PauseOutcome {
                matched,
                ..PauseOutcome::default()
            };
        }

        let plan = pause_plan::plan(&pending, &scan.processes);
        let order: Vec<i32> = plan
            .stop_order
            .iter()
            .copied()
            .filter(|pid| !already_stopped(*pid))
            .collect();
        let results = self.signaler.send(ProcessSignal::Stop, &order);
        let delivered: HashSet<i32> = results
            .iter()
            .filter(|result| result.is_delivered())
            .map(|result| result.pid)
            .collect();

        let moment = SystemTime::now();
        let additions: Vec<StoppedProcess> = order
            .iter()
            .filter(|pid| delivered.contains(pid))
            .map(|pid| StoppedProcess {
                pid: *pid,
                executable_path: by_pid
                    .get(pid)
                    .map(|p| p.executable_path.clone())
                    .unwrap_or_default(),
                stopped_at: moment,
                is_shell: plan.shells.contains(pid),
            })
            .collect();
        self.remember(&additions);

        // Шелл — не цель, но остановлен он нами, и запись о нём обязана быть
        // такой же полной: имя цели, ради терминала которой он встал, его
        // родитель и путь.
        let fresh_shells: Vec<MatchedProcess> = plan
            .shells
            .iter()
            .filter(|pid| delivered.contains(pid))
            .map(|pid| MatchedProcess {
                pid: *pid,
                target_name: plan.shell_targets.get(pid).cloned().unwrap_or_default(),
                parent_pid: by_pid.get(pid).map(|p| p.parent_pid).unwrap_or_default(),
                executable_path: by_pid
                    .get(pid)
                    .map(|p| p.executable_path.clone())
                    .unwrap_or_default(),
                matched_by: MatchBasis::Shell,
            })
            .collect();

        PauseOutcome {
            plan,
            fresh: pending
                .into_iter()
                .filter(|process| delivered.contains(&process.pid))
                .collect(),
            fresh_shells,
            results,
            matched,
        }
    }

    /// Продолжение всем из учёта — в обратном порядке: потомки, цели, шеллы.
    ///
    /// Обязательство снимает наблюдение, а не отправка сигнала. Наблюдение идёт
    /// по обходу, снятому **до** сигналов: увидеть последствия SIGCONT в тот же
    /// миг нельзя — процесс успеет проснуться и встать уже после нашего чтения.
    /// Поэтому проход, отправивший сигнал, обязательства не снимает; разбирает
    /// его следующий, и всё ещё стоящая цель получает SIGCONT снова.
    ///
    /// `skipping` — записи, которым досылать сигнал перестали: настоящее фоновое
    /// задание отвечает стопом на каждый SIGCONT, а `notify` у zsh печатает
    /// пользователю `suspended (tty input)` раз в секунду до самого `fg`.
    /// Из учёта такая запись не уходит: обязательство исполнят завершение
    /// и штатный выход.
    pub fn resume(&self, scan: Option<&Scan>, skipping: &HashSet<i32>) -> ResumeOutcome {
        let entries = self.entries();
        if entries.is_empty() {
            return ResumeOutcome::default();
        }

        let processes = self.observed_processes(scan);
        self.settle_and_signal(&entries, &processes, skipping)
    }

    /// Общий разбор для всех, кто продолжает записи учёта: наблюдение снимает
    /// обязательство, сигнал уходит в обратном стоп-порядке, из учёта уходят
    /// только наблюдённые. Второй такой дороги в файле нет намеренно — обязательство
    /// обязано сниматься одним и тем же способом, кто бы ни продолжал запись.
    fn settle_and_signal(
        &self,
        entries: &[StoppedProcess],
        processes: &[ProcessSnapshot],
        skipping: &HashSet<i32>,
    ) -> ResumeOutcome {
        let (living, standing, released) = settle(entries, processes);

        // Сигнал уходит всем живым записям, а не только стоящим: наблюдение
        // снимает обязательство, но порядок «потомки, цели, шеллы» — часть
        // контракта, и рвать его из-за одной записи, успевшей проснуться, нельзя.
        let order: Vec<i32> = living
            .iter()
            .rev()
            .map(|entry| entry.pid)
            .filter(|pid| !skipping.contains(pid))
            .collect();
        let results = if order.is_empty() {
            Vec::new()
        } else {
            self.signaler.send(ProcessSignal::Resume, &order)
        };
        self.forget(&released);

        ResumeOutcome {
            results,
            released,
            unresolved: standing,
        }
    }

    /// Цель, снятая с охраны, освобождается тем же проходом, а не исходом эпизода.
    ///
    /// Пользователь сказал «это больше не моё» — держать процесс weto не за чем,
    /// и ждать до потолка паузы нельзя: до тех пор он стоял бы уже ничьим.
    /// `guarded` — всё, что под правилами прямо сейчас; запись учёта, которой там
    /// нет, своё основание потеряла.
    ///
    /// Шелл считается иначе, и это не послабление, а тот же контракт порядка
    /// сигналов: целью он не был никогда, стоит он ради терминала цели, с которой
    /// его взяли. Отпустить его, пока хоть одна не-шелловая запись остаётся под
    /// охраной, значит отдать ему терминал раньше цели — и цель встанет по SIGTTIN.
    /// Поэтому шелл освобождается только тогда, когда держать ему больше некого:
    /// все живые записи учёта, кроме шеллов, уходят этим же проходом (или их
    /// не осталось вовсе). Внутри прохода порядок обратный стоп-порядку, так что
    /// шелл получает сигнал последним — после своей цели, как и на пути снятия паузы.
    pub fn release(&self, guarded: &[MatchedProcess], scan: Option<&Scan>) -> ReleaseOutcome {
        let entries = self.entries();
        if entries.is_empty() {
            return ReleaseOutcome::default();
        }

        let processes = self.observed_processes(scan);
        let alive: HashMap<i32, &ProcessSnapshot> = processes.iter().map(|p| (p.pid, p)).collect();

        // Мёртвая запись не держит ничего и не отпускает ничего: её вычеркнет
        // наблюдение на своём месте — здесь она не в счёт ни как основание
        // для шелла, ни как кандидат на сигнал.
        let living: Vec<StoppedProcess> = entries
            .into_iter()
            .filter(|entry| {
                alive
                    .get(&entry.pid)
                    .is_some_and(|process| process.executable_path == entry.executable_path)
            })
            .collect();
        let guarded_pids: HashSet<i32> = guarded.iter().map(|process| process.pid).collect();
        let targets = living.iter().filter(|entry| !entry.is_shell).count();
        let unguarded = living
            .iter()
            .filter(|entry| !entry.is_shell && !guarded_pids.contains(&entry.pid))
            .count();
        let frees_shells = unguarded == targets;

        let freed: Vec<StoppedProcess> = living
            .into_iter()
            .filter(|entry| {
                if entry.is_shell {
                    frees_shells
                } else {
                    !guarded_pids.contains(&entry.pid)
                }
            })
            .collect();
        if freed.is_empty() {
            return ReleaseOutcome::default();
        }

        let outcome = self.settle_and_signal(&freed, &processes, &HashSet::new());
        ReleaseOutcome {
            results: outcome.results,
            freed,
            released: outcome.released,
        }
    }

    /// После падения weto: продолжить только тех, кто всё ещё стоит и остался
    /// тем же процессом. pid переиспользуются, и SIGCONT чужому процессу
    /// недопустим.
    ///
    /// Порядок — точный обратный, как и в `resume`: файл учёта хранит записи
    /// в порядке добавления, а добавляет их `pause` ровно в порядке отправки
    /// SIGSTOP. Подлинный стоп-порядок доезжает до нового запуска сам.
    ///
    /// Обход тот же самый, что уезжает вызывающему, и он настоящий даже при
    /// пустом списке правил: обязательство «вернуть из паузы» от наличия целей
    /// не зависит, а `scan()` без правил не обходит ничего.
    pub fn resume_orphans(&self, rules: &[TargetRule]) -> (ResumeOutcome, Scan) {
        let entries = self.entries();
        if entries.is_empty() {
            return (
                ResumeOutcome::default(),
                Scan {
                    processes: Vec::new(),
                    rules: rules.to_vec(),
                },
            );
        }

        let processes = self.registry.snapshot();
        let (_, standing, released) = settle(&entries, &processes);

        let results = if standing.is_empty() {
            Vec::new()
        } else {
            let order: Vec<i32> = standing.iter().rev().map(|entry| entry.pid).collect();
            self.signaler.send(ProcessSignal::Resume, &order)
        };
        self.forget(&released);

        (
            ResumeOutcome {
                results,
                released,
                unresolved: standing,
            },
            Scan {
                processes,
                rules: rules.to_vec(),
            },
        )
    }

    /// Завершение целей: SIGKILL тем, кто под правилом, SIGCONT всем остальным
    /// из учёта — шеллу, стоявшему ради терминала цели, и любому, кто перестал
    /// совпадать с правилом между паузой и завершением. Оставить его стоять
    /// значило бы заморозить процесс до следующего запуска weto.
    ///
    /// SIGKILL, а не SIGTERM: стоящий процесс обработчика не исполняет,
    /// и SIGTERM просто встал бы в очередь до продолжения — цель осталась бы
    /// жива и заморожена. Канон называет здесь SIGKILL для обеих платформ.
    pub fn terminate(&self, scan: &Scan) -> EnforcementResult {
        if scan.is_empty() {
            return EnforcementResult {
                killed: Vec::new(),
                running: Vec::new(),
            };
        }

        let matched = weto_core::process::matches(&scan.processes, &scan.rules);
        let pids: Vec<i32> = matched.iter().map(|m| m.pid).collect();
        // Процесс, умерший сам за миг до сигнала, доставкой считается: журнал
        // объясняет цель, которой больше нет, а не отказ ядра.
        let results = if pids.is_empty() {
            Vec::new()
        } else {
            self.signaler.send(ProcessSignal::Kill, &pids)
        };
        let killed: HashSet<i32> = results
            .iter()
            .filter(|result| result.is_delivered())
            .map(|result| result.pid)
            .collect();

        // Учёт: завершённые уходят, остальные получают продолжение.
        let doomed: HashSet<i32> = pids.iter().copied().collect();
        let survivors: Vec<StoppedProcess> = self
            .entries()
            .into_iter()
            .filter(|entry| !doomed.contains(&entry.pid))
            .collect();
        let processes = self.observed_processes(Some(scan));
        let (living, _, released) = settle(&survivors, &processes);
        if !living.is_empty() {
            let order: Vec<i32> = living.iter().rev().map(|entry| entry.pid).collect();
            self.signaler.send(ProcessSignal::Resume, &order);
        }
        let mut forgotten = released;
        forgotten.extend(
            self.entries()
                .iter()
                .map(|entry| entry.pid)
                .filter(|pid| killed.contains(pid)),
        );
        self.forget(&forgotten);

        EnforcementResult {
            killed: matched
                .into_iter()
                .filter(|m| killed.contains(&m.pid))
                .collect(),
            running: running_targets(&scan.processes, &scan.rules),
        }
    }

    /// Наблюдать обязательство можно только по настоящему обходу. `scan()` при
    /// пустом списке правил возвращает пустой снимок — обходить незачем, — и по
    /// нему все записи учёта выглядели бы исчезнувшими, а это ровно те, которых
    /// забывать нельзя.
    fn observed_processes(&self, scan: Option<&Scan>) -> Vec<ProcessSnapshot> {
        match scan {
            Some(scan) if !scan.processes.is_empty() => scan.processes.clone(),
            _ => self.registry.snapshot(),
        }
    }

    fn entries(&self) -> Vec<StoppedProcess> {
        self.ledger
            .lock()
            .expect("учёт остановленных")
            .entries()
            .to_vec()
    }

    fn remember(&self, additions: &[StoppedProcess]) {
        if additions.is_empty() {
            return;
        }
        let mut ledger = self.ledger.lock().expect("учёт остановленных");
        if ledger.add(additions) {
            self.persist(&ledger);
        }
    }

    fn forget(&self, pids: &[i32]) {
        if pids.is_empty() {
            return;
        }
        let mut ledger = self.ledger.lock().expect("учёт остановленных");
        if ledger.remove(pids) {
            self.persist(&ledger);
        }
    }

    fn persist(&self, ledger: &StoppedLedger) {
        if let Err(error) = ledger.save(&self.ledger_path) {
            eprintln!("weto: учёт остановленных не сохранился: {error}");
        }
    }
}

/// Кого учёт всё ещё держит, а кого отпускает: процесса нет в обходе — записи
/// конец; чужой путь по тому же pid — тоже конец (число переиспользовано ядром).
fn settle(
    entries: &[StoppedProcess],
    processes: &[ProcessSnapshot],
) -> (Vec<StoppedProcess>, Vec<StoppedProcess>, Vec<i32>) {
    let alive: HashMap<i32, &ProcessSnapshot> = processes.iter().map(|p| (p.pid, p)).collect();
    let mut living = Vec::new();
    let mut standing = Vec::new();
    let mut released = Vec::new();
    for entry in entries {
        match alive.get(&entry.pid) {
            Some(process) if process.executable_path == entry.executable_path => {
                living.push(entry.clone());
                if process.is_stopped {
                    standing.push(entry.clone());
                } else {
                    released.push(entry.pid);
                }
            }
            _ => released.push(entry.pid),
        }
    }
    (living, standing, released)
}
