package com.airplayreceiver.desktop.backend

import java.util.Base64
import java.util.Locale

internal const val XIAOMI_PROTOCOL = "小米妙播"
internal const val XIAOMI_PLACEHOLDER_TITLE = "小米妙播音频"

private const val MAXIMUM_XIAOMI_ARTWORK_ENCODED_CHARACTERS =
    22 * 1024 * 1024

/**
 * Xiaomi's mArt field is commonly a MIME-less, line-wrapped Base64 WebP.
 * Convert that wire representation into a data URI once at the reducer
 * boundary so both the Android artwork loader and Windows SMTC consume the
 * same safe source instead of attempting to parse the payload as a file path.
 */
internal fun normalizeXiaomiArtworkSource(value: String?): String? {
    val source = value?.trim()?.takeIf(String::isNotEmpty) ?: return null
    if (
        source.startsWith("data:", ignoreCase = true) ||
        source.startsWith("http://", ignoreCase = true) ||
        source.startsWith("https://", ignoreCase = true) ||
        source.startsWith("file:", ignoreCase = true)
    ) {
        return source
    }

    val encoded = source.filterNot(Char::isWhitespace)
    if (
        encoded.length !in 16..MAXIMUM_XIAOMI_ARTWORK_ENCODED_CHARACTERS ||
        encoded.length % 4 != 0 ||
        encoded.any { character ->
            !character.isLetterOrDigit() &&
                character != '+' &&
                character != '/' &&
                character != '='
        }
    ) {
        return source
    }

    val bytes = runCatching {
        Base64.getDecoder().decode(encoded)
    }.getOrNull() ?: return source
    val mimeType = when {
        bytes.size >= 3 &&
            bytes[0] == 0xFF.toByte() &&
            bytes[1] == 0xD8.toByte() &&
            bytes[2] == 0xFF.toByte() -> "image/jpeg"

        bytes.size >= 8 &&
            bytes.copyOfRange(0, 8).contentEquals(
                byteArrayOf(
                    0x89.toByte(), 0x50, 0x4E, 0x47,
                    0x0D, 0x0A, 0x1A, 0x0A,
                ),
            ) -> "image/png"

        bytes.size >= 12 &&
            bytes.copyOfRange(0, 4).contentEquals("RIFF".encodeToByteArray()) &&
            bytes.copyOfRange(8, 12).contentEquals("WEBP".encodeToByteArray()) ->
            "image/webp"

        else -> return source
    }
    return "data:$mimeType;base64,$encoded"
}

internal fun PlaybackSnapshot.activateXiaomi(
    sourceName: String?,
    newSession: Boolean,
    rawState: Int?,
): PlaybackSnapshot {
    val alreadyActive = protocol.equals(
        XIAOMI_PROTOCOL,
        ignoreCase = true,
    )
    if (alreadyActive) {
        val updatedArtist = if (
            title == XIAOMI_PLACEHOLDER_TITLE ||
            (newSession && artist.isNullOrBlank())
        ) {
            sourceName
                ?.takeIf(String::isNotBlank)
                ?.let { "来自 $it" }
                ?: artist
        } else {
            artist
        }
        return copy(
            artist = updatedArtist,
            isPlaying = xiaomiPlayingForRawState(
                rawState = rawState,
                fallback = isPlaying,
            ),
            streamActive = true,
            // A resumed route can be reported as a replacement session before
            // HyperOS republishes metadata. Keep the previous visual snapshot
            // during that gap so the artwork background does not flash to the
            // default colour.
        )
    }

    return PlaybackSnapshot(
        title = XIAOMI_PLACEHOLDER_TITLE,
        artist = sourceName
            ?.takeIf(String::isNotBlank)
            ?.let { "来自 $it" }
            ?: XIAOMI_PROTOCOL,
        protocol = XIAOMI_PROTOCOL,
        isPlaying = xiaomiPlayingForRawState(
            rawState = rawState,
            fallback = true,
        ),
        streamActive = true,
        sourceEpoch = sourceEpoch.takeIf { alreadyActive },
    )
}

internal fun xiaomiPlayingForRawState(
    rawState: Int?,
    fallback: Boolean,
): Boolean = when (rawState) {
    null -> fallback
    2 -> true
    else -> false
}

