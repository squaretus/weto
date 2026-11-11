; Установщик Weto для Windows (Inno Setup 6).
;
; Ставится пользователю, без прав администратора: %LOCALAPPDATA%\Programs\weto
; (Paths::windows_under), ярлык в меню «Пуск». Тот же установщик — обновление:
; приложение запускает его тихо (/VERYSILENT … /CLOSEAPPLICATIONS) и выходит
; штатно; установщик просит выйти и работающий экземпляр (Weto.exe --quit),
; ставит новую версию поверх и поднимает её.
;
; Удаление — то же обязательство, что на macOS и Linux: до сноса чего-либо
; Weto.exe --uninstall просит работающий экземпляр выйти, досылает SIGCONT
; по учёту и называет оставшихся стоять; код не 0 — удаление отменяется.
; Каталоги данных сносятся в конце, учёт остановленных (%LOCALAPPDATA%\weto)
; последним.
;
; Сборка: ISCC /DAppVersion=1.2.0 /DArch=x86_64 /DSourceDir=…\out\x86_64
;              /DOutputDir=… weto.iss
; Имя на выходе — weto-<версия>-<arch>-windows-setup.exe: его ищет обновление
; (weto-ffi/src/update.rs, asset_suffix).

#ifndef AppVersion
  #error Нужна версия: /DAppVersion=…
#endif
#ifndef Arch
  #error Нужна архитектура: /DArch=x86_64 или /DArch=aarch64
#endif
#ifndef SourceDir
  #error Нужен каталог публикации: /DSourceDir=…
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

#if Arch == "x86_64"
  #define Allowed "x64compatible"
#elif Arch == "aarch64"
  #define Allowed "arm64"
#else
  #error Неизвестная архитектура
#endif

