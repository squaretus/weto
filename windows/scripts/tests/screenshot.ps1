# Скриншот экрана приложения на раннере — замена проверке глазами, пока живой
# Windows нет. Запускает Weto с флагом, ждёт, снимает основной экран, закрывает.
#   powershell -File screenshot.ps1 -Exe out\x86_64\Weto.exe -Flag --show-status -Out status.png
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $Flag,
    [Parameter(Mandatory)] [string] $Out,
    [int] $Wait = 15
)
$ErrorActionPreference = 'Stop'
$process = Start-Process -FilePath $Exe -ArgumentList $Flag -PassThru
Start-Sleep -Seconds $Wait
if ($process.HasExited) {
    Write-Error "Weto завершился сам, код $($process.ExitCode)"
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$bitmap.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
Stop-Process -Id $process.Id -Force
Write-Output "снято: $Out ($($bounds.Width)x$($bounds.Height))"
