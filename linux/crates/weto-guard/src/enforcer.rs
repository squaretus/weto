//! Применение решения к процессам.
//!
//! Один обход `/proc` на такт: и отбор целей, и список живых сеансов строятся
//! из одного снимка. Второй обход стоил бы столько же, сколько первый, а данные
//! успели бы разъехаться.

use weto_core::process::{running_targets, MatchedProcess, RunningTarget, TargetRule};
use weto_sys::process_killer::ProcessKilling;
use weto_sys::process_registry::ProcessRegistryReading;

pub struct EnforcementResult {
    pub killed: Vec<MatchedProcess>,
    pub running: Vec<RunningTarget>,
}

pub struct ProcessEnforcer {
    registry: Box<dyn ProcessRegistryReading>,
    killer: Box<dyn ProcessKilling>,
}

impl ProcessEnforcer {
    pub fn new(
        registry: Box<dyn ProcessRegistryReading>,
        killer: Box<dyn ProcessKilling>,
    ) -> ProcessEnforcer {
        ProcessEnforcer { registry, killer }
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
        let delivered = self.killer.kill(&pids);

        EnforcementResult {
            killed: matched
                .into_iter()
                .filter(|m| delivered.contains(&m.pid))
                .collect(),
            running: running_targets(&processes, rules),
        }
    }
}
