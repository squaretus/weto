# A bare-name target on Windows matched nothing

## Symptoms
- The guard reached «Небезопасно» (proof, SIGKILL phase), yet the target (Claude desktop) kept
  running, and the kill journal had no entry for the episode at all.
- The target entry in the user's journal export was the bare name `Claude`; the export itself
  claimed `app.platform: "Linux"` and `app.version: "0.0.0"`.

## Scope
Windows only. `weto-core` process matching (`path_text`, `process::matches_paths`), target
description in `presentation`, journal export in `weto-config`.

## Root cause
- Claude desktop is installed from Microsoft Store (MSIX): no `.lnk` in the Start menu, so
  «Выбрать…» cannot offer it, and the executable lives under
  `C:\Program Files\WindowsApps\Claude_<version>_x64__<publisher>\app\claude.exe` — a closed,
  versioned directory. Typing the name was the only option.
- A bare name is resolved via `PATH` + `PATHEXT`; not found → the rule's path stays the literal
  `Claude`. `Binary` matching compares whole paths, so the rule matched no process: `terminate`
  had nothing to kill, and nothing to journal.
- The export hard-coded `"Linux"` and took `CARGO_PKG_VERSION` of `weto-config` (`0.0.0`).

## Reproduction
1. On Windows, add the target `Claude` (or any program absent from `PATH`).
2. Start Claude from the Store install; the popup lists no running target.
3. Produce proof (e.g. a blocked country) — phase «Небезопасно», the process survives.

## Fix
- `path_text::names_program(name, exe)`: under `cfg!(windows)`, a bare name (no separators)
  equals the program stem of the process case-insensitively (`Claude` / `claude.exe` ↔
  `…\claude.exe`), like `taskkill /IM`. `matches_paths` accepts it in the `Binary` branch only;
  a path still names one file, `Script` is unchanged. Never on Linux.
- `target_description` on Windows describes such a target as «по имени программы: Claude.exe»
  instead of asking for a full path.
- Export: `app.platform` from `platform_name()`, `app.version` from `option_env!("WETO_VERSION")`.

## Regression checks
- [ ] `weto-guard/tests/controller.rs::a_target_named_by_its_program_name_is_killed_under_danger`
      (cfg(windows), Windows CI)
- [ ] `process.rs`: `a_bare_windows_name_matches_the_program_by_name`,
      `a_windows_path_still_names_one_file`, `a_bare_unix_name_does_not_match_by_file_name`
- [ ] `export.rs::the_export_names_the_platform_it_was_made_on`

## Related files
- `linux/crates/weto-core/src/path_text.rs`
- `linux/crates/weto-core/src/process.rs`
- `linux/crates/weto-core/src/presentation.rs`
- `linux/crates/weto-config/src/export.rs`
- `windows/crates/weto-sys-windows/src/target_resolver.rs`
