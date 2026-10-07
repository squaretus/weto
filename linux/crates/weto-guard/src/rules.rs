//! Правила целей и VPN-приложения: разрешаются заново, а не один раз.
//!
//! Порт кэша правил из `macos/Sources/WetoShared/ProcessEnforcer.swift`.
//! Путь, развёрнутый при добавлении цели, у версионных инструментов
//! (`~/.local/share/claude/versions/2.1.228`) устаревает с первым обновлением:
//! новый процесс запускается с `…/2.1.241`, правило молча перестаёт с ним
//! совпадать, и цель выпадает из-под охраны. У VPN-приложения то же самое
//! хуже: охрана решила бы, что VPN закрыт, и завершала бы цели каждый проход.
//!
//! Поэтому запись разрешается заново — но не на каждом проходе: под паузой
//! проход идёт раз в 250 мс, а разрешение лезет в файловую систему. Повода
//! пересчитать два, как на macOS: изменился список целей или истекло окно
//! `TARGET_RULE_REFRESH`. Обхода `/proc` здесь нет вовсе: он у прохода один.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

use weto_config::settings::{Settings, Target};
use weto_core::process::{TargetKind, TargetRule};
use weto_sys::target_resolver::{locate_with_launch_paths, TargetResolving};

/// Как часто запись цели разрешается заново. То же число, что у macOS
/// (`Constants.targetRuleRefreshSeconds`): обновление инструмента замечается
/// за пару секунд, а файловая система не трогается на каждом проходе.
pub const TARGET_RULE_REFRESH: Duration = Duration::from_secs(2);

/// Кэш правил охраны и память о путях, по которым цели уже запускались.
pub struct RuleCache {
    resolver: Box<dyn TargetResolving>,
    state: Mutex<CacheState>,
}

#[derive(Default)]
struct CacheState {
    targets: Slot<Vec<Target>>,
    target_rules: Vec<TargetRule>,
    vpn_app: Slot<Option<Target>>,
    vpn_app_rule: Option<TargetRule>,
    /// Последнее известное правило по записи — у целей и у VPN-приложения
    /// раздельно: снятие приложения из целей (его выбор как VPN) не должно
    /// стирать память о его путях.
    known_targets: HashMap<String, TargetRule>,
    known_vpn_app: HashMap<String, TargetRule>,
}

/// По каким настройкам и когда правило разрешалось последний раз.
struct Slot<T> {
    key: Option<T>,
    resolved_at: Option<SystemTime>,
}

impl<T> Default for Slot<T> {
    fn default() -> Self {
        Slot {
            key: None,
            resolved_at: None,
        }
    }
}

impl<T: PartialEq + Clone> Slot<T> {
    /// Пора ли пересчитать. Часы, ушедшие назад, — тоже повод: лишнее
    /// разрешение стоит миллисекунды, а застрявшее правило — цели.
    fn is_stale(&self, key: &T, now: SystemTime) -> bool {
        if self.key.as_ref() != Some(key) {
            return true;
        }
        match self.resolved_at.map(|at| now.duration_since(at)) {
            Some(Ok(elapsed)) => elapsed >= TARGET_RULE_REFRESH,
            _ => true,
        }
    }

    fn mark(&mut self, key: &T, now: SystemTime) {
        self.key = Some(key.clone());
        self.resolved_at = Some(now);
    }
}

impl RuleCache {
    pub fn new(resolver: Box<dyn TargetResolving>) -> RuleCache {
        RuleCache {
            resolver,
            state: Mutex::new(CacheState::default()),
        }
    }

    /// Правила целей — то, что охрана имеет право останавливать и завершать.
    pub fn targets(&self, settings: &Settings, now: SystemTime) -> Vec<TargetRule> {
        let mut state = self.state.lock().expect("кэш правил");
        if state.targets.is_stale(&settings.targets, now) {
            let entries: Vec<&str> = settings.targets.iter().map(|t| t.entry.as_str()).collect();
            // Память о записи, которой больше нет в настройках, уходит: цель,
            // снятую пользователем, держать незачем.
            state
                .known_targets
                .retain(|entry, _| entries.contains(&entry.as_str()));
            let rules = settings
                .targets
                .iter()
                .map(|target| self.resolve(target, &mut state.known_targets))
                .collect();
            state.target_rules = rules;
            state.targets.mark(&settings.targets, now);
        }
        state.target_rules.clone()
    }

