using System.Numerics;
using System.Runtime.InteropServices;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace FusionPlay.Windows.Platform;

/// <summary>Prepares a single artwork/strength batch and shares its loaded surfaces across player layouts.</summary>
internal sealed class AlbumBackdropCache(DispatcherQueue dispatcher) : IDisposable
{
    internal static ReadOnlySpan<float> ProgressiveRadii => [6, 14, 26, 40];
    private static readonly float[] radii = [6, 12, 14, 26, 34, 40, 48];
    private const int SurfaceSide = 512;
    private const float RasterDpi = 96;

    private sealed class Request(byte[] artwork, int strength)
    {
        internal readonly byte[] Artwork = artwork;
        internal readonly int Strength = strength;
        internal bool Started;
        internal PreparedArtwork? Prepared;

        internal bool Matches(byte[] value, int strength) => ReferenceEquals(Artwork, value) && Strength == strength;
    }

    internal sealed class PreparedArtwork : IDisposable
    {
        private sealed class Entry(LoadedImageSurface surface, IRandomAccessStream stream)
        {
            internal LoadedImageSurface Surface { get; } = surface;
            internal IRandomAccessStream Stream { get; } = stream;
            internal TypedEventHandler<LoadedImageSurface, LoadedImageSourceLoadCompletedEventArgs>? Handler;

            internal void Unsubscribe()
            {
                if (Handler == null) return;
                try { Surface.LoadCompleted -= Handler; }
                catch (Exception error) when (error is COMException or ObjectDisposedException) { }
                Handler = null;
            }
        }

        private readonly Dictionary<float, Entry> entries = [];
        private int references = 1, pending;
        internal bool IsReady { get; private set; }

        internal PreparedArtwork(Dictionary<float, IRandomAccessStream> streams, DispatcherQueue queue, Action<bool> completed)
        {
            pending = streams.Count;
            try
            {
                foreach (var (radius, stream) in streams)
                {
                    var entry = new Entry(LoadedImageSurface.StartLoadFromStream(stream), stream);
                    entries.Add(radius, entry);
                    entry.Handler = (_, args) =>
                    {
                        bool success = args.Status == LoadedImageSourceLoadStatus.Success;
                        queue.TryEnqueue(() =>
                        {
                            if (references == 0 || pending == 0 || entry.Handler == null) return;
                            entry.Unsubscribe();
                            if (!success)
                            {
                                pending = 0;
                                completed(false);
                            }
                            else if (--pending == 0)
                            {
                                IsReady = true;
                                completed(true);
                            }
                        });
                    };
                    entry.Surface.LoadCompleted += entry.Handler;
                }
                streams.Clear();
            }
            catch
            {
                foreach (float radius in entries.Keys) streams.Remove(radius);
                Dispose();
                throw;
            }
        }

        internal bool Contains(float radius) => entries.ContainsKey(radius);
        internal LoadedImageSurface Surface(float radius) => entries[radius].Surface;

        internal PreparedArtwork Acquire()
        {
            references++;
            return this;
        }

        public void Dispose()
        {
            if (--references != 0) return;
            foreach (var entry in entries.Values)
            {
                entry.Unsubscribe();
                Close(entry.Surface);
                Close(entry.Stream);
            }
            entries.Clear();
        }
    }

    private Request? current;
    private CancellationTokenSource? worker;
    private bool disposed;

    internal event Action? Ready;

    internal void Prepare(byte[] artwork, int strength)
    {
        if (disposed || current?.Matches(artwork, strength) == true) return;
        current?.Prepared?.Dispose();
        current = new Request(artwork, strength);
        if (worker != null) worker.Cancel();
        else StartNext();
    }

    internal PreparedArtwork? Acquire(byte[] artwork, int strength, ReadOnlySpan<float> requestedRadii)
    {
        if (current?.Matches(artwork, strength) != true || current.Prepared is not { IsReady: true } prepared) return null;
        foreach (float radius in requestedRadii)
            if (!prepared.Contains(radius)) return null;
        return prepared.Acquire();
    }

    private void StartNext()
    {
        if (disposed || current is not { Strength: > 0, Started: false } request) return;
        request.Started = true;
        var cancellation = new CancellationTokenSource();
        worker = cancellation;
        _ = Task.Run(async () =>
        {
            Dictionary<float, IRandomAccessStream>? streams = null;
            try { streams = await RenderAsync(request.Artwork, request.Strength, cancellation.Token); }
            catch (Exception error) when (error is COMException or ArgumentException or InvalidOperationException
                or IOException or NotSupportedException or OperationCanceledException)
            {
                // LoadedImageSurface and the live composition brushes remain available.
            }
            // If shutdown has closed the dispatcher, only the worker still owns these streams.
            if (!dispatcher.TryEnqueue(() => Publish(request, streams, cancellation)))
                CloseStreams(streams);
        });
    }

