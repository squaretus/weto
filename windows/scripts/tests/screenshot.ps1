# Скриншоты окон приложения на раннере — замена проверке глазами, пока живой
# Windows нет. Запускает Weto с флагом, ждёт и снимает каждое видимое окно
# процесса через PrintWindow: окно рисуется само, даже если его перекрывает
# чужое (на windows-11-arm поверх рабочего стола висит экран первичной
# настройки Windows, и снимок экрана показывал только его).
#   pwsh -File screenshot.ps1 -Exe out\x86_64\Weto.exe -Flag --show-status -Out screens\status
# Файлы: <Out>-1.png, <Out>-2.png … — по окну на файл.
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $Flag,
    [Parameter(Mandatory)] [string] $Out,
    [int] $Wait = 15
)
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class WindowShot
{
    private delegate bool EnumProc(IntPtr window, IntPtr param);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, IntPtr param);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }

    public static int Capture(uint pid, string prefix)
    {
        var windows = new List<IntPtr>();
        EnumWindows((window, _) =>
        {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == pid && IsWindowVisible(window)) windows.Add(window);
            return true;
        }, IntPtr.Zero);

        var saved = 0;
        foreach (var window in windows)
        {
            Rect rect;
            GetWindowRect(window, out rect);
            int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
            if (width < 40 || height < 40) continue;
            using (var bitmap = new Bitmap(width, height))
            {
                using (var graphics = Graphics.FromImage(bitmap))
                {
                    var dc = graphics.GetHdc();
                    PrintWindow(window, dc, 2); // PW_RENDERFULLCONTENT — содержимое DirectComposition
                    graphics.ReleaseHdc(dc);
                }
                saved++;
                bitmap.Save(prefix + "-" + saved + ".png", ImageFormat.Png);
            }
        }
        return saved;
    }
}
'@

$process = Start-Process -FilePath $Exe -ArgumentList $Flag -PassThru
Start-Sleep -Seconds $Wait
if ($process.HasExited) {
    Write-Error "Weto завершился сам, код $($process.ExitCode)"
}
$count = [WindowShot]::Capture([uint32]$process.Id, $Out)
Stop-Process -Id $process.Id -Force
if ($count -eq 0) {
    Write-Error "у Weto нет видимых окон для снимка"
}
Write-Output "снято окон: $count → $Out-*.png"
