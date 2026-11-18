package com.airplayreceiver.desktop.backend

import java.util.Locale

/** Optional presentation labels. Empty is an intentional fallback, null leaves the original label. */
data class PlaybackDisplayMetadata(val title: String? = null, val artist: String? = null, val album: String? = null)

internal fun PlaybackSnapshot.displayMetadata(correctLyricTitles: Boolean): PlaybackDisplayMetadata {
    val corrected = lyricTitleCorrection.takeIf { correctLyricTitles }
    return PlaybackDisplayMetadata(corrected?.title ?: title, corrected?.artist ?: artist, corrected?.album ?: album)
}

private const val MAX_LABEL_LENGTH = 512
private val header = Regex("^\\[([^:\\]]+):([^\\]]*)\\]")
private val songHeaders = setOf("ti", "ar", "al")
private val whitespace = Regex("\\s+")
private val dashes = setOf('-', '–', '—')

/** Reads [ti], [ar] and [al] from sender-supplied LRC without consulting external sources. */
internal fun parseLrcDisplayHeaders(text: String): PlaybackDisplayMetadata {
    val values = mutableMapOf<String, String>()
    val conflicts = mutableSetOf<String>()
    for (line in text.lineSequence()) {
        var remainder = line.trim().trimStart('\uFEFF')
        while (remainder.startsWith('[')) {
            val match = header.find(remainder) ?: break
            val key = match.groupValues[1].trim().lowercase(Locale.ROOT)
            if (key.firstOrNull()?.isDigit() == true) break
            if (key in songHeaders) {
                val value = match.groupValues[2].trim()
                if (value.length in 1..MAX_LABEL_LENGTH && value.none(Char::isISOControl)) {
                    val previous = values.putIfAbsent(key, value)
                    if (previous != null && !sameLabel(previous, value)) conflicts.add(key)
                }
            }
            remainder = remainder.substring(match.range.last + 1).trimStart()
        }
    }
    fun label(key: String) = values[key].takeUnless { key in conflicts }
    return PlaybackDisplayMetadata(label("ti"), label("ar"), label("al"))
}

/** Extra evidence for captions the native SDK has not already recognized as exact lyric lines. */
internal fun LyricsDocument?.matchesTitleCaption(title: String?, positionMs: Long?): Boolean {
    if (this == null || title.isNullOrBlank() || title.length > MAX_LABEL_LENGTH) return false
    val needle = normalizedLabel(title)
    if (needle.isEmpty()) return false
    val substantial = ' ' in needle || needle.count(Char::isCjk) >= 4
    val activeIndex = positionMs?.let { activeLineIndex((it - 700L).coerceAtLeast(0L)) } ?: 0
    val upperMs = positionMs?.coerceAtMost(Long.MAX_VALUE - 700L)?.plus(700L)
    return lines.withIndex().any { (index, line) ->
        val lineTime = line.startMs ?: return@any false
        val nearPlayback = upperMs != null && index >= activeIndex && lineTime <= upperMs
        line.text.lineSequence().any { text ->
            val row = normalizedLabel(text)
            row == needle || ((substantial || nearPlayback) && containsWords(row, needle))
        }
    }
}

internal fun LyricsDocument?.containsExactTimedCaption(title: String?): Boolean {
    if (this == null || title.isNullOrBlank() || title.length > MAX_LABEL_LENGTH) return false
    return lines.any { line ->
        line.startMs != null && line.text.lineSequence().any { it.trim() == title }
    }
}

