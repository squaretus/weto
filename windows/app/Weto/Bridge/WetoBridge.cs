// Обёртка над мостом: поднять, спросить экран, отдать команду, остановить.
//
// Мост внутри потокобезопасен — охрана живёт своим потоком, — поэтому вызывать
// его можно с любого потока. Уведомление приходит с потока охраны: показывать
// его — забота того, кто подписан (он переносит показ на поток интерфейса).
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace Weto.Bridge;

public sealed unsafe class WetoBridge : IDisposable
{
    private nint _weto;
    private GCHandle _self;

    /// <summary>Уведомление охраны. Приходит с потока охраны.</summary>
    public event Action<Notification>? Notified;

    /// <summary>Поднять мост и охрану. Охрана стартует здесь, а не с первым окном.</summary>
    public static WetoBridge Start()
    {
        var bridge = new WetoBridge();
        bridge._self = GCHandle.Alloc(bridge);
        var callbacks = new Native.Callbacks
        {
            Context = GCHandle.ToIntPtr(bridge._self),
            Notify = &OnNotify,
        };
        bridge._weto = Native.weto_start(callbacks);
        if (bridge._weto == 0)
        {
            bridge._self.Free();
            throw new InvalidOperationException("Мост Weto не поднялся");
        }
        return bridge;
    }

    public StatusView Status() =>
        View("status", BridgeJson.Default.StatusView)
        ?? throw new InvalidOperationException("Мост не отдал экран статуса");

    public SettingsView Settings() =>
        View("settings", BridgeJson.Default.SettingsView)
        ?? throw new InvalidOperationException("Мост не отдал экран настроек");

    /// <summary>Образец экрана «цели на паузе» — для скриншотов в CI.</summary>
    public StatusView StatusSample() =>
        View("status-sample", BridgeJson.Default.StatusView)
        ?? throw new InvalidOperationException("Мост не отдал образец");

    public JournalView Journal() =>
        View("journal", BridgeJson.Default.JournalView)
        ?? throw new InvalidOperationException("Мост не отдал журнал");

    public UpdateView Update() =>
        View("update", BridgeJson.Default.UpdateView)
        ?? throw new InvalidOperationException("Мост не отдал экран обновления");

    public DialogView UninstallConfirmation() =>
        View("uninstall-confirmation", BridgeJson.Default.DialogView)
        ?? throw new InvalidOperationException("Мост не отдал текст подтверждения");

    /// <summary>
    /// Проверка перед сносом (<c>Weto.exe --uninstall</c>): без запуска охраны.
    /// <c>null</c> — сбой, удалять нельзя.
    /// </summary>
    public static UninstallCheck? UninstallCheck()
    {
        var text = Native.Take(Native.weto_uninstall_check());
        return text is null ? null : JsonSerializer.Deserialize(text, BridgeJson.Default.UninstallCheck);
    }

    /// <summary>Снос токена и автозапуска (<c>Weto.exe --uninstall-cleanup</c>).</summary>
    public static CommandResult UninstallCleanup()
    {
        var text = Native.Take(Native.weto_uninstall_cleanup());
        return text is null
            ? new CommandResult(false, null, "Мост не ответил")
            : JsonSerializer.Deserialize(text, BridgeJson.Default.CommandResult)
              ?? new CommandResult(false, null, "Ответ моста не разобран");
    }

    /// <summary>
    /// Команда моста: имя и поля, как их ждёт weto-ffi/src/command.rs
    /// (<c>{"command":"addTarget","entry":"claude"}</c>).
    /// </summary>
    public CommandResult Command(string name, IReadOnlyDictionary<string, object?>? fields = null)
    {
        var payload = new Dictionary<string, object?> { ["command"] = name };
        if (fields is not null)
        {
            foreach (var (key, value) in fields)
            {
                payload[key] = value;
            }
        }
        var json = JsonSerializer.Serialize(payload, BridgeJson.Default.DictionaryStringObject);
        var answer = Native.Take(Native.weto_command(_weto, json));
        return answer is null
            ? new CommandResult(false, null, "Мост не ответил")
            : JsonSerializer.Deserialize(answer, BridgeJson.Default.CommandResult)
              ?? new CommandResult(false, null, "Ответ моста не разобран");
    }

    private T? View<T>(string kind, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type)
    {
        var text = Native.Take(Native.weto_view(_weto, kind));
        return text is null ? default : JsonSerializer.Deserialize(text, type);
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static void OnNotify(nint context, byte* json)
    {
        try
        {
            if (GCHandle.FromIntPtr(context).Target is not WetoBridge bridge)
            {
                return;
            }
            var text = Marshal.PtrToStringUTF8((nint)json);
            var notification = text is null
                ? null
                : JsonSerializer.Deserialize(text, BridgeJson.Default.Notification);
            if (notification is not null)
            {
                bridge.Notified?.Invoke(notification);
            }
        }
        catch
        {
            // Исключение не должно пересечь границу FFI: охрана живёт дальше,
            // уведомление пропадает — журнал о завершении всё равно есть.
        }
    }

    /// <summary>Штатный выход: продолжить стоящие цели и остановить охрану.</summary>
    public void Dispose()
    {
        if (_weto != 0)
        {
            Native.weto_stop(_weto);
            _weto = 0;
        }
        if (_self.IsAllocated)
        {
            _self.Free();
        }
    }
}
