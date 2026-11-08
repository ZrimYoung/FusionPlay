using System.Net;
using System.Text.Json;

namespace FusionPlay.Core;

public sealed class ArtworkException(string code, bool retryable = false) : Exception(code)
{
    public string Code { get; } = code;
    public bool Retryable { get; } = retryable;
}

public static class ArtworkLoader
{
    public const int MaximumBytes = 4_000_000;
    private const int MaximumEncoded = ((MaximumBytes + 2) / 3) * 4;
    public static string Normalize(string source)
    {
        string value = source.Trim();
        if (value.Length > MaximumEncoded + 256) throw new ArtworkException("size_limit");
        if (value.StartsWith('"'))
        {
            try { value = JsonSerializer.Deserialize<string>(value)?.Trim() ?? ""; }
            catch (JsonException) { }
        }
        return value.StartsWith("//", StringComparison.Ordinal) && !value.StartsWith("/9j/", StringComparison.Ordinal) ? "https:" + value : value;
    }
    public static bool IsNetworkUrl(Uri url) => (url.Scheme == "http" || url.Scheme == "https") && !string.IsNullOrEmpty(url.Host) && string.IsNullOrEmpty(url.UserInfo);
    public static string Kind(string source)
    {
        string value = Normalize(source);
        if (value.Length == 0) return "missing";
        if (value.StartsWith("data:image/", StringComparison.OrdinalIgnoreCase)) return "inline";
        if (Uri.TryCreate(value, UriKind.Absolute, out Uri? url) && IsNetworkUrl(url)) return url.Scheme;
        if (TryInline(value) != null) return "raw_base64";
        return "unsupported";
    }
    private static byte[]? TryInline(string value)
    {
        if (value.Length < 16 || value.Length > MaximumEncoded || value.Contains(':') || (value.StartsWith('/') && !value.StartsWith("/9j/", StringComparison.Ordinal))) return null;
        try { return Convert.FromBase64String(value); } catch (FormatException) { return null; }
    }
    public static async Task<byte[]> LoadAsync(string source, CancellationToken cancellation)
    {
        string value = Normalize(source);
        byte[]? inline;
        if (value.StartsWith("data:image/", StringComparison.OrdinalIgnoreCase))
        {
            int comma = value.IndexOf(',');
            if (comma < 0 || !value[..comma].EndsWith(";base64", StringComparison.OrdinalIgnoreCase)) throw new ArtworkException("invalid_inline_data");
            try { inline = Convert.FromBase64String(value[(comma + 1)..]); }
            catch (FormatException) { throw new ArtworkException("invalid_inline_data"); }
        }
        else inline = TryInline(value);
        if (inline != null)
        {
            if (inline.Length > MaximumBytes) throw new ArtworkException("size_limit");
            cancellation.ThrowIfCancellationRequested(); return inline;
        }
        if (!Uri.TryCreate(value, UriKind.Absolute, out Uri? url) || !IsNetworkUrl(url)) throw new ArtworkException("unsupported_source");
        using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, Credentials = null, DefaultProxyCredentials = null };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) };
        for (int redirect = 0; redirect < 6; redirect++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.Accept.ParseAdd("image/*");
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation).ConfigureAwait(false);
            if ((int)response.StatusCode is >= 300 and <= 399)
            {
                if (response.Headers.Location == null || redirect == 5) throw new ArtworkException("redirect_limit");
                url = new Uri(url, response.Headers.Location);
                if (!IsNetworkUrl(url)) throw new ArtworkException("unsupported_source");
                continue;
            }
            if (response.StatusCode != HttpStatusCode.OK)
            {
                int code = (int)response.StatusCode;
                throw new ArtworkException($"http_{code}", code is 408 or 429 || code >= 500);
            }
            if (response.Content.Headers.ContentLength > MaximumBytes) throw new ArtworkException("size_limit");
            await using var stream = await response.Content.ReadAsStreamAsync(cancellation).ConfigureAwait(false);
            using var content = new MemoryStream(); byte[] buffer = new byte[16_384];
            int read;
            while ((read = await stream.ReadAsync(buffer, cancellation).ConfigureAwait(false)) > 0)
            {
                if (content.Length + read > MaximumBytes) throw new ArtworkException("size_limit");
                content.Write(buffer, 0, read);
            }
            return content.ToArray();
        }
        throw new ArtworkException("redirect_limit");
    }
}