    /// Правило выбранного VPN-приложения. В правила целей оно не попадает
    /// никогда: завершать свой источник защиты охрана не имеет права.
    pub fn vpn_app(&self, settings: &Settings, now: SystemTime) -> Option<TargetRule> {
        let mut state = self.state.lock().expect("кэш правил");
        if state.vpn_app.is_stale(&settings.vpn_app, now) {
            let rule = match &settings.vpn_app {
                Some(app) => {
                    state.known_vpn_app.retain(|entry, _| *entry == app.entry);
                    Some(self.resolve(app, &mut state.known_vpn_app))
                }
                None => {
                    state.known_vpn_app.clear();
                    None
                }
            };
            state.vpn_app_rule = rule;
            state.vpn_app.mark(&settings.vpn_app, now);
        }
        state.vpn_app_rule.clone()
    }

    /// Правило записи по тому, что лежит на диске сейчас.
    ///
    /// Разрешение никогда не сужает охрану. Новое правило — свежий путь плюс
    /// все пути, по которым цель запускалась раньше: сеанс, начатый до
    /// обновления, живёт на прежнем бинарнике, и `/proc/<pid>/exe` называет
    /// старый путь. Забытый путь на диске уже не существует, поэтому новый
    /// процесс по нему появиться не может. Неудача разрешения — пока файл
    /// подменяют, его на мгновение нет или он пуст — оставляет прежнее правило:
    /// живой процесс в этот момент никуда не девается.
    ///
    /// Вид выводится заново вместе с путём, а не берётся из настроек: окно
    /// настроек до исправления записывало бинарником и скрипты (`qwen` из npm,
    /// у которого `exe` — `node`), и такая цель не совпадала ни с одним
    /// процессом. Свежий вид чинит старый конфиг без участия пользователя.
    ///
    /// Сменившийся вид не отменяет прежний. Инструмент, переехавший из npm
    /// в нативную сборку (или обратно), оставляет сеансы на прежней форме, и
    /// они остаются целями: пути, увиденные в прежнем виде, сравниваются по его
    /// правилам (`other_kind_paths`). Применить новый вид ко всем путям разом
    /// значило бы молча потерять живой сеанс — а под паузой ещё и отпустить его
    /// как снятый с охраны. Прежним считается только **увиденный** вид:
    /// записанное в настройках трактуется в свежем, иначе старый конфиг с
    /// `/usr/bin/node` бинарником ловил бы каждый node-процесс машины.
    ///
    /// Кандидаты — та же цепочка, что у описания цели в окне настроек
    /// (`locate_with_launch_paths`): сперва запись, затем пути запуска.
    fn resolve(&self, target: &Target, known: &mut HashMap<String, TargetRule>) -> TargetRule {
        let recorded = target.rule();
        let previous = known.get(&target.entry).cloned();
        let fresh =
            locate_with_launch_paths(self.resolver.as_ref(), &target.entry, &target.launch_paths);

        let mut rule = match (previous, fresh) {
            // Не видели ни разу: правило из настроек как есть, и запоминать
            // его незачем — видом из настроек прежний вид не становится.
            (None, None) => {
                let mut rule = recorded;
                self.drop_native_binaries(&mut rule);
                return rule;
            }
            (Some(mut previous), None) => {
                extend_unique(&mut previous.launch_paths, &recorded.launch_paths);
                previous
            }
            (previous, Some(fresh)) => {
                let mut current = vec![fresh.path.clone()];
                let mut other = Vec::new();
                if let Some(previous) = previous {
                    if previous.kind == fresh.kind {
                        extend_unique(&mut current, &previous.launch_paths);
                        extend_unique(&mut other, &previous.other_kind_paths);
                    } else {
                        extend_unique(&mut current, &previous.other_kind_paths);
                        extend_unique(&mut other, &previous.launch_paths);
                    }
                }
                extend_unique(&mut current, &recorded.launch_paths);
                TargetRule {
                    kind: fresh.kind,
                    path: fresh.path,
                    launch_paths: current,
                    other_kind_paths: other,
                    ..recorded
                }
            }
        };

        self.drop_native_binaries(&mut rule);
        known.insert(target.entry.clone(), rule.clone());
        rule
    }

    /// ELF скриптом не бывает. Старые конфиги хранили целью-скриптом сам
    /// интерпретатор (`exe` у `qwen` из npm — `/usr/bin/node`), а на месте
    /// скрипта он стоять может: `python3 /usr/bin/node` под охрану попал бы.
    /// Спрашиваются только абсолютные пути: голое имя открылось бы относительно
    /// рабочего каталога, а совпасть по argv оно не может всё равно.
    fn drop_native_binaries(&self, rule: &mut TargetRule) {
        let scripts = match rule.kind {
            TargetKind::Script => &mut rule.launch_paths,
            TargetKind::Binary => &mut rule.other_kind_paths,
        };
        scripts.retain(|path| {
            !path.starts_with('/') || self.resolver.kind_of(path) != Some(TargetKind::Binary)
        });
    }
}

fn extend_unique(paths: &mut Vec<String>, more: &[String]) {
    for path in more {
        if !paths.contains(path) {
            paths.push(path.clone());
        }
    }
}
