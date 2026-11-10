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

{ Перед заменой файлов работающий Weto просится выйти штатно — стоящие
  цели продолжаются, а не гибнут вместе с принудительно закрытым процессом.
  Restart Manager (CloseApplications) приложение в трее закрыть не умеет:
  установка поверх работающего возвращала код 5. Обновление из самого
  приложения сюда приходит, когда Weto уже вышел, и --quit ничего не ждёт. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
  Exe: String;
begin
  Result := '';
  Exe := ExpandConstant('{app}\Weto.exe');
  if CheckForMutexes(InstanceMutex) and FileExists(Exe) then
    if not Exec(Exe, '--quit', '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then
      Result := 'Weto не закрылся. Закройте его из меню в трее и запустите установку снова.';
end;

{ Проверка перед сносом: Weto.exe --uninstall. Код 0 — удалять; иначе
  (стоящие остались и пользователь выбрал «Не удалять», Weto не вышел,
  мост не ответил) — удаление отменяется. Ничего ещё не удалено. }
function InitializeUninstall(): Boolean;
var
  Code: Integer;
begin
  Result := Exec(ExpandConstant('{app}\Weto.exe'), '--uninstall', '', SW_SHOWNORMAL,
    ewWaitUntilTerminated, Code) and (Code = 0);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Code: Integer;
begin
  { До удаления файлов: токен, автозапуск и регистрация уведомлений —
    то, что лежит вне каталогов данных и знает только сам Weto. }
  if CurUninstallStep = usUninstall then
  begin
    Exec(ExpandConstant('{app}\Weto.exe'), '--uninstall-cleanup', '', SW_HIDE,
      ewWaitUntilTerminated, Code);
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
