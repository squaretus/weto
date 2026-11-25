// Попап статуса у трея — порт попапа менюбара macOS (docs/design-system.md,
// «Попап менюбара»): щит и заголовок, проверить и настройки; три строки
// объяснения, когда охрана что-то сделала с целями; показания гео; живые цели
// пилюлями или строка-совет. Навигации, тумблеров и журнала здесь нет.
//
// Окно без рамки и без кнопки на панели задач, ширина popupWidth, прячется,
// потеряв фокус, — как всплывающее окно у значка. Первый раз стоит над треем
// в правом нижнем углу рабочей области; его можно перетащить за любое место,
// кроме кнопок, — как окно статуса на Linux, — и дальше оно открывается там,
// куда его поставили.
using System;
using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Weto.Bridge;
using static Weto.Ui.Components;

namespace Weto;

public sealed class StatusWindow : Window
{
    private readonly StackPanel _panel;
    private readonly Grid _root;
    private readonly StackPanel _bannerSlot = new() { Visibility = Visibility.Collapsed };
    private StatusView? _shown;
    private BannerView? _shownBanner;
    private Grid? _header;
    private string? _headerKey;

    /// <summary>Куда пользователь перетащил попап; null — над треем.</summary>
    private Windows.Graphics.PointInt32? _chosen;
    private bool _pressed;
    private bool _dragging;
    private CursorPoint _pressCursor;
    private Windows.Graphics.PointInt32 _pressWindow;

    public bool IsOpen { get; private set; }

