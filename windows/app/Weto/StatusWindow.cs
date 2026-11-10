// Попап статуса у трея — порт попапа менюбара macOS (docs/design-system.md,
// «Попап менюбара»): щит и заголовок, проверить и настройки; три строки
// объяснения, когда охрана что-то сделала с целями; показания гео; живые цели
// пилюлями или строка-совет. Навигации, тумблеров и журнала здесь нет.
//
// Окно без рамки и без кнопки на панели задач, ширина popupWidth, стоит над
// треем в правом нижнем углу рабочей области и прячется, потеряв фокус, —
// как всплывающее окно у значка.
using System;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Weto.Bridge;
using static Weto.Ui.Components;

namespace Weto;

public sealed class StatusWindow : Window
{
    private readonly StackPanel _panel;
    private StatusView? _shown;

    public bool IsOpen { get; private set; }

    public StatusWindow()
    {
        Title = "Weto";
        _panel = Panel();
        _panel.Width = Number("PopupWidth");
        // Сверху, а не на всю высоту: тогда фактическая высота панели — её
        // естественная высота, и окно подгоняется под неё после раскладки.
        // Заранее посчитанная через Measure высота выходила больше настоящей,
        // и под содержимым оставалась пустая полоса.
        _panel.VerticalAlignment = VerticalAlignment.Top;
        _panel.SizeChanged += (_, _) =>
        {
            if (IsOpen)
            {
                Place();
            }
        };
        Content = _panel;

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false);
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.IsAlwaysOnTop = true;
        }
        AppWindow.IsShownInSwitchers = false;
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated && !KeepOpen)
            {
                Dismiss();
            }
        };
        AppWindow.Closing += (_, args) =>
        {
            // Закрытие попапа — это «спрятать»: окно живёт всё время работы.
            args.Cancel = true;
            Dismiss();
        };
    }

    /// <summary>Не прятать при потере фокуса — для скриншота в CI.</summary>
    public static bool KeepOpen { get; set; } =
        Array.Exists(Environment.GetCommandLineArgs(), a => a is "--show-status" or "--show-status-sample");

    public void Present(StatusView status)
    {
        Show(status);
        IsOpen = true;
        AppWindow.Show();
        Activate();
        Place();
    }

    public void Dismiss()
    {
        IsOpen = false;
        AppWindow.Hide();
    }

    /// <summary>Перерисовать по экрану моста — только когда сказать есть что новое.</summary>
    public void Show(StatusView status)
    {
        if (!IsOpen && _shown is not null)
        {
            _shown = status;
            return;
        }
        if (status == _shown || (_shown is not null && Same(status, _shown)))
        {
            return;
        }
        _shown = status;
        Build(status);
        if (IsOpen)
        {
            Place();
        }
    }

    /// <summary>Смена темы: те же данные, новые кисти.</summary>
    public void Rebuild()
    {
        _panel.Background = Brush("Shell");
        if (_shown is not null)
        {
            Build(_shown);
        }
    }

    private void Build(StatusView status)
    {
        _panel.Children.Clear();

        var header = new Grid { ColumnSpacing = Number("Space3") };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(Shield(status.Tone));
        var title = Text(status.Title, "Status");
        title.Foreground = ToneBrush(status.Tone);
        Grid.SetColumn(title, 1);
        header.Children.Add(title);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (status.Probing)
        {
            actions.Children.Add(new ProgressRing { Width = 16, Height = 16, IsActive = true, Margin = new Thickness(6) });
        }
        else
        {
            actions.Children.Add(IconButton("", "Проверить сейчас", () => App.Current.Bridge.Command("probeNow")));
        }
        actions.Children.Add(IconButton("", "Настройки", () => App.Current.ShowSettings()));
        Grid.SetColumn(actions, 2);
        header.Children.Add(actions);
        _panel.Children.Add(header);

        if (status.Explanation is { } explanation)
        {
            var lines = new StackPanel { Spacing = 2 };
            lines.Children.Add(Text(explanation.Action, "Label", "Ink", wrap: true));
            lines.Children.Add(Text(explanation.Evidence, "Caption", "Dim", wrap: true));
            lines.Children.Add(Text(explanation.Next, "Caption", "Faint", wrap: true));
            _panel.Children.Add(lines);
        }

        var readout = new StackPanel { Spacing = 2 };
        foreach (var line in status.Readout)
        {
            readout.Children.Add(DataRow(line));
        }
        _panel.Children.Add(readout);

        if (status.PermissionFailure is { } failure)
        {
            _panel.Children.Add(Text(failure, "Caption", "Red", wrap: true));
        }

        if (status.Targets is { } targets)
        {
            _panel.Children.Add(Divider());
            if (targets.Pills.Count > 0)
            {
                var pills = new StackPanel { Spacing = Number("Space2") };
                foreach (var pill in targets.Pills)
                {
                    pills.Children.Add(ProcessPill(pill));
                }
                _panel.Children.Add(pills);
            }
            else
            {
                var notice = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Number("Space2") };
                notice.Children.Add(Glyph(targets.NoticeHint is null ? "" : "", 12, ToneBrush(targets.NoticeTone)));
                var text = Text(targets.Notice, "Caption");
                text.Foreground = ToneBrush(targets.NoticeTone);
                notice.Children.Add(text);
                if (targets.NoticeHint is { } hint)
                {
                    notice.Children.Add(Text(hint, "Caption", "Faint"));
                }
                _panel.Children.Add(notice);
            }
        }
    }

    /// <summary>
    /// Экраны равны по содержанию. Записи со списками сравниваются по ссылкам
    /// списков, поэтому сравнение — по сериализованному виду.
    /// </summary>
    private static bool Same(StatusView left, StatusView right) =>
        System.Text.Json.JsonSerializer.Serialize(left, BridgeJson.Default.StatusView)
        == System.Text.Json.JsonSerializer.Serialize(right, BridgeJson.Default.StatusView);

    /// <summary>Первая прикидка до раскладки — дальше окно уточняет SizeChanged.</summary>
    private double MeasuredHeight()
    {
        _panel.Measure(new Windows.Foundation.Size(_panel.Width, double.PositiveInfinity));
        return _panel.DesiredSize.Height;
    }

    /// <summary>
    /// Над треем: правый нижний угол рабочей области экрана с курсором, отступ space4.
    /// Высота — по содержимому: у окна WinUI нет «размера по содержимому».
    /// </summary>
    private void Place()
    {
        var scale = _panel.XamlRoot?.RasterizationScale ?? 1.0;
        var natural = _panel.ActualHeight > 0
            ? _panel.ActualHeight
            : MeasuredHeight();
        var width = (int)Math.Ceiling(_panel.Width * scale);
        var height = (int)Math.Ceiling(natural * scale);
        if (AppWindow.ClientSize.Width == width && AppWindow.ClientSize.Height == height)
        {
            return;
        }
        // Размер — клиентской области: рамка окна в него не входит, и при
        // MoveAndResize по внешнему размеру низ попапа обрезался.
        AppWindow.ResizeClient(new Windows.Graphics.SizeInt32(width, height));
        var outer = AppWindow.Size;
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var margin = (int)(Number("Space4") * scale);
        AppWindow.Move(new Windows.Graphics.PointInt32(
            area.X + area.Width - outer.Width - margin,
            area.Y + area.Height - outer.Height - margin));
    }
}