/**
 * A connected paused/transitional Xiaomi session should remain visible and
 * controllable when no other source is currently playing. It must not replace
 * a different foreground source which is still producing media.
 */
internal fun shouldExposeConnectedXiaomiSession(
    activeSource: MediaSource?,
    foregroundPlaying: Boolean,
): Boolean =
    activeSource == null ||
        activeSource == MediaSource.XIAOMI_MIPLAY ||
        !foregroundPlaying

internal fun PlaybackSnapshot.applyXiaomiMediaInfo(
    trackId: String? = null,
    title: String?,
    artist: String?,
    album: String?,
    artworkUrl: String?,
    durationMs: Long?,
    positionMs: Long?,
    replaceTrack: Boolean,
    codec: String? = null,
    bitrateBps: Long? = null,
    sampleRate: Int? = null,
    bitsPerSample: Int? = null,
    channels: Int? = null,
    lyrics: LyricsDocument? = null,
    lyricHeaders: PlaybackDisplayMetadata? = null,
    titleIsLyric: Boolean? = null,
    trackIdSource: String? = null,
): PlaybackSnapshot {
    if (!protocol.equals(XIAOMI_PROTOCOL, ignoreCase = true)) {
        return this
    }

    val normalizedTitle = title?.trim()?.takeIf(String::isNotEmpty)
    val normalizedTrackId = trackId?.trim()?.takeIf(String::isNotEmpty)
    val normalizedArtist = artist?.trim()?.takeIf(String::isNotEmpty)
    val normalizedAlbum = album?.trim()?.takeIf(String::isNotEmpty)
    val normalizedArtwork = normalizeXiaomiArtworkSource(artworkUrl)
    val incomingQuality = xiaomiQualityText(
        codec = codec,
        bitrateBps = bitrateBps,
        sampleRate = sampleRate,
        bitsPerSample = bitsPerSample,
        channels = channels,
    )
    val effectiveDuration = durationMs
        ?.takeIf { it > 0L }
        ?: this.durationMs.takeUnless { replaceTrack }
    val effectivePosition = positionMs
        ?.coerceAtLeast(0L)
        ?.let { position ->
            effectiveDuration
                ?.let { position.coerceAtMost(it) }
                ?: position
        }
        ?: this.positionMs.takeUnless { replaceTrack }
        ?: 0L

    val effectiveTitle = normalizedTitle ?: this.title.takeUnless { replaceTrack } ?: XIAOMI_PLACEHOLDER_TITLE
    val effectiveArtist = normalizedArtist ?: this.artist.takeUnless { replaceTrack }
    val effectiveAlbum = normalizedAlbum ?: this.album.takeUnless { replaceTrack }
    // The transport still uses its existing track boundary and raw labels.
    // The SDK hashes metadata when the sender omits its audio ID. A caption
    // then gets a fresh synthetic ID. Require an exact match in the cached
    // timed lyrics before keeping presentation evidence across that boundary.
    val positionForCorrection = positionMs?.takeIf { it >= 0L }
        ?: this.positionMs.takeUnless { replaceTrack }
    val newHeaderTitle = lyricHeaders?.title
    val previousHeaderTitle = this.lyricHeaders?.title
    val conflictingHeaders = newHeaderTitle != null && previousHeaderTitle != null && !sameLabel(newHeaderTitle, previousHeaderTitle)
    val sameTrackCaption = replaceTrack && normalizedTrackId != null && normalizedTrackId == trackIdentity && !conflictingHeaders &&
        (titleIsLyric == true || (lyrics ?: this.lyrics).matchesTitleCaption(normalizedTitle, positionMs))
    val fallbackIdentity = trackIdSource != "explicit" && (normalizedTrackId == null ||
        (trackIdSource == "metadata" && normalizedTrackId.startsWith("metadata:")))
    val compatibleLyrics = (lyrics == null && lyricHeaders == null) ||
        (lyrics == this.lyrics && lyricHeaders == this.lyricHeaders)
    val fallbackCaption = replaceTrack && fallbackIdentity && compatibleLyrics &&
        this.lyrics.containsExactTimedCaption(normalizedTitle)
    val previousPresentation = takeIf { !replaceTrack || sameTrackCaption || fallbackCaption }
    val nextLyrics = lyrics ?: previousPresentation?.lyrics
    val nextHeaders = lyricHeaders ?: previousPresentation?.lyricHeaders
    val nextHint = titleIsLyric ?: previousPresentation?.lyricCaptionHint.takeIf { effectiveTitle == this.title }
    val labelsChanged = replaceTrack || lyrics != null || lyricHeaders != null ||
        nextHint != lyricCaptionHint || effectiveTitle != this.title || effectiveArtist != this.artist || effectiveAlbum != this.album
    val correction = if (labelsChanged) {
        resolveLyricTitleCorrection(
            title = effectiveTitle.takeUnless { it == XIAOMI_PLACEHOLDER_TITLE },
            artist = effectiveArtist,
            album = effectiveAlbum,
            explicitCaption = nextHint == true,
            positionMs = positionForCorrection,
            lyrics = nextLyrics,
            headers = nextHeaders,
            previous = previousPresentation,
        )
    } else lyricTitleCorrection

    return copy(
        trackIdentity = normalizedTrackId
            ?: this.trackIdentity.takeUnless { replaceTrack },
        title = effectiveTitle,
        artist = effectiveArtist,
        album = effectiveAlbum,
        coverArt = normalizedArtwork
            ?: this.coverArt.takeUnless { replaceTrack },
        durationMs = effectiveDuration,
        positionMs = effectivePosition,
        qualityText = incomingQuality
            ?: this.qualityText.takeUnless { replaceTrack },
        lyrics = nextLyrics,
        lyricHeaders = nextHeaders,
        lyricTitleCorrection = correction,
        lyricCaptionHint = nextHint,
    )
}

