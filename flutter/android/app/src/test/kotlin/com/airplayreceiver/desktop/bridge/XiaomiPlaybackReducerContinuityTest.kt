package com.airplayreceiver.desktop.bridge

import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class XiaomiPlaybackReducerContinuityTest {
    @Test
    fun resumedSessionMergesPartialMetadataWithPreviousArtwork() {
        val reducer = XiaomiPlaybackReducer()
        reducer.reduce(playbackEvent(session = 1, sequence = 1, active = true, rawState = 2))
        reducer.reduce(
            mediaEvent(
                session = 1,
                sequence = 2,
                title = "Song",
                trackId = "track-1",
                artwork = "https://example.test/cover.webp",
            ),
        )
        reducer.reduce(playbackEvent(session = 1, sequence = 3, active = false, rawState = 3))

        val resumed = reducer.reduce(
            playbackEvent(session = 2, sequence = 4, active = true, rawState = 2),
        )
        val activation = resumed.mutations.single() as XiaomiPlaybackMutation.Activate
        assertTrue(activation.newSession)

        val metadata = reducer.reduce(
            mediaEvent(
                session = 2,
                sequence = 5,
                title = "Song",
                trackId = "track-1",
                artwork = null,
            ),
        )
        val applied = metadata.mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo

        assertFalse(applied.replaceTrack)
        assertEquals("https://example.test/cover.webp", applied.mediaInfo.artworkUrl)
    }

    @Test
    fun mediaInfoPreservesOfficialTrackChangeDirectionType() {
        val reducer = XiaomiPlaybackReducer()
        reducer.reduce(playbackEvent(session = 1, sequence = 1, active = true, rawState = 2))

        val metadata = reducer.reduce(
            mediaEvent(
                session = 1,
                sequence = 2,
                title = "Previous song",
                trackId = "track-previous",
                artwork = null,
                metadataChangeType = 2,
            ),
        )
        val applied = metadata.mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo

        assertEquals(2, applied.mediaInfo.metadataChangeType)
    }

    @Test
    fun lyricsWaitForAnAcceptedSessionAndDoNotReplayAfterReplacement() {
        val reducer = XiaomiPlaybackReducer()
        val lyrics = "[00:01.00]One line"
        val first = mediaEvent(1, 1, "Song", "track-1", null, lyricsText = lyrics)
        assertEquals(XiaomiReductionOutcome.CACHED, reducer.reduce(first).outcome)
        val activated = reducer.reduce(playbackEvent(1, 2, active = true, rawState = 2))
        val cached = activated.mutations.filterIsInstance<XiaomiPlaybackMutation.ApplyMediaInfo>().single()
        assertEquals(lyrics, cached.mediaInfo.lyricsText)

        val duplicate = reducer.reduce(mediaEvent(1, 3, "Song", "track-1", null, lyricsText = lyrics))
        assertNull((duplicate.mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo).mediaInfo.lyricsText)
        assertEquals(XiaomiReductionOutcome.IGNORED, reducer.reduce(first).outcome)

        val replacement = reducer.reduce(mediaEvent(1, 4, "Next", "track-2", null))
        val applied = replacement.mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertTrue(applied.replaceTrack)
        assertNull(applied.mediaInfo.lyricsText)
    }

    @Test
    fun oversizedLyricsAndProgressLyricsAreIgnored() {
        val large = "词".repeat(100_000)
        val oversized = mediaEvent(1, 1, "Song", "track", null, lyricsText = large)
        assertNull(oversized.toMediaInfoOrNull()?.lyricsText)
        val small = mediaEvent(1, 2, "Song", "track", null, lyricsText = "[00:01]Example")
        assertNull(small.copy(eventName = "progress").toMediaInfoOrNull()?.lyricsText)
    }

    @Test
    fun trackIdSourceIsForwardedOnlyAsMetadataEvidence() {
        val reducer = XiaomiPlaybackReducer()
        reducer.reduce(playbackEvent(session = 1, sequence = 1, active = true, rawState = 2))
        val mapping = mediaEvent(1, 2, "Caption", "metadata:caption", null, trackIdSource = "metadata")
        val caption = reducer.reduce(mapping).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertEquals("metadata", caption.mediaInfo.trackIdSource)

        val progress = mapping.copy(
            eventName = "progress",
            payload = buildJsonObject { put("position_ms", JsonPrimitive(75_000)) },
            bridgeSequence = 3,
        )
        val tick = reducer.reduce(progress).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertEquals("metadata:caption", tick.mediaInfo.trackId)
        assertNull(tick.mediaInfo.trackIdSource)
    }

    @Test
    fun captionRefreshRetainsTrackMetadataAndOnlyPublishesFreshPositions() {
        val reducer = XiaomiPlaybackReducer(nowMillis = { 10_000 })
        val cover = "https://example.test/cover.webp"
        val lyrics = "[ti:Song]\n[00:31]First caption\n[00:37]Second caption"
        reducer.reduce(playbackEvent(session = 1, sequence = 1, active = true, rawState = 2))
        reducer.reduce(
            mediaEvent(1, 2, "Song", "stable-id", cover, lyricsText = lyrics, trackIdSource = "explicit",
                positionMs = 30_000, durationMs = 180_000),
        )

        val first = reducer.reduce(
            mediaEvent(1, 3, "First caption", "metadata:caption-1", null, trackIdSource = "metadata"),
        ).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertFalse(first.replaceTrack)
        assertEquals("stable-id", first.mediaInfo.trackId)
        assertEquals("First caption", first.mediaInfo.title)
        assertEquals(180_000L, first.mediaInfo.durationMs)
        assertEquals(cover, first.mediaInfo.artworkUrl)
        assertNull(first.mediaInfo.lyricsText)
        assertNull(first.mediaInfo.positionMs)

        val second = reducer.reduce(
            mediaEvent(1, 4, "Second caption", null, null, positionMs = 37_000),
        ).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertFalse(second.replaceTrack)
        assertEquals("stable-id", second.mediaInfo.trackId)
        assertEquals("Second caption", second.mediaInfo.title)
        assertEquals(37_000L, second.mediaInfo.positionMs)
        assertNull(second.mediaInfo.lyricsText)

        reducer.beginSeek(55_000)
        val duringSeek = reducer.reduce(
            mediaEvent(1, 5, "First caption", "stable-id", null, trackIdSource = "explicit"),
        ).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertFalse(duringSeek.replaceTrack)
        assertNull(duringSeek.mediaInfo.positionMs)

        val staleSample = reducer.reduce(progressEvent(1, 6, 37_500)).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertNull(staleSample.mediaInfo.positionMs)
        val acknowledgement = reducer.reduce(progressEvent(1, 7, 55_400)).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertEquals(55_400L, acknowledgement.mediaInfo.positionMs)
    }

    @Test
    fun sameExplicitIdKeepsTrackWhenSenderAlternatesTitleAndTimedCaption() {
        val reducer = XiaomiPlaybackReducer()
        val lyrics = "[ti:Song]\n[00:01]Caption"
        reducer.reduce(playbackEvent(1, 1, active = true, rawState = 2))
        reducer.reduce(mediaEvent(1, 2, "Song", "stable-id", null, lyricsText = lyrics, trackIdSource = "explicit", positionMs = 1000))

        for ((sequence, title) in listOf(3L to "Caption", 4L to "Song")) {
            val update = reducer.reduce(mediaEvent(1, sequence, title, "stable-id", null, trackIdSource = "explicit"))
                .mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
            assertFalse(update.replaceTrack)
            assertEquals("stable-id", update.mediaInfo.trackId)
            assertNull(update.mediaInfo.positionMs)
        }
    }

    @Test
    fun equivalentLyricsAndCanonicalTitleKeepAnchorAcrossIdentityPromotion() {
        val reducer = XiaomiPlaybackReducer()
        val lyrics = "[ti:Song]\n[00:01.00]Caption\n[00:02]Second line"
        val reformattedLyrics = "[ti:Song]\r\n[00:01.000]Caption\r\n[00:02.00]Second line"
        reducer.reduce(playbackEvent(1, 1, active = true, rawState = 2))
        reducer.reduce(mediaEvent(1, 2, "Song", "lyrics:one", null, lyricsText = lyrics, trackIdSource = "lyrics"))

        val refreshed = reducer.reduce(
            mediaEvent(1, 3, "Caption", "metadata:song-header", null, lyricsText = reformattedLyrics, trackIdSource = "lyrics_metadata"),
        ).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertFalse(refreshed.replaceTrack)
        assertEquals("lyrics:one", refreshed.mediaInfo.trackId)

        val canonical = reducer.reduce(
            mediaEvent(1, 4, "Song", "metadata:song", null, trackIdSource = "metadata"),
        ).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertFalse(canonical.replaceTrack)
        assertEquals("lyrics:one", canonical.mediaInfo.trackId)

        val promoted = reducer.reduce(
            mediaEvent(1, 5, "Song", "sender-id", null, trackIdSource = "explicit"),
        ).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertFalse(promoted.replaceTrack)
        assertEquals("lyrics:one", promoted.mediaInfo.trackId)

        val replacement = reducer.reduce(
            mediaEvent(1, 6, "Song", "different-sender-id", null, lyricsText = lyrics, trackIdSource = "explicit", positionMs = 0),
        ).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertTrue(replacement.replaceTrack)
        assertEquals("different-sender-id", replacement.mediaInfo.trackId)
        assertEquals(0L, replacement.mediaInfo.positionMs)
    }

    @Test
    fun sameTrackMetadataZeroCannotRewindPlaybackOrConfirmZeroSeek() {
        val reducer = XiaomiPlaybackReducer(nowMillis = { 10_000 })
        reducer.reduce(playbackEvent(1, 1, active = true, rawState = 2))
        val first = reducer.reduce(mediaEvent(1, 2, "Song", "one", null, positionMs = 0))
            .mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertEquals(0L, first.mediaInfo.positionMs)

        val placeholder = reducer.reduce(mediaEvent(1, 3, "Song", "one", null, positionMs = 0), displayedPositionMs = 2500)
            .mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertNull(placeholder.mediaInfo.positionMs)
        reducer.reduce(progressEvent(1, 4, 18_000))
        val wireAdvancePlaceholder = reducer.reduce(mediaEvent(1, 5, "Song", "one", null, positionMs = 0))
            .mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertNull(wireAdvancePlaceholder.mediaInfo.positionMs)

        reducer.beginSeek(0)
        val seekPlaceholder = reducer.reduce(mediaEvent(1, 6, "Song", "one", null, positionMs = 0))
            .mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertNull(seekPlaceholder.mediaInfo.positionMs)
        val stale = reducer.reduce(progressEvent(1, 7, 18_500)).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertNull(stale.mediaInfo.positionMs)
        val realZero = reducer.reduce(progressEvent(1, 8, 0)).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertEquals(0L, realZero.mediaInfo.positionMs)
        val resumed = reducer.reduce(progressEvent(1, 9, 3500)).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertEquals(3500L, resumed.mediaInfo.positionMs)
    }

    @Test
    fun pendingMetadataZeroDoesNotOverwriteCachedProgress() {
        val reducer = XiaomiPlaybackReducer()
        reducer.reduce(mediaEvent(1, 1, "Song", "one", null, positionMs = 6000))
        reducer.reduce(mediaEvent(1, 2, "Song", "one", null, positionMs = 0))
        val resumed = reducer.reduce(playbackEvent(1, 3, active = true, rawState = 2))
            .mutations.filterIsInstance<XiaomiPlaybackMutation.ApplyMediaInfo>().single()
        assertEquals(6000L, resumed.mediaInfo.positionMs)

        reducer.reduce(mediaEvent(2, 4, "Next", "two", null, positionMs = 4000))
        reducer.reduce(progressEvent(2, 5, 0))
        val next = reducer.reduce(playbackEvent(2, 6, active = true, rawState = 2))
            .mutations.filterIsInstance<XiaomiPlaybackMutation.ApplyMediaInfo>().single()
        assertEquals(0L, next.mediaInfo.positionMs)
    }

    @Test
    fun actualTrackChangesDiscardCaptionContinuity() {
        val lyrics = "[ti:Song]\n[00:01]Shared lyric line"
        for ((trackId, source, newLyrics) in listOf(
            Triple("another-id", "explicit", null),
            Triple("metadata:another-song", "metadata", "[ti:Another Song]\n[00:41]Another lyric"),
        )) {
            val reducer = XiaomiPlaybackReducer()
            reducer.reduce(playbackEvent(session = 1, sequence = 1, active = true, rawState = 2))
            reducer.reduce(
                mediaEvent(1, 2, "Song", "stable-id", "https://example.test/cover.webp",
                    lyricsText = lyrics, trackIdSource = "explicit", durationMs = 180_000),
            )
            val next = reducer.reduce(
                mediaEvent(1, 3, "Shared lyric line", trackId, null, lyricsText = newLyrics, trackIdSource = source),
            ).mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
            assertTrue(next.replaceTrack)
            assertEquals(trackId, next.mediaInfo.trackId)
            assertEquals(newLyrics, next.mediaInfo.lyricsText)
            assertNull(next.mediaInfo.durationMs)
            assertNull(next.mediaInfo.artworkUrl)
        }
    }

    @Test
    fun confirmedCaptionKeepsArtworkDurationAndPendingSeek() {
        val reducer = XiaomiPlaybackReducer(nowMillis = { 0L })
        reducer.reduce(playbackEvent(session = 1, sequence = 1, active = true, rawState = 2))
        reducer.reduce(
            mediaEvent(
                session = 1,
                sequence = 2,
                title = "Song",
                trackId = "metadata:track-1",
                artwork = "https://example.test/cover.webp",
                durationMs = 180_000,
                positionMs = 10_000,
            ),
        )
        reducer.beginSeek(positionMs = 70_000)

        val update = reducer.reduce(
            mediaEvent(
                session = 1,
                sequence = 3,
                title = "word",
                trackId = "metadata:track-1",
                artwork = null,
                trackTransition = "same",
                titleIsLyric = true,
                positionMs = 11_000,
            ),
        )
        val applied = update.mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo

        assertFalse(applied.replaceTrack)
        assertEquals("word", applied.mediaInfo.title)
        assertEquals("metadata:track-1", applied.mediaInfo.trackId)
        assertEquals("https://example.test/cover.webp", applied.mediaInfo.artworkUrl)
        assertEquals(180_000L, applied.mediaInfo.durationMs)
        assertNull(applied.mediaInfo.positionMs)

        val acknowledgement = reducer.reduce(progressEvent(1, 4, 70_200))
            .mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertEquals(70_200L, acknowledgement.mediaInfo.positionMs)

        val replacement = reducer.reduce(
            mediaEvent(
                session = 1,
                sequence = 5,
                title = "Next song",
                trackId = "metadata:track-1",
                artwork = null,
                trackTransition = "new",
            ),
        )
        val newTrack = replacement.mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertTrue(newTrack.replaceTrack)
    }

    @Test
    fun onlyConfirmedMatchingIdentitySuppressesTitleBasedReplacement() {
        val fallbackCases = listOf(
            null to "metadata:track-1",
            "new" to "metadata:track-1",
            "unrecognized" to "metadata:track-1",
            "same" to "metadata:track-2",
            "same" to null,
            "same" to " ",
        )
        for ((transition, trackId) in fallbackCases) {
            val reducer = XiaomiPlaybackReducer()
            reducer.reduce(playbackEvent(session = 1, sequence = 1, active = true, rawState = 2))
            reducer.reduce(
                mediaEvent(
                    session = 1,
                    sequence = 2,
                    title = "Song",
                    trackId = "metadata:track-1",
                    artwork = "https://example.test/cover.webp",
                ),
            )
            val update = reducer.reduce(
                mediaEvent(
                    session = 1,
                    sequence = 3,
                    title = "word",
                    trackId = trackId,
                    artwork = null,
                    trackTransition = transition,
                ),
            )
            val applied = update.mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo

            assertTrue("transition=$transition, trackId=$trackId", applied.replaceTrack)
            assertEquals(null, applied.mediaInfo.artworkUrl)
        }
    }

    @Test
    fun confirmedMatchingTrackMayUpdateArtistAndAlbumWithoutReplacement() {
        for (titleIsLyric in listOf(true, false)) {
            val reducer = XiaomiPlaybackReducer()
            reducer.reduce(playbackEvent(session = 1, sequence = 1, active = true, rawState = 2))
            reducer.reduce(
                mediaEvent(
                    session = 1,
                    sequence = 2,
                    title = "Song",
                    trackId = "metadata:track-1",
                    artwork = "https://example.test/cover.webp",
                    artist = "Artist",
                    album = "Album",
                ),
            )
            val update = reducer.reduce(
                mediaEvent(
                    session = 1,
                    sequence = 3,
                    title = "word",
                    trackId = "metadata:track-1",
                    artwork = null,
                    artist = "Song - Artist",
                    album = "Song - Album",
                    trackTransition = "same",
                    titleIsLyric = titleIsLyric,
                ),
            )
            val applied = update.mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo

            assertFalse(applied.replaceTrack)
            assertEquals("Song - Artist", applied.mediaInfo.artist)
            assertEquals("Song - Album", applied.mediaInfo.album)
            assertEquals("https://example.test/cover.webp", applied.mediaInfo.artworkUrl)
        }
    }

    private fun playbackEvent(
        session: Long,
        sequence: Long,
        active: Boolean,
        rawState: Int,
    ): WindowsBridgeXiaomiEvent = WindowsBridgeXiaomiEvent(
        eventName = "playback_state",
        payload = buildJsonObject {
            put("session_active", JsonPrimitive(active))
            put("raw_state", JsonPrimitive(rawState))
        },
        bridgeSequence = sequence,
        sessionSequence = session,
        rawJson = "{}",
    )

    private fun progressEvent(session: Long, sequence: Long, positionMs: Long): WindowsBridgeXiaomiEvent =
        WindowsBridgeXiaomiEvent(
            eventName = "progress",
            payload = buildJsonObject { put("position_ms", JsonPrimitive(positionMs)) },
            bridgeSequence = sequence,
            sessionSequence = session,
            rawJson = "{}",
        )

    private fun mediaEvent(
        session: Long,
        sequence: Long,
        title: String,
        trackId: String?,
        artwork: String?,
        metadataChangeType: Int? = null,
        lyricsText: String? = null,
        trackIdSource: String? = null,
        positionMs: Long? = null,
        durationMs: Long? = null,
        trackTransition: String? = null,
        artist: String? = null,
        album: String? = null,
        titleIsLyric: Boolean? = null,
    ): WindowsBridgeXiaomiEvent = WindowsBridgeXiaomiEvent(
        eventName = "media_info",
        payload = buildJsonObject {
            put("title", JsonPrimitive(title))
            trackId?.let { put("track_id", JsonPrimitive(it)) }
            artwork?.let { put("artwork_url", JsonPrimitive(it)) }
            metadataChangeType?.let {
                put("metadata_change_type", JsonPrimitive(it))
            }
            lyricsText?.let { put("lyrics_text", JsonPrimitive(it)) }
            trackIdSource?.let { put("track_id_source", JsonPrimitive(it)) }
            positionMs?.let { put("position_ms", JsonPrimitive(it)) }
            durationMs?.let { put("duration_ms", JsonPrimitive(it)) }
            trackTransition?.let { put("track_transition", JsonPrimitive(it)) }
            artist?.let { put("artist", JsonPrimitive(it)) }
            album?.let { put("album", JsonPrimitive(it)) }
            titleIsLyric?.let { put("title_is_lyric", JsonPrimitive(it)) }
        },
        bridgeSequence = sequence,
        sessionSequence = session,
        rawJson = "{}",
    )
}