internal fun resolveLyricTitleCorrection(
    title: String?,
    artist: String?,
    album: String?,
    explicitCaption: Boolean,
    positionMs: Long?,
    lyrics: LyricsDocument?,
    headers: PlaybackDisplayMetadata?,
    previous: PlaybackSnapshot?,
): PlaybackDisplayMetadata {
    val composite = recoverCompositeArtist(artist, headers?.title, headers?.artist, album, headers?.album)
    val headerTitle = headers?.title ?: composite?.first
    val verifiedPreviousTitle = previous?.lyricTitleCorrection?.title?.takeIf(String::isNotBlank)
    val previousRegularTitle = previous?.takeIf { it.lyricCaptionHint != true && it.lyricTitleCorrection?.title == null }
        ?.title?.takeUnless { it == XIAOMI_PLACEHOLDER_TITLE }
    // The SDK can mark its raw title as a caption even when it already recovered
    // the actual song title sent to Kotlin. Don't blank that known label.
    val alreadyRecovered = explicitCaption && sameLabel(title, previousRegularTitle) &&
        !lyrics.matchesTitleCaption(previousRegularTitle, positionMs)
    val agreesWithTitle = sameLabel(title, headerTitle) || sameLabel(title, verifiedPreviousTitle) || alreadyRecovered
    val caption = !agreesWithTitle && (explicitCaption || lyrics.matchesTitleCaption(title, positionMs))
    val correctedTitle = when {
        !headerTitle.isNullOrBlank() && (title.isNullOrBlank() || caption || agreesWithTitle) -> headerTitle
        alreadyRecovered -> previousRegularTitle
        caption -> verifiedPreviousTitle ?: previousRegularTitle?.takeUnless { lyrics.matchesTitleCaption(it, positionMs) }.orEmpty()
        else -> null
    }
    val resolvedTitle = correctedTitle ?: title
    val previousArtist = (previous?.lyricTitleCorrection?.artist ?: previous?.artist)
        .takeIf { (caption || alreadyRecovered) && artist.isNullOrBlank() }
    val previousAlbum = (previous?.lyricTitleCorrection?.album ?: previous?.album)
        .takeIf { (caption || alreadyRecovered) && album.isNullOrBlank() }
    return PlaybackDisplayMetadata(
        title = correctedTitle,
        artist = composite?.second?.takeIf { sameLabel(composite.first, resolvedTitle) }
            ?: headers?.artist?.takeIf { caption || artist.isNullOrBlank() }
            ?: previousArtist,
        album = headers?.album?.takeIf { caption || album.isNullOrBlank() } ?: previousAlbum,
    )
}

private fun recoverCompositeArtist(
    artist: String?, titleHeader: String?, artistHeader: String?, album: String?, albumHeader: String?,
): Pair<String, String>? {
    if (artist.isNullOrBlank() || artist.length > MAX_LABEL_LENGTH || (titleHeader == null && artistHeader == null)) return null
    val variants = listOfNotNull(artist, artist.stripSuffix(album), artist.stripSuffix(albumHeader)).distinct()
    val matches = variants.mapNotNull { source ->
        source.indices.firstNotNullOfOrNull { index ->
            if (source[index] !in dashes) return@firstNotNullOfOrNull null
            val title = source.substring(0, index).trim()
            val performer = source.substring(index + 1).trim()
            if (title.isEmpty() || performer.isEmpty()) return@firstNotNullOfOrNull null
            if (titleHeader != null && !sameLabel(title, titleHeader)) return@firstNotNullOfOrNull null
            if (artistHeader != null && !sameLabel(performer, artistHeader)) return@firstNotNullOfOrNull null
            Pair(titleHeader ?: title, artistHeader ?: performer)
        }
    }
    val candidate = matches.firstOrNull() ?: return null
    return candidate.takeIf { matches.all { (title, performer) ->
        sameLabel(title, candidate.first) && sameLabel(performer, candidate.second)
    } }
}

private fun String.stripSuffix(expected: String?): String? {
    if (expected.isNullOrBlank()) return null
    return indices.reversed().firstNotNullOfOrNull { index ->
        if (this[index] in dashes && sameLabel(substring(index + 1), expected)) {
            substring(0, index).trim().takeIf(String::isNotEmpty)
        } else null
    }
}

private fun normalizedLabel(value: String): String =
    value.trim().replace(whitespace, " ").replace('’', '\'').lowercase(Locale.ROOT)

internal fun sameLabel(first: String?, second: String?): Boolean =
    !first.isNullOrBlank() && !second.isNullOrBlank() && normalizedLabel(first) == normalizedLabel(second)

private fun Char.isCjk(): Boolean = code in 0x3400..0x9FFF || code in 0xF900..0xFAFF ||
    code in 0x3040..0x31FF || code in 0xAC00..0xD7AF

private fun Char.isWordChar(): Boolean = (isLetterOrDigit() || this in "_-'") && !isCjk()

private fun containsWords(row: String, needle: String): Boolean {
    var start = row.indexOf(needle)
    while (start >= 0) {
        val end = start + needle.length
        val left = needle.first().isWordChar() && row.getOrNull(start - 1)?.isWordChar() == true
        val right = needle.last().isWordChar() && row.getOrNull(end)?.isWordChar() == true
        if (!left && !right) return true
        start = row.indexOf(needle, start + 1)
    }
    return false
}
