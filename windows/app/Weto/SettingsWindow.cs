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
using Weto.Ui;
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
    private readonly Dictionary<string, string> _errors = new();
    private readonly Dictionary<string, TextBlock> _counts = new(StringComparer.OrdinalIgnoreCase);
    private string? _tokenError;
    private string? _maintenanceError;
    private ToggleSwitch? _autoInstall;
    private bool _syncing;
    private Button? _check;
    private FooterView? _footer;

    public SettingsWindow()
    {
        Title = "Weto — настройки";
        Content = _scroll;
        var scale = 1.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(
            (int)(Number("WindowWidth") * scale),
            (int)(Number("WindowHeight") * scale)));
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Weto.ico"));
        Rebuild();
        // Для скриншота в CI: низ вкладки — «Обслуживание» и подвал.
        if (Array.Exists(Environment.GetCommandLineArgs(), a => a == "--show-settings-end"))
        {
            _scroll.Loaded += (_, _) => DispatcherQueue.TryEnqueue(() =>
                _scroll.ChangeView(null, _scroll.ScrollableHeight, null, disableAnimation: true));
        }
    }

    /// <summary>
    /// Заголовок окна в цветах темы: системный светлый заголовок над тёмными
    /// карточками читался чужим. Кнопки окна остаются системными.
    /// </summary>
    private void PaintTitleBar()
    {
        var bar = AppWindow.TitleBar;
        var shell = (Windows.UI.Color)Application.Current.Resources["WetoShellColor"];
        var ink = (Windows.UI.Color)Application.Current.Resources["WetoInkColor"];
        var faint = (Windows.UI.Color)Application.Current.Resources["WetoFaintColor"];
        bar.BackgroundColor = shell;
        bar.InactiveBackgroundColor = shell;
        bar.ButtonBackgroundColor = shell;
        bar.ButtonInactiveBackgroundColor = shell;
        bar.ForegroundColor = ink;
        bar.ButtonForegroundColor = ink;
        bar.InactiveForegroundColor = faint;
        bar.ButtonInactiveForegroundColor = faint;
    }

    public void Rebuild()
    {
        PaintTitleBar();
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
            panel.Children.Add(GeoCard("Чёрный список", settings.Blocked, "blocked", settings.Hints.Geo));
            panel.Children.Add(GeoCard("Белый список", settings.Allowed, "allowed", settings.Hints.Geo));
            panel.Children.Add(AppearanceCard(settings));
            panel.Children.Add(MaintenanceCard(settings));
        }
        else
        {
            panel.Children.Add(JournalCard());
        }

        panel.Children.Add(Footer());
    }

    /// <summary>
    /// Команда моста; отказ — под своим полем (<paramref name="field"/>), успех —
    /// перерисовка. Отказ — текст ядра: повтор цели, неверная запись списка.
    /// </summary>
    private void Run(string command, IReadOnlyDictionary<string, object?>? fields = null, string? field = null)
    {
        var result = App.Current.Bridge.Command(command, fields);
        if (field is not null)
        {
            if (result.Ok)
            {
                _errors.Remove(field);
            }
            else
            {
                _errors[field] = result.Error ?? "";
            }
        }
        Rebuild();
    }

    /// <summary>Подпись отказа под полем — капшен red; нет отказа — строки нет.</summary>
    private UIElement? ErrorRow(string field) =>
        _errors.TryGetValue(field, out var error)
            ? WithoutDivider(Text(error, "Caption", "Red", wrap: true))
            : null;

    // --- Цели ----------------------------------------------------------------

    /// <summary>
    /// Цели — как на Linux: имя над описанием, число запущенных процессов, корзина;
    /// под списком «Новая цель» с пояснением формата, «Добавить» (неактивна,
    /// пока поле пустое) и «Выбрать…» — ярлыки меню «Пуск», аналог каталога
    /// приложений на Linux.
    /// </summary>
    private Border TargetsCard(SettingsView settings)
    {
        var rows = new List<UIElement>();
        _counts.Clear();
        if (settings.Targets.Count == 0)
        {
            rows.Add(Row(Text("Цели не выбраны — охрана ничего не завершает", "Caption", "Dim", wrap: true)));
        }
        foreach (var target in settings.Targets)
        {
            var entry = target.Entry;
            var count = DataValue(target.Running.ToString());
            _counts[entry] = count;
            var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Number("Space3") };
            right.Children.Add(count);
            right.Children.Add(IconButton("\uE74D", "Удалить цель", () =>
                Run("removeTarget", new Dictionary<string, object?> { ["entry"] = entry })));
            rows.Add(Row(Described(target.DisplayName, target.Description), right));
        }

        var field = Field("Новая цель");
        void Add(string text) => Run(
            "addTarget",
            new Dictionary<string, object?> { ["entry"] = text, ["displayName"] = null },
            "target");
        var add = AddButton(field, Add);
        var pick = PillButton("Выбрать…", ButtonKind.Muted, PickTargets);
        var input = new Grid { ColumnSpacing = Number("Space3"), Padding = new Thickness(0, Number("Space2"), 0, Number("Space2")) };
        input.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        input.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        input.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        input.Children.Add(HintedField(field, settings.Hints.Target));
        Grid.SetColumn(add, 1);
        input.Children.Add(add);
        Grid.SetColumn(pick, 2);
        input.Children.Add(pick);
        rows.Add(WithoutDividerIf(settings.Targets.Count == 0, input));
        if (ErrorRow("target") is { } error)
        {
            rows.Add(error);
        }
        return Card("Цели", rows);
    }

    /// <summary>Ярлыки и программы из меню «Пуск» пользователя; можно несколько сразу.</summary>
    private void PickTargets()
    {
        var owner = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var picked = FileDialogs.Open(
            owner,
            "Выбрать цель",
            Environment.GetFolderPath(Environment.SpecialFolder.Programs),
            [("Программы и ярлыки", "*.lnk;*.exe")]);
        foreach (var path in picked)
        {
            var result = App.Current.Bridge.Command(
                "addTarget", new Dictionary<string, object?> { ["entry"] = path, ["displayName"] = null });
            if (!result.Ok)
            {
                _errors["target"] = result.Error ?? "";
            }
        }
        if (picked.Count > 0)
        {
            Rebuild();
        }
    }

    // --- Сеть и гео ------------------------------------------------------------

    private Border NetworkCard(SettingsView settings)
    {
        var rows = new List<UIElement>();

        // VPN-приложение: два состояния, как на Linux. Не выбрано — «не выбрано»,
        // поле «Команда или путь» и «Выбрать»; выбрано — имя над описанием
        // и корзина «Снять выбор».
        FrameworkElement vpnRight;
        if (settings.VpnApp is { } vpn)
        {
            var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            var name = Text(vpn.DisplayName, "Value");
            name.HorizontalAlignment = HorizontalAlignment.Right;
            text.Children.Add(name);
            var description = Text(vpn.Description, "Caption", "Faint", wrap: true);
            description.HorizontalAlignment = HorizontalAlignment.Right;
            description.TextAlignment = TextAlignment.Right;
            description.IsTextSelectionEnabled = true;
            text.Children.Add(description);
            var chosen = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Number("Space3") };
            chosen.Children.Add(text);
            chosen.Children.Add(IconButton("\uE74D", "Снять выбор", () => Run("clearVpnApp")));
            vpnRight = chosen;
        }
        else
        {
            var unchosen = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Number("Space3") };
            unchosen.Children.Add(Text("не выбрано", "Value", "Faint"));
            var field = Field("Команда или путь");
            field.Width = 160;
            void Set()
            {
                if (!string.IsNullOrWhiteSpace(field.Text))
                {
                    Run("setVpnApp", new Dictionary<string, object?> { ["entry"] = field.Text, ["displayName"] = null }, "vpn");
                }
            }
            field.KeyDown += (_, args) =>
            {
                if (args.Key == Windows.System.VirtualKey.Enter)
                {
                    Set();
                }
            };
            unchosen.Children.Add(field);
            unchosen.Children.Add(PillButton("Выбрать", ButtonKind.Primary, Set));
            vpnRight = unchosen;
        }
        rows.Add(Row(Text("VPN-приложение", "Label"), vpnRight));
        if (ErrorRow("vpn") is { } vpnError)
        {
            rows.Add(vpnError);
        }

        rows.Add(FieldRow(LabelWithHint("Токен ipinfo", settings.Hints.Token), TokenField(settings)));
        if (_tokenError is { } tokenError)
        {
            rows.Add(WithoutDivider(Text(tokenError, "Caption", "Red", wrap: true)));
        }

        var choices = new List<(ulong, string)>();
        foreach (var choice in settings.PauseCeilings)
        {
            choices.Add((choice.Seconds, choice.Title));
        }
        rows.Add(FieldRow(
            LabelWithHint("Таймаут", settings.Hints.Timeout),
            Segments(choices, settings.PauseCeiling, seconds =>
                Run("setPauseCeiling", new Dictionary<string, object?> { ["seconds"] = seconds }))));
        return Card("Сеть и гео", rows);
    }

    /// <summary>
    /// Поле токена — порт Linux: вне фокуса маска с хвостом, в фокусе сам токен;
    /// сохраняется по ходу правки, а маска и её обломки не сохраняются никогда
    /// (<c>presentation::token_to_save</c>: текст с «•» — не ввод).
    /// </summary>
    private TextBox TokenField(SettingsView settings)
    {
        var field = Field("Ключ ipinfo.io");
        var stored = "";
        var replacing = false;
        void Show(string text)
        {
            replacing = true;
            field.Text = text;
            replacing = false;
        }
        Show(settings.TokenMask);
        field.GotFocus += (_, _) =>
        {
            stored = App.Current.Bridge.Token();
            Show(stored);
        };
        field.LostFocus += (_, _) => Show(App.Current.Bridge.Settings().TokenMask);
        field.TextChanged += (_, _) =>
        {
            if (replacing || field.Text.Contains('\u2022'))
            {
                return;
            }
            var value = field.Text.Trim();
            if (value == stored)
            {
                return;
            }
            var result = App.Current.Bridge.Command("setToken", new Dictionary<string, object?> { ["token"] = value });
            if (result.Ok)
            {
                stored = value;
                _tokenError = null;
            }
            else
            {
                _tokenError = result.Error;
            }
        };
        return field;
    }

    // --- Списки геоправил ------------------------------------------------------

    /// <summary>Чёрный и белый списки — одна функция: расходиться им нельзя.</summary>
    private Border GeoCard(string title, IReadOnlyList<string> entries, string list, string hint)
    {
        var rows = new List<UIElement>();
        if (entries.Count == 0)
        {
            rows.Add(Row(Text("Список пуст", "Caption", "Dim")));
        }
        foreach (var entry in entries)
        {
            var value = entry;
            rows.Add(Row(
                Text(entry, "Label"),
                IconButton("\uE74D", "Удалить из списка", () =>
                    Run("removeGeoEntry", new Dictionary<string, object?> { ["entry"] = value, ["list"] = list }))));
        }
        var field = Field("Код страны (RU), IP или CIDR");
        var add = AddButton(field, text => Run(
            "addGeoEntry", new Dictionary<string, object?> { ["text"] = text, ["list"] = list }, list));
        rows.Add(WithoutDividerIf(entries.Count == 0, Row(HintedField(field, hint), add)));
        if (ErrorRow(list) is { } error)
        {
            rows.Add(error);
        }
        return Card(title, rows);
    }

    // --- Внешний вид -----------------------------------------------------------

    /// <summary>«Тема» над сегментами, как на Linux.</summary>
    private Border AppearanceCard(SettingsView settings)
    {
        var stack = new StackPanel { Spacing = Number("Space2"), Padding = new Thickness(0, Number("Space2"), 0, Number("Space2")) };
        stack.Children.Add(Text("Тема", "Label"));
        stack.Children.Add(Segments([("dark", "Тёмная"), ("light", "Светлая")], settings.Theme, theme =>
            Run("setTheme", new Dictionary<string, object?> { ["theme"] = theme })));
        return Card("Внешний вид", [stack]);
    }

    // --- Обслуживание ----------------------------------------------------------

    /// <summary>
    /// Два тумблера одной группой (без линии между ними), отказ автозапуска,
    /// затем «Закрыть приложение» и «Удалить приложение…» — обе деструктивные.
    /// </summary>
    private Border MaintenanceCard(SettingsView settings)
    {
        var autostart = Toggle(settings.Autostart);
        autostart.Toggled += (_, _) =>
            Run("setAutostart", new Dictionary<string, object?> { ["enabled"] = autostart.IsOn }, "autostart");
        _autoInstall = Toggle(App.Current.Bridge.Update().AutoInstall);
        var autoInstall = _autoInstall;
        autoInstall.Toggled += (_, _) =>
        {
            if (!_syncing)
            {
                App.Current.Bridge.Command("setAutoInstall", new Dictionary<string, object?> { ["enabled"] = autoInstall.IsOn });
            }
        };
        var rows = new List<UIElement>
        {
            Row(Text("Запускать при входе в систему", "Label"), autostart),
            WithoutDivider(Row(Text("Обновлять автоматически", "Label"), autoInstall)),
        };
        if (ErrorRow("autostart") is { } error)
        {
            rows.Add(error);
        }
        rows.Add(WithoutDivider(MaintenanceButtons()));
        if (_maintenanceError is { } failure)
        {
            rows.Add(WithoutDivider(Text(failure, "Caption", "Red", wrap: true)));
        }
        return Card("Обслуживание", rows);
    }

    /// <summary>«Закрыть приложение» и «Удалить приложение…» делят ширину поровну.</summary>
    private Grid MaintenanceButtons()
    {
        var buttons = new Grid { ColumnSpacing = Number("Space2"), Margin = new Thickness(0, Number("Space3"), 0, 0) };
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var close = PillButton("Закрыть приложение", ButtonKind.Destructive, () => App.Current.AskToClose());
        close.HorizontalAlignment = HorizontalAlignment.Stretch;
        buttons.Children.Add(close);
        var uninstall = PillButton("Удалить приложение…", ButtonKind.Destructive, () =>
            App.Current.AskToUninstall(error =>
            {
                _maintenanceError = error;
                Rebuild();
            }));
        uninstall.HorizontalAlignment = HorizontalAlignment.Stretch;
        Grid.SetColumn(uninstall, 1);
        buttons.Children.Add(uninstall);
        return buttons;
    }

    /// <summary>Тумблер без подписей «Вкл/Выкл», у правого края строки.</summary>
    private static ToggleSwitch Toggle(bool on) => new()
    {
        IsOn = on,
        OnContent = null,
        OffContent = null,
        // MinWidth шаблона (154) держит место под подписи, которых нет:
        // без сброса тумблер стоял посередине строки, а не у правого края.
        MinWidth = 0,
        HorizontalAlignment = HorizontalAlignment.Right,
    };

    /// <summary>
    /// Такт приложения: число процессов у целей и тумблер автообновления —
    /// без пересборки окна, которая сбросила бы фокус и набранный текст.
    /// </summary>
    public void Tick()
    {
        if (_tab != Tab.Settings || _counts.Count == 0)
        {
            return;
        }
        foreach (var target in App.Current.Bridge.Settings().Targets)
        {
            if (_counts.TryGetValue(target.Entry, out var count))
            {
                var text = target.Running.ToString();
                if (count.Text != text)
                {
                    count.Text = text;
                }
            }
        }
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
        var export = PillButton("Выгрузить журнал", ButtonKind.Muted, () => ExportJournal(journal.ExportFileName));
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

    /// <summary>
    /// Выгрузка — в файл, который выберет пользователь, с именем по умолчанию
    /// из общего кода (<c>JournalExport::file_name</c>), как на Linux.
    /// </summary>
    private void ExportJournal(string fileName)
    {
        var owner = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var path = FileDialogs.Save(owner, "Выгрузка журнала Weto", fileName, ("JSON", "*.json"), "json");
        if (path is null)
        {
            return;
        }
        var result = App.Current.Bridge.Command("exportJournal", new Dictionary<string, object?> { ["path"] = path });
        if (!result.Ok)
        {
            DialogWindow.Tell("Журнал не выгрузился", result.Error ?? "", "OK");
        }
    }

    /// <summary>
    /// Подвал: «github» слева, справа версия и плитка проверки обновлений
    /// (канон, «Окно»). Плитку освежает такт приложения — <see cref="ShowUpdate"/>.
    /// </summary>
    private UIElement Footer()
    {
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Number("Space3") };
        var version = Text($"версия {typeof(App).Assembly.GetName().Version?.ToString(3)}", "Caption", "Faint");
        version.VerticalAlignment = VerticalAlignment.Center;
        right.Children.Add(version);
        _check = TileButton("\uE72C", "Проверить обновления", CheckUpdates);
        right.Children.Add(_check);
        _footer = null;
        var github = new HyperlinkButton
        {
            Content = Text("github", "Caption", "Faint"),
            NavigateUri = new Uri("https://github.com/squaretus/weto"),
            Padding = new Thickness(0),
        };
        ToolTipService.SetToolTip(github, "https://github.com/squaretus/weto");
        return Row(github, right);
    }

    private void CheckUpdates()
    {
        var result = App.Current.Bridge.Command("checkUpdates");
        if (result.Ok && result.Value is { ValueKind: System.Text.Json.JsonValueKind.True })
        {
            App.Current.ShowUpdate();
        }
    }

    /// <summary>
    /// Плитка по исходу проверки, как SettingsFooter на macOS: неактивна, пока
    /// идут проверка или установка; подсказка называет исход; иконка говорит,
    /// что нажатие покажет обновление.
    /// </summary>
    public void ShowUpdate(UpdateView update)
    {
        if (_check is null)
        {
            return;
        }
        _check.IsEnabled = !update.Footer.Busy;
        // Тумблер сверяется с настройкой каждый такт: галочка окна обновления
        // меняет то же значение. Сверка — не нажатие, команды она не шлёт.
        if (_autoInstall is { } auto && auto.IsOn != update.AutoInstall)
        {
            _syncing = true;
            auto.IsOn = update.AutoInstall;
            _syncing = false;
        }
        if (update.Footer == _footer)
        {
            return;
        }
        _footer = update.Footer;
        ToolTipService.SetToolTip(_check, update.Footer.Hint);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_check, update.Footer.Label);
        _check.Content = Glyph(update.Footer.Offers ? "\uE896" : "\uE72C", 14,
            new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.White));
    }

    /// <summary>
    /// «Добавить» при поле: неактивна, пока поле пустое (как на macOS);
    /// Enter в поле — то же, что кнопка.
    /// </summary>
    private static Button AddButton(TextBox field, Action<string> add)
    {
        void Submit()
        {
            if (!string.IsNullOrWhiteSpace(field.Text))
            {
                add(field.Text.Trim());
            }
        }
        var button = PillButton("Добавить", ButtonKind.Primary, Submit);
        button.IsEnabled = !string.IsNullOrWhiteSpace(field.Text);
        field.TextChanged += (_, _) => button.IsEnabled = !string.IsNullOrWhiteSpace(field.Text);
        field.KeyDown += (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Enter)
            {
                Submit();
            }
        };
        return button;
    }

    /// <summary>Название строки и значок пояснения после него с зазором space2.</summary>
    private static StackPanel LabelWithHint(string label, string hint) => new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = Number("Space2"),
        VerticalAlignment = VerticalAlignment.Center,
        Children = { Text(label, "Label"), Hint(hint) },
    };

    /// <summary>Имя над описанием (путь цели), описание выделяется и переносится.</summary>
    private static StackPanel Described(string title, string description)
    {
        var caption = Text(description, "Caption", "Faint", wrap: true);
        caption.IsTextSelectionEnabled = true;
        return new StackPanel
        {
            Spacing = 2,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { Text(title, "Label"), caption },
        };
    }

    private static T WithoutDividerIf<T>(bool condition, T row)
        where T : FrameworkElement => condition ? WithoutDivider(row) : row;
}
