# Цель, записанная путём с версией в каталоге, выпадала из охраны после обновления

## Symptoms
- После обновления программы новый сеанс не виден среди запущенных, не встаёт на паузу и не
  завершается при падении VPN. В окне настроек цель описана как «не найдено: по этому пути нет
  исполняемого файла».
- VPN-клиент, записанный таким путём, после своего обновления считается закрытым: «Опасно»
  с «VPN-приложение не запущено» при живом VPN.
- Найдено по журналу коллеги: цель `C:\Program Files\WindowsApps\Claude_6.28899.6.0_x64__pzs8sxrjxfjjc\app\Claude.exe`
  (Claude из Microsoft Store), которая перестала бы совпадать с первым же обновлением Claude.

## Scope
Все три платформы. Linux и Windows — общий `weto-core` (`path_text`), macOS — `WetoCore`
(`ProgramPath`) с тем же правилом и теми же случаями в тестах. На macOS записи обычно стабильны
сами (бандл `.app`, симлинк в `PATH`), но цель вида `/Applications/Tool/1.0.9/Tool` или скрипт
под `~/.nvm/versions/node/v20.11.0/…` выпадали так же: `ProcessEnforcer` держит последнее
известное правило, а оно называет удалённый каталог. Бандл `.app` (`appBundle`) правило
не использует — он сравнивается префиксом каталога.

## Root cause
- `RuleCache` разрешает запись заново раз в 2 с, и это спасает только стабильную запись: симлинк
  (`~/.local/bin/claude`), `.desktop`, `.lnk`. Здесь сама запись — версионный путь. Обновление
  кладёт программу в соседний каталог и удаляет прежний, `locate` отвечает `None`, остаётся
  прежнее правило со старым путём.
- `process::matches_paths` сравнивал пути точно (`same_path`).
- Искать соседний каталог на диске нельзя: `C:\Program Files\WindowsApps` обычному пользователю
  не перечислить.

## Fix
- `path_text::same_program_across_versions` — та же программа, если пути различаются только
  первой в сегменте серией из двух и больше чисел через точку, а текст вокруг неё (у Store — имя
  пакета, архитектура, издатель) и имя файла совпадают. Одиночное число версией не считается
  (`Python311`, ревизия snap). На Windows — без учёта регистра и в любой записи, как `same_path`.
- `matches_paths` спрашивает его для `Binary` и для пути скрипта у `Script`.
- macOS: `ProgramPath.sameProgramAcrossVersions` — то же правило; `ProcessMatcher` спрашивает его
  для `binary` и для каждого аргумента у `script`. Регистр различается, как во всём сопоставлении
  на macOS.
- Цена: цель `…\IntelliJ IDEA 2024.1\bin\idea64.exe` охраняет и `IntelliJ IDEA 2024.2` рядом —
  та же программа другой версии, охрана шире, а не уже.

## Regression checks
- [ ] `cargo test -p weto-guard --test rules` — `a_target_named_by_its_version_directory_is_guarded_after_an_update`,
      `a_vpn_app_named_by_its_version_directory_is_running_after_an_update`,
      `a_different_program_in_a_neighbouring_version_is_not_guarded`
- [ ] `cargo test -p weto-core --lib path_text` — Store, Squirrel, JetBrains, nvm; другой издатель,
      архитектура, имя файла, одиночное число, относительный путь
- [ ] `cd macos && swift test --filter 'ProgramPathTests|ProcessMatcherTests|ProcessEnforcerTests'` —
      те же случаи в `ProgramPathTests`; `test_target_named_by_its_version_directory_is_guarded_after_an_update`,
      `test_a_different_program_in_a_neighbouring_version_is_not_guarded`

## Related files
- `linux/crates/weto-core/src/path_text.rs`, `linux/crates/weto-core/src/process.rs`
- `linux/crates/weto-guard/src/rules.rs` (`RuleCache`)
- `macos/Sources/WetoCore/ProgramPath.swift`, `macos/Sources/WetoCore/ProcessMatcher.swift`
- `macos/Sources/WetoShared/ProcessEnforcer.swift` (`lastKnownRules`)
