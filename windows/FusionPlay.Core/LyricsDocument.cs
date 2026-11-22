using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace FusionPlay.Core;

public sealed record LyricsLine(int Id, ulong? TimeMs, string Text, string? Translation);

/// <summary>Bounded immutable LRC or plain text, held only in memory.</summary>
public sealed class LyricsDocument
{
    public const int MaxSourceBytes = 256 * 1024, MaxLines = 4_000;
    public const int MaxLineCharacters = 2_048, MaxTranslationCharacters = 4_096;
    public const long MaxTimestampMs = 24 * 60 * 60 * 1_000;
    private static readonly Regex WordTimes = new(@"<[0-9]{1,4}:[0-9]{2}(?:\.[0-9]{1,3})?>", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly HashSet<string> Metadata = new(StringComparer.OrdinalIgnoreCase)
        { "ar", "al", "ti", "au", "by", "re", "ve", "length", "offset", "id", "tool" };
    public static LyricsDocument Empty { get; } = new([]);
    public IReadOnlyList<LyricsLine> Lines { get; }
    public bool HasLyrics => Lines.Count > 0;
    public bool IsTimed => HasLyrics && Lines[0].TimeMs != null;
    private LyricsDocument(IEnumerable<LyricsLine> lines) => Lines = Array.AsReadOnly(lines.ToArray());

    public static LyricsDocument Parse(string? source)
    {
        if (string.IsNullOrEmpty(source)) return Empty;
        string bounded = BoundSource(source);
        var timed = new List<(long Time, string Text, int Order)>();
        var plain = new List<string>();
        long offset = 0;
        using var reader = new StringReader(bounded);
        for (int line = 0; line < MaxLines * 2 && reader.ReadLine() is { } raw; line++)
        {
            string body = Trim(Clip(raw, MaxLineCharacters));
            var stamps = new List<long>();
            while (body.StartsWith('['))
            {
                int end = body.IndexOf(']');
                if (end < 0) break;
                string token = body[1..end];
                if (Timestamp(token) is { } time) { if (stamps.Count < 64) stamps.Add(time); }
                else if (Offset(token) is { } adjustment) offset = adjustment;
                else if (!IsMetadata(token) && !LooksTimed(token)) break;
                body = body[(end + 1)..];
            }
            string text = WordTimes.Replace(body, "").Trim();
            if (stamps.Count > 0)
            {
                foreach (long time in stamps) if (timed.Count < MaxLines) timed.Add((time, text, timed.Count));
            }
            else if (text.Length > 0 && plain.Count < MaxLines) plain.Add(text);
        }
        if (timed.Count == 0) return plain.Count == 0 ? Empty : new(plain.Select((text, id) => new LyricsLine(id, null, text, null)));
        if (!timed.Any(entry => entry.Text.Length > 0)) return Empty;
        var sorted = timed.Select(entry => (Time: Math.Clamp(entry.Time - offset, 0, MaxTimestampMs), entry.Text, entry.Order))
            .OrderBy(entry => entry.Time).ThenBy(entry => entry.Order);
        var lines = new List<LyricsLine>();
        foreach (var group in sorted.GroupBy(entry => entry.Time))
        {
            var words = group.Select(entry => entry.Text).Distinct(StringComparer.Ordinal).Take(16).Where(text => text.Length > 0).ToArray();
            string translation = Clip(string.Join('\n', words.Skip(1)), MaxTranslationCharacters);
            lines.Add(new(lines.Count, (ulong)group.Key, words.FirstOrDefault() ?? "", translation.Length == 0 ? null : translation));
        }
        return new(lines);
    }

    public int ActiveLineIndex(ulong? positionMs)
    {
        if (!IsTimed || positionMs is not { } position || position < Lines[0].TimeMs!.Value) return -1;
        int low = 0, high = Lines.Count;
        while (low < high)
        {
            int middle = low + (high - low) / 2;
            if (Lines[middle].TimeMs!.Value <= position) low = middle + 1; else high = middle;
        }
        return low - 1;
    }

    private static string BoundSource(string source)
    {
        if (Encoding.UTF8.GetByteCount(source) <= MaxSourceBytes) return source;
        int bytes = 0, characters = 0;
        foreach (var rune in source.EnumerateRunes())
        {
            if (bytes + rune.Utf8SequenceLength > MaxSourceBytes) break;
            bytes += rune.Utf8SequenceLength; characters += rune.Utf16SequenceLength;
        }
        return source[..characters];
    }
    private static string Clip(string source, int maximum)
    {
        if (source.Length <= maximum) return source;
        int[] elements = StringInfo.ParseCombiningCharacters(source);
        return elements.Length <= maximum ? source : source[..elements[maximum]];
    }
    private static string Trim(string source)
    {
        int first = 0, last = source.Length;
        while (first < last && (char.IsWhiteSpace(source[first]) || source[first] == '\uFEFF')) first++;
        while (last > first && (char.IsWhiteSpace(source[last - 1]) || source[last - 1] == '\uFEFF')) last--;
        return source[first..last];
    }
    private static bool Digits(ReadOnlySpan<char> text)
    {
        if (text.IsEmpty) return false;
        foreach (char value in text) if (value is < '0' or > '9') return false;
        return true;
    }
    private static long? Timestamp(string token)
    {
        int colon = token.IndexOf(':');
        if (colon is < 1 or > 4 || !Digits(token.AsSpan(0, colon))) return null;
        var seconds = token.AsSpan(colon + 1); int dot = seconds.IndexOf('.');
        var whole = dot < 0 ? seconds : seconds[..dot];
        if (whole.Length != 2 || !Digits(whole)) return null;
        long fraction = 0;
        if (dot >= 0)
        {
            var digits = seconds[(dot + 1)..];
            if (digits.Length is < 1 or > 3 || !Digits(digits)) return null;
            fraction = long.Parse(digits, CultureInfo.InvariantCulture) * (digits.Length == 1 ? 100 : digits.Length == 2 ? 10 : 1);
        }
        long second = long.Parse(whole, CultureInfo.InvariantCulture);
        if (second >= 60) return null;
        long value = (long.Parse(token.AsSpan(0, colon), CultureInfo.InvariantCulture) * 60 + second) * 1_000 + fraction;
        return value <= MaxTimestampMs ? value : null;
    }
    private static long? Offset(string token)
    {
        if (!token.StartsWith("offset:", StringComparison.OrdinalIgnoreCase)
            || !long.TryParse(token.AsSpan(7).Trim(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out long value)) return null;
        return Math.Clamp(value, -MaxTimestampMs, MaxTimestampMs);
    }
    private static bool IsMetadata(string token)
    {
        int colon = token.IndexOf(':');
        return colon >= 0 && Metadata.Contains(token[..colon]);
    }
    private static bool LooksTimed(string token) => token.Length > 0 && char.IsAsciiDigit(token[0]) && token.Contains(':');
}

public sealed record LyricsParseRequest(long Version, string Source);

/// <summary>Versioned publication and last real position, independent of UI threads.</summary>
public sealed class LyricsState
{
    public static readonly TimeSpan MissingLyricsGracePeriod = TimeSpan.FromSeconds(2);
    private ReceiverSnapshot? identity;
    private string source = "";
    private long version;
    private ulong? lastPosition;
    public LyricsDocument Document { get; private set; } = LyricsDocument.Empty;
    public bool Loading { get; private set; }
    public bool Available { get; private set; }
    public bool WaitingForLyrics => MissingLyricsWaitToken.HasValue;
    public long? MissingLyricsWaitToken { get; private set; }

    public LyricsParseRequest? Observe(ReceiverSnapshot snapshot)
    {
        if (!snapshot.ControlsAvailable) { Clear(); return null; }
        string incoming = snapshot.LyricsText ?? "";
        if (identity == null || !Seeking.SameTrack(identity, snapshot))
        {
            // Keep only the previous pane's availability while the next song's
            // metadata arrives. Never keep its text, row identities or position.
            bool retainPane = identity != null && Available;
            ++version; source = ""; Document = LyricsDocument.Empty; Loading = false; lastPosition = null;
            MissingLyricsWaitToken = retainPane && incoming.Length == 0 ? version : null;
        }
        identity = snapshot;
        if (snapshot.PositionMs is { } position) lastPosition = position;
        if (string.Equals(source, incoming, StringComparison.Ordinal)) { ResolveAvailability(); return null; }
        source = incoming; ++version; MissingLyricsWaitToken = null; Loading = source.Length > 0;
        if (!Loading) Document = LyricsDocument.Empty;
        ResolveAvailability();
        return Loading ? new(version, source) : null;
    }
    public bool Complete(LyricsParseRequest request, LyricsDocument document)
    {
        if (identity?.ControlsAvailable != true || request.Version != version || !string.Equals(request.Source, source, StringComparison.Ordinal)) return false;
        Document = document; Loading = false; ResolveAvailability(); return true;
    }
    /// <summary>Expires one track's metadata wait; repeated empty polls never renew it.</summary>
    public bool ExpireMissingLyrics(long token)
    {
        if (MissingLyricsWaitToken != token) return false;
        MissingLyricsWaitToken = null; ResolveAvailability(); return true;
    }
    public ulong? Position(ulong? displayPosition, bool connected) => connected ? displayPosition ?? lastPosition : null;
    public void Clear()
    {
        ++version; identity = null; source = ""; Document = LyricsDocument.Empty;
        Loading = false; Available = false; lastPosition = null; MissingLyricsWaitToken = null;
    }
    private void ResolveAvailability() => Available = Document.HasLyrics || (Loading || WaitingForLyrics) && Available;
}
