# Terminal version (`weto`) on macOS and Linux

## Goal
Run weto on a server without a desktop: install with one command, set targets, VPN, black/white
lists, timeout and token by commands, run the guard as a whole-machine service, read status and
journal from a terminal, update in place — with exactly the same guard behaviour as the menu bar
app. New shell, same backend. New for the terminal version only: the VPN can be a tunnel
(interface name).

## Scope
- Core (both): `GuardPolicy.swift`, `Model/GeoModels.swift`, `Model/NetworkSnapshot.swift`,
  `Model/KillEvent.swift`; `weto-core/src/{policy,network,presentation}.rs`;
  fixtures `shared/fixtures/guard-policy.json` (v5), `guard-transitions.json`.
- macOS: `WetoShared/{GuardController,GuardVM,SettingsStore,StatusPresentation}.swift`,
  `WetoSystem/{NetworkSnapshotReader,NetworkEventSource,KeychainStore,RaisedInterfaces,FileSecretStore}.swift`,
  new `Sources/WetoCLI/`, `Tests/WetoCLITests/`, `Package.swift` (product `weto`),
  `scripts/make-cli.sh`, `scripts/tests/module-boundary-contract.sh`.
- Linux: `weto-config/src/{paths,settings}.rs`, `weto-sys/src/{network_snapshot,target_resolver}.rs`,
  `weto-guard/src/controller.rs`, new `weto-guard/src/runtime.rs` (moved from
  `weto-app/src/state.rs`), `weto-app/src/settings_window.rs`, `weto-update/src/checker.rs`,
  new crate `linux/crates/weto-cli`, `scripts/build.sh`, `scripts/Dockerfile.dev` (musl).
- Delivery: `shared/cli/install.sh`, `shared/cli/tests/install-contract.sh`,
  `.github/workflows/{pr-checks,release}.yml`, `README.md`.

## Changes
- Added (guard): `VPNTunnelStatus` / `VpnTunnelStatus`; `GuardConfig.vpnTunnel`;
  evidences `vpnTunnelDown`, `trafficBypassesTunnel`; `UnsafeEvidence.isLocal` / `is_local()`;
  `NetworkSnapshot.upInterfaces` (outside the fingerprint); `InterfaceListing` on both platforms;
  `SettingsStore.vpnTunnel`, `reloadFromDefaults()`; `Settings.vpn_tunnel`, `set_vpn_tunnel`,
  `add_target`, `validate_tunnel_name`; `Paths::from_env_named`, `Paths::system()`, `status_file`,
  `run_lock_file`; `FileSecretStore` (macOS); `settings_target` (Linux);
  `GuardSnapshot.{outgoing, vpn_app, vpn_tunnel, probed_at}`; `NetworkEventSource(observesWorkspace:)`.
- Added (CLI): the `weto` command, grammar `weto <object> <action> [value]`, per-object help;
  `vpn set` with app/tunnel auto-detection, `vpn list`; whole-machine mode by euid 0 with system
  storage and system service (`weto.service`, LaunchDaemon `com.weto.cli`); refusal hint for
  non-root beside a system install; `update check|install` against GitHub Releases with
  `SHA256SUMS`; daily release check in `run` → `updateAvailable` in `status.json` v1; `version`.
- Added (delivery): CLI archives `weto-cli-<v>-linux-<arch>.tar.gz` (static musl) and
  `weto-cli-<v>-macos-arm64.tar.gz`, `SHA256SUMS` and `install.sh` as release assets; one-command
  installer; installer contract in CI.
- Modified: `decideLocal` checks app then tunnel, each only if chosen; reassessment without a probe
  for any local evidence; "country hidden" and `StatusPresentation.knownReading` use `isLocal`;
  setters for app and tunnel clear each other; Linux `ReleaseChecker` skips `weto-cli-` assets;
  release `publish` collects assets flat.
- Removed (relative to the first cut): command `weto-cli`, `vpn app|tunnel|tunnels`, `timeout [N]`,
  unit name `weto-cli.service`, `Environment=HOME` in the system unit, the unpublished
  `weto-cli-…-linux.tar.zst`, `NSRunningApplication` app detection.

## Risks
- **Two guards over one target set** fight with SIGSTOP/SIGCONT. A user guard refuses to start
  next to the GUI app; a root guard only warns and keeps guarding — the app is recognised by its
  path, which any user can fake, and a refusal would let them switch the whole-machine guard off.
  `run` holds `flock`; a GUI started *after* `weto run` is not checked by the app.
- **Bare target names under `sudo`** — not found by root, they are looked up in the `PATH`
  of `SUDO_USER` and stored as an absolute path (round 4); verified live on Linux, not on macOS
  (no passwordless `sudo` on the dev machine).
- **macOS root suite via `sudo` with preserved `HOME`** — assumed from cfprefsd behaviour, not
  verified live.
- **macOS `/private` stripping** — targets under `/tmp`, `/var` never match (GUI too); open task.
- **Asset name drift** between `build.sh`/`make-cli.sh`, workflow, `install.sh` and `weto update`
  breaks install and update silently for every server. `install-contract.sh` covers the installer
  only.
- **Tunnel that is down at set time** kills targets until it is up — intended, warned about.
- GUI behaviour must stay identical: nobody sets a tunnel there, and the fixtures pin the app path.

## How to test
- [ ] macOS: `cd macos && swift test` — 694 green (`WetoCLITests` incl. `SystemModeTests`,
      `UpdateTests`); `swift test --package-path macos/Packages/UpdateKit` — 83 green.
- [ ] Linux: workspace tests in the container — 657 green; `-p weto-cli` for the CLI alone.
- [ ] `macos/scripts/tests/module-boundary-contract.sh`, Linux `core-boundary-contract.sh`,
      `bash shared/cli/tests/install-contract.sh` pass.
- [ ] `linux/scripts/build.sh 9.9.9` — CLI archive built, `ldd` says static;
      `macos/scripts/make-cli.sh release 9.9.9` — archive lists only `weto`.
- [ ] Live, root: `sudo weto service install`; as a user `weto status` works,
      `weto target list` answers «… — sudo weto target list» (code 1).
- [ ] Live, two processes: `sudo weto run` + `sudo weto target add …` → «настройки …» in the log
      within a second.
- [ ] `vpn set wg0`, then `wg-quick down wg0` → «VPN-туннель wg0 не поднят», targets killed;
      `wg-quick up wg0` → back to «На страже» without a probe if the fingerprint held.
- [ ] `kill -TERM` the guard with a paused target → target resumed, `status.json` removed, exit 0.
- [ ] `weto update check` against a release without a CLI archive → «нет терминальной версии…», code 0.

## Related modules
- modules/weto-cli.md
- modules/weto-core.md, modules/weto-shared.md, modules/weto-system.md, modules/linux-guard.md
- decisions/vpn-tunnel-in-terminal-version.md, decisions/whole-machine-guard-from-root.md
- runbooks/install-weto-cli-on-a-server.md, runbooks/release.md
