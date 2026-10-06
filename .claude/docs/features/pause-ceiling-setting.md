# Pause ceiling as a user setting

## Goal
How long paused targets wait for geo confirmation before `SIGKILL` used to be a hard 60 s
(`Constants.pauseCeilingSeconds` on macOS, `PAUSE_CEILING` on Linux). A minute is too short for a
slow or flapping channel where the user would rather keep the work frozen than lose it. Now the
user picks one of four values — 1, 2, 5, 10 min, default 1 min — on both platforms. The policy and
the phase model are unchanged; only the `Tick` threshold of the `Пауза` phase moves.

## Scope
- Core: `macos/Sources/WetoCore/PauseCeiling.swift`, `GuardMachine.swift`, `GuardPolicy.swift`,
  `Model/KillEvent.swift`; `linux/crates/weto-core/src/pause_ceiling.rs`, `guard_machine.rs`,
  `policy.rs`, `presentation.rs`.
- Settings and guard: `WetoShared/SettingsStore.swift`, `GuardController.swift`, `GuardVM.swift`,
  `StatusPresentation.swift`; `weto-config/src/settings.rs`, `weto-app/src/state.rs`,
  `weto-guard/src/controller.rs`.
- UI: `WetoMenuBar/Settings/NetworkSettingsCard.swift`, `WetoDesign/Components/WetoPauseBadge.swift`;
  `weto-app/src/settings_window.rs` (`network_card`), `weto-ui/src/components.rs`.
- Fixture: `shared/fixtures/guard-transitions.json` (new 300 s case).

## Changes
- Added: `PauseCeiling` on both platforms (`durationText`/`duration_text` — «5 мин», «90 с»;
  Linux `countdown_text`); `GuardMachine.setPauseCeiling` / `set_pause_ceiling`;
  `UnsafeEvidence.isPauseExpired` / `is_pause_expired`; macOS `SettingsStore.pauseCeiling`
  (UserDefaults key `pauseCeilingSeconds`) with its own `onPauseCeilingChange` bus; Linux
  `Settings.pause_ceiling_seconds` (serde default 60, unknown → 60 via `pause_ceiling()`) and
  `SharedSettings::edit_untracked`; the «Таймаут» row in the «Сеть и гео» card; its explanation is a `WetoHint` «?» right after the label (Linux `ui::hint`), and the token field and the segments share one label column.
- Modified: `pauseExpired` → `pauseExpired(ceiling:)` / `PauseExpired(Duration)`, wording
  «Подтверждение не получено за 1 мин» (was «за 60 с»); countdown format — above a minute «4:59»,
  the last minute «43 с» (`WetoPauseBadge.remainingText`, `pause_countdown_text`, the paused
  explanation line); `pauseDeadline` / snapshot `pause_deadline` read the machine's ceiling.
- Removed: `Constants.pauseCeilingSeconds`, `PAUSE_CEILING`.

## Risks
- **The ceiling must never ride the settings revision / `GuardConfigurationChange`.** That path
  drops the verdict, asks for a probe and writes «правка настроек» to the check log — changing a
  timeout would send the guard into «Проверка». macOS uses a separate bus, Linux saves with
  `edit_untracked`.
- **One source for screen and threshold.** macOS sets the machine's ceiling in
  `GuardController.init` and on change (even for a test-injected machine); Linux sets it in
  `feed` before every input. Computing a deadline from the setting directly instead of from the
  machine would let the badge and the kill disagree.
- **A change applies to the current pause.** Deadline stays `pausedSince + ceiling`; lowering it
  below the time already paused kills on the next tick. That is intended, not a bug.
- **Compare evidence with `isPauseExpired`, not `==`** — equality now includes the ceiling, so
  `== .pauseExpired(...)` with another number silently fails («по потолку» vs «по доказательству»).
- The evidence is not serialized; the journal format is unchanged, only the reason text now names
  the ceiling. Golden-fixture runners build `pauseExpired` from the case's `ceilingSeconds`, so
  the file does not repeat the number.

## How to test
- [ ] `cd macos && swift test --filter 'PauseCeilingTests|GuardMachineTests|GuardMachineFixtureTests|SettingsStoreTests|GuardVMTests|WetoPauseBadgeTests|StatusPresentationTests'`
- [ ] Linux: `cargo test -p weto-core -p weto-config -p weto-guard -p weto-app` in the container
      (`pause_ceiling`, `guard_machine`, `guard_transition_fixtures`, `storage`, `pause`, `state`).
- [ ] Manual: pick 5 min, silence the geo services while a target runs → badge shows «4:59…»,
      the target is killed at 5 min with «Подтверждение не получено за 5 мин»; switch to 1 min
      mid-pause after 2 min → killed on the next tick. Linux steps — `linux/docs/manual-check.md`.
- [ ] Changing the ceiling leaves no «правка настроек» entry in the check log and starts no probe.

## Related modules
- modules/weto-core.md
- modules/weto-shared.md
- modules/weto-menubar.md
- modules/weto-design.md
- modules/linux-guard.md
