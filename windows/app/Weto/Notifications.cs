// Уведомления Windows — аналог UserNotifications на macOS и D-Bus на Linux.
//
// Неупакованному приложению AUMID и COM-регистрация руками не нужны: Register()
// делает процесс COM-сервером сам. Порядок по документации обязателен —
// подписка на NotificationInvoked раньше Register(), иначе щелчок поднимет
// второй процесс. Щелчок открывает попап статуса, как на других платформах.
using System;
using System.IO;
using Microsoft.UI.Dispatching;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Weto.Bridge;

namespace Weto;

public static class Notifications
{
    private static DispatcherQueue? _queue;
    private static bool _registered;

    /// <summary>Зарегистрироваться; щелчок по уведомлению зовёт <paramref name="open"/> на потоке интерфейса.</summary>
    public static void Register(Action open)
    {
        _queue = DispatcherQueue.GetForCurrentThread();
        var manager = AppNotificationManager.Default;
        manager.NotificationInvoked += (_, _) => _queue?.TryEnqueue(() => open());
        try
        {
            var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "Weto.ico");
            manager.Register("Weto", new Uri(icon));
            _registered = true;
        }
        catch (Exception error)
        {
            // Без уведомлений охрана работает так же: журнал о завершении есть всё равно.
            System.Diagnostics.Debug.WriteLine($"weto: уведомления недоступны: {error.Message}");
        }
    }

    /// <summary>Показать уведомление охраны. Зовётся с потока интерфейса.</summary>
    public static void Show(Notification notification)
    {
        if (!_registered)
        {
            return;
        }
        var content = new AppNotificationBuilder()
            .AddText(notification.Title)
            .AddText(notification.Body)
            .BuildNotification();
        AppNotificationManager.Default.Show(content);
    }

    public static void Unregister()
    {
        if (_registered)
        {
            AppNotificationManager.Default.Unregister();
            _registered = false;
        }
    }
}
