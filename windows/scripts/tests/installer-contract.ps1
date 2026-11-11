# Контракт установщика Windows на раннере: то, что пользователь получит
# от setup.exe и что останется после удаления.
#   powershell -File installer-contract.ps1 -Setup out\release_build\weto-9.9.9-x86_64-windows-setup.exe
#
# 1. Тихая установка: файлы на месте, ярлык в «Пуске», Weto запущен.
# 2. Установка поверх работающего — так выглядит обновление: установщик
#    закрывает старый экземпляр, ставит новый и поднимает его.
# 3. Тихое удаление: программы, ярлыка, данных (настройки, журналы, учёт),
#    автозапуска и токена в Диспетчере учётных данных больше нет.
param(
    [Parameter(Mandatory)] [string] $Setup
)
$ErrorActionPreference = 'Stop'

$app = Join-Path $env:LOCALAPPDATA 'Programs\weto'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Weto.lnk'
$settingsDir = Join-Path $env:APPDATA 'weto'
$stateDir = Join-Path $env:LOCALAPPDATA 'weto'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$credential = 'com.weto.ipinfo'

function Fail([string] $what) {
    Write-Error "контракт установщика: $what"
}

# Ждём сам установщик, а не Start-Process -Wait: тот ждёт и всех потомков,
# а установщик в конце запускает Weto, который не выходит, — контракт висел
# до таймаута раннера.
function Install {
    $run = Start-Process -FilePath $Setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS' -PassThru
    if (-not $run.WaitForExit(180000)) { Fail 'установщик не закончил за 3 минуты' }
    if ($run.ExitCode -ne 0) { Fail "установщик вернул $($run.ExitCode)" }
}

# Зависший шаг объясняет себя: список процессов Weto и установщика и снимки
# их окон (диалог со стоящими, сообщение Inno) — в screens/stuck-*.png.
function Describe-Profile {
    foreach ($dir in $settingsDir, $stateDir) {
        if (Test-Path $dir) {
            Write-Output "в профиле: $dir"
            Get-ChildItem -Recurse $dir | Select-Object -ExpandProperty FullName | Write-Output
        } else {
            Write-Output "в профиле нет: $dir"
        }
    }
}

function Describe-Stuck {
    Describe-Profile
    $suspects = Get-Process | Where-Object { $_.Name -match '^(Weto|unins\d+|_iu\d+|.*setup.*|is-.*)$' }
    $suspects | Format-Table Id, Name, Path -AutoSize | Out-String | Write-Output
    # Откликается ли работающий Weto на просьбу выйти — тот же путь, что у деинсталлятора.
    $exe = Join-Path $app 'Weto.exe'
    if (Test-Path $exe) {
        $started = Get-Date
        $quit = Start-Process -FilePath $exe -ArgumentList '--quit' -PassThru
        $done = $quit.WaitForExit(30000)
        $code = if ($done) { $quit.ExitCode } else { 'не завершился' }
        Write-Output "Weto.exe --quit: код $code за $([int]((Get-Date) - $started).TotalSeconds) с"
        Get-Process -Name Weto -ErrorAction SilentlyContinue | Format-Table Id, Path -AutoSize | Out-String | Write-Output
    }
    if ($suspects) {
        New-Item -ItemType Directory -Force screens | Out-Null
        & (Join-Path $PSScriptRoot 'screenshot.ps1') -Attach ([uint32[]]$suspects.Id) -Out screens/stuck
    }
}

function Wait-Until([scriptblock] $done, [string] $what, [int] $seconds = 60) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while (-not (& $done)) {
        if ((Get-Date) -gt $deadline) {
            Describe-Stuck
            Fail "не дождались: $what"
        }
        Start-Sleep -Milliseconds 500
    }
}

function Weto-Process {
    Get-Process -Name Weto -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($app, [StringComparison]::OrdinalIgnoreCase) }
}

# --- 1. Установка -----------------------------------------------------------
Describe-Profile
Install
foreach ($file in 'Weto.exe', 'weto_ffi.dll', 'unins000.exe', 'Assets\Weto.ico', 'Assets\tray-guarded.ico') {
    if (-not (Test-Path (Join-Path $app $file))) { Fail "нет $file в $app" }
}
if (-not (Test-Path $shortcut)) { Fail "нет ярлыка в меню «Пуск»" }
Wait-Until { Weto-Process } 'Weto запущен после тихой установки'
$first = (Weto-Process).Id
Write-Output "установлено, Weto запущен (pid $first)"

# --- 2. Поверх работающего --------------------------------------------------
Install
Wait-Until { (Weto-Process) -and ((Weto-Process).Id -ne $first) } 'новый экземпляр после переустановки'
Write-Output "переустановлено поверх работающего, Weto поднят заново (pid $((Weto-Process).Id))"

# Следы, которые обязано снести удаление: автозапуск, токен, данные.
Set-ItemProperty -Path $runKey -Name 'Weto' -Value "`"$app\Weto.exe`""
cmdkey "/generic:$credential" '/user:weto' '/pass:contract-test-value' | Out-Null
New-Item -ItemType Directory -Force $settingsDir, $stateDir | Out-Null
# Метки, а не настоящие файлы weto: формат учёта и настроек здесь не проверяется.
Set-Content (Join-Path $settingsDir 'contract-marker.txt') 'x'
Set-Content (Join-Path $stateDir 'contract-marker.txt') 'x'

# --- 3. Удаление ------------------------------------------------------------
# Деинсталлятор перезапускает себя из временного каталога и сразу выходит:
# конец удаления — исчезнувший каталог программы.
Start-Process -FilePath (Join-Path $app 'unins000.exe') -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
Wait-Until { -not (Test-Path $app) } 'каталог программы удалён' 120
Wait-Until { -not (Weto-Process) } 'Weto вышел'
Wait-Until { -not (Test-Path $stateDir) } 'учёт и журналы удалены' 30

if (Test-Path $shortcut) { Fail 'ярлык остался' }
if (Test-Path $settingsDir) { Fail "остались настройки: $settingsDir" }
if ((Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue).PSObject.Properties.Name -contains 'Weto') {
    Fail 'автозапуск остался'
}
# Заголовок вывода cmdkey называет цель и при пустом списке; сама запись — строка «Target:».
if ((cmdkey "/list:$credential") -match "Target:.*$([regex]::Escape($credential))") {
    Fail 'токен остался в Диспетчере учётных данных'
}

Write-Output 'контракт установщика: установка, обновление поверх работающего и удаление — в порядке'
