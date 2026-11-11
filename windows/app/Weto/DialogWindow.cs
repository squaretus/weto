// Диалог с двумя исходами — подтверждение удаления и «эти программы ещё
// стоят». Своё окно, а не ContentDialog: при удалении через деинсталлятор
// (Weto.exe --uninstall) других окон у процесса нет, и диалогу не к чему
// крепиться. Тексты и обе кнопки приходят из моста — общие с macOS и Linux.
using System;
using System.Collections.Generic;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Weto.Bridge;
using static Weto.Ui.Components;

namespace Weto;

public sealed class DialogWindow : Window
{
    private readonly Grid _root;
    private readonly StackPanel _panel;
    private readonly DialogView _text;
    private readonly bool _destructive;
    private Action<bool>? _answer;

    /// <summary>Открытые диалоги — чтобы смена темы перекрасила и их.</summary>
    private static readonly List<DialogWindow> Open = [];

    /// <summary>Смена темы: открытые диалоги перестраиваются с новыми кистями.</summary>
    public static void RebuildOpen()
    {
        foreach (var dialog in Open)
        {
            dialog.Build();
        }
    }

    /// <summary>
    /// Спросить: <paramref name="answer"/> получает true на «подтвердить»,
    /// false — на «отмену» и на закрытие окна крестиком.
    /// </summary>
    public static void Ask(DialogView text, bool destructive, Action<bool> answer)
    {
        var window = new DialogWindow(text, destructive, answer);
        window.Activate();
    }

    /// <summary>Сообщить с одной кнопкой — отказ, о котором надо сказать («Журнал не выгрузился»).</summary>
    public static void Tell(string title, string message, string button) =>
        Ask(new DialogView(title, message, button, ""), destructive: false, _ => { });

    private DialogWindow(DialogView text, bool destructive, Action<bool> answer)
    {
        _answer = answer;
        _text = text;
        _destructive = destructive;
        Title = text.Title;
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Weto.ico"));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.IsAlwaysOnTop = true;
        }

        _panel = Panel();
        _panel.Width = Number("PopupWidth");
        _panel.VerticalAlignment = VerticalAlignment.Top;
        _root = new Grid();
        _root.Children.Add(_panel);
        Build();
        _panel.SizeChanged += (_, _) => FitToPanel(AppWindow, _root, _panel);
        _root.SizeChanged += (_, _) => FitToPanel(AppWindow, _root, _panel);
        Content = _root;
        FitToPanel(AppWindow, _root, _panel);
        Center();

        // Esc — тот же ответ, что крестик: «отмена», а у сообщения — единственная кнопка.
        var escape = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.Escape };
        escape.Invoked += (_, args) =>
        {
            args.Handled = true;
            Finish(text.Cancel.Length == 0);
        };
        _root.KeyboardAccelerators.Add(escape);

        Open.Add(this);
        // Окно уже закрывается: ответ без повторного Close().
        Closed += (_, _) =>
        {
            Open.Remove(this);
            Finish(false, closing: true);
        };
    }

    /// <summary>Содержимое по текстам моста — при открытии и при смене темы.</summary>
    private void Build()
    {
        var text = _text;
        var destructive = _destructive;
        _panel.Children.Clear();
        _root.Background = Brush("Shell");
        _root.RequestedTheme = App.Current.ElementTheme;
        _panel.Children.Add(Text(text.Title, "Status", wrap: true));
        _panel.Children.Add(Text(text.Message, "Value", "Dim", wrap: true));

        // Без «отмены» кнопка одна: сообщение, а не вопрос.
        var buttons = new Grid { ColumnSpacing = Number("Space2") };
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var column = 0;
        if (text.Cancel.Length > 0)
        {
            buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var cancel = PillButton(text.Cancel, ButtonKind.Muted, () => Finish(false));
            cancel.HorizontalAlignment = HorizontalAlignment.Stretch;
            buttons.Children.Add(cancel);
            column = 1;
        }
        var confirm = PillButton(text.Confirm, destructive ? ButtonKind.Destructive : ButtonKind.Primary, () => Finish(true));
        confirm.HorizontalAlignment = HorizontalAlignment.Stretch;
        Grid.SetColumn(confirm, column);
        buttons.Children.Add(confirm);
        _panel.Children.Add(buttons);
    }

    private void Center()
    {
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var size = AppWindow.Size;
        AppWindow.Move(new Windows.Graphics.PointInt32(
            area.X + (area.Width - size.Width) / 2,
            area.Y + (area.Height - size.Height) / 3));
    }

    /// <summary>Ответ отдаётся ровно один раз: кнопка закрывает окно, а закрытие — тоже ответ.</summary>
    private void Finish(bool confirmed, bool closing = false)
    {
        var answer = _answer;
        _answer = null;
        if (answer is null)
        {
            return;
        }
        if (!closing)
        {
            Close();
        }
        answer(confirmed);
    }
}
