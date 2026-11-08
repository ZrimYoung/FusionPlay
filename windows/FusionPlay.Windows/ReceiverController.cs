using FusionPlay.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Diagnostics;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace FusionPlay.Windows;

public sealed class ReceiverController : IAsyncDisposable
{
    private readonly DispatcherQueue ui;
    private readonly SemaphoreSlim operations = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private NativeReceiver? native;
    private ulong revision;
    private long generation;
    private Task? polling;
    private CancellationTokenSource? artworkCancellation;
    private CancellationTokenSource? volumeDebounce;
    private bool volumeGesture;
    private string artworkKey = "";
    private string deviceSignature = "";
    private bool sleeping;
    private int retryCount;
    private bool disposed;
    private readonly VolumeInteraction volume = new();
    public PortableStore Store { get; } = new(AppContext.BaseDirectory);
    public ReceiverSettings Settings { get; private set; } = new();
    public ReceiverSnapshot State { get; private set; } = new();
    public NetworkInterface[] Networks { get; private set; } = [];
    public AudioDevice[] Outputs { get; private set; } = [];
    public bool Initialized { get; private set; }
    public bool Busy { get; private set; }
    public bool ControlBusy { get; private set; }
    public bool CalibrationBusy { get; private set; }
    public bool WantsReceiving { get; private set; }
    public bool MigrationRequired { get; private set; }
    public string Error { get; private set; } = "";
    public string ControlMessage { get; private set; } = "";
    public string ArtworkStatus { get; private set; } = "尚未连接";
    public BitmapImage? Artwork { get; private set; }
    public byte[]? ArtworkBytes { get; private set; }
    public double Volume => volume.Value;
    public bool CanControl => State.ControlsAvailable && !Busy && !ControlBusy;
    public event Action? Changed;
    public event Action? DevicesChanged;
    public ReceiverController(DispatcherQueue dispatcher) => ui = dispatcher;
    private void Notify() => Changed?.Invoke();
    private Task OnUi(Action action)
    {
        if (ui.HasThreadAccess) { action(); return Task.CompletedTask; }
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!ui.TryEnqueue(() => { try { action(); completion.SetResult(); } catch (Exception e) { completion.SetException(e); } }))
            completion.TrySetCanceled();
        return completion.Task;
    }
    private async Task<T> Background<T>(Func<T> action)
    {
        await operations.WaitAsync(lifetime.Token);
        try { return await Task.Run(action, lifetime.Token); }
        finally { operations.Release(); }
    }
    public async Task InitializeAsync()
    {
        Busy = true; Error = ""; Notify();
        try
        {
            var restored = await Background(() =>
            {
                Store.Initialize();
                native = new NativeReceiver(Store.Data);
                return (native.InitialSettings, NativeReceiver.Networks(), NativeReceiver.Outputs());
            });
            Settings = restored.InitialSettings; Networks = restored.Item2; Outputs = restored.Item3;
            volume.Observe(Settings.Volume); Initialized = true; MigrationRequired = false;
            Busy = false; DevicesChanged?.Invoke(); Notify();
            polling = PollAsync(lifetime.Token);
            await StartAsync(Settings);
        }
        catch (IdentityMigrationRequiredException e) { MigrationRequired = true; Error = e.Message; Busy = false; Notify(); }
        catch (Exception e) { Error = Friendly(e); Busy = false; Store.EventDiagnostic("initialization_failed"); Notify(); }
    }
    public async Task MigrateAsync()
    {
        try { await Task.Run(Store.MigrateIdentity); await InitializeAsync(); }
        catch (Exception e) { Error = Friendly(e); Notify(); }
    }
    public Task StartAsync(ReceiverSettings? settings = null, bool recovery = false)
    {
        if (!Initialized || disposed) return Task.CompletedTask;
        Settings = (settings ?? Settings) with { Volume = (uint)Math.Round(volume.Value) };
        WantsReceiving = true;
        if (!recovery) retryCount = 0;
        return ApplyLifecycleAsync();
    }
    public Task StopAsync()
    {
        WantsReceiving = false; retryCount = 0;
        return ApplyLifecycleAsync();
    }
    private async Task ApplyLifecycleAsync()
    {
        long request = Interlocked.Increment(ref generation);
        bool start = WantsReceiving && !sleeping;
        var settings = Settings;
        Busy = true; Error = ""; ControlMessage = ""; Notify();
        try
        {
            var result = await Background(() =>
            {
                if (request != Interlocked.Read(ref generation) || native == null) return (ReceiverSnapshot?)null;
                if (start) native.Start(settings); else native.Stop();
                return native.Poll().Snapshot;
            });
            if (request != Interlocked.Read(ref generation) || disposed) return;
            if (result != null) Accept(result);
            deviceSignature = Signature(); Busy = false; Notify();
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            if (request != Interlocked.Read(ref generation) || disposed) return;
            Error = Friendly(e); Busy = false; Store.EventDiagnostic("lifecycle_failed"); Notify();
        }
    }
    private async Task PollAsync(CancellationToken cancellation)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(250));
        int ticks = 0;
        try
        {
            while (await timer.WaitForNextTickAsync(cancellation))
            {
                bool devices = ++ticks % 12 == 0;
                var observedGeneration = Interlocked.Read(ref generation);
                try
                {
                    var result = await Background(() => (native!.Poll(revision),
                        devices ? NativeReceiver.Networks() : null, devices ? NativeReceiver.Outputs() : null));
                    await OnUi(() =>
                    {
                        if (disposed || observedGeneration != Interlocked.Read(ref generation)) return;
                        revision = result.Item1.Revision;
                        if (result.Item1.Snapshot != null) Accept(result.Item1.Snapshot);
                        if (!devices) return;
                        bool changed = !Networks.SequenceEqual(result.Item2!) || !Outputs.SequenceEqual(result.Item3!);
                        Networks = result.Item2!; Outputs = result.Item3!;
                        if (changed) DevicesChanged?.Invoke();
                        if (Busy || sleeping || !WantsReceiving) return;
                        string signature = Signature();
                        bool routeChanged = signature != deviceSignature;
                        if (routeChanged) { deviceSignature = signature; retryCount = 0; }
                        if (routeChanged || (State.Phase == ReceiverPhase.Failed && retryCount < 3))
                        {
                            retryCount++;
                            _ = StartAsync(recovery: true);
                        }
                    });
                }
                catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { break; }
                catch (Exception e)
                {
                    string detail = e is System.Text.Json.JsonException json ? "json:" + json.Path : e.GetType().Name + ":" + e.HResult.ToString("X8") + ":" + e.TargetSite?.Name;
                    Store.EventDiagnostic("poll_failed:" + detail);
                    await OnUi(() => { if (!disposed) { Error = "无法读取接收器状态，请停止后重新启动接收。"; Notify(); } });
                }
            }
        }
        catch (OperationCanceledException) { }
    }
    private string Signature()
    {
        var network = Networks.FirstOrDefault(n => Settings.InterfaceName == "" || n.Name == Settings.InterfaceName);
        var output = Outputs.FirstOrDefault(n => Settings.OutputDevice == "" ? n.IsDefault : n.Id == Settings.OutputDevice);
        return $"{network?.Name}/{network?.Address}/{output?.Id}";
    }
    private void Accept(ReceiverSnapshot snapshot)
    {
        State = snapshot; volume.Observe(snapshot.Volume);
        if (!snapshot.ControlsAvailable) ControlMessage = "";
        UpdateArtwork(snapshot); Notify();
    }
    public Task TogglePlaybackAsync() => ControlAsync(State.Phase == ReceiverPhase.Playing ? PlaybackCommand.Pause : PlaybackCommand.Play);
    public void DispatchControl(PlaybackCommand command) => ui.TryEnqueue(() => _ = ControlAsync(command));
    public async Task ControlAsync(PlaybackCommand command)
    {
        if (!CanControl || disposed) return;
        ControlBusy = true; ControlMessage = "正在发送到手机…"; Notify();
        long request = Interlocked.Read(ref generation);
        try
        {
            var outcome = await Background(() => native!.Control(command));
            if (request != Interlocked.Read(ref generation) || disposed) return;
            ControlMessage = outcome.Confirmed ? "手机已确认" : "指令已发送，手机尚未确认";
        }
        catch (Exception e) { if (!disposed) ControlMessage = "播放控制失败：" + Friendly(e); }
        finally { ControlBusy = false; if (!disposed) Notify(); }
    }
    public void BeginVolume() { volumeGesture = true; volume.BeginEditing(); }
    public void EditVolume(double value)
    {
        volume.BeginEditing(); volume.Edit(value); Notify();
        volumeDebounce?.Cancel(); volumeDebounce?.Dispose();
        volumeDebounce = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        _ = DebounceVolumeAsync(volumeDebounce.Token);
    }
    private async Task DebounceVolumeAsync(CancellationToken cancellation)
    {
        try { await Task.Delay(300, cancellation); if (!volumeGesture) await CommitVolumeAsync(); }
        catch (OperationCanceledException) { }
    }
    public async Task CommitVolumeAsync()
    {
        if (disposed) return;
        volumeGesture = false; volumeDebounce?.Cancel();
        if (!Initialized || disposed || !volume.IsEditing) return;
        var submission = volume.Submit(); Notify();
        try
        {
            await Background(() => { native!.SetVolume(submission.Value); return true; });
            if (!volume.Complete(submission.Token, true)) return;
            Settings = Settings with { Volume = submission.Value }; Notify();
            await Task.Delay(2000, lifetime.Token);
            volume.Expire(submission.Token); Notify();
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { volume.Complete(submission.Token, false); Error = Friendly(e); Notify(); }
    }
    public void Suspend() { sleeping = true; if (Initialized) _ = ApplyLifecycleAsync(); }
    public void Resume() { sleeping = false; retryCount = 0; if (Initialized && WantsReceiving) _ = ApplyLifecycleAsync(); }
    public void ReloadArtwork() { artworkKey = "\0"; UpdateArtwork(State); }
    public Task<OutputCalibration> GetCalibrationAsync() => Background(() => native!.Calibration());
    public async Task ApplyCalibrationAsync(OutputCalibration calibration)
    {
        if (!Initialized || disposed || Busy || CalibrationBusy) return;
        CalibrationBusy = true; Error = ""; Notify();
        try
        {
            await Background(() => { native!.SetCalibration(calibration); return true; });
        }
        catch (OperationCanceledException) when (disposed) { }
        catch (Exception e) { Error = Friendly(e); }
        finally { CalibrationBusy = false; if (!disposed) Notify(); }
    }
    private void UpdateArtwork(ReceiverSnapshot snapshot)
    {
        string key = snapshot.ControlsAvailable ? snapshot.TrackId + "|" + snapshot.ArtworkUrl : "";
        if (key == artworkKey) return;
        artworkKey = key; artworkCancellation?.Cancel(); artworkCancellation?.Dispose();
        Artwork = null; ArtworkBytes = null;
        if (key == "") { ArtworkStatus = "尚未连接"; return; }
        if (snapshot.ArtworkUrl.Length == 0) { ArtworkStatus = "手机未提供封面"; return; }
        artworkCancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        _ = LoadArtworkAsync(key, snapshot.ArtworkUrl, artworkCancellation.Token);
    }
    private async Task LoadArtworkAsync(string key, string source, CancellationToken cancellation)
    {
        string kind;
        try { kind = ArtworkLoader.Kind(source); } catch (ArtworkException) { kind = "unsupported"; }
        ArtworkStatus = "正在加载封面";
        for (int attempt = 1; attempt <= 3; attempt++)
        {
            try
            {
                byte[] bytes = await Task.Run(() => ArtworkLoader.LoadAsync(source, cancellation), cancellation);
                cancellation.ThrowIfCancellationRequested();
                using var stream = new InMemoryRandomAccessStream();
                using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(bytes); await writer.StoreAsync(); }
                stream.Seek(0);
                var decoder = await BitmapDecoder.CreateAsync(stream);
                if ((ulong)decoder.PixelWidth * decoder.PixelHeight > 40_000_000 || decoder.PixelWidth == 0 || decoder.PixelHeight == 0)
                    throw new ArtworkException("invalid_image");
                stream.Seek(0);
                var image = new BitmapImage { DecodePixelWidth = 800 }; await image.SetSourceAsync(stream);
                if (cancellation.IsCancellationRequested || key != artworkKey || disposed) return;
                Artwork = image; ArtworkBytes = bytes; ArtworkStatus = "已加载";
                Store.ArtworkDiagnostic(kind, "loaded", attempt); Notify(); return;
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { return; }
            catch (Exception e)
            {
                if (cancellation.IsCancellationRequested || key != artworkKey || disposed) return;
                bool retry = attempt < 3 && (e is HttpRequestException or TaskCanceledException || e is ArtworkException { Retryable: true });
                string code = e is ArtworkException ae ? ae.Code : e is HttpRequestException or TaskCanceledException ? "network_error" : "invalid_image";
                Store.ArtworkDiagnostic(kind, code, attempt);
                ArtworkStatus = retry ? "加载失败，正在重试" : "封面加载失败，可在设置中重试"; Notify();
                if (!retry) return;
                try { await Task.Delay(attempt * 2000, cancellation); } catch (OperationCanceledException) { return; }
            }
        }
    }
    public void OpenLogs()
    {
        try { Directory.CreateDirectory(Store.Logs); Process.Start(new ProcessStartInfo(Store.Logs) { UseShellExecute = true }); }
        catch (Exception) { Error = "无法打开日志目录。"; Notify(); }
    }
    public void ClearError() { Error = ""; Notify(); }
    private static string Friendly(Exception e) => e switch
    {
        DllNotFoundException or EntryPointNotFoundException or BadImageFormatException => "接收核心缺失或版本不匹配，请重新解压完整的 x64 程序包。",
        UnauthorizedAccessException or IOException => "程序旁的数据目录不可写或正被使用，请将完整程序文件夹放到可写位置后重试。",
        ReceiverException { Code: "already_running" } => "这份设备数据正在被另一接收器使用，请先退出另一个实例。",
        ReceiverException re when re.Message.Contains("No active LAN") => "未找到可用局域网，请连接 Wi-Fi 或网线，或在设置中选择网卡。",
        ReceiverException re when re.Message.Contains("audio output") => "所选声音输出不可用，请重新连接设备或在设置中更换输出。",
        ReceiverException re => re.Message,
        IdentityMigrationRequiredException => e.Message,
        _ => "操作未完成，请重试或打开日志检查。"
    };
    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        disposed = true; WantsReceiving = false; Interlocked.Increment(ref generation);
        artworkCancellation?.Cancel(); lifetime.Cancel();
        volumeDebounce?.Cancel(); volumeDebounce?.Dispose();
        if (polling != null) await polling;
        await operations.WaitAsync();
        try { await Task.Run(() => { native?.Stop(); native?.Dispose(); native = null; }); }
        finally { operations.Release(); artworkCancellation?.Dispose(); lifetime.Dispose(); }
    }
}
