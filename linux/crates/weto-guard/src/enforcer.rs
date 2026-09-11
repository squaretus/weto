//! Применение решения к процессам.
//!
//! Один обход `/proc` на такт: и отбор целей, и список живых сеансов строятся
//! из одного снимка. Второй обход стоил бы столько же, сколько первый, а данные
//! успели бы разъехаться.

use weto_core::process::{running_targets, MatchedProcess, RunningTarget, TargetRule};
use weto_sys::process_registry::ProcessRegistryReading;
use weto_sys::process_signaler::{ProcessSignal, ProcessSignaling};

pub struct EnforcementResult {
    pub killed: Vec<MatchedProcess>,
    pub running: Vec<RunningTarget>,
}

pub struct ProcessEnforcer {
    registry: Box<dyn ProcessRegistryReading>,
    signaler: Box<dyn ProcessSignaling>,
}

impl ProcessEnforcer {
    pub fn new(
        registry: Box<dyn ProcessRegistryReading>,
        signaler: Box<dyn ProcessSignaling>,
    ) -> ProcessEnforcer {
        ProcessEnforcer { registry, signaler }
    }

    /// Живые цели без единого сигнала — для экрана.
    pub fn running(&self, rules: &[TargetRule]) -> Vec<RunningTarget> {
        if rules.is_empty() {
            return Vec::new();
        }
        running_targets(&self.registry.snapshot(), rules)
    }

    /// Живо ли хоть одно совпадение с правилом. Нужен для VPN-приложения:
    /// его запущенность и есть локальное основание вердикта, а завершать его
    /// нельзя — поэтому отдельный вопрос, а не часть `enforce`.
    pub fn is_running(&self, rule: &TargetRule) -> bool {
        !weto_core::process::matches(&self.registry.snapshot(), std::slice::from_ref(rule))
            .is_empty()
    }

    /// Завершает всё, что подходит под правила, и сообщает, кому сигнал
    /// действительно ушёл.
    pub fn enforce(&self, rules: &[TargetRule]) -> EnforcementResult {
        if rules.is_empty() {
            return EnforcementResult {
                killed: Vec::new(),
                running: Vec::new(),
            };
        }

        let processes = self.registry.snapshot();
        let matched = weto_core::process::matches(&processes, rules);
        let pids: Vec<i32> = matched.iter().map(|m| m.pid).collect();
        // Процесс, умерший сам за миг до сигнала, доставкой считается: журнал
        // объясняет цель, которой больше нет, а не отказ ядра. Отказом остаётся
        // только настоящий отказ — тот же счёт, что и у `ProcessEnforcer`
        // на macOS.
        let delivered: Vec<i32> = self
            .signaler
            .send(ProcessSignal::Terminate, &pids)
            .into_iter()
            .filter(|result| result.is_delivered())
            .map(|result| result.pid)
            .collect();

        EnforcementResult {
            killed: matched
                .into_iter()
                .filter(|m| delivered.contains(&m.pid))
                .collect(),
            running: running_targets(&processes, rules),
        }
    }
}
