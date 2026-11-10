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
[JsonSerializable(typeof(CommandResult))]
[JsonSerializable(typeof(Notification))]
[JsonSerializable(typeof(Dictionary<string, object?>))]
// Значения полей команд приходят как object: их типы обязаны быть известны
// генератору заранее, иначе сериализация упадёт на первой же команде.
[JsonSerializable(typeof(string))]
[JsonSerializable(typeof(bool))]
[JsonSerializable(typeof(ulong))]
internal sealed partial class BridgeJson : JsonSerializerContext;