    public StatusWindow()
    {
        Title = "Weto";
        _panel = Panel();
        _panel.Width = Number("PopupWidth");
        // Сверху, а не на всю высоту: тогда фактическая высота панели — её
        // естественная высота, и окно подгоняется под неё после раскладки.
        _panel.VerticalAlignment = VerticalAlignment.Top;
        // Корень — вся клиентская область. Он нужен, чтобы видеть, сколько места
        // дала система на самом деле: у окна без заголовка ResizeClient считает
        // внешний размер так, будто заголовок есть, и под панелью оставалась
        // полоса его высоты.
        _root = new Grid { Background = Brush("Shell"), RequestedTheme = App.Current.ElementTheme };
        _root.Children.Add(_panel);
        _panel.SizeChanged += (_, _) => FitIfOpen();
        _root.SizeChanged += (_, _) => FitIfOpen();
        // Нажатия на кнопки сюда не доходят — кнопка помечает их обработанными
        // сама, — поэтому тащить можно за любое место, кроме кнопок.
        _root.PointerPressed += OnPointerPressed;
        _root.PointerMoved += OnPointerMoved;
        _root.PointerReleased += (_, _) => EndDrag();
        _root.PointerCaptureLost += (_, _) => EndDrag();
        Content = _root;

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
        Array.Exists(Environment.GetCommandLineArgs(), a => a is "--show-status" or "--show-status-sample" or "--show-update-sample");

    public void Present(StatusView status)
    {
        // Открыт до показа: закрытый попап экран только запоминает, и состояние,
        // сменившееся, пока попап был спрятан, не рисовалось до следующей смены.
        IsOpen = true;
        _shown = null;
        Show(status);
        AppWindow.Show();
        Activate();
        Place();
    }

    /// <summary>
    /// Когда попап спрятался. Щелчок по значку при открытом попапе сперва
    /// отнимает у него фокус и прячет его, а до трея доходит уже после —
    /// и открывал бы попап снова, вместо того чтобы закрыть.
    /// </summary>
    public DateTime DismissedAt { get; private set; }

    public void Dismiss()
    {
        DismissedAt = DateTime.UtcNow;
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
        _root.Background = Brush("Shell");
        _root.RequestedTheme = App.Current.ElementTheme;
        _shownBanner = null;
        _headerKey = null;
        _bannerSlot.Children.Clear();
        _bannerSlot.Visibility = Visibility.Collapsed;
        if (_shown is not null)
        {
            Build(_shown);
        }
    }

    /// <summary>
    /// Баннер обновления — пересобирается только на смену того, что он говорит:
    /// кнопка, пересозданная посреди нажатия, нажатия не получила бы.
    /// </summary>
    public void ShowUpdate(UpdateView update)
    {
        if (update.Banner == _shownBanner && _bannerSlot.Children.Count == (update.Banner is null ? 0 : 1))
        {
            return;
        }
        _shownBanner = update.Banner;
        _bannerSlot.Children.Clear();
        if (update.Banner is { } banner)
        {
            _bannerSlot.Children.Add(Banner(banner, update.Labels.Details, () => App.Current.ShowUpdate()));
        }
        // Пустой слот свёрнут: иначе StackPanel добавил бы ему интервал.
        _bannerSlot.Visibility = update.Banner is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Build(StatusView status)
    {
        _panel.Children.Clear();
        _panel.Children.Add(Header(status));
        Body(status);
    }

    /// <summary>
    /// Шапка живёт, пока не сменились тон, заголовок или проба: на паузе экран
    /// меняется каждую секунду (отсчёт на пилюлях), и кнопки, пересозданные
    /// посреди нажатия, нажатия не получали.
    /// </summary>
    private Grid Header(StatusView status)
    {
        var key = $"{status.Tone}|{status.Title}|{status.Probing}";
        if (_header is not null && key == _headerKey)
        {
            return _header;
        }
        _headerKey = key;
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
        _header = header;
        return header;
    }

    private void Body(StatusView status)
    {
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

        // Баннер — после показаний, перед целями, как в попапе macOS; слот
        // живёт дольше пересборок экрана статуса.
        _panel.Children.Add(_bannerSlot);

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

    private void FitIfOpen()
    {
        if (IsOpen)
        {
            Place();
        }
    }

    /// <summary>
    /// Там, куда попап перетащили, — целиком в рабочей области того экрана:
    /// высота меняется с содержимым, и выросший попап не уходит за край.
    /// Пока не перетаскивали — над треем: правый нижний угол рабочей области,
    /// отступ space4. Высота — по содержимому (<see cref="FitToPanel"/>).
    /// </summary>
    private void Place()
    {
        FitToPanel(AppWindow, _root, _panel);
        if (_dragging)
        {
            return;
        }
        var outer = AppWindow.Size;
        Windows.Graphics.PointInt32 position;
        if (_chosen is { } chosen)
        {
            var area = DisplayArea.GetFromPoint(chosen, DisplayAreaFallback.Nearest).WorkArea;
            position = new Windows.Graphics.PointInt32(
                Math.Clamp(chosen.X, area.X, Math.Max(area.X, area.X + area.Width - outer.Width)),
                Math.Clamp(chosen.Y, area.Y, Math.Max(area.Y, area.Y + area.Height - outer.Height)));
        }
        else
        {
            var scale = _panel.XamlRoot?.RasterizationScale ?? 1.0;
            var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
            var margin = (int)(Number("Space4") * scale);
            position = new Windows.Graphics.PointInt32(
                area.X + area.Width - outer.Width - margin,
                area.Y + area.Height - outer.Height - margin);
        }
        if (AppWindow.Position.X != position.X || AppWindow.Position.Y != position.Y)
        {
            AppWindow.Move(position);
        }
    }

    // --- Перетаскивание ---------------------------------------------------
    //
    // Смещение считается по курсору на экране (GetCursorPos), а не по точке
    // относительно окна: окно едет вместе с курсором, и относительная точка
    // дрожала бы. Координаты курсора и AppWindow — одни и те же физические
    // пиксели экрана. Пока курсор не сдвинулся на порог, это ещё щелчок.

    private void OnPointerPressed(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(_root).Properties.IsLeftButtonPressed || !GetCursorPos(out var cursor))
        {
            return;
        }
        _pressed = true;
        _dragging = false;
        _pressCursor = cursor;
        _pressWindow = AppWindow.Position;
        // Захват — чтобы движение не терялось, когда курсор обгоняет окно.
        _root.CapturePointer(e.Pointer);
    }

    private void OnPointerMoved(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (!_pressed || !GetCursorPos(out var cursor))
        {
            return;
        }
        var dx = cursor.X - _pressCursor.X;
        var dy = cursor.Y - _pressCursor.Y;
        if (!_dragging)
        {
            var threshold = 4 * (_panel.XamlRoot?.RasterizationScale ?? 1.0);
            if (Math.Abs(dx) < threshold && Math.Abs(dy) < threshold)
            {
                return;
            }
            _dragging = true;
        }
        AppWindow.Move(new Windows.Graphics.PointInt32(_pressWindow.X + dx, _pressWindow.Y + dy));
    }

    private void EndDrag()
    {
        if (!_pressed)
        {
            return;
        }
        _pressed = false;
        _root.ReleasePointerCaptures();
        if (_dragging)
        {
            _dragging = false;
            _chosen = AppWindow.Position;
            Place();
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CursorPoint
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out CursorPoint point);
}