internal fun xiaomiQualityText(
    codec: String?,
    bitrateBps: Long?,
    sampleRate: Int?,
    bitsPerSample: Int?,
    channels: Int?,
): String? {
    val parts = buildList {
        codec
            ?.trim()
            ?.takeIf(String::isNotEmpty)
            ?.removePrefix("audio/")
            ?.uppercase(Locale.ROOT)
            ?.let(::add)
        bitsPerSample
            ?.takeIf { it in 1..64 }
            ?.let { add("$it-bit") }
        sampleRate
            ?.takeIf { it in 8_000..768_000 }
            ?.let { rate ->
                add(
                    if (rate % 1_000 == 0) {
                        "${rate / 1_000} kHz"
                    } else {
                        String.format(
                            Locale.ROOT,
                            "%.1f kHz",
                            rate / 1_000.0,
                        )
                    },
                )
            }
        channels
            ?.takeIf { it in 1..32 }
            ?.let { count ->
                add(
                    when (count) {
                        1 -> "单声道"
                        2 -> "立体声"
                        else -> "$count 声道"
                    },
                )
            }
        bitrateBps
            ?.takeIf { it in 8_000L..100_000_000L }
            ?.let { bitrate ->
                add(
                    if (bitrate % 1_000L == 0L) {
                        "${bitrate / 1_000L} kbps"
                    } else {
                        String.format(
                            Locale.ROOT,
                            "%.1f kbps",
                            bitrate / 1_000.0,
                        )
                    },
                )
            }
    }
    return parts.takeIf(List<String>::isNotEmpty)?.joinToString(" · ")
}

internal fun PlaybackSnapshot.advanceXiaomiProgress(
    elapsedMs: Long,
): PlaybackSnapshot {
    if (
        elapsedMs <= 0L ||
        !protocol.equals(XIAOMI_PROTOCOL, ignoreCase = true) ||
        !isPlaying
    ) {
        return this
    }

    val duration = durationMs?.takeIf { it > 0L } ?: return this
    val currentPosition = positionMs.coerceAtLeast(0L)
    if (currentPosition >= duration) {
        return this
    }
    val remaining = duration - currentPosition
    val nextPosition = if (elapsedMs >= remaining) {
        duration
    } else {
        currentPosition + elapsedMs
    }
    return copy(positionMs = nextPosition)
}
