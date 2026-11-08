using FusionPlay.Core;
using Windows.Media;
using Windows.Storage.Streams;
using System.Runtime.InteropServices;

namespace FusionPlay.Windows.Platform;

internal sealed class SystemMedia : IDisposable
{
    private readonly SystemMediaTransportControls controls;
    private readonly Action<PlaybackCommand> dispatch;
    private IRandomAccessStream? thumbnailStream;
    private byte[]? thumbnailBytes;
    private int reservation;
    private bool enabled;
    private bool active;
    private string metadata = "";
    private bool disposed;
    public SystemMedia(nint ownerWindow, Action<PlaybackCommand> send)
    {
        dispatch = send;
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
        bool shouldPublish = !model.Busy && (state.Phase == ReceiverPhase.Playing || state.ControlsAvailable && state.Phase == ReceiverPhase.Paused || active && state.HasMedia);
        if (!shouldPublish) { Clear(); return; }
        enabled = model.CanControl;
        if (!model.ControlBusy) Interlocked.Exchange(ref reservation, 0);
        controls.IsEnabled = true;
        controls.IsPlayEnabled = controls.IsPauseEnabled = controls.IsPreviousEnabled = controls.IsNextEnabled = enabled;
        controls.PlaybackStatus = state.Phase == ReceiverPhase.Playing ? MediaPlaybackStatus.Playing : MediaPlaybackStatus.Paused;
        string nextMetadata = state.TrackId + "|" + state.Title + "|" + state.Artist + "|" + state.Album;
        if (metadata != nextMetadata || !ReferenceEquals(thumbnailBytes, model.ArtworkBytes) || !active)
        {
            var updater = controls.DisplayUpdater;
            updater.Type = MediaPlaybackType.Music;
            updater.AppMediaId = state.TrackId;
            updater.MusicProperties.Title = state.Title.Length == 0 ? "FusionPlay" : state.Title;
            updater.MusicProperties.Artist = state.Artist;
            updater.MusicProperties.AlbumTitle = state.Album;
            thumbnailStream?.Dispose(); thumbnailStream = null;
            thumbnailBytes = model.ArtworkBytes;
            if (thumbnailBytes != null)
            {
                thumbnailStream = new MemoryStream(thumbnailBytes, writable: false).AsRandomAccessStream();
                updater.Thumbnail = RandomAccessStreamReference.CreateFromStream(thumbnailStream);
            }
            else updater.Thumbnail = null;
            updater.Update(); metadata = nextMetadata;
        }
        active = true;
    }
    public void Clear()
    {
        enabled = false; Interlocked.Exchange(ref reservation, 0);
        controls.IsPlayEnabled = controls.IsPauseEnabled = controls.IsPreviousEnabled = controls.IsNextEnabled = false;
        controls.PlaybackStatus = MediaPlaybackStatus.Stopped;
        if (active) { controls.DisplayUpdater.ClearAll(); controls.DisplayUpdater.Update(); }
        controls.IsEnabled = false; active = false; metadata = "";
        thumbnailStream?.Dispose(); thumbnailStream = null; thumbnailBytes = null;
    }
    public void Dispose()
    {
        if (disposed) return;
        Clear(); disposed = true; controls.ButtonPressed -= ButtonPressed;
    }
}