    private void Publish(Request request, Dictionary<float, IRandomAccessStream>? streams, CancellationTokenSource cancellation)
    {
        worker = null;
        cancellation.Dispose();
        try
        {
            if (disposed || !ReferenceEquals(current, request) || streams == null) return;
            request.Prepared = new PreparedArtwork(streams, dispatcher, success =>
            {
                if (disposed || !ReferenceEquals(current, request)) return;
                if (success) Ready?.Invoke();
                else
                {
                    request.Prepared?.Dispose();
                    request.Prepared = null;
                }
            });
        }
        catch (Exception error) when (error is COMException or ArgumentException or InvalidOperationException or NotSupportedException)
        {
            // The new artwork's live layers are already in place.
        }
        finally
        {
            CloseStreams(streams);
            StartNext();
        }
    }

    internal static async Task<Dictionary<float, IRandomAccessStream>> RenderAsync(byte[] artwork, int strength, CancellationToken cancellation)
    {
        using var input = new MemoryStream(artwork, writable: false).AsRandomAccessStream();
        var decoder = await BitmapDecoder.CreateAsync(input);
        cancellation.ThrowIfCancellationRequested();
        double scale = Math.Min(1, (double)SurfaceSide / Math.Max(decoder.PixelWidth, decoder.PixelHeight));
        var transform = new BitmapTransform
        {
            ScaledWidth = (uint)Math.Max(1, Math.Round(decoder.PixelWidth * scale)),
            ScaledHeight = (uint)Math.Max(1, Math.Round(decoder.PixelHeight * scale)),
            InterpolationMode = BitmapInterpolationMode.Linear
        };
        using var decoded = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
        cancellation.ThrowIfCancellationRequested();
        // CreateFromSoftwareBitmap inherits file DPI. Each layer must instead map the
        // same normalized source pixels to the same output rectangle as the original art.
        using var writable = decoded.IsReadOnly ? SoftwareBitmap.Copy(decoded) : null;
        var source = writable ?? decoded;
        source.DpiX = source.DpiY = RasterDpi;
        var device = CanvasDevice.GetSharedDevice();
        using var bitmap = CanvasBitmap.CreateFromSoftwareBitmap(device, source);
        using var target = new CanvasRenderTarget(device, source.PixelWidth, source.PixelHeight, RasterDpi);
        var artworkBounds = new Rect(0, 0, source.PixelWidth, source.PixelHeight);
        // Keep proportional blur for small artwork that will stretch to the same visual size.
        float radiusScale = Math.Max(source.PixelWidth, source.PixelHeight) / (float)SurfaceSide;
        using var gaussian = new GaussianBlurEffect
        {
            Source = bitmap,
            BorderMode = EffectBorderMode.Hard,
            Optimization = EffectOptimization.Quality
        };
        var streams = new Dictionary<float, IRandomAccessStream>(radii.Length);
        try
        {
            foreach (float radius in radii)
            {
                cancellation.ThrowIfCancellationRequested();
                gaussian.BlurAmount = radius * radiusScale * (strength / 100f);
                using (var drawing = target.CreateDrawingSession())
                {
                    drawing.Clear(Microsoft.UI.Colors.Transparent);
                    drawing.DrawImage(gaussian, Vector2.Zero, artworkBounds);
                }
                var stream = new InMemoryRandomAccessStream();
                streams.Add(radius, stream);
                await target.SaveAsync(stream, CanvasBitmapFileFormat.Png);
                cancellation.ThrowIfCancellationRequested();
                stream.Seek(0);
            }
            return streams;
        }
        catch
        {
            CloseStreams(streams);
            throw;
        }
    }

    private static void CloseStreams(Dictionary<float, IRandomAccessStream>? streams)
    {
        if (streams == null) return;
        foreach (var stream in streams.Values) Close(stream);
    }

    private static void Close(IDisposable resource)
    {
        try { resource.Dispose(); }
        catch (Exception error) when (error is COMException or ObjectDisposedException) { }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        current?.Prepared?.Dispose();
        current = null;
        worker?.Cancel();
        Ready = null;
    }
}
