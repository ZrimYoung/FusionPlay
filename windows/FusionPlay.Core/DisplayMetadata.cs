using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace FusionPlay.Core;

/// <summary>Presentation only; never replace the source identity used by playback or seeking.</summary>
public sealed record DisplayMetadata(string Title, string Artist, string Album, bool WasCorrected = false);

/// <summary>Recovers a caption title only from independently supplied, bounded metadata.</summary>
public static class DisplayMetadataResolver
{
    private const int MaximumMetadataCharacters = 512;
    private const int MaximumDisplayFieldCharacters = 4_096;
    private static readonly Regex Words = new(@"\p{L}[\p{L}\p{M}\p{N}]*(?:['-][\p{L}\p{M}\p{N}]+)*", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Regex Whitespace = new(@"\s+", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    // Control availability can briefly disappear during a track transition.
    // Ready/stopped states clear the presentation even if their last fields linger.
    public static bool HasCurrentTrack(ReceiverSnapshot state) => state.Phase is ReceiverPhase.Playing or ReceiverPhase.Paused
        || state.Phase == ReceiverPhase.Connected && (!string.IsNullOrWhiteSpace(state.TrackId)
            || !string.IsNullOrWhiteSpace(state.Title) || state.DurationMs is > 0);

    public static DisplayMetadata Resolve(string title, string artist, string album, string lyricsText)
    {
        var original = new DisplayMetadata(title, artist, album);
        if (lyricsText.Length == 0 || title.Length > MaximumDisplayFieldCharacters || artist.Length > MaximumDisplayFieldCharacters
            || album.Length > MaximumDisplayFieldCharacters || Encoding.UTF8.GetByteCount(lyricsText) > LyricsDocument.MaxSourceBytes
            || InvalidUtf16(lyricsText) || InvalidUtf16(title) || InvalidUtf16(artist) || InvalidUtf16(album)) return original;
        var (headers, conflicts) = ReadHeaders(lyricsText);
        if (conflicts.Contains("ti") || conflicts.Contains("ar")) return original;
        headers.TryGetValue("ti", out string? knownTitle); headers.TryGetValue("ar", out string? knownArtist);
        if (knownTitle == null && knownArtist == null) return original;
        headers.TryGetValue("al", out string? knownAlbum);
        var composite = RecoverComposite(artist, album, knownTitle, knownArtist, knownAlbum);
        string? realTitle = knownTitle ?? composite?.Title;
        if (realTitle == null) return original;
        bool alreadyCorrect = Equivalent(title, realTitle);
        if (!alreadyCorrect && Trim(title).Length > 0 && !MatchesTimedCaption(title, LyricsDocument.Parse(lyricsText))) return original;
        string resolvedTitle = alreadyCorrect ? title : realTitle;
        string resolvedArtist = composite?.Artist ?? (Trim(artist).Length == 0 ? knownArtist ?? artist : artist);
        string resolvedAlbum = Trim(album).Length == 0 ? knownAlbum ?? album : album;
        return new(resolvedTitle, resolvedArtist, resolvedAlbum,
            resolvedTitle != title || resolvedArtist != artist || resolvedAlbum != album);
    }

    private static (Dictionary<string, string> Values, HashSet<string> Conflicts) ReadHeaders(string source)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var conflicts = new HashSet<string>(StringComparer.Ordinal);
        using var reader = new StringReader(source);
        for (int line = 0; line < LyricsDocument.MaxLines * 2 && reader.ReadLine() is { } raw; line++)
        {
            string body = Trim(raw.Length <= LyricsDocument.MaxLineCharacters ? raw : raw[..LyricsDocument.MaxLineCharacters]);
            while (body.StartsWith('['))
            {
                int end = body.IndexOf(']'); if (end < 0) break;
                string token = body[1..end]; int colon = token.IndexOf(':'); if (colon < 0) break;
                string key = Trim(token[..colon]).ToLowerInvariant();
                if (key is not ("ti" or "ar" or "al")) break;
                string value = Trim(token[(colon + 1)..]);
                if (value.Length > 0 && value.EnumerateRunes().Count() <= MaximumMetadataCharacters && !value.Any(char.IsControl))
                {
                    if (values.TryGetValue(key, out string? previous) && !Equivalent(previous, value))
                    { values.Remove(key); conflicts.Add(key); }
                    else if (!conflicts.Contains(key)) values[key] = value;
                }
                body = body[(end + 1)..];
            }
        }
        return (values, conflicts);
    }

    private sealed record Composite(string Title, string Artist);
    private static Composite? RecoverComposite(string artist, string album, string? knownTitle, string? knownArtist, string? knownAlbum)
    {
        var variants = new List<string> { Trim(artist) };
        foreach (string suffix in new[] { album, knownAlbum ?? "" })
            if (Trim(suffix).Length > 0 && RemoveSuffix(suffix, Trim(artist)) is { } stripped && !variants.Contains(stripped)) variants.Add(stripped);
        var candidates = new List<Composite>();
        foreach (string value in variants.Where(value => value.Length > 0))
        {
            if (knownTitle != null && RemovePrefix(knownTitle, value) is { } tail && (knownArtist == null || Equivalent(tail, knownArtist)))
                candidates.Add(new(knownTitle, knownArtist ?? tail));
            if (knownArtist != null && RemoveSuffix(knownArtist, value) is { } head && (knownTitle == null || Equivalent(head, knownTitle)))
                candidates.Add(new(knownTitle ?? head, knownArtist));
        }
        if (candidates.Count == 0) return null;
        var first = candidates[0];
        return candidates.All(candidate => Equivalent(candidate.Title, first.Title) && Equivalent(candidate.Artist, first.Artist)) ? first : null;
    }

    private static string? RemovePrefix(string prefix, string value)
    {
        prefix = Trim(prefix); if (prefix.Length == 0) return null;
        // Compare the complete field, then require a separate delimiter. Never
        // split a real song or artist name at an arbitrary embedded hyphen.
        int boundary = FieldBoundary(value, prefix, fromEnd: false); if (boundary < 0) return null;
        string remainder = Trim(value[boundary..]);
        if (remainder.Length == 0 || !IsDelimiter(remainder[0])) return null;
        string tail = Trim(remainder[1..]);
        return tail.Length > 0 && tail.EnumerateRunes().Count() <= MaximumMetadataCharacters ? tail : null;
    }
    private static string? RemoveSuffix(string suffix, string value)
    {
        suffix = Trim(suffix); if (suffix.Length == 0) return null;
        int boundary = FieldBoundary(value, suffix, fromEnd: true); if (boundary < 0) return null;
        string remainder = Trim(value[..boundary]);
        if (remainder.Length == 0 || !IsDelimiter(remainder[^1])) return null;
        string head = Trim(remainder[..^1]);
        return head.Length > 0 && head.EnumerateRunes().Count() <= MaximumMetadataCharacters ? head : null;
    }
    private static int FieldBoundary(string value, string known, bool fromEnd)
    {
        // Compare original delimiter boundaries after normalization, so width
        // and canonical differences never invent a split within a full name.
        if (!fromEnd)
        {
            for (int i = 0; i <= value.Length; i++)
                if ((i == value.Length || char.IsWhiteSpace(value[i]) || IsDelimiter(value[i])) && Equivalent(value[..i], known)) return i;
        }
        else
        {
            for (int i = value.Length; i >= 0; i--)
                if ((i == 0 || char.IsWhiteSpace(value[i - 1]) || IsDelimiter(value[i - 1])) && Equivalent(value[i..], known)) return i;
        }
        return -1;
    }

    private static bool MatchesTimedCaption(string title, LyricsDocument document)
    {
        string phrase = Normalized(title);
        if (phrase.Length == 0 || phrase.EnumerateRunes().Count() > MaximumMetadataCharacters) return false;
        int cjk = phrase.EnumerateRunes().Count(IsCjk);
        int words = Words.Matches(phrase).Count(match => match.Value.EnumerateRunes().Any(rune => Rune.IsLetter(rune) && !IsCjk(rune))
            && !match.Value.EnumerateRunes().Any(IsCjk));
        if (words < 2 && cjk < 4) return false;
        foreach (var line in document.Lines.Where(line => line.TimeMs != null))
            foreach (string source in new[] { line.Text }.Concat(line.Translation?.Split('\n') ?? []))
            {
                string row = Normalized(source); int start = 0;
                while (start < row.Length)
                {
                    int match = row.IndexOf(phrase, start, StringComparison.Ordinal); if (match < 0) break;
                    if (HasBoundaries(row, match, phrase)) return true;
                    start = match + (char.IsHighSurrogate(row[match]) ? 2 : 1);
                }
            }
        return false;
    }
    private static bool HasBoundaries(string row, int start, string phrase)
    {
        int end = start + phrase.Length;
        Rune first = Rune.GetRuneAt(phrase, 0), last = Rune.GetRuneAt(phrase, char.IsLowSurrogate(phrase[^1]) ? phrase.Length - 2 : phrase.Length - 1);
        if (IsWord(first) && !IsCjk(first) && start > 0)
        {
            int previous = start - (char.IsLowSurrogate(row[start - 1]) ? 2 : 1);
            if (IsWord(Rune.GetRuneAt(row, previous))) return false;
            if (IsConnector(row[previous]) && previous > 0 && IsWord(Rune.GetRuneAt(row, previous - (char.IsLowSurrogate(row[previous - 1]) ? 2 : 1)))) return false;
        }
        if (IsWord(last) && !IsCjk(last) && end < row.Length)
        {
            if (IsWord(Rune.GetRuneAt(row, end))) return false;
            if (IsConnector(row[end]) && end + 1 < row.Length && IsWord(Rune.GetRuneAt(row, end + 1))) return false;
        }
        return true;
    }
    private static bool IsWord(Rune rune) => rune.Value == '_' || Rune.IsLetterOrDigit(rune)
        || Rune.GetUnicodeCategory(rune) is UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark;
    private static bool IsConnector(char value) => value is '-' or '\'';
    private static bool IsDelimiter(char value) => value is '-' or '–' or '—';
    private static bool IsCjk(Rune rune) => rune.Value is >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF
        or >= 0xF900 and <= 0xFAFF or >= 0x20000 and <= 0x323AF or >= 0x3040 and <= 0x30FF
        or >= 0x31F0 and <= 0x31FF or >= 0xAC00 and <= 0xD7AF;
    private static string Trim(string value)
    {
        int first = 0, last = value.Length;
        while (first < last && (char.IsWhiteSpace(value[first]) || value[first] == '\uFEFF')) first++;
        while (last > first && (char.IsWhiteSpace(value[last - 1]) || value[last - 1] == '\uFEFF')) last--;
        return value[first..last];
    }
    private static string Normalized(string value) => Whitespace.Replace(Trim(value).Normalize(NormalizationForm.FormKC).Replace('’', '\'').ToLowerInvariant(), " ");
    private static bool Equivalent(string left, string right) => Normalized(left) == Normalized(right);
    private static bool InvalidUtf16(string value)
    {
        for (int i = 0; i < value.Length; i++)
            if (char.IsHighSurrogate(value[i])) { if (++i == value.Length || !char.IsLowSurrogate(value[i])) return true; }
            else if (char.IsLowSurrogate(value[i])) return true;
        return false;
    }
}

/// <summary>One transient result avoids parsing the same lyric source on UI/timeline ticks.</summary>
public sealed class DisplayMetadataCache
{
    private (string Title, string Artist, string Album, string Lyrics)? previous;
    private DisplayMetadata? result;
    public DisplayMetadata Resolve(string title, string artist, string album, string lyricsText)
    {
        var input = (title, artist, album, lyricsText);
        if (previous == input && result != null) return result;
        var resolved = DisplayMetadataResolver.Resolve(title, artist, album, lyricsText);
        previous = input; result = resolved; return resolved;
    }
    public void Reset() { previous = null; result = null; }
}
