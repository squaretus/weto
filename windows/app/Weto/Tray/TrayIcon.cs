// Значок в области уведомлений — аналог значка в менюбаре macOS и трея Linux.
//
// В WinUI 3 своего значка в трее нет, поэтому он собран на Shell_NotifyIcon:
// скрытое окно получает щелчки и пересоздаёт значок, когда Проводник
// перезапустился (сообщение TaskbarCreated). Окно — верхнего уровня, никогда
// не показываемое, а не HWND_MESSAGE: окну-приёмнику не приходят широковещательные
// сообщения, то есть ни TaskbarCreated, ни WM_ENDSESSION, и после перезапуска
// Проводника значок не возвращался. Левый щелчок открывает
// попап статуса, правый — меню «Настройки» / «Закрыть Weto».
using System;
using System.Runtime.InteropServices;

namespace Weto.Tray;

public sealed partial class TrayIcon : IDisposable
{
    private const int WmApp = 0x8000;
    private const int CallbackMessage = WmApp + 1;
    private const int WmLButtonUp = 0x0202;
    private const int WmRButtonUp = 0x0205;
    private const int WmContextMenu = 0x007B;
    private const int WmCommand = 0x0111;
    private const int WmEndSession = 0x0016;
    private const uint WsExToolWindow = 0x80;

    private const uint NimAdd = 0, NimModify = 1, NimDelete = 2, NimSetVersion = 4;
    private const uint NifMessage = 0x1, NifIcon = 0x2, NifTip = 0x4, NifShowTip = 0x80;
    private const uint NotifyIconVersion4 = 4;

    private const int MenuProbe = 3, MenuSettings = 1, MenuQuit = 2;

    private readonly WndProc _proc;
    private readonly uint _taskbarCreated;
    private readonly nint _window;
    private nint _icon;
    private string _tip;
    private bool _added;

    /// <summary>Левый щелчок: показать попап статуса.</summary>
    public event Action? Clicked;
    public event Action? ProbeRequested;

    public event Action? SettingsRequested;
    public event Action? QuitRequested;

    /// <summary>Сеанс заканчивается (выход, перезагрузка): выйти до возврата из обработчика.</summary>
    public event Action? SessionEnding;

    public TrayIcon(string iconPath, string tip)
    {
        _tip = tip;
        _icon = LoadIcon(iconPath);
        _proc = Handle;
        _taskbarCreated = RegisterWindowMessageW("TaskbarCreated");

        var instance = GetModuleHandleW(null);
        var windowClass = new WindowClass
        {
            Size = (uint)Marshal.SizeOf<WindowClass>(),
            Procedure = Marshal.GetFunctionPointerForDelegate(_proc),
            Instance = instance,
            ClassName = "WetoTrayWindow",
        };
        RegisterClassExW(ref windowClass);
        _window = CreateWindowExW(WsExToolWindow, "WetoTrayWindow", "Weto", 0, 0, 0, 0, 0, 0, 0, instance, 0);
        Add();
    }

    /// <summary>
    /// Значок не добавился (Проводник ещё не поднялся при входе в систему) —
    /// повторить. Зовётся каждым тактом; добавленный значок не трогает.
    /// </summary>
    public void EnsureAdded()
    {
        if (!_added)
        {
            Add();
        }
    }

    /// <summary>Сменить картинку и подсказку: тон статуса виден и без попапа.</summary>
    public void Update(string iconPath, string tip)
    {
        var previous = _icon;
        _icon = LoadIcon(iconPath);
        _tip = tip;
        var data = Data(NifIcon | NifTip | NifShowTip);
        ShellNotifyIconW(NimModify, ref data);
        if (previous != 0)
        {
            DestroyIcon(previous);
        }
    }

    private void Add()
    {
        var data = Data(NifMessage | NifIcon | NifTip | NifShowTip);
        _added = ShellNotifyIconW(NimAdd, ref data);
        data.VersionOrTimeout = NotifyIconVersion4;
        ShellNotifyIconW(NimSetVersion, ref data);
    }

    private NotifyIconData Data(uint flags) => new()
    {
        Size = (uint)Marshal.SizeOf<NotifyIconData>(),
        Window = _window,
        Id = 1,
        Flags = flags,
        CallbackMessage = CallbackMessage,
        Icon = _icon,
        Tip = _tip.Length > 127 ? _tip[..127] : _tip,
        Info = string.Empty,
        InfoTitle = string.Empty,
    };

