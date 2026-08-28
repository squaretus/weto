//! Испытательный стенд охраны без интерфейса.
//!
//! В продукт не поставляется: приложение держит охрану в своём процессе, ровно
//! как на macOS. Отдельный демон на Linux не нужен ни для прав (их не требуется
//! нигде), ни для резидентности (её обеспечивает автозапуск сессии).
//!
//!   wetod --dump-network   печатает снимок сети и статус выбранного туннеля
//!   wetod --check          одна проба, отчёт по каждому источнику
//!   wetod --watch          цикл охраны с реакцией на события сети

use std::sync::mpsc::RecvTimeoutError;
use std::time::Duration;

use weto_config::paths::Paths;
use weto_config::settings::Settings;
use weto_core::check::CheckEvent;
use weto_core::diagnostics::KillContext;
use weto_core::policy::GuardDecision;
use weto_core::process::MatchedProcess;
use weto_guard::controller::{CheckReporting, GuardController, KillReporting, SettingsProviding};
use weto_guard::enforcer::ProcessEnforcer;
use weto_sys::geo_probe::{GeoEndpoints, HttpGeoProbe, RouteNetworkPath};
use weto_sys::network_events::{NetlinkEventSource, NetworkEventSourcing};
use weto_sys::network_snapshot::{KernelNetworkReader, NetworkSnapshotReading};
use weto_sys::process_killer::SigtermKiller;
use weto_sys::process_registry::ProcRegistry;
use weto_sys::secret_store::FileSecretStore;

/// Пока небезопасно — 250 мс: терминальные цели больше ничем не поймать.
/// Когда всё сошлось — 5 секунд, как на macOS.
const TICK_UNSAFE: Duration = Duration::from_millis(250);
const TICK_SAFE: Duration = Duration::from_secs(5);

struct FileSettings(std::path::PathBuf);

impl SettingsProviding for FileSettings {
    fn settings(&self) -> Settings {
        Settings::load(&self.0).unwrap_or_default()
    }
}

struct PrintingReporter;

/// Демон журнал проверок не ведёт: он инструмент отладки, а не резидент.
struct SilentChecks;

impl CheckReporting for SilentChecks {
    fn record(&self, _event: CheckEvent) {}
}

impl KillReporting for PrintingReporter {
    fn report(&self, killed: &[MatchedProcess], context: &KillContext) {
        let names: Vec<&str> = killed.iter().map(|k| k.target_name.as_str()).collect();
        let pids: Vec<String> = killed.iter().map(|k| k.pid.to_string()).collect();
        println!(
            "завершено: {} (pid {}) — {}",
            names.join(", "),
            pids.join(", "),
            context.reason
        );
    }
}

fn build_controller(paths: &Paths) -> GuardController {
    GuardController::new(
        Box::new(KernelNetworkReader::new()),
        Box::new(HttpGeoProbe::new(
            GeoEndpoints::default(),
            Box::new(RouteNetworkPath),
        )),
        Box::new(FileSecretStore::new(paths.token_file())),
        Box::new(FileSettings(paths.settings_file())),
        ProcessEnforcer::new(Box::new(ProcRegistry::new()), Box::new(SigtermKiller)),
        Box::new(PrintingReporter),
        Box::new(SilentChecks),
    )
}

fn main() {
    let paths = Paths::from_env();
    let command = std::env::args().nth(1).unwrap_or_else(|| "--check".into());

    match command.as_str() {
        "--dump-network" => dump_network(&paths),
        "--check" => check(&paths),
        "--watch" => watch(&paths),
        other => {
            eprintln!("неизвестная команда «{other}»");
            eprintln!("доступно: --dump-network, --check, --watch");
            std::process::exit(2);
        }
    }
}

fn dump_network(paths: &Paths) {
    let settings = Settings::load(&paths.settings_file()).unwrap_or_default();
    let snapshot = KernelNetworkReader::new().snapshot();

    println!(
        "трафик наружу:  {}",
        snapshot
            .outgoing
            .as_ref()
            .map(|o| format!("{} (адрес {})", o.interface, o.address))
            .unwrap_or_else(|| "никто".to_string())
    );
    println!(
        "VPN-приложение: {}",
        settings
            .vpn_app
            .as_ref()
            .map(|app| format!("{} ({})", app.display_name, app.path))
            .unwrap_or_else(|| "не выбрано".to_string())
    );
}

fn check(paths: &Paths) {
    let controller = build_controller(paths);
    let decision = controller.probe_now();
    let snapshot = controller.snapshot();

    if let Some(presentation) = snapshot.presentation {
        println!("{}", presentation.title);
        println!("{}", presentation.subtitle);
    }
    if let Some(report) = snapshot.report {
        println!();
        println!("ipinfo:        {:?}", report.ipinfo);
        println!("подтверждение: {:?}", report.confirmation);
        println!(
            "адрес:         {}",
            report.ip.as_deref().unwrap_or("неизвестен")
        );
    }
    println!();
    println!("решение: {decision:?}");
}

fn watch(paths: &Paths) {
    let controller = build_controller(paths);
    let events = NetlinkEventSource.subscribe();
    let mut previous: Option<GuardDecision> = None;

    println!("охрана запущена, Ctrl-C для выхода");
    loop {
        let decision = controller.tick();

        if previous.as_ref() != Some(&decision) {
            match &decision {
                GuardDecision::Safe => println!("на страже"),
                GuardDecision::Kill(reason) => {
                    println!("небезопасно: {}", reason.display_text())
                }
            }
            previous = Some(decision.clone());
        }

        // Событие сети прерывает ожидание: реакция на падение туннеля не должна
        // ждать конца интервала.
        let interval = match decision {
            GuardDecision::Safe => TICK_SAFE,
            GuardDecision::Kill(_) => TICK_UNSAFE,
        };
        match events.recv_timeout(interval) {
            Ok(()) | Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => std::thread::sleep(interval),
        }
    }
}
