package com.airplayreceiver.desktop.bridge

import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    fun confirmedCaptionKeepsArtworkDurationAndPendingSeek() {
        val reducer = XiaomiPlaybackReducer(nowMillis = { 0L })
        reducer.reduce(playbackEvent(session = 1, sequence = 1, active = true, rawState = 2))
        reducer.reduce(
            mediaEvent(
                session = 1,
                sequence = 2,
                title = "Song",
                trackId = "track-1",
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
                trackId = "track-1",
                artwork = null,
                trackTransition = "same",
                positionMs = 11_000,
            ),
        )
        val applied = update.mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo

        assertFalse(applied.replaceTrack)
        assertEquals("word", applied.mediaInfo.title)
        assertEquals("track-1", applied.mediaInfo.trackId)
        assertEquals("https://example.test/cover.webp", applied.mediaInfo.artworkUrl)
        assertEquals(180_000L, applied.mediaInfo.durationMs)
        assertEquals(70_000L, applied.mediaInfo.positionMs)

        val legacyUpdate = reducer.reduce(
            mediaEvent(
                session = 1,
                sequence = 4,
                title = "Next song",
                trackId = "track-1",
                artwork = null,
            ),
        )
        val legacyTrack = legacyUpdate.mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo
        assertTrue(legacyTrack.replaceTrack)
    }

    @Test
    fun onlyConfirmedMatchingIdentitySuppressesTitleBasedReplacement() {
        val fallbackCases = listOf(
            null to "track-1",
            "new" to "track-1",
            "unrecognized" to "track-1",
            "same" to "track-2",
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
                    trackId = "track-1",
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
    fun confirmedLyricMayUpdateArtistAndAlbumWithoutReplacement() {
        for (titleIsLyric in listOf(true, false)) {
            val reducer = XiaomiPlaybackReducer()
            reducer.reduce(playbackEvent(session = 1, sequence = 1, active = true, rawState = 2))
            reducer.reduce(
                mediaEvent(
                    session = 1,
                    sequence = 2,
                    title = "Song",
                    trackId = "track-1",
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
                    trackId = "track-1",
                    artwork = null,
                    artist = "Song - Artist",
                    album = "Song - Album",
                    trackTransition = "same",
                    titleIsLyric = titleIsLyric,
                ),
            )
            val applied = update.mutations.single() as XiaomiPlaybackMutation.ApplyMediaInfo

            assertEquals(!titleIsLyric, applied.replaceTrack)
            assertEquals("Song - Artist", applied.mediaInfo.artist)
            assertEquals("Song - Album", applied.mediaInfo.album)
            assertEquals("https://example.test/cover.webp".takeIf { titleIsLyric }, applied.mediaInfo.artworkUrl)
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

    private fun mediaEvent(
        session: Long,
        sequence: Long,
        title: String,
        trackId: String?,
        artwork: String?,
        metadataChangeType: Int? = null,
        trackTransition: String? = null,
        durationMs: Long? = null,
        positionMs: Long? = null,
        artist: String? = null,
        album: String? = null,
        titleIsLyric: Boolean? = null,
    ): WindowsBridgeXiaomiEvent = WindowsBridgeXiaomiEvent(
        eventName = "media_info",
        payload = buildJsonObject {
            put("title", JsonPrimitive(title))
            trackId?.let { put("track_id", JsonPrimitive(it)) }
            artwork?.let { put("artwork_url", JsonPrimitive(it)) }
            trackTransition?.let { put("track_transition", JsonPrimitive(it)) }
            durationMs?.let { put("duration_ms", JsonPrimitive(it)) }
            positionMs?.let { put("position_ms", JsonPrimitive(it)) }
            artist?.let { put("artist", JsonPrimitive(it)) }
            album?.let { put("album", JsonPrimitive(it)) }
            titleIsLyric?.let { put("title_is_lyric", JsonPrimitive(it)) }
            metadataChangeType?.let {
                put("metadata_change_type", JsonPrimitive(it))
            }
        },
        bridgeSequence = sequence,
        sessionSequence = session,
        rawJson = "{}",
    )
}
