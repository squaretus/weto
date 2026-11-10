// Модели экранов, как их отдаёт мост (weto-ffi/src/view.rs). Ни одного текста
// о состоянии здесь нет и быть не должно: слова и решения приходят из Rust,
// общего с Linux и macOS, а интерфейс только рисует.
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Weto.Bridge;

/// <summary>Тон щита: те же имена, что у классов CSS на Linux.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<Tone>))]
public enum Tone
{
    [JsonStringEnumMemberName("guarded")] Guarded,
    [JsonStringEnumMemberName("pending")] Pending,
    [JsonStringEnumMemberName("killed")] Killed,
    [JsonStringEnumMemberName("disabled")] Disabled,
}

public sealed record StatusView(
    string Title,
    Tone Tone,
    Explanation? Explanation,
    bool Probing,
    IReadOnlyList<Line> Readout,
    string? PermissionFailure,
    TargetsView? Targets);

public sealed record Explanation(string Action, string Evidence, string Next);

public sealed record Line(string Key, string Value);

public sealed record TargetsView(
    IReadOnlyList<Pill> Pills,
    string Notice,
    string? NoticeHint,
    Tone NoticeTone);

public sealed record Pill(
    int Pid,
    string Name,
    string Entry,
    int Extra,
    string? Countdown,
    bool CommandLine);

public sealed record SettingsView(
    IReadOnlyList<TargetRow> Targets,
    TargetRow? VpnApp,
    IReadOnlyList<string> Blocked,
    IReadOnlyList<string> Allowed,
    ulong PauseCeiling,
    IReadOnlyList<Choice> PauseCeilings,
    string Theme,
    bool TokenSet,
    bool Autostart);

public sealed record TargetRow(string Entry, string DisplayName, string Description, bool CommandLine);

public sealed record Choice(ulong Seconds, string Title);

public sealed record JournalView(IReadOnlyList<JournalRow> Rows, string? LimitCaption);

public sealed record JournalRow(string Title, string Summary, string? Resolution, string Diagnostics);

/// <summary>Обновление: баннер, окно, плитка подвала (weto-ffi/src/update.rs).</summary>
public sealed record UpdateView(
    BannerView? Banner,
    UpdateDialogView? Dialog,
    bool WindowRequested,
    bool AutoInstall,
    FooterView Footer,
    bool Installed,
    UpdateLabels Labels);

public sealed record BannerView(string Text, bool Warning, bool InFlight);

public sealed record UpdateDialogView(
    string Title,
    string Detail,
    double? Fraction,
    bool ShowsProgress,
    bool ShowsChoiceButtons,
    bool ShowsReleasePageButton,
    string? ReleasePage);

public sealed record FooterView(bool Offers, string Hint, bool Busy, string Label);

public sealed record UpdateLabels(
    string WindowTitle,
    string Details,
    string Skip,
    string RemindLater,
    string Install,
    string OpenReleasePage,
    string AutoInstall,
    IReadOnlyList<RemindOption> Remind);

/// <summary>Пункт «Напомнить позже»: имя интервала для команды и подпись.</summary>
public sealed record RemindOption(string Interval, string Title);

/// <summary>Текст диалога: тексты общие с macOS и Linux (weto_core::presentation).</summary>
public sealed record DialogView(string Title, string Message, string Confirm, string Cancel);

/// <summary>Итог проверки перед сносом: <c>Dialog</c> — null, когда стоящих нет.</summary>
public sealed record UninstallCheck(int Standing, DialogView? Dialog);

/// <summary>Ответ на команду: исполнена или отказ с текстом для пользователя.</summary>
public sealed record CommandResult(bool Ok, JsonElement? Value, string? Error);

/// <summary>Уведомление охраны: заголовок и тело, тексты из ядра.</summary>
public sealed record Notification(string Title, string Body);

/// <summary>
/// Сериализация без отражения — так её не вырежет обрезка сборки.
/// Имена в JSON — camelCase, как пишет мост.
/// </summary>
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(StatusView))]
[JsonSerializable(typeof(SettingsView))]
[JsonSerializable(typeof(JournalView))]
[JsonSerializable(typeof(UpdateView))]
[JsonSerializable(typeof(DialogView))]
[JsonSerializable(typeof(UninstallCheck))]
[JsonSerializable(typeof(CommandResult))]
[JsonSerializable(typeof(Notification))]
[JsonSerializable(typeof(Dictionary<string, object?>))]
// Значения полей команд приходят как object: их типы обязаны быть известны
// генератору заранее, иначе сериализация упадёт на первой же команде.
[JsonSerializable(typeof(string))]
[JsonSerializable(typeof(bool))]
[JsonSerializable(typeof(ulong))]
internal sealed partial class BridgeJson : JsonSerializerContext;
