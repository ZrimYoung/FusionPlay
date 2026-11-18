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

    private fun mediaEvent(
        session: Long,
        sequence: Long,
        title: String,
        trackId: String,
        artwork: String?,
        metadataChangeType: Int? = null,
        lyricsText: String? = null,
    ): WindowsBridgeXiaomiEvent = WindowsBridgeXiaomiEvent(
        eventName = "media_info",
        payload = buildJsonObject {
            put("title", JsonPrimitive(title))
            put("track_id", JsonPrimitive(trackId))
            artwork?.let { put("artwork_url", JsonPrimitive(it)) }
            metadataChangeType?.let {
                put("metadata_change_type", JsonPrimitive(it))
            }
            lyricsText?.let { put("lyrics_text", JsonPrimitive(it)) }
        },
        bridgeSequence = sequence,
        sessionSequence = session,
        rawJson = "{}",
    )
}
