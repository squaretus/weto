# Script targets were stored and matched as binaries (Linux)

## Symptoms
- `qwen` (npm: `~/.npm-global/bin/qwen` → `…/cli.js` with `#!/usr/bin/env node`) added as a
  target looked fine in the settings window, but never appeared in the running list and kept
  running when the VPN dropped — silently unprotected.
- The same for any shebang tool (pip/pipx entry points, Ruby gems, shell wrappers that do not
  `exec` a sibling binary) and for a VPN client written as a script: the latter read as closed
  forever, i.e. `Kill(VpnAppNotRunning)` on every pass.
- A `.desktop` entry with `Exec=node /opt/app/cli.js` (or `python3`, `ruby`, `perl`, `deno`,
  `bun`, `bash /opt/app/start.sh`) resolved to the interpreter itself: the target became
  `/usr/bin/node`, so a VPN drop would pause and kill every Node process on the machine.

## Scope
Linux only. macOS has always derived the kind from a two-byte `#!` read
(`TargetResolver.hasShebang`) and matched scripts by argv (`ProcessMatcher`); the Linux core
already had `Script` matching, but nothing produced a `Script` rule.

## Root cause
- `add_target_named` / `set_vpn_app_named` in `weto-app/src/settings_window.rs` hard-coded
  `TargetKind::Binary`, and `weto_guard::rules::RuleCache` refreshed the path and launch paths
  but copied the kind from `config.toml`.
- For a script, `/proc/<pid>/exe` is the interpreter (`/usr/bin/node`); `Binary` matching is
  `launch_paths.contains(exe)`, which can never hold. The module doc claimed the kernel had
  solved this trap — it had only removed the `KERN_PROCARGS2` parsing.
- `weto_core::launcher::verdict` treated any first word of `Exec` as the program, so an
  interpreter in front of a script file became the target.
- Latent: `launch_paths` carries the typed bare name (`qwen`); with element-wise argv matching
  it would have matched `grep qwen` and `man qwen` as soon as scripts became `Script`.

## Reproduction
1. In the container: `npm i -g` a shebang CLI (or create `~/bin/qwen` → a file starting with
   `#!/usr/bin/env node`), add `qwen` as a target.
2. Start `qwen`; `/proc/<pid>/exe` is `/usr/bin/node`, `cmdline` has `~/bin/qwen`.
3. The status window shows no running target; make the geo probe fail — the process is not
   stopped.
4. Add a `.desktop` with `Exec=node /opt/app/cli.js` — the stored path is `/usr/bin/node`.

## Fix
- `weto_sys::target_resolver::locate_target_with_kind` returns path **and** kind; the
  `TargetResolving` boundary returns `LocatedTarget { path, kind }`. The kind comes from at most
  four bytes of the canonical file: `#!` → `Script`, ELF magic → `Binary`, other readable content
  → `Script` (the kernel runs only ELF directly, so `exe` of anything else is an interpreter).
  Unreadable or shorter than the ELF magic → no answer (`None`; it used to be `Binary`, which
  flipped a live script's kind during a reinstall). A file handed to an interpreter by a
  `.desktop` is `Script` regardless of its first bytes.
- The settings window stores `target_kind_for(entry)` for targets and the VPN app; the target
  description takes the kind from the same fresh answer as the path.
- `RuleCache::resolve` sets `rule.kind` from the fresh answer together with the path; a failed
  resolution keeps the previously derived kind. Configs saved before the fix heal without user
  action, and a tool that changes form across an update stays guarded for new sessions.
- `weto_core::process::matches_rule` (`Script` branch) compares only absolute argv elements
  with `launch_paths`. Placed in matching, not rule building: rules are assembled both by
  `Target::rule` and by the cache memory, and the `Binary` branch is untouched.
- Follow-up (whole-branch review): any-element argv matching was too broad — `vim /p/qwen`,
  `less /p/qwen`, `code /p/qwen` (and their trees) were paused and killed. `Script` now matches
  only the script position: the process is an interpreter (`INTERPRETER_NAMES` or `SHELL_NAMES`,
  by `exe` or `argv[0]` basename without a version suffix), and the script is its first argument
  after `argv[0]` not starting with `-`. `RuleCache` drops ELF files from script paths
  (`TargetResolving::kind_of`), so an old config storing `/usr/bin/node` as a script path neither
  catches `#!/usr/bin/node` scripts nor `python3 /usr/bin/node`. A script under an interpreter
  outside the list is not matched — the same trade-off as `SHELL_NAMES` for the pause plan.
- `weto_core::launcher` returns `DesktopCommand::Script(path)` for an interpreter (`node`,
  `nodejs`, `python*`, `ruby*`, `perl*`, `php*`, `lua*`, `deno`, `bun`, `java`; version suffix
  ignored) or a shell followed by an absolute file, skipping only long flags and deno/bun's
  `run`. Without a determinable file an interpreter answers `Indirect` (→ `NeedsPath`, the user
  is asked for the program file); a shell without a file stays a target as before.

## Regression checks
- [ ] `linux/scripts/dev.sh cargo test -p weto-sys --test target_resolver` — a symlink in `PATH`
      to a shebang file is `Script`; a plain ELF and the `sh` sibling launcher chain are
      `Binary`; `Exec=node <file>` gives the file as `Script`, bare `Exec=node` gives
      `NeedsPath { node }`.
- [ ] `linux/scripts/dev.sh cargo test -p weto-guard --test rules` — a stored `Binary` entry for
      a shebang file is re-derived as `Script`: `node ~/.npm-global/bin/qwen` and `node …/cli.js`
      are guarded, `node other.js`, `grep qwen`, `man qwen` are not, a `Binary` target next to it
      is unaffected, a transient resolution failure keeps the kind.
- [ ] `cargo test -p weto-core` — `launcher` interpreter cases; `process`
      `script_ignores_a_bare_name_among_its_launch_paths`,
      `a_program_that_merely_opens_the_script_file_is_not_the_script`,
      `the_script_is_the_first_non_option_argument_of_an_interpreter`,
      `an_interpreter_path_in_a_script_rule_does_not_catch_every_script_it_runs`.
- [ ] `cargo test -p weto-guard --test rules` — `an_interpreter_stored_as_a_script_path_is_not_a_script`.
- [ ] Any new producer of `TargetRule` on Linux must take the kind from the file, never assume
      `Binary`.

## Related files
- `linux/crates/weto-sys/src/target_resolver.rs`
- `linux/crates/weto-guard/src/rules.rs`
- `linux/crates/weto-core/src/process.rs` (`matches_rule`), `linux/crates/weto-core/src/launcher.rs`
- `linux/crates/weto-app/src/settings_window.rs` (`add_target_named`, `set_vpn_app_named`,
  `resolved_description`)
- macOS original: `macos/Sources/WetoSystem/TargetResolver.swift`,
  `macos/Sources/WetoCore/ProcessMatcher.swift`
