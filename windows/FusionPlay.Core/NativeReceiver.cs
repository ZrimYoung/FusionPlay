using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace FusionPlay.Core;

[StructLayout(LayoutKind.Sequential)]
internal readonly struct NativeBuffer { public readonly IntPtr Data; public readonly nuint Length; }

internal static partial class NativeMethods
{
    [LibraryImport("fusionplay_host", EntryPoint = "fp_abi_version")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial uint AbiVersion();
    [LibraryImport("fusionplay_host", EntryPoint = "fp_invoke")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static unsafe partial NativeBuffer Invoke(ulong handle, byte* request, nuint length);
    [LibraryImport("fusionplay_host", EntryPoint = "fp_buffer_free")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial void Free(NativeBuffer buffer);
}

internal sealed class ReceiverHandle(ulong value) : SafeHandle(new IntPtr(0), true)
{
    public override bool IsInvalid => handle == IntPtr.Zero;
    public ReceiverHandle() : this(0) { }
    public ulong Value { get { ObjectDisposedException.ThrowIf(IsClosed, this); return (ulong)handle; } }
    public void Initialize() => SetHandle((IntPtr)value);
    protected override bool ReleaseHandle()
    {
        try { NativeReceiver.CallRaw((ulong)handle, new { op = "destroy" }); return true; }
        catch { return false; }
    }
}

public sealed class NativeReceiver : IDisposable
{
    private readonly ReceiverHandle handle;
    public ReceiverSettings InitialSettings { get; }
    public NativeReceiver(string dataDirectory)
    {
        if (NativeMethods.AbiVersion() != 1) throw new ReceiverException("abi_mismatch", "接收核心与程序版本不一致，请重新解压完整安装包。");
        var created = Call<CreateResult>(0, new { op = "create", data_directory = Path.GetFullPath(dataDirectory) });
        handle = new ReceiverHandle(created.Handle); handle.Initialize(); InitialSettings = created.Settings;
    }
    internal static unsafe JsonElement CallRaw(ulong receiver, object request)
    {
        byte[] json = JsonSerializer.SerializeToUtf8Bytes(request, WireJson.Options);
        NativeBuffer buffer;
        fixed (byte* bytes = json) buffer = NativeMethods.Invoke(receiver, bytes, (nuint)json.Length);
        try
        {
            if (buffer.Data == IntPtr.Zero || buffer.Length > 16 * 1024 * 1024) throw new ReceiverException("invalid_response", "接收核心返回了无效数据。");
            using var response = JsonDocument.Parse(new ReadOnlySpan<byte>((void*)buffer.Data, checked((int)buffer.Length)).ToArray());
            var root = response.RootElement;
            if (root.GetProperty("abi").GetInt32() != 1) throw new ReceiverException("abi_mismatch", "接收核心接口版本不兼容。");
            if (!root.GetProperty("ok").GetBoolean())
            {
                var error = root.GetProperty("error");
                throw new ReceiverException(error.GetProperty("code").GetString()!, error.GetProperty("message").GetString()!);
            }
            return root.GetProperty("value").Clone();
        }
        finally { NativeMethods.Free(buffer); }
    }
    private static T Call<T>(ulong receiver, object request) => CallRaw(receiver, request).Deserialize<T>(WireJson.Options) ?? throw new ReceiverException("invalid_response", "缺少接收核心返回值。");
    private JsonElement Invoke(object request)
    {
        bool added = false;
        try { handle.DangerousAddRef(ref added); return CallRaw(handle.Value, request); }
        finally { if (added) handle.DangerousRelease(); }
    }
    public static NetworkInterface[] Networks() => Call<NetworkInterface[]>(0, new { op = "networks" });
    public static AudioDevice[] Outputs() => Call<AudioDevice[]>(0, new { op = "outputs" });
    public ReceiverSettings Settings() => Invoke(new { op = "settings" }).Deserialize<ReceiverSettings>(WireJson.Options)!;
    public OutputCalibration Calibration()
    {
        var value = Invoke(new { op = "get_calibration" });
        // Read older ABI-1 responses without silently reversing their direction.
        int offset = value.TryGetProperty("offset_ms", out var signed) ? signed.GetInt32() : -value.GetProperty("advance_ms").GetInt32();
        return new OutputCalibration(value.GetProperty("output_device_id").GetString()!, offset);
    }
    public void SetCalibration(OutputCalibration calibration) => Invoke(new { op = "set_calibration", output_device_id = calibration.OutputDeviceId, offset_ms = calibration.OffsetMs });
    public PollResult Poll(ulong revision = 0) => Invoke(new { op = "poll", revision }).Deserialize<PollResult>(WireJson.Options)!;
    public void Start(ReceiverSettings settings) => Invoke(new { op = "start", settings });
    public void Stop() => Invoke(new { op = "stop" });
    public void SetVolume(uint volume) => Invoke(new { op = "volume", volume });
    public CommandOutcome Control(PlaybackCommand command) => Invoke(new { op = "control", command }).Deserialize<CommandOutcome>(WireJson.Options)!;
    public void Dispose() => handle.Dispose();
}
