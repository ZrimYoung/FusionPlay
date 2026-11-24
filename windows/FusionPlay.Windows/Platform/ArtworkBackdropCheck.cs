using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace FusionPlay.Windows.Platform;

internal static class ArtworkBackdropCheck
{
    internal static async Task<object[]> VerifyProgressiveRegistration()
    {
        return [await CheckArtwork(360, 240, 72), await CheckArtwork(768, 432, 144)];
    }

    private static async Task<object> CheckArtwork(int width, int height, double dpi)
    {
        const int maximumSide = 512;
        int verticalEdge = width * 37 / 100, horizontalEdge = height * 58 / 100;
        int outputWidth = Math.Min(maximumSide, width);
        int outputHeight = (int)Math.Round(height * ((double)outputWidth / width));
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int index = (y * width + x) * 4;
                pixels[index] = y < horizontalEdge ? (byte)32 : (byte)224;
                pixels[index + 1] = 128;
                pixels[index + 2] = x < verticalEdge ? (byte)32 : (byte)224;
                pixels[index + 3] = 255;
            }
        }

        using var source = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, source);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)width, (uint)height, dpi, dpi, pixels);
        await encoder.FlushAsync();
        source.Seek(0);
        var original = await BitmapDecoder.CreateAsync(source);
        if (Math.Abs(original.DpiX - dpi) > .1) throw new InvalidOperationException("artwork_registration_fixture_dpi_missing");
        source.Seek(0);
        using var reader = new DataReader(source);
        await reader.LoadAsync((uint)source.Size);
        var artwork = new byte[checked((int)source.Size)];
        reader.ReadBytes(artwork);

        var prepared = await AlbumBackdropCache.RenderAsync(artwork, 100, CancellationToken.None);
        double maximumOffset = 0;
        try
        {
            foreach (float radius in AlbumBackdropCache.ProgressiveRadii.ToArray())
            {
                var stream = prepared[radius];
                var decoder = await BitmapDecoder.CreateAsync(stream);
                if (decoder.PixelWidth != outputWidth || decoder.PixelHeight != outputHeight)
                    throw new InvalidOperationException("artwork_registration_changed_pixel_bounds");
                var provider = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                    new BitmapTransform(), ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
                byte[] blurred = provider.DetachPixelData();
                int row = outputHeight / 2, column = outputWidth / 2;
                int blurredVerticalEdge = Enumerable.Range(0, outputWidth).FirstOrDefault(x => blurred[(row * outputWidth + x) * 4 + 2] >= 128);
                int blurredHorizontalEdge = Enumerable.Range(0, outputHeight).FirstOrDefault(y => blurred[(y * outputWidth + column) * 4] >= 128);
                double horizontalOffset = Math.Abs(blurredVerticalEdge - verticalEdge * ((double)outputWidth / width));
                double verticalOffset = Math.Abs(blurredHorizontalEdge - horizontalEdge * ((double)outputHeight / height));
                maximumOffset = Math.Max(maximumOffset, Math.Max(horizontalOffset, verticalOffset));
                if (maximumOffset > 2 || blurred[3] < 250 || blurred[^1] < 250)
                    throw new InvalidOperationException($"artwork_registration_shift_{dpi}_{radius}_{horizontalOffset:F2}_{verticalOffset:F2}");
            }
            return new { dpi, output_width = outputWidth, output_height = outputHeight, largest_pixel_offset = maximumOffset };
        }
        finally
        {
            foreach (var stream in prepared.Values) stream.Dispose();
        }
    }
}
