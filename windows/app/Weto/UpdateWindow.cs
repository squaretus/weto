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
        _root = new Grid { Background = Brush("Shell") };
        _root.Children.Add(_panel);
        _panel.SizeChanged += (_, _) => FitToPanel(AppWindow, _root, _panel);
        _root.SizeChanged += (_, _) => FitToPanel(AppWindow, _root, _panel);
        Content = _root;

        Closed += (_, _) =>
        {
            if (!_closingByModel)
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

        if (dialog.ShowsChoiceButtons)
        {
            _panel.Children.Add(ChoiceRow(update.Labels));
        }
        if (dialog.ShowsReleasePageButton && dialog.ReleasePage is { } page)
        {
            var release = PillButton(update.Labels.OpenReleasePage, ButtonKind.Muted, () =>
                _ = Windows.System.Launcher.LaunchUriAsync(new Uri(page)));
            release.HorizontalAlignment = HorizontalAlignment.Right;
            _panel.Children.Add(release);
        }
    }

    /// <summary>
    /// «Пропустить версию», «Напомнить позже» (с меню) и «Обновить» во всю ширину:
    /// свободное место делится поровну — по распорке на каждый промежуток (канон, «Кнопки»).
    /// </summary>
    private UIElement ChoiceRow(UpdateLabels labels)
    {
        var row = new Grid();
        foreach (var width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto,
                     new GridLength(1, GridUnitType.Star), GridLength.Auto })
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        }

        var skip = PillButton(labels.Skip, ButtonKind.Muted, () => Answer("skipUpdate"));
        row.Children.Add(skip);

        var remind = PillButton(labels.RemindLater + "  ", ButtonKind.Muted, () => { });
        var menu = new MenuFlyout();
        foreach (var option in labels.Remind)
        {
            var item = new MenuFlyoutItem { Text = option.Title };
            item.Click += (_, _) => Answer("remindLater", new Dictionary<string, object?> { ["interval"] = option.Interval });
            menu.Items.Add(item);
        }
        remind.Flyout = menu;
        Grid.SetColumn(remind, 2);
        row.Children.Add(remind);

        var install = PillButton(labels.Install, ButtonKind.Primary, () => App.Current.Bridge.Command("installUpdate"));
        Grid.SetColumn(install, 4);
        row.Children.Add(install);
        return row;
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
