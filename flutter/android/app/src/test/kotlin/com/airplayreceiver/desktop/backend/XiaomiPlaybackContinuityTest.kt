package com.airplayreceiver.desktop.backend

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class XiaomiPlaybackContinuityTest {
    @Test
    fun replacementSessionKeepsArtworkUntilFreshMetadataArrives() {
        val previous = PlaybackSnapshot(
            title = "Song",
            artist = "Artist",
            album = "Album",
            coverArt = "https://example.test/cover.webp",
            protocol = XIAOMI_PROTOCOL,
            durationMs = 240_000,
            positionMs = 72_000,
            isPlaying = false,
            streamActive = true,
            trackIdentity = "track-1",
        )

        val resumed = previous.activateXiaomi(
            sourceName = "Phone",
            newSession = true,
            rawState = 2,
        )

        assertTrue(resumed.isPlaying)
        assertTrue(resumed.streamActive)
        assertEquals(previous.title, resumed.title)
        assertEquals(previous.artist, resumed.artist)
        assertEquals(previous.coverArt, resumed.coverArt)
        assertEquals(previous.trackIdentity, resumed.trackIdentity)
    }

    @Test
    fun partialMetadataKeepsParsedLyricsUntilTrackReplacement() {
        val document = requireNotNull(LrcParser.parse("[00:01.00]One line"))
        val playback = PlaybackSnapshot(protocol = XIAOMI_PROTOCOL, lyrics = document)
        fun update(replaceTrack: Boolean) = playback.applyXiaomiMediaInfo(
            title = null,
            artist = null,
            album = null,
            artworkUrl = null,
            durationMs = null,
            positionMs = 1_500,
            replaceTrack = replaceTrack,
        )
        assertSame(document, update(false).lyrics)
        assertNull(update(true).lyrics)
    }
}
