using System.Text.Json;
using System.Text.Json.Serialization;

namespace FusionPlay.Core;

public sealed record ReceiverSettings(string Name = "FusionPlay-Windows", string InterfaceName = "", string OutputDevice = "", uint Volume = 50);
public enum ReceiverPhase { Stopped, Starting, Ready, Connected, Playing, Paused, Failed }
public enum PlaybackCommand { Play, Pause, Previous, Next }
public sealed record CommandOutcome(bool Dispatched, bool Confirmed);
public sealed record OutputCalibration(string OutputDeviceId, uint AdvanceMs);
public sealed record NetworkInterface(string Name, string Address)
{
    public string DisplayName => string.IsNullOrEmpty(Name) ? "自动选择局域网" : $"{Name} · {Address}";
}
public sealed record AudioDevice(string Id, string Name, bool IsDefault)
{
    public string DisplayName => Name + (IsDefault && Id.Length > 0 ? "（系统默认）" : "");
}
public sealed record ReceiverSnapshot
{
    public ReceiverPhase Phase { get; init; }
    public string Title { get; init; } = "";
    public string Artist { get; init; } = "";
    public string Album { get; init; } = "";
    public string TrackId { get; init; } = "";
    public string ArtworkUrl { get; init; } = "";
    public ulong? DurationMs { get; init; }
    public ulong? PositionMs { get; init; }
    public bool ControlsAvailable { get; init; }
    public uint Volume { get; init; } = 50;
    public string Message { get; init; } = "接收器未启动";
    public string Address { get; init; } = "";
    public string Output { get; init; } = "";
    public double QueueMs { get; init; }
    public double OutputLatencyMs { get; init; }
    public double ScheduleErrorMs { get; init; }
    public ulong Underruns { get; init; }
    public ulong DroppedFrames { get; init; }
    public ulong Resyncs { get; init; }
    public bool HasMedia => ControlsAvailable && Phase is ReceiverPhase.Playing or ReceiverPhase.Paused or ReceiverPhase.Connected;
    public string PhaseLabel => Phase switch
    {
        ReceiverPhase.Starting => "正在启动", ReceiverPhase.Ready => "等待连接", ReceiverPhase.Connected => "已连接",
        ReceiverPhase.Playing => "正在播放", ReceiverPhase.Paused => "已暂停", ReceiverPhase.Failed => "需要处理", _ => "未启动"
    };
}
public sealed record PollResult(ulong Revision, ReceiverSnapshot? Snapshot);
internal sealed record CreateResult(ulong Handle, ReceiverSettings Settings);
public static class WireJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() }
    };
}

public sealed class ReceiverException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}
