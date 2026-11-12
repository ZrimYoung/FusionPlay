using FusionPlay.Core;
using Windows.Media;
using Windows.Storage.Streams;
using System.Runtime.InteropServices;
using Windows.Graphics.Imaging;

namespace FusionPlay.Windows.Platform;

internal sealed class SystemMedia : IDisposable
{
    private readonly SystemMediaTransportControls controls;
    private readonly Action<PlaybackCommand> dispatch;
    private readonly Action<string>? diagnostic;
    private readonly CancellationTokenSource lifetime = new();
    private readonly List<ThumbnailPublication> retiredThumbnails = [];
    private CancellationTokenSource? thumbnailRequest;
    private ThumbnailPublication? thumbnail;
    private byte[]? thumbnailBytes;
    private long thumbnailGeneration;
    private ulong? timelineDuration, timelinePosition;
    private string timelineTrack = "";
    private bool timelinePublished;
    private int reservation;
    private bool enabled;
    private bool active;
    private string metadata = "";
    private bool disposed;
    public SystemMedia(nint ownerWindow, Action<PlaybackCommand> send, Action<string>? report = null)
    {
        dispatch = send; diagnostic = report;
        controls = GetForWindow(ownerWindow);
        controls.ButtonPressed += ButtonPressed;
        controls.IsEnabled = false;
        controls.IsFastForwardEnabled = controls.IsRewindEnabled = controls.IsStopEnabled = false;
    }
    private static unsafe SystemMediaTransportControls GetForWindow(nint window)
    {
        // The SDK declares this factory interface as IInspectable (six base
        // methods), not IUnknown. Keep the HWND alive for the whole app session.
        const string runtimeClass = "Windows.Media.SystemMediaTransportControls";
        Guid interopId = new("ddb0472d-c911-4a1f-86d9-dc3d71a95f5a");
        Guid controlsId = new("99fa3ff4-1742-42a6-902e-087d41f965ec");
        Marshal.ThrowExceptionForHR(WindowsCreateString(runtimeClass, (uint)runtimeClass.Length, out nint className));
        nint factory = 0, result = 0;
        try
        {
            Marshal.ThrowExceptionForHR(RoGetActivationFactory(className, in interopId, out factory));
            var get = (delegate* unmanaged[Stdcall]<nint, nint, Guid*, nint*, int>)(*(nint**)factory)[6];
            Marshal.ThrowExceptionForHR(get(factory, window, &controlsId, &result));
            return WinRT.MarshalInterface<SystemMediaTransportControls>.FromAbi(result);
        }
        finally
        {
            if (result != 0) Marshal.Release(result);
            if (factory != 0) Marshal.Release(factory);
            WindowsDeleteString(className);
        }
    }
    [DllImport("combase.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int WindowsCreateString(string source, uint length, out nint value);
    [DllImport("combase.dll", ExactSpelling = true)]
    private static extern int WindowsDeleteString(nint value);
    [DllImport("combase.dll", ExactSpelling = true)]
    private static extern int RoGetActivationFactory(nint className, in Guid iid, out nint factory);
    private void ButtonPressed(SystemMediaTransportControls sender, SystemMediaTransportControlsButtonPressedEventArgs args)
    {
        if (disposed || !Volatile.Read(ref enabled) || Interlocked.CompareExchange(ref reservation, 1, 0) != 0) return;
        PlaybackCommand? command = args.Button switch
        {
            SystemMediaTransportControlsButton.Play => PlaybackCommand.Play,
            SystemMediaTransportControlsButton.Pause => PlaybackCommand.Pause,
            SystemMediaTransportControlsButton.Previous => PlaybackCommand.Previous,
            SystemMediaTransportControlsButton.Next => PlaybackCommand.Next,
            _ => null
        };
        if (command == null) { Interlocked.Exchange(ref reservation, 0); return; }
        dispatch(command.Value);
    }
    public void Update(ReceiverController model)
    {
        if (disposed) return;
        var state = model.State;
        // Discovery, authentication and a control-only connection never publish
        // a new system music session. Keep an existing paused/connected session.
        bool shouldPublish = !model.Busy && !model.Suspended && (state.Phase == ReceiverPhase.Playing || state.ControlsAvailable && state.Phase == ReceiverPhase.Paused || active && state.HasMedia);
        if (!shouldPublish) { Clear(); return; }
        enabled = model.CanControl;
        if (!model.ControlBusy) Interlocked.Exchange(ref reservation, 0);
        controls.IsEnabled = true;
        controls.IsPlayEnabled = controls.IsPauseEnabled = controls.IsPreviousEnabled = controls.IsNextEnabled = enabled;
        controls.PlaybackStatus = state.Phase == ReceiverPhase.Playing ? MediaPlaybackStatus.Playing : MediaPlaybackStatus.Paused;
        string nextMetadata = state.TrackId + "|" + state.Title + "|" + state.Artist + "|" + state.Album;
        byte[]? currentArtwork = model.ArtworkLoading ? null : model.ArtworkBytes;
        if (metadata != nextMetadata || !ReferenceEquals(thumbnailBytes, currentArtwork) || !active)
        {
            CancelThumbnailRequest();
            long generation = ++thumbnailGeneration;
            // Clear the preceding track's artwork immediately. A native in-memory
            // thumbnail is published after decoding, only if this request is still current.
            PublishMetadata(state, null);
            thumbnailBytes = currentArtwork;
            metadata = nextMetadata;
            RetireThumbnail(thumbnail); thumbnail = null;
            if (currentArtwork != null)
            {
                thumbnailRequest = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                _ = PublishThumbnailAsync(state, currentArtwork, generation, thumbnailRequest.Token);
            }
        }
        UpdateTimeline(state);
        active = true;
    }

    private sealed class ThumbnailPublication(InMemoryRandomAccessStream stream) : IDisposable
    {
        public InMemoryRandomAccessStream Stream { get; } = stream;
        public RandomAccessStreamReference Reference { get; } = RandomAccessStreamReference.CreateFromStream(stream);
        private bool disposed;
        public void Dispose() { if (!disposed) { disposed = true; Stream.Dispose(); } }
    }
    private void PublishMetadata(ReceiverSnapshot state, ThumbnailPublication? artwork)
    {
        var updater = controls.DisplayUpdater;
        updater.Type = MediaPlaybackType.Music;
        updater.AppMediaId = state.TrackId;
        updater.MusicProperties.Title = state.Title.Length == 0 ? "FusionPlay" : state.Title;
        updater.MusicProperties.Artist = state.Artist;
        updater.MusicProperties.AlbumTitle = state.Album;
        updater.Thumbnail = artwork?.Reference;
        updater.Update();
    }
    private async Task PublishThumbnailAsync(ReceiverSnapshot state, byte[] bytes, long generation, CancellationToken cancellation)
    {
        ThumbnailPublication? incoming = null;
        try
        {
            incoming = await Task.Run(() => CreateThumbnailAsync(bytes, cancellation), cancellation);
            if (disposed || cancellation.IsCancellationRequested || generation != thumbnailGeneration) return;
            PublishMetadata(state, incoming);
            RetireThumbnail(thumbnail); thumbnail = incoming; incoming = null;
            diagnostic?.Invoke("system_media_thumbnail_published");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (!disposed && generation == thumbnailGeneration) Report("thumbnail", error);
        }
        finally { incoming?.Dispose(); }
    }
    private static async Task<ThumbnailPublication> CreateThumbnailAsync(byte[] bytes, CancellationToken cancellation)
    {
        using var source = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(source.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(bytes); await writer.StoreAsync(); await writer.FlushAsync();
        }
        cancellation.ThrowIfCancellationRequested(); source.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(source);
        if (decoder.PixelWidth == 0 || decoder.PixelHeight == 0 || (ulong)decoder.PixelWidth * decoder.PixelHeight > 40_000_000)
            throw new InvalidDataException("Invalid thumbnail dimensions.");
        double scale = Math.Min(1, 512.0 / Math.Max(decoder.PixelWidth, decoder.PixelHeight));
        uint width = Math.Max(1, (uint)Math.Round(decoder.PixelWidth * scale));
        uint height = Math.Max(1, (uint)Math.Round(decoder.PixelHeight * scale));
        var transform = new BitmapTransform { ScaledWidth = width, ScaledHeight = height, InterpolationMode = BitmapInterpolationMode.Fant };
        var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            transform, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.ColorManageToSRgb);
        cancellation.ThrowIfCancellationRequested();
        var output = new InMemoryRandomAccessStream();
        try
        {
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, width, height, 96, 96, pixels.DetachPixelData());
            await encoder.FlushAsync(); cancellation.ThrowIfCancellationRequested(); output.Seek(0);
            // A native stream can be read asynchronously by the Shell. Keep it and
            // its reference alive, rather than exposing a managed Stream adapter.
            return new ThumbnailPublication(output);
        }
        catch { output.Dispose(); throw; }
    }
    // Background diagnostic only: exercises the exact publication pipeline and
    // its externally readable native stream reference without creating an SMTC
    // session, registering identity, or touching any window.
    internal static async Task<(uint Width, uint Height)> CheckThumbnailAsync(byte[] bytes)
    {
        using var publication = await Task.Run(() => CreateThumbnailAsync(bytes, CancellationToken.None));
        using var readable = await publication.Reference.OpenReadAsync();
        var decoder = await BitmapDecoder.CreateAsync(readable);
        if (decoder.PixelWidth == 0 || decoder.PixelHeight == 0 || decoder.PixelWidth > 512 || decoder.PixelHeight > 512)
            throw new InvalidDataException("Published thumbnail dimensions are outside the supported range.");
        // Decode pixels as well as the header, so this confirms a complete image
        // survived encoding and reopening through RandomAccessStreamReference.
        var pixels = await decoder.GetPixelDataAsync();
        if (pixels.DetachPixelData().Length == 0) throw new InvalidDataException("Published thumbnail contains no pixels.");
        return (decoder.PixelWidth, decoder.PixelHeight);
    }
    private void CancelThumbnailRequest()
    {
        var request = thumbnailRequest; thumbnailRequest = null;
        request?.Cancel(); request?.Dispose();
    }
    private void RetireThumbnail(ThumbnailPublication? outgoing)
    {
        if (outgoing == null) return;
        retiredThumbnails.Add(outgoing); _ = RetireThumbnailAsync(outgoing);
    }
    private async Task RetireThumbnailAsync(ThumbnailPublication outgoing)
    {
        // DisplayUpdater.Update hands work to the Shell; allow an already-open
        // reader to finish before closing the preceding stream.
        try { await Task.Delay(10_000, lifetime.Token); }
        catch (OperationCanceledException) { }
        finally { retiredThumbnails.Remove(outgoing); outgoing.Dispose(); }
    }
    private void UpdateTimeline(ReceiverSnapshot state)
    {
        try
        {
            if (state.DurationMs is > 0 && state.PositionMs.HasValue)
            {
                ulong position = Math.Min(state.PositionMs.Value, state.DurationMs.Value);
                if (timelinePublished && timelineDuration == state.DurationMs && timelinePosition == position && timelineTrack == state.TrackId) return;
                // No MinSeekTime/MaxSeekTime and no position-change handler: the
                // sender owns seeking. Publish only its actual reported timeline.
                controls.UpdateTimelineProperties(new SystemMediaTransportControlsTimelineProperties
                {
                    StartTime = TimeSpan.Zero, EndTime = TimelineTime(state.DurationMs.Value), Position = TimelineTime(position)
                });
                timelinePublished = true; timelineDuration = state.DurationMs; timelinePosition = position; timelineTrack = state.TrackId;
            }
            else ClearTimeline();
        }
        catch (Exception error) { Report("timeline", error); }
    }
    private static TimeSpan TimelineTime(ulong millis) => TimeSpan.FromTicks((long)Math.Min(millis, (ulong)(TimeSpan.MaxValue.Ticks / TimeSpan.TicksPerMillisecond)) * TimeSpan.TicksPerMillisecond);
    private void ClearTimeline()
    {
        if (!timelinePublished) return;
        controls.UpdateTimelineProperties(new SystemMediaTransportControlsTimelineProperties { StartTime = TimeSpan.Zero, EndTime = TimeSpan.Zero, Position = TimeSpan.Zero });
        timelinePublished = false; timelineDuration = timelinePosition = null; timelineTrack = "";
    }
    private void Report(string stage, Exception error) => diagnostic?.Invoke("system_media_" + stage + ":" + error.GetType().Name + ":" + error.HResult.ToString("X8"));
    public void Clear()
    {
        CancelThumbnailRequest(); ++thumbnailGeneration;
        enabled = false; Interlocked.Exchange(ref reservation, 0);
        controls.IsPlayEnabled = controls.IsPauseEnabled = controls.IsPreviousEnabled = controls.IsNextEnabled = false;
        controls.PlaybackStatus = MediaPlaybackStatus.Stopped;
        if (active) { controls.DisplayUpdater.ClearAll(); controls.DisplayUpdater.Update(); }
        controls.IsEnabled = false; active = false; metadata = "";
        ClearTimeline(); RetireThumbnail(thumbnail); thumbnail = null; thumbnailBytes = null;
    }
    public void Dispose()
    {
        if (disposed) return;
        Clear(); disposed = true; controls.ButtonPressed -= ButtonPressed;
        lifetime.Cancel(); lifetime.Dispose();
        foreach (var retired in retiredThumbnails.ToArray()) retired.Dispose(); retiredThumbnails.Clear();
    }
}