    private nint Handle(nint window, uint message, nint wParam, nint lParam)
    {
        if (message == _taskbarCreated)
        {
            // Проводник перезапустился и забыл все значки: добавляем заново.
            Add();
            return 0;
        }
        if (message == CallbackMessage)
        {
            // NOTIFYICON_VERSION_4: событие — младшее слово lParam.
            switch ((int)(lParam & 0xFFFF))
            {
                case WmLButtonUp:
                    Clicked?.Invoke();
                    break;
                case WmRButtonUp:
                case WmContextMenu:
                    ShowMenu();
                    break;
            }
            return 0;
        }
        if (message == WmEndSession && wParam != 0)
        {
            SessionEnding?.Invoke();
            return 0;
        }
        if (message == WmCommand)
        {
            switch ((int)(wParam & 0xFFFF))
            {
                case MenuProbe:
                    ProbeRequested?.Invoke();
                    break;
                case MenuSettings:
                    SettingsRequested?.Invoke();
                    break;
                case MenuQuit:
                    QuitRequested?.Invoke();
                    break;
            }
            return 0;
        }
        return DefWindowProcW(window, message, wParam, lParam);
    }

    private void ShowMenu()
    {
        var menu = CreatePopupMenu();
        // Пункты — как в трее Linux; «Выход» спрашивает то же «Закрыть Weto?»,
        // что кнопка «Закрыть приложение».
        AppendMenuW(menu, 0, MenuProbe, "Проверить сейчас");
        AppendMenuW(menu, 0, MenuSettings, "Настройки");
        AppendMenuW(menu, 0x800, 0, null); // MF_SEPARATOR
        AppendMenuW(menu, 0, MenuQuit, "Выход");
        GetCursorPos(out var point);
        // Без SetForegroundWindow меню не закрывается щелчком мимо него.
        SetForegroundWindow(_window);
        TrackPopupMenu(menu, 0x0020 /* TPM_RIGHTBUTTON */, point.X, point.Y, 0, _window, 0);
        DestroyMenu(menu);
    }

    private static nint LoadIcon(string path) =>
        LoadImageW(0, path, 1 /* IMAGE_ICON */, 0, 0, 0x10 /* LR_LOADFROMFILE */ | 0x40 /* LR_DEFAULTSIZE */);

    public void Dispose()
    {
        if (_added)
        {
            var data = Data(0);
            ShellNotifyIconW(NimDelete, ref data);
            _added = false;
        }
        if (_icon != 0)
        {
            DestroyIcon(_icon);
            _icon = 0;
        }
        if (_window != 0)
        {
            DestroyWindow(_window);
        }
    }

    private delegate nint WndProc(nint window, uint message, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WindowClass
    {
        public uint Size;
        public uint Style;
        public nint Procedure;
        public int ClassExtra;
        public int WindowExtra;
        public nint Instance;
        public nint Icon;
        public nint Cursor;
        public nint Background;
        public string? MenuName;
        public string ClassName;
        public nint SmallIcon;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public nint Window;
        public uint Id;
        public uint Flags;
        public uint CallbackMessage;
        public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Tip;
        public uint State;
        public uint StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string Info;
        public uint VersionOrTimeout;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string InfoTitle;
        public uint InfoFlags;
        public Guid Item;
        public nint BalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)]
    private static extern bool ShellNotifyIconW(uint message, ref NotifyIconData data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern ushort RegisterClassExW(ref WindowClass windowClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint CreateWindowExW(uint exStyle, string className, string windowName, uint style,
        int x, int y, int width, int height, nint parent, nint menu, nint instance, nint param);

    [DllImport("user32.dll")]
    private static extern nint DefWindowProcW(nint window, uint message, nint wParam, nint lParam);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(nint window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessageW(string name);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern nint LoadImageW(nint instance, string name, uint type, int width, int height, uint load);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(nint icon);

    [DllImport("user32.dll")]
    private static extern nint CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool AppendMenuW(nint menu, uint flags, nint id, string? text);

    [DllImport("user32.dll")]
    private static extern bool TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint window, nint rect);

    [DllImport("user32.dll")]
    private static extern bool DestroyMenu(nint menu);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(nint window);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern nint GetModuleHandleW(string? name);
}