[Setup]
; AppId постоянный: по нему обновление находит прежнюю установку.
AppId={{6F1D3C52-8B47-4E0A-9C1E-5A7B2D94E0F3}
AppName=Weto
AppVersion={#AppVersion}
AppVerName=Weto {#AppVersion}
AppPublisher=squaretus
AppPublisherURL=https://github.com/squaretus/weto
AppSupportURL=https://github.com/squaretus/weto/issues
AppUpdatesURL=https://github.com/squaretus/weto/releases
DefaultDirName={localappdata}\Programs\weto
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed={#Allowed}
ArchitecturesInstallIn64BitMode={#Allowed}
OutputDir={#OutputDir}
OutputBaseFilename=weto-{#AppVersion}-{#Arch}-windows-setup
SetupIconFile={#SourceDir}\Assets\Weto.ico
UninstallDisplayIcon={app}\Weto.exe
UninstallDisplayName=Weto
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=no
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Weto"; Filename: "{app}\Weto.exe"

[Run]
; Ручная установка — галочка «Запустить» на последней странице; тихая
; (обновление из приложения) — запуск без вопросов.
Filename: "{app}\Weto.exe"; Description: "Запустить Weto"; Flags: nowait postinstall skipifsilent
Filename: "{app}\Weto.exe"; Flags: nowait; Check: WizardSilent

[Code]
const
  InstanceMutex = 'Local\com.weto.app';
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';

var
  { Установка дошла до конца: файлы новой версии на месте. }
  Installed: Boolean;
  { Weto работал, когда началось удаление: отменённое удаление обязано
    поднять его снова. }
  WetoWasRunning: Boolean;
  { Пользователь сам выбрал «Не удалять и закрыть Weto». }
  KeepClosed: Boolean;
  UninstallStarted: Boolean;
  Relaunched: Boolean;

{ Путь фиксирован (DisableDirPage), поэтому годится и там, где каталог
  установки ещё не известен. Фигурных скобок в комментариях Pascal не пишем:
  первая закрывающая кончает комментарий. }
function InstalledWeto(): String;
begin
  Result := ExpandConstant('{localappdata}\Programs\weto\Weto.exe');
end;

procedure LaunchWeto();
var
  Code: Integer;
begin
  if FileExists(InstalledWeto()) then
    Exec(InstalledWeto(), '', '', SW_SHOWNORMAL, ewNoWait, Code);
end;

{ Перед заменой файлов работающий Weto просится выйти штатно — стоящие
  цели продолжаются, а не гибнут вместе с принудительно закрытым процессом.
  Restart Manager (CloseApplications) приложение в трее закрыть не умеет:
  установка поверх работающего возвращала код 5. Обновление из самого
  приложения сюда приходит, когда Weto уже вышел, и --quit ничего не ждёт. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Result := '';
  if CheckForMutexes(InstanceMutex) and FileExists(InstalledWeto()) then
    if not Exec(InstalledWeto(), '--quit', '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then
      Result := 'Weto не закрылся. Закройте его из меню в трее и запустите установку снова.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    Installed := True;
end;

{ Тихое обновление, не дошедшее до конца (Weto не закрылся, нет места,
  вмешался антивирус), не оставляет машину без охраны: прежний Weto уже
  вышел, и поднять его, кроме установщика, некому. }
procedure DeinitializeSetup();
begin
  if WizardSilent and not Installed then
    LaunchWeto();
end;

{ Удаление не состоялось, а Weto, работавший до него, закрыт проверкой —
  поднять его, иначе машина осталась бы без охраны. Зовётся и из
  InitializeUninstall, и из DeinitializeUninstall: документация Inno не
  говорит, вызывается ли второе после отказа первого, поэтому подъём ровно
  один (Relaunched) и только при свободном мьютексе — Weto, не успевший
  выйти за 20 с проверки, второй копией не дублируется. }
procedure RelaunchIfClosed();
begin
  if WetoWasRunning and not KeepClosed and not UninstallStarted and not Relaunched
    and not CheckForMutexes(InstanceMutex) then
  begin
    Relaunched := True;
    LaunchWeto();
  end;
end;

{ Проверка перед сносом: Weto.exe --uninstall. Коды: 0 — удалять; 1 —
  стоящие остались и выбрано «Не удалять и закрыть Weto»; 2 — Weto не
  закрылся; 3 — проверка не удалась. Ничего ещё не удалено. Вопросы —
  SuppressibleMsgBox: молчат только при /SUPPRESSMSGBOXES (скрипты), а
  удаление кнопкой из приложения (/SILENT) их показывает. }
function InitializeUninstall(): Boolean;
var
  Code: Integer;
begin
  WetoWasRunning := CheckForMutexes(InstanceMutex);
  if not FileExists(InstalledWeto())
    or not Exec(InstalledWeto(), '--uninstall', '', SW_SHOWNORMAL, ewWaitUntilTerminated, Code) then
  begin
    { Сломанная установка удаляется, а не застревает навсегда. }
    Result := SuppressibleMsgBox('Weto не запускается, и проверить, не осталось ли программ на паузе, нечем. Удалить всё равно?',
      mbConfirmation, MB_YESNO, IDYES) = IDYES;
    exit;
  end;
  case Code of
    0:
      Result := True;
    1:
      begin
        KeepClosed := True;
        Result := False;
      end;
    2:
      begin
        SuppressibleMsgBox('Weto не закрылся. Закройте его из меню в трее и запустите удаление снова.',
          mbError, MB_OK, IDOK);
        Result := False;
        { Мог выйти и позже двадцати секунд ожидания. }
        RelaunchIfClosed();
      end;
  else
    begin
      Result := SuppressibleMsgBox('Weto не смог проверить, не осталось ли программ на паузе. Удалить всё равно?',
        mbConfirmation, MB_YESNO, IDYES) = IDYES;
      { Отказались — Weto, закрытый проверкой, поднимается снова. }
      if not Result then
        RelaunchIfClosed();
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Code: Integer;
begin
  { До удаления файлов: токен, автозапуск и регистрация уведомлений —
    то, что лежит вне каталогов данных и знает только сам Weto. }
  if CurUninstallStep = usUninstall then
  begin
    UninstallStarted := True;
    Exec(InstalledWeto(), '--uninstall-cleanup', '', SW_HIDE, ewWaitUntilTerminated, Code);
    { Страховка, если Weto.exe не отработал: автозапуск без программы
      открывал бы ошибку при каждом входе. }
    RegDeleteValue(HKEY_CURRENT_USER, RunKey, 'Weto');
  end;
  { После файлов: настройки, затем журналы, кэш и учёт остановленных —
    учёт последним. }
  if CurUninstallStep = usPostUninstall then
  begin
    DelTree(ExpandConstant('{userappdata}\weto'), True, True, True);
    DelTree(ExpandConstant('{localappdata}\weto'), True, True, True);
  end;
end;

{ Удаление отменено после проверки (например, «Нет» на вопрос самого
  деинсталлятора): Weto к этому моменту закрыт, и без него машина осталась
  бы без охраны. Выбор «Не удалять и закрыть Weto» уважается. }
procedure DeinitializeUninstall();
begin
  RelaunchIfClosed();
end;
