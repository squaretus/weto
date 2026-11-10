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

    /// <summary>
    /// Просьба выйти от деинсталлятора (<c>Weto.exe --uninstall</c>): работающий
    /// экземпляр выходит штатно — стоящие цели продолжаются.
    /// </summary>
    private const string QuitEvent = @"Local\com.weto.app.quit";

    /// <summary>Сколько деинсталлятор ждёт выхода работающего экземпляра.</summary>
    private static readonly TimeSpan QuitTimeout = TimeSpan.FromSeconds(20);

    private Mutex? _instance;
    private WetoBridge? _bridge;
    private TrayIcon? _tray;
    private DispatcherQueueTimer? _timer;
    private StatusWindow? _status;
    private SettingsWindow? _settings;
    private UpdateWindow? _update;
    private EventWaitHandle? _quitRequest;
    private Tone? _shownTone;
    private string? _theme;

    /// <summary>Показывать образец «цели на паузе» вместо живого статуса — для скриншота в CI.</summary>
    private static readonly bool Sample =
        Array.Exists(Environment.GetCommandLineArgs(), a => a == "--show-status-sample");

    /// <summary>Показывать образец находки обновления (баннер и окно) — для скриншота в CI.</summary>
    private static readonly bool UpdateSample =
        Array.Exists(Environment.GetCommandLineArgs(), a => a == "--show-update-sample");

    public App()
    {
        InitializeComponent();
    }

    public static new App Current => (App)Application.Current;

    public WetoBridge Bridge => _bridge ?? throw new InvalidOperationException("Мост не поднят");

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Режимы деинсталлятора — без охраны, трея и мьютекса экземпляра.
        var arguments = Environment.GetCommandLineArgs();
        if (Array.Exists(arguments, a => a == "--uninstall"))
        {
            Uninstall();
            return;
        }
        if (Array.Exists(arguments, a => a == "--uninstall-cleanup"))
        {
            UninstallCleanup();
            return;
        }

        _instance = new Mutex(initiallyOwned: true, InstanceMutex, out var created);
        if (!created)
        {
            // Второй экземпляр ничего не охраняет: охрана уже идёт в первом.
            Exit();
            return;
        }

        _bridge = WetoBridge.Start();
        ListenForQuitRequest();
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
            if (argument is "--show-status" or "--show-status-sample")
            {
                ShowStatus();
            }
            if (argument is "--show-settings" or "--show-settings-end")
            {
                ShowSettings();
            }
            if (argument == "--show-update-sample")
            {
                ShowStatus();
                ShowUpdate();
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
        var status = Sample ? _bridge.StatusSample() : _bridge.Status();
        if (status.Tone != _shownTone)
        {
            _tray.Update(TrayIconPath(status.Tone), $"Weto — {status.Title}");
            _shownTone = status.Tone;
        }
        _status?.Show(status);

        var update = CurrentUpdate();
        if (update.Installed)
        {
            // Установщик запущен и ждёт мьютекса: выход штатный, стоящие цели
            // продолжаются, новую версию установщик поднимет сам.
            Quit();
            return;
        }
        if (update.WindowRequested)
        {
            ShowUpdate();
        }
        _status?.ShowUpdate(update);
        _settings?.ShowUpdate(update);
        _update?.Show(update);

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
        _status.Present(Sample ? Bridge.StatusSample() : Bridge.Status());
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

    /// <summary>Окно обновления: одно на процесс; закрывается само, когда находки нет.</summary>
    public void ShowUpdate()
    {
        if (_update is null)
        {
            _update = new UpdateWindow();
            _update.Closed += (_, _) => _update = null;
        }
        _update.Show(CurrentUpdate());
        _update?.Activate();
    }

    private UpdateView CurrentUpdate() => UpdateSample ? Bridge.UpdateSample() : Bridge.Update();

    /// <summary>
    /// Кнопка «Удалить приложение…»: подтверждение текстами моста, затем
    /// деинсталлятор Inno Setup тихо и штатный выход. Стоящих проверит
    /// уже деинсталлятор (<c>--uninstall</c>) — один путь и для «Параметров» Windows.
    /// </summary>
    public void AskToUninstall(Action<string> fail)
    {
        var uninstaller = Path.Combine(AppContext.BaseDirectory, "unins000.exe");
        if (!File.Exists(uninstaller))
        {
            fail("Удаление доступно только у установленной копии Weto");
            return;
        }
        DialogWindow.Ask(Bridge.UninstallConfirmation(), destructive: true, confirmed =>
        {
            if (!confirmed)
            {
                return;
            }
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(uninstaller, "/SILENT")
                {
                    UseShellExecute = true,
                });
            }
            catch (Exception error)
            {
                fail($"Деинсталлятор не запустился: {error.Message}");
                return;
            }
            Quit();
        });
    }

    /// <summary>Поток ждёт просьбы деинсталлятора и переносит выход на поток интерфейса.</summary>
    private void ListenForQuitRequest()
    {
        var queue = DispatcherQueue.GetForCurrentThread();
        _quitRequest = new EventWaitHandle(false, EventResetMode.AutoReset, QuitEvent);
        var request = _quitRequest;
        new Thread(() =>
        {
            try
            {
                request.WaitOne();
                queue.TryEnqueue(Quit);
            }
            catch (ObjectDisposedException)
            {
                // Выход случился раньше просьбы.
            }
        }) { IsBackground = true, Name = "weto-quit-request" }.Start();
    }

    /// <summary>
    /// <c>Weto.exe --uninstall</c> из деинсталлятора, до удаления чего-либо.
    /// Попросить работающий экземпляр выйти и дождаться его мьютекса; затем
    /// мост без охраны досылает SIGCONT по учёту и называет оставшихся стоять.
    /// Код 0 — удалять, иначе деинсталлятор отменяет удаление.
    /// </summary>
    private void Uninstall()
    {
        if (EventWaitHandle.TryOpenExisting(QuitEvent, out var quit))
        {
            quit.Set();
            quit.Dispose();
        }
        // Мьютекс держится до конца процесса: второй Weto не поднимется
        // посреди проверки и вопроса.
        _instance = new Mutex(false, InstanceMutex);
        bool acquired;
        try
        {
            acquired = _instance.WaitOne(QuitTimeout);
        }
        catch (AbandonedMutexException)
        {
            // Экземпляр упал, не отпустив мьютекс: учёт разберёт мост ниже.
            acquired = true;
        }
        if (!acquired)
        {
            Environment.Exit(2);
        }
        var check = WetoBridge.UninstallCheck();
        if (check is null)
        {
            Environment.Exit(3);
        }
        if (check.Dialog is null)
        {
            Environment.Exit(0);
        }
        // Второй исход — «Не удалять и закрыть Weto»: Weto к этому моменту уже закрыт.
        DialogWindow.Ask(check.Dialog, destructive: true, confirmed => Environment.Exit(confirmed ? 0 : 1));
    }

    /// <summary>
    /// <c>Weto.exe --uninstall-cleanup</c>: регистрация уведомлений, токен и
    /// автозапуск. Каталоги данных сносит деинсталлятор — учёт последним.
    /// </summary>
    private static void UninstallCleanup()
    {
        try
        {
            Microsoft.Windows.AppNotifications.AppNotificationManager.Default.UnregisterAll();
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"weto: регистрация уведомлений не снята: {error.Message}");
        }
        var result = WetoBridge.UninstallCleanup();
        if (!result.Ok)
        {
            Console.Error.WriteLine($"weto: {result.Error}");
        }
        Environment.Exit(result.Ok ? 0 : 1);
    }

    /// <summary>Штатный выход: стоящие цели продолжаются, охрана останавливается.</summary>
    public void Quit()
    {
        _timer?.Stop();
        _quitRequest?.Dispose();
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
