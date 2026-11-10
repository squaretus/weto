// Окно настроек — порт окна macOS (docs/design-system.md, «Окно»): сегменты
// «Настройки» / «Журнал», под ними карточки вкладки и подвал.
//
// Вкладка «Настройки»: Цели → Сеть и гео → Чёрный список → Белый список →
// Внешний вид → Обслуживание. Каждое действие — команда моста; отказ моста
// (повтор цели, неверная запись списка) показывается под полем его же текстом.
// Тумблера охраны нет: kill switch включён всегда, пока приложение запущено.
using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Weto.Bridge;
using static Weto.Ui.Components;

namespace Weto;

public sealed class SettingsWindow : Window
{
    private enum Tab
    {
        Settings,
        Journal,
    }

    private readonly ScrollViewer _scroll = new();
    private Tab _tab = Tab.Settings;
    private string? _error;

    public SettingsWindow()
    {
        Title = "Weto";
        Content = _scroll;
        var scale = 1.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(
            (int)(Number("WindowWidth") * scale),
            (int)(Number("WindowHeight") * scale)));
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Weto.ico"));
        Rebuild();
    }

    public void Rebuild()
    {
        var settings = App.Current.Bridge.Settings();
        var panel = Panel();
        _scroll.Background = Brush("Shell");
        _scroll.Content = panel;

        panel.Children.Add(Segments(
            [(Tab.Settings, "Настройки"), (Tab.Journal, "Журнал")],
            _tab,
            tab =>
            {
                _tab = tab;
                Rebuild();
            }));

        if (_tab == Tab.Settings)
        {
            panel.Children.Add(TargetsCard(settings));
            panel.Children.Add(NetworkCard(settings));
            panel.Children.Add(GeoCard("Чёрный список", settings.Blocked, "blocked"));
            panel.Children.Add(GeoCard("Белый список", settings.Allowed, "allowed"));
            panel.Children.Add(AppearanceCard(settings));
            panel.Children.Add(MaintenanceCard(settings));
        }
        else
        {
            panel.Children.Add(JournalCard());
        }

        panel.Children.Add(Footer());
    }

    /// <summary>Команда моста; отказ — под полем, успех — перерисовка.</summary>
    private void Run(string command, IReadOnlyDictionary<string, object?>? fields = null)
    {
        var result = App.Current.Bridge.Command(command, fields);
        _error = result.Ok ? null : result.Error;
        Rebuild();
    }

    private UIElement ErrorLine() =>
        _error is null ? new StackPanel() : (UIElement)Text(_error, "Caption", "Red", wrap: true);

    private Border TargetsCard(SettingsView settings)
    {
        var rows = new List<UIElement>();
        if (settings.Targets.Count == 0)
        {
            rows.Add(Row(Text("Цели не выбраны — охрана ничего не завершает", "Caption", "Faint", wrap: true)));
        }
        foreach (var target in settings.Targets)
        {
            var entry = target.Entry;
            rows.Add(Row(
                Titled(target.DisplayName, target.Description),
                IconButton("", "Убрать цель", () => Run("removeTarget", new Dictionary<string, object?> { ["entry"] = entry }))));
        }
        rows.Add(WithoutDividerIf(settings.Targets.Count == 0, EntryRow(
            "Имя команды или путь к программе",
            text => Run("addTarget", new Dictionary<string, object?> { ["entry"] = text, ["displayName"] = null }))));
        return Card("Цели", rows);
    }

    private Border NetworkCard(SettingsView settings)
    {
        var rows = new List<UIElement>();
        var vpn = settings.VpnApp;
        rows.Add(Row(
            Titled("VPN-приложение", vpn is null ? "не выбрано — охрана работает по гео" : $"{vpn.DisplayName} · {vpn.Description}"),
            vpn is null ? null : PillButton("Сбросить", ButtonKind.Muted, () => Run("clearVpnApp"))));
        rows.Add(EntryRow(
            "Путь к программе VPN",
            text => Run("setVpnApp", new Dictionary<string, object?> { ["entry"] = text, ["displayName"] = null })));

        var token = Field(settings.TokenSet ? "токен сохранён" : "Токен ipinfo (необязательно)");
        token.KeyDown += (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Enter)
            {
                Run("setToken", new Dictionary<string, object?> { ["token"] = token.Text });
            }
        };
        rows.Add(FieldRow("Токен ipinfo", token));

        var choices = new List<(ulong, string)>();
        foreach (var choice in settings.PauseCeilings)
        {
            choices.Add((choice.Seconds, choice.Title));
        }
        rows.Add(FieldRow(
            "Потолок паузы",
            Segments(choices, settings.PauseCeiling, seconds =>
                Run("setPauseCeiling", new Dictionary<string, object?> { ["seconds"] = seconds }))));
        return Card("Сеть и гео", rows);
    }

    private Border GeoCard(string title, IReadOnlyList<string> entries, string list)
    {
        var rows = new List<UIElement>();
        foreach (var entry in entries)
        {
            var value = entry;
            rows.Add(Row(
                Text(entry, "Value", "Dim"),
                IconButton("", "Убрать", () => Run("removeGeoEntry", new Dictionary<string, object?> { ["entry"] = value, ["list"] = list }))));
        }
        rows.Add(WithoutDividerIf(entries.Count == 0, EntryRow(
            "Код страны (RU), IP или CIDR",
            text => Run("addGeoEntry", new Dictionary<string, object?> { ["text"] = text, ["list"] = list }))));
        return Card(title, rows);
    }

    private Border AppearanceCard(SettingsView settings) => Card("Внешний вид",
    [
        FieldRow(
            "Тема",
            Segments([("dark", "Тёмная"), ("light", "Светлая")], settings.Theme, theme =>
                Run("setTheme", new Dictionary<string, object?> { ["theme"] = theme }))),
    ]);

    private Border MaintenanceCard(SettingsView settings)
    {
        var autostart = new ToggleSwitch { IsOn = settings.Autostart, OnContent = null, OffContent = null };
        autostart.Toggled += (_, _) =>
            Run("setAutostart", new Dictionary<string, object?> { ["enabled"] = autostart.IsOn });
        return Card("Обслуживание",
        [
            Row(Text("Запускать при входе в Windows", "Label"), autostart),
            WithoutDivider(Row(PillButton("Закрыть приложение", ButtonKind.Muted, () => App.Current.Quit()))),
        ]);
    }

    /// <summary>
    /// Журнал: строка на эпизод — имя, итог, диагностика; свежие сверху.
    /// «Выгрузить» доступна всегда (в выгрузке и журнал проверок, и настройки),
    /// «Очистить» — только когда есть что очищать.
    /// </summary>
    private Border JournalCard()
    {
        var journal = App.Current.Bridge.Journal();
        var rows = new List<UIElement>();
        if (journal.Rows.Count == 0)
        {
            rows.Add(Row(Text("Срабатываний не было", "Caption", "Faint")));
        }
        foreach (var entry in journal.Rows)
        {
            var lines = new StackPanel { Spacing = 2, Padding = new Thickness(0, Number("Space2"), 0, Number("Space2")) };
            lines.Children.Add(Text(entry.Title, "Label"));
            lines.Children.Add(Text(entry.Summary, "Value", "Dim", wrap: true));
            if (entry.Resolution is { } resolution)
            {
                lines.Children.Add(Text(resolution, "Value", "Dim", wrap: true));
            }
            lines.Children.Add(Text(entry.Diagnostics, "Diagnostics", "Faint", wrap: true));
            rows.Add(lines);
        }
        if (journal.LimitCaption is { } caption)
        {
            rows.Add(Row(Text(caption, "Caption", "Faint", wrap: true)));
        }

        var buttons = new Grid { ColumnSpacing = Number("Space2"), Margin = new Thickness(0, Number("Space3"), 0, 0) };
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var export = PillButton("Выгрузить журнал", ButtonKind.Muted, ExportJournal);
        export.HorizontalAlignment = HorizontalAlignment.Stretch;
        buttons.Children.Add(export);
        if (journal.Rows.Count > 0)
        {
            buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var clear = PillButton("Очистить журнал", ButtonKind.Destructive, () => Run("clearJournal"));
            clear.HorizontalAlignment = HorizontalAlignment.Stretch;
            Grid.SetColumn(clear, 1);
            buttons.Children.Add(clear);
        }
        rows.Add(WithoutDivider(buttons));
        return Card("Журнал", rows);
    }

    private void ExportJournal()
    {
        var name = $"weto-journal-{DateTime.UtcNow:yyyy-MM-dd-HHmm}.json";
        var path = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", name);
        Run("exportJournal", new Dictionary<string, object?> { ["path"] = path });
    }

    private UIElement Footer() => Row(
        Text("github", "Caption", "Faint"),
        Text($"версия {typeof(App).Assembly.GetName().Version?.ToString(3)}", "Caption", "Faint"));

    /// <summary>Строка ввода: поле во всю ширину и «Добавить»; Enter — то же, что кнопка.</summary>
    private Grid EntryRow(string placeholder, Action<string> add)
    {
        var field = Field(placeholder);
        void Submit()
        {
            if (!string.IsNullOrWhiteSpace(field.Text))
            {
                add(field.Text);
            }
        }
        field.KeyDown += (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Enter)
            {
                Submit();
            }
        };
        var stack = new StackPanel { Spacing = Number("Space1") };
        stack.Children.Add(field);
        stack.Children.Add(ErrorLine());
        return Row(stack, PillButton("Добавить", ButtonKind.Primary, Submit));
    }

    private static T WithoutDividerIf<T>(bool condition, T row)
        where T : FrameworkElement => condition ? WithoutDivider(row) : row;
}
