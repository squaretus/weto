// Окно обновления — порт update_window Linux и UpdateDialog macOS.
//
// Что показывать (выбор, ход, отказ) решает модель моста
// (weto_update::dialog::UpdateDialogModel), тексты — weto_update::strings;
// здесь только вёрстка. Крестик — отсрочка на три часа, как на macOS:
// молчаливое закрытие не значит «больше никогда».
using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Weto.Bridge;
using static Weto.Ui.Components;

namespace Weto;

public sealed class UpdateWindow : Window
{
    private readonly Grid _root;
    private readonly StackPanel _panel;
    private UpdateView? _shown;
    private bool _closingByModel;

    public UpdateWindow()
    {
        Title = "Weto";
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Weto.ico"));
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
        }
        _panel = Panel();
        _panel.Width = Number("WindowWidth");
        _panel.VerticalAlignment = VerticalAlignment.Top;
        _root = new Grid { Background = Brush("Shell"), RequestedTheme = App.Current.ElementTheme };
        _root.Children.Add(_panel);
        _panel.SizeChanged += (_, _) => FitToPanel(AppWindow, _root, _panel);
        _root.SizeChanged += (_, _) => FitToPanel(AppWindow, _root, _panel);
        Content = _root;

        Closed += (_, _) =>
        {
            // Закрытие выходом приложения — не «отложить»: мост уже освобождён.
            if (!_closingByModel && !App.Current.Quitting)
            {
                App.Current.Bridge.Command("dismissUpdate");
            }
        };
    }

    /// <summary>Перерисовать по виду моста; находки нет — окно закрывается само.</summary>
    public void Show(UpdateView update)
    {
        if (update.Dialog is null)
        {
            _closingByModel = true;
            Close();
            return;
        }
        if (_shown is not null && Same(update, _shown))
        {
            return;
        }
        _shown = update;
        Title = update.Labels.WindowTitle;
        Build(update, update.Dialog);
        FitToPanel(AppWindow, _root, _panel);
    }

    /// <summary>Смена темы: те же данные, новые кисти.</summary>
    public void Rebuild()
    {
        _root.RequestedTheme = App.Current.ElementTheme;
        if (_shown is { Dialog: { } dialog } shown)
        {
            Build(shown, dialog);
        }
    }

    private void Build(UpdateView update, UpdateDialogView dialog)
    {
        _panel.Children.Clear();
        _panel.Background = Brush("Shell");
        _root.Background = Brush("Shell");

        var header = new Grid { ColumnSpacing = Number("Space4") };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.Children.Add(new Image
        {
            Width = 52,
            Height = 52,
            VerticalAlignment = VerticalAlignment.Top,
            Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(
                new Uri(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Weto.ico"))),
        });

        var column = new StackPanel { Spacing = Number("Space3") };
        column.Children.Add(Text(dialog.Title, "Status", wrap: true));
        column.Children.Add(Text(dialog.Detail, "Value", "Dim", wrap: true));
        if (dialog.ShowsProgress)
        {
            column.Children.Add(new ProgressBar
            {
                IsIndeterminate = dialog.Fraction is null,
                Value = (dialog.Fraction ?? 0) * 100,
                Maximum = 100,
            });
        }
        if (dialog.ShowsChoiceButtons)
        {
            var auto = new CheckBox
            {
                IsChecked = update.AutoInstall,
                Content = Text(update.Labels.AutoInstall, "Value"),
            };
            auto.Click += (_, _) => App.Current.Bridge.Command(
                "setAutoInstall", new Dictionary<string, object?> { ["enabled"] = auto.IsChecked == true });
            column.Children.Add(auto);
        }
        Grid.SetColumn(column, 1);
        header.Children.Add(column);
        _panel.Children.Add(header);

        var buttons = new List<UIElement>();
        if (dialog.ShowsChoiceButtons)
        {
            buttons.AddRange(ChoiceButtons(update.Labels));
        }
        if (dialog.ShowsReleasePageButton && dialog.ReleasePage is { } page)
        {
            buttons.Add(PillButton(update.Labels.OpenReleasePage, ButtonKind.Muted, () =>
                _ = Windows.System.Launcher.LaunchUriAsync(new Uri(page))));
        }
        if (buttons.Count > 0)
        {
            _panel.Children.Add(ButtonRow(buttons));
        }
    }

    /// <summary>
    /// Кнопки одним рядом, как на Linux: свободное место делится поровну —
    /// по распорке на каждый промежуток (канон, «Кнопки»). Одна кнопка — справа.
    /// </summary>
    private static Grid ButtonRow(IReadOnlyList<UIElement> buttons)
    {
        var row = new Grid();
        var column = 0;
        for (var i = 0; i < buttons.Count; i++)
        {
            if (i > 0 || buttons.Count == 1)
            {
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                column++;
            }
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn((FrameworkElement)buttons[i], column);
            row.Children.Add(buttons[i]);
            column++;
        }
        return row;
    }

    /// <summary>«Пропустить версию», «Напомнить позже» (с меню) и «Обновить».</summary>
    private IEnumerable<UIElement> ChoiceButtons(UpdateLabels labels)
    {
        yield return PillButton(labels.Skip, ButtonKind.Muted, () => Answer("skipUpdate"));

        // Кнопка с меню: как приглушённая, плюс стрелка (канон, «Кнопки»).
        var remind = PillButton(labels.RemindLater, ButtonKind.Muted, () => { });
        var caption = (TextBlock)remind.Content;
        remind.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Number("Space2"),
            Children = { caption, Glyph("\uE70D", 10, Brush("Ink")) },
        };
        var menu = new MenuFlyout();
        foreach (var option in labels.Remind)
        {
            var item = new MenuFlyoutItem { Text = option.Title };
            item.Click += (_, _) => Answer("remindLater", new Dictionary<string, object?> { ["interval"] = option.Interval });
            menu.Items.Add(item);
        }
        remind.Flyout = menu;
        yield return remind;

        yield return PillButton(labels.Install, ButtonKind.Primary, () => App.Current.Bridge.Command("installUpdate"));
    }

    /// <summary>Пропуск и отсрочка закрывают окно: находка спрятана, отсрочка уже записана.</summary>
    private void Answer(string command, IReadOnlyDictionary<string, object?>? fields = null)
    {
        App.Current.Bridge.Command(command, fields);
        _closingByModel = true;
        Close();
    }

    /// <summary>Окно говорит то же самое: модель окна и галочка автоустановки.</summary>
    private static bool Same(UpdateView left, UpdateView right) =>
        left.Dialog == right.Dialog && left.AutoInstall == right.AutoInstall;
}
