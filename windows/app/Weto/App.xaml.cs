// Точка входа: один экземпляр, мост с охраной, значок в трее, попап статуса.
//
// Охрана стартует здесь, при запуске процесса, а не с первым окном: на macOS
// ровно эта ловушка (лениво строящийся попап) оставляла машину без защиты,
// пока меню не откроют. Экран статуса опрашивается раз в секунду — тот же
// приём, что у Linux: событийной рассылки между потоками здесь не нужно.
using System;
using System.IO;
using System.Threading;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Weto.Bridge;
using Weto.Tray;

namespace Weto;

public partial class App : Application
{
    private const string InstanceMutex = @"Local\com.weto.app";

    private Mutex? _instance;
    private WetoBridge? _bridge;
    private TrayIcon? _tray;
    private DispatcherQueueTimer? _timer;
    private StatusWindow? _status;
    private SettingsWindow? _settings;
    private Tone? _shownTone;
    private string? _theme;

    public App()
    {
        InitializeComponent();
    }

    public static new App Current => (App)Application.Current;

    public WetoBridge Bridge => _bridge ?? throw new InvalidOperationException("Мост не поднят");

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _instance = new Mutex(initiallyOwned: true, InstanceMutex, out var created);
        if (!created)
        {
            // Второй экземпляр ничего не охраняет: охрана уже идёт в первом.
            Exit();
            return;
        }

        _bridge = WetoBridge.Start();
        _bridge.Notified += Notifications.Show;
        Notifications.Register(() => ShowStatus());

        _tray = new TrayIcon(TrayIconPath(Tone.Disabled), "Weto");
        _tray.Clicked += () => Dispatch(() => ToggleStatus());
        _tray.SettingsRequested += () => Dispatch(ShowSettings);
        _tray.QuitRequested += () => Dispatch(Quit);

        var queue = DispatcherQueue.GetForCurrentThread();
        _timer = queue.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(1);
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();
        Refresh();

        // Флаг для проверки в CI: открыть экраны сразу, чтобы снять их скриншотом.
        foreach (var argument in Environment.GetCommandLineArgs())
        {
            if (argument == "--show-status")
            {
                ShowStatus();
            }
            if (argument == "--show-settings")
            {
                ShowSettings();
            }
        }
    }

    /// <summary>Такт интерфейса: значок трея по тону, открытые окна — по экрану моста.</summary>
    private void Refresh()
    {
        if (_bridge is null || _tray is null)
        {
            return;
        }
        var status = _bridge.Status();
        if (status.Tone != _shownTone)
        {
            _tray.Update(TrayIconPath(status.Tone), $"Weto — {status.Title}");
            _shownTone = status.Tone;
        }
        _status?.Show(status);
        var theme = _bridge.Settings().Theme;
        if (theme != _theme)
        {
            ApplyTheme(theme);
            _theme = theme;
        }
    }

    /// <summary>Подменить словарь токенов темы: Тёмная или Светлая, без следования системе.</summary>
    public void ApplyTheme(string theme)
    {
        var dictionaries = Resources.MergedDictionaries;
        var source = new Uri(theme == "light"
            ? "ms-appx:///Themes/Tokens.Light.xaml"
            : "ms-appx:///Themes/Tokens.Dark.xaml");
        // Индекс 1 — словарь токенов (0 — XamlControlsResources).
        dictionaries[1] = new ResourceDictionary { Source = source };
        _status?.Rebuild();
        _settings?.Rebuild();
    }

    public void ShowStatus()
    {
        _status ??= new StatusWindow();
        _status.Present(Bridge.Status());
    }

    private void ToggleStatus()
    {
        if (_status is { IsOpen: true })
        {
            _status.Dismiss();
            return;
        }
        ShowStatus();
    }

    public void ShowSettings()
    {
        if (_settings is null)
        {
            _settings = new SettingsWindow();
            _settings.Closed += (_, _) => _settings = null;
        }
        _settings.Activate();
    }

    /// <summary>Штатный выход: стоящие цели продолжаются, охрана останавливается.</summary>
    public void Quit()
    {
        _timer?.Stop();
        _tray?.Dispose();
        _bridge?.Dispose();
        _bridge = null;
        _instance?.ReleaseMutex();
        Exit();
    }

    private static string TrayIconPath(Tone tone) =>
        Path.Combine(AppContext.BaseDirectory, "Assets", $"tray-{tone.ToString().ToLowerInvariant()}.ico");

    private static void Dispatch(Action action) =>
        DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => action());
}
