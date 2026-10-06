# Target rules were resolved once, at add time (Linux)

## Symptoms
- After `claude` / `codex` updated itself, the new session silently left the guard: it was not in
  the running list, it was not paused or killed when the VPN dropped. The target still looked
  alive in the settings window, whose description resolves the entry on every redraw.
- A VPN client living under a versioned path that updated itself read as closed: the guard
  answered `Kill(VpnAppNotRunning)` on every pass and killed the targets with the VPN up.
- A session started before the update, whose binary the update deleted, also dropped out once the
  kernel started reporting its `exe` as `…/versions/228 (deleted)`.

## Scope
Linux only. macOS has re-resolved rules since the same bug there
(`ProcessEnforcer.rules()`, `Constants.targetRuleRefreshSeconds`); the Linux port copied the
stored path instead of the cache.

## Root cause
- `Settings::target_rules()` / `vpn_app_rule()` turned `Target.path` + `launch_paths` from
  `config.toml` into rules as-is, and the guard called them on every pass
  (`run`, `recover_stopped`, `resume_from_ledger`, `apply_probe`, `vpn_app_status`).
  `resolve_launch_entry` was called only from the settings window, at add time.
- `Binary` matching is exact (`launch_paths.contains(executable_path)`), and the resolved path of
  a versioned tool changes completely with each update.
- `ProcRegistry` read `/proc/<pid>/exe` verbatim, including the kernel's ` (deleted)` suffix.

## Reproduction
1. Add `~/.local/bin/claude` (a symlink to `~/.local/share/claude/versions/228`) as a target.
2. Re-point the symlink to `…/versions/300` and start `claude` again.
3. The new pid is not in the status window; drop the VPN — it keeps running.
4. Same with a VPN app whose symlink is re-pointed: the phase goes to «Опасно» with
   «VPN-приложение не запущено».

## Fix
- `weto_guard::rules::RuleCache` re-resolves every target entry and the VPN app through the
  `TargetResolving` boundary (`weto-sys`, real `LaunchTargetResolver` = `locate_target`) when the
  `targets` / `vpn_app` value changes or `TARGET_RULE_REFRESH` (2 s) passes on the guard clock.
  No `/proc` walk inside — the pass keeps one walk.
- The new rule is the fresh path plus every launch path seen before (seeded from the stored
  `path` / `launch_paths`); a failed resolution keeps the last known rule; entries removed from
  settings are forgotten.
- The entry is tried first, then the stored absolute launch paths; on add the settings window
  stores the `PATH` file a bare name was found at (`launch_paths_for`, unresolved symlink).
- `ProcRegistry` strips ` (deleted)` from `exe`.

## Regression checks
- [ ] `linux/scripts/dev.sh cargo test -p weto-guard --test rules` — retarget 228→300 is picked
      up after the window and not within it; old sessions (228, and 300 after 300→400) stay
      guarded; a transient resolution failure keeps the rule; no resolver call within the window,
      an immediate one on a target-list edit; a VPN app on a new path stays `Running`; a bare
      name missing from the guard's `PATH` is found by its stored `PATH` file.
- [ ] `linux/scripts/dev.sh cargo test -p weto-sys --test process_registry` — the suffix is
      stripped on a fake root and on the real kernel (a copied binary deleted under a live process).
- [ ] `linux/scripts/dev.sh cargo test -p weto-sys --test target_resolver` —
      `launch_paths_in`, `LaunchTargetResolver` following a re-pointed symlink.
- [ ] Any new place that needs target rules in the guard must take them from `RuleCache`, not
      from `Settings::target_rules()`.

## Related files
- `linux/crates/weto-guard/src/rules.rs`, `linux/crates/weto-guard/src/controller.rs`
- `linux/crates/weto-sys/src/target_resolver.rs`, `linux/crates/weto-sys/src/process_registry.rs`
- `linux/crates/weto-config/src/settings.rs` (`Target::rule`)
- `linux/crates/weto-app/src/settings_window.rs` (`add_target_named`, `set_vpn_app_named`)
- macOS original: `macos/Sources/WetoShared/ProcessEnforcer.swift`
