// Компоненты дизайн-системы (docs/design-system.md) на WinUI 3.
//
// Порт WetoDesign (macOS) и weto-ui (Linux): те же панель, карточка, строка,
// сегменты, кнопки, поле ввода, щит, пилюля процесса и строка данных. Значения —
// только из токенов (Themes/Tokens.*.xaml, генерируются из design-tokens.json);
// сырых hex и размеров здесь нет. Компоненты не знают о состоянии приложения.
using System;
using System.Collections.Generic;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Weto.Bridge;

namespace Weto.Ui;

public static class Components
{
    public static Brush Brush(string token) => (Brush)Application.Current.Resources["Weto" + token];

    public static double Number(string token) => (double)Application.Current.Resources["Weto" + token];

    public static CornerRadius Radius(string token) => (CornerRadius)Application.Current.Resources["Weto" + token];

    private static Style TextStyle(string role) => (Style)Application.Current.Resources["WetoText" + role];

    /// <summary>Цвет тона: щит, заголовок статуса, строка-совет под ним.</summary>
    public static Brush ToneBrush(Tone tone) => Brush(tone switch
    {
        Tone.Guarded => "Green",
        Tone.Pending => "Amber",
        Tone.Killed => "Red",
        _ => "Faint",
    });

    /// <summary>Текст по роли типографики и токену цвета.</summary>
    public static TextBlock Text(string text, string role, string color = "Ink", bool wrap = false) => new()
    {
        Text = text,
        Style = TextStyle(role),
        Foreground = Brush(color),
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        IsTextSelectionEnabled = role is "Data" or "Diagnostics",
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>Панель: фон shell, паддинг space4.</summary>
    public static StackPanel Panel() => new()
    {
        Background = Brush("Shell"),
        Padding = new Thickness(Number("Space4")),
        Spacing = Number("Space3"),
    };

    /// <summary>Карточка: капс, затем строки, разделённые волосяной линией.</summary>
    public static Border Card(string title, IEnumerable<UIElement> rows)
    {
        var stack = new StackPanel { Spacing = 0 };
        var caps = Text(title.ToUpperInvariant(), "CardCap", "Faint");
        caps.Margin = new Thickness(0, 0, 0, Number("Space3"));
        stack.Children.Add(caps);
        var first = true;
        foreach (var row in rows)
        {
            if (!first && row is not FrameworkElement { Tag: NoDividerTag })
            {
                stack.Children.Add(Divider());
            }
            stack.Children.Add(row);
            first = false;
        }
        return new Border
        {
            Background = Brush("Card"),
            BorderBrush = Brush("Line"),
            BorderThickness = new Thickness(1),
            CornerRadius = Radius("RadiusCard"),
            Padding = new Thickness(Number("Space4")),
            Child = stack,
        };
    }

    private const string NoDividerTag = "weto:no-divider";

    /// <summary>
    /// Строка карточки без линии над ней — исключения канона: поле под пустым
    /// списком, тумблеры «Обслуживания», ряд кнопок журнала.
    /// </summary>
    public static T WithoutDivider<T>(T row)
        where T : FrameworkElement
    {
        row.Tag = NoDividerTag;
        return row;
    }

    public static Border Divider() => new()
    {
        Height = 1,
        Background = Brush("Line"),
    };

    /// <summary>Строка: название слева, управление справа, паддинг space2.</summary>
    public static Grid Row(UIElement left, UIElement? right = null)
    {
        var grid = new Grid
        {
            Padding = new Thickness(0, Number("Space2"), 0, Number("Space2")),
            ColumnSpacing = Number("Space3"),
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(left);
        if (right is not null)
        {
            Grid.SetColumn((FrameworkElement)right, 1);
            grid.Children.Add(right);
        }
        return grid;
    }

    /// <summary>
    /// Ширина колонки подписей у строк с полем и сегментами: поля и сегменты
    /// одной карточки начинаются с одной вертикали (канон, «Окно»). В WinUI нет
    /// общей колонки на несколько сеток, поэтому ширина — по самой длинной
    /// подписи вкладки («Потолок паузы»).
    /// </summary>
    public const double LabelColumn = 120;

    /// <summary>Строка с полем или сегментами: подпись, зазор space5, контрол во всю остальную ширину.</summary>
    public static Grid FieldRow(string label, FrameworkElement control)
    {
        var grid = new Grid
        {
            Padding = new Thickness(0, Number("Space2"), 0, Number("Space2")),
            ColumnSpacing = Number("Space5"),
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(LabelColumn) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(Text(label, "Label"));
        control.HorizontalAlignment = HorizontalAlignment.Stretch;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }

    /// <summary>Название с подписью под ним (путь цели).</summary>
    public static StackPanel Titled(string title, string? caption) => new()
    {
        VerticalAlignment = VerticalAlignment.Center,
        Children =
        {
            Text(title, "Label"),
            caption is null ? new StackPanel() : (UIElement)Text(caption, "Caption", "Faint"),
        },
    };

    /// <summary>Щит статуса: плитка 32×32, радиус 11, белый щит внутри.</summary>
    public static Border Shield(Tone tone) => new()
    {
        Width = 32,
        Height = 32,
        CornerRadius = new CornerRadius(11),
        Background = ToneBrush(tone),
        Child = Glyph("", 16, new SolidColorBrush(Microsoft.UI.Colors.White)),
    };

    /// <summary>Значок из Segoe Fluent Icons.</summary>
    public static FontIcon Glyph(string glyph, double size, Brush brush) => new()
    {
        Glyph = glyph,
        FontSize = size,
        Foreground = brush,
        FontFamily = new FontFamily("Segoe Fluent Icons,Segoe MDL2 Assets"),
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>
    /// Баннер попапа (канон, «Баннер»): фон card, рамка line, радиус radiusTile,
    /// паддинг space3 × space2; тон — только у иконки (violet — новость, amber —
    /// предупреждение), текст caption цветом dim; справа одно действие primary
    /// или индикатор, пока идёт работа.
    /// </summary>
    public static Border Banner(BannerView view, string action, Action onAction)
    {
        var grid = new Grid { ColumnSpacing = Number("Space2") };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Glyph(view.Warning ? "\uE7BA" : "\uE896", 14, Brush(view.Warning ? "Amber" : "Violet")));
        var text = Text(view.Text, "Caption", "Dim", wrap: true);
        text.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        FrameworkElement right = view.InFlight
            ? new ProgressRing { Width = 16, Height = 16, IsActive = true }
            : PillButton(action, ButtonKind.Primary, onAction);
        Grid.SetColumn(right, 2);
        grid.Children.Add(right);
        return new Border
        {
            Background = Brush("Card"),
            BorderBrush = Brush("Line"),
            BorderThickness = new Thickness(1),
            CornerRadius = Radius("RadiusTile"),
            Padding = new Thickness(Number("Space3"), Number("Space2"), Number("Space3"), Number("Space2")),
            Child = grid,
        };
    }

    /// <summary>Плитка-иконка (канон, «Кнопки»): violet, белая иконка, 30×30, радиус radiusTile.</summary>
    public static Button TileButton(string glyph, string tooltip, Action onClick)
    {
        var button = new Button
        {
            Content = Glyph(glyph, 14, new SolidColorBrush(Microsoft.UI.Colors.White)),
            Background = Brush("Violet"),
            BorderThickness = new Thickness(0),
            CornerRadius = Radius("RadiusTile"),
            Width = 30,
            Height = 30,
            Padding = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(button, tooltip);
        button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>
    /// Подогнать окно под естественный размер панели. У WinUI нет «размера
    /// по содержимому», а ResizeClient у окна без заголовка считает внешний
    /// размер так, будто заголовок есть, — поэтому подгонка по факту: внешний
    /// размер правится на разницу между корнем (вся клиентская область) и
    /// панелью. Сходится за шаг; до первой раскладки — прикидка через Measure.
    /// </summary>
    public static void FitToPanel(Microsoft.UI.Windowing.AppWindow window, FrameworkElement root, FrameworkElement panel)
    {
        var scale = panel.XamlRoot?.RasterizationScale ?? 1.0;
        double natural;
        if (panel.ActualHeight > 0)
        {
            natural = panel.ActualHeight;
        }
        else
        {
            panel.Measure(new Windows.Foundation.Size(panel.Width, double.PositiveInfinity));
            natural = panel.DesiredSize.Height;
        }
        if (root.ActualHeight > 0)
        {
            var extraWidth = (int)Math.Round((root.ActualWidth - panel.Width) * scale);
            var extraHeight = (int)Math.Round((root.ActualHeight - natural) * scale);
            if (extraWidth != 0 || extraHeight != 0)
            {
                var size = window.Size;
                window.Resize(new Windows.Graphics.SizeInt32(size.Width - extraWidth, size.Height - extraHeight));
            }
        }
        else
        {
            window.ResizeClient(new Windows.Graphics.SizeInt32(
                (int)Math.Ceiling(panel.Width * scale),
                (int)Math.Ceiling(natural * scale)));
        }
    }

    /// <summary>Иконочная кнопка без фона: шестерёнка, обновить, удалить строку.</summary>
    public static Button IconButton(string glyph, string tooltip, Action onClick)
    {
        var button = new Button
        {
            Content = Glyph(glyph, 14, Brush("Faint")),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(Number("Space2")),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(button, tooltip);
        button.Click += (_, _) => onClick();
        return button;
    }

    public enum ButtonKind
    {
        Primary,
        Muted,
        Destructive,
    }

    /// <summary>Кнопка-пилюля: высота controlHeight, радиус radiusPill, 13 semibold.</summary>
    public static Button PillButton(string title, ButtonKind kind, Action onClick)
    {
        Brush white = new SolidColorBrush(Microsoft.UI.Colors.White);
        (Brush background, Brush foreground, Brush? border) = kind switch
        {
            ButtonKind.Primary => (Brush("Violet"), white, (Brush?)null),
            ButtonKind.Destructive => (RedWash(), Brush("Red"), (Brush?)null),
            _ => (Brush("Sunk"), Brush("Ink"), (Brush?)Brush("Line")),
        };
        var button = new Button
        {
            Content = new TextBlock { Text = title, Style = TextStyle("Button"), Foreground = foreground },
            Background = background,
            BorderBrush = border,
            BorderThickness = new Thickness(border is null ? 0 : 1),
            CornerRadius = Radius("RadiusPill"),
            Height = Number("ControlHeight"),
            Padding = new Thickness(15, 0, 15, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>Заливка деструктивной кнопки — red 16 %.</summary>
    private static Brush RedWash()
    {
        var red = (Windows.UI.Color)Application.Current.Resources["WetoRedColor"];
        return new SolidColorBrush(Windows.UI.Color.FromArgb(41, red.R, red.G, red.B));
    }

    /// <summary>Поле ввода: фон sunk, высота controlHeight, подсказка — формат ввода.</summary>
    public static TextBox Field(string placeholder, bool password = false) => new()
    {
        PlaceholderText = placeholder,
        Background = Brush("Sunk"),
        BorderBrush = Brush("SunkLine"),
        BorderThickness = new Thickness(1),
        CornerRadius = Radius("RadiusPill"),
        MinHeight = Number("ControlHeight"),
        Padding = new Thickness(11, 6, 11, 6),
        FontSize = 13,
        Foreground = Brush("Ink"),
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>Сегменты: дорожка sunk, активный — violet с белым текстом, ширина поровну.</summary>
    public static Border Segments<T>(IReadOnlyList<(T Value, string Title)> items, T selected, Action<T> onSelect)
    {
        var grid = new Grid { ColumnSpacing = Number("Space1") };
        for (var i = 0; i < items.Count; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var (value, title) = items[i];
            var active = EqualityComparer<T>.Default.Equals(value, selected);
            var segment = new Button
            {
                Content = new TextBlock
                {
                    Text = title,
                    Style = TextStyle("Segment"),
                    Foreground = active ? new SolidColorBrush(Microsoft.UI.Colors.White) : Brush("Dim"),
                },
                Background = active ? Brush("Violet") : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
                CornerRadius = Radius("RadiusTile"),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(0, 5, 0, 5),
            };
            segment.Click += (_, _) => onSelect(value);
            Grid.SetColumn(segment, i);
            grid.Children.Add(segment);
        }
        return new Border
        {
            Background = Brush("Sunk"),
            BorderBrush = Brush("SunkLine"),
            BorderThickness = new Thickness(1),
            CornerRadius = Radius("RadiusControl"),
            Padding = new Thickness(Number("Space1")),
            Child = grid,
        };
    }

    /// <summary>Строка данных: ключ faint, значение dim, цифры табличные.</summary>
    public static StackPanel DataRow(Line line) => new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = 4,
        Children =
        {
            Text(line.Key + ":", "Data", "Faint"),
            Text(line.Value, "Data", "Dim"),
        },
    };

    /// <summary>Значок паузы: капсула amber 16 % с отсчётом до потолка.</summary>
    public static Border PauseBadge(string countdown)
    {
        var amber = (Windows.UI.Color)Application.Current.Resources["WetoAmberColor"];
        return new Border
        {
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(41, amber.R, amber.G, amber.B)),
            CornerRadius = new CornerRadius(100),
            Padding = new Thickness(Number("Space2"), Number("BadgeInset"), Number("Space2"), Number("BadgeInset")),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 4,
                Children =
                {
                    Glyph("", 10, Brush("Amber")),
                    Text(countdown, "Data", "Amber"),
                },
            },
        };
    }

    /// <summary>Пилюля процесса: иконка 32, имя, «terminal», значок паузы, +N.</summary>
    public static Border ProcessPill(Pill pill)
    {
        var grid = new Grid { ColumnSpacing = Number("Space3") };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var icon = new Border
        {
            Width = 32,
            Height = 32,
            CornerRadius = new CornerRadius(8),
            Background = Brush("Card"),
            Child = Glyph("", 16, Brush("Dim")), // CommandPrompt
        };
        grid.Children.Add(icon);

        var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Number("Space2") };
        name.Children.Add(Text(pill.Name, "Label"));
        if (pill.CommandLine)
        {
            name.Children.Add(Text("terminal", "Caption", "Faint"));
        }
        Grid.SetColumn(name, 1);
        grid.Children.Add(name);

        var accessory = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Number("Space2") };
        if (pill.Countdown is not null)
        {
            accessory.Children.Add(PauseBadge(pill.Countdown));
        }
        if (pill.Extra > 0)
        {
            accessory.Children.Add(Text($"+{pill.Extra}", "Data", "Faint"));
        }
        Grid.SetColumn(accessory, 2);
        grid.Children.Add(accessory);

        return new Border
        {
            Background = Brush("Sunk"),
            BorderBrush = Brush("SunkLine"),
            BorderThickness = new Thickness(1),
            CornerRadius = Radius("RadiusCard"),
            Padding = new Thickness(6, 6, 12, 6),
            Child = grid,
        };
    }
}
