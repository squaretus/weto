# The Windows in-app update was offered again and again

## Symptoms
- Пользователи Windows нажимают «Установить», Weto закрывается и поднимается снова той же
  версией; баннер обновления появляется опять.
- Подтверждения по `setup.log` пользователя пока нет
  (`%LOCALAPPDATA%\weto\cache\updates\setup.log`) — причина выведена из кода и документации Inno.

## Scope
Windows: `windows/installer/weto.iss` (`PrepareToInstall`, `DeinitializeSetup`), выход приложения
(`App.xaml.cs`, `Quit()`), `weto-ffi/src/update.rs` (`SetupInstaller`).

## Root cause
- Обновление из приложения: мост запускает `setup.exe` тихо, такт видит `UpdateView.installed`
  и делает штатный `Quit()`. Мьютекс экземпляра `Local\com.weto.app` отпускается в `Quit()`,
  а процесс с загруженными `Weto.exe` и `weto_ffi.dll` живёт после этого ещё какое-то время.
- `PrepareToInstall` ждал только мьютекс: занят — `--quit`, свободен — сразу к замене файлов.
- Inno повторяет замену занятого файла 4 раза по секунде (замечания к секции `[Files]`), затем под
  `/SUPPRESSMSGBOXES` выбирает «Прервать» (код 5). `DeinitializeSetup` поднимает прежний Weto,
  а тот снова находит обновление.
- Контракт установщика гонку не воспроизводил: в шаге «поверх работающего» Weto закрывает сам
  установщик, а сценария «приложение выходит само» не было.

## Reproduction
1. Установить Weto, дождаться события `Local\com.weto.app.quit`.
2. Запустить `setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /LOG=…`
   и сразу выставить событие выхода — так выходит приложение, запустившее обновление.
3. Без `WaitForWetoToExit` ожидается код 5 и прежняя версия.

## Fix
- `WaitForWetoToExit` в `weto.iss` после `--quit`: WMI-запрос `Win32_Process WHERE ExecutablePath =
  {localappdata}\Programs\weto\Weto.exe` раз в 250 мс до 30 с; без WMI — пауза 5 с; таймаут —
  ошибка `PrepareToInstall` «Weto не закрылся…». В WQL обратная косая и апостроф экранируются.
- То же ожидание в `InitializeUninstall` после `--uninstall` с кодом 0: удаление упирается в ту же
  гонку, и `Weto.exe`/`weto_ffi.dll` остались бы на месте.
- Метки в журнале Inno — ASCII (`weto: no running Weto after check N`, `weto: WMI failed: …`):
  контракт ищет их, а кириллицу кодировка журнала на раннере и PowerShell 5.1 не переживают.
- Исправление живёт в новом `setup.exe`, поэтому помогает и тем, кто обновляется с 1.21.0/1.21.1.

## Regression checks
- [ ] `windows/scripts/tests/installer-contract.ps1`, шаг 3 «обновление из приложения»
      (на отказе печатает журнал Inno `/LOG`; каждая установка обязана пройти ожидание через WMI,
      а не через запасную паузу, и печатает номер проверки: больше 1 — гонка была)

## Related files
- `windows/installer/weto.iss`
- `windows/scripts/tests/installer-contract.ps1`
- `windows/app/Weto/App.xaml.cs`
- `windows/crates/weto-ffi/src/update.rs`
