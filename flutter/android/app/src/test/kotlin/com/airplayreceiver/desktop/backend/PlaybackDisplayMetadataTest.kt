package com.airplayreceiver.desktop.backend

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class PlaybackDisplayMetadataTest {
    @Test
    fun sdkLabelsPreserveOriginalTextAndQualifiedCreditsSeparately() {
        val sender = PlaybackDisplayMetadata("  now we are going home  ", "Alpha", "Sender Album")
        val corrected = PlaybackDisplayMetadata("Night Walk (Live)", "Alpha/Beta", "Sender Album")
        val playback = PlaybackSnapshot(protocol = XIAOMI_PROTOCOL).receive(
            id = "one", title = "Night Walk", artist = "Alpha", album = "Header Album",
            lrc = "[ti:Night Walk][ar:Alpha][al:Header Album]\n[00:05]now we are going home",
            position = 5_000L, flagged = true, senderMetadata = sender, sdkMetadata = corrected,
        )
        assertEquals(sender, playback.displayMetadata(false))
        assertEquals(corrected, playback.displayMetadata(true))
        assertEquals("Night Walk", playback.title)
        assertEquals("one", playback.trackIdentity)
        assertEquals(
            "Sender Album",
            playback.copy(sdkDisplayMetadata = corrected.copy(album = null)).displayMetadata(true).album,
        )

        val partial = playback.receive(
            id = "one", replace = false, position = 8_000L,
            senderMetadata = PlaybackDisplayMetadata(title = "home", artist = "", album = ""),
            sdkMetadata = PlaybackDisplayMetadata(album = "Updated Album"),
        )
        assertEquals(sender.copy(title = "home"), partial.displayMetadata(false))
        assertEquals(corrected.copy(album = "Updated Album"), partial.displayMetadata(true))
        assertEquals(8_000L, partial.positionMs)
    }

    @Test
    fun explicitEmptyProjectionSurvivesPartialUpdatesAndClearsOnNewTrack() {
        val previous = PlaybackSnapshot(protocol = XIAOMI_PROTOCOL).receive(
            id = "one", title = "Previous Song", artist = "Previous Artist",
            lrc = "[ti:Previous Song][ar:Previous Artist]\n[00:05]Another caption",
            sdkMetadata = PlaybackDisplayMetadata(title = "Previous Song (Live)", artist = "Previous Artist"),
        )
        val next = previous.receive(
            id = "one", title = "Another caption", flagged = true, trackTransition = "new",
            senderMetadata = PlaybackDisplayMetadata(title = "Another caption"),
            sdkMetadata = PlaybackDisplayMetadata(title = ""),
        )
        val tick = next.receive(id = "one", replace = false, position = 2_000L)
        assertEquals(PlaybackDisplayMetadata(title = "Another caption"), tick.displayMetadata(false))
        assertEquals(PlaybackDisplayMetadata(title = ""), tick.displayMetadata(true))
        assertNull(tick.lyrics)

        val legacy = tick.receive(id = "two", title = "Next Song")
        assertEquals(PlaybackDisplayMetadata(title = "Next Song"), legacy.displayMetadata(true))
    }

    @Test
    fun captionCorrectionUsesLocalHeadersWithoutChangingTransport() {
        val lrc = "[ti:Night-Walk][ar:Example-Artist][al:Record]\n[00:10.00]<00:10.00>Now we are going home"
        val playback = PlaybackSnapshot(protocol = XIAOMI_PROTOCOL).receive(
            id = "stable1", title = "home", artist = "Night-Walk — Example-Artist — Record",
            album = "Record", position = 10_000L, lrc = lrc,
        )
        assertEquals(PlaybackDisplayMetadata("Night-Walk", "Example-Artist", "Record"), playback.displayMetadata(true))
        assertEquals("home", playback.displayMetadata(false).title)
        assertEquals("Night-Walk — Example-Artist — Record", playback.artist)
        assertEquals("stable1", playback.trackIdentity)
        assertEquals(10_000L, playback.positionMs)

        val tick = playback.receive(id = "stable1", position = 42_000L, replace = false)
        assertSame(playback.lyricTitleCorrection, tick.lyricTitleCorrection)
        assertEquals("Night-Walk", tick.displayMetadata(true).title)
        assertEquals("home", tick.title)
    }

    @Test
    fun knownTitleSurvivesIncrementalCaptionButNeverLeaksToNewTrack() {
        val first = PlaybackSnapshot(protocol = XIAOMI_PROTOCOL).receive(
            id = "first", title = "Actual Song", artist = "Artist", album = "Album",
        )
        val normalized = first.receive(id = "first", title = "Actual Song", flagged = true, replace = false)
        assertEquals("Actual Song", normalized.displayMetadata(true).title)
        val caption = normalized.receive(id = "first", title = "First line to sing", flagged = true)
        assertEquals("Actual Song", caption.displayMetadata(true).title)
        assertEquals("First line to sing", caption.title)

        val nextCaption = caption.receive(id = "first", title = "Second line to sing", flagged = true)
        assertEquals(PlaybackDisplayMetadata("Actual Song", "Artist", "Album"), nextCaption.displayMetadata(true))
        val unrelated = nextCaption.receive(id = "second", title = "Another lyric", flagged = true)
        assertEquals("", unrelated.displayMetadata(true).title)
        assertEquals("Another lyric", unrelated.displayMetadata(false).title)
        assertNull(unrelated.lyricHeaders)
    }

    @Test
    fun exactCaptionsWithSyntheticOrMissingIdsKeepTheCachedTitle() {
        val first = PlaybackSnapshot(protocol = XIAOMI_PROTOCOL).receive(
            id = "stable-song", title = "Actual Song", artist = "Artist", album = "Album", position = 20_000,
            lrc = "[ti:Actual Song]\n[00:01]First caption\n[00:03]Second caption",
        )
        val synthetic = first.receive(
            id = "metadata:first-caption", title = "First caption", flagged = false, idSource = "metadata",
        )
        assertEquals(PlaybackDisplayMetadata("Actual Song", "Artist", "Album"), synthetic.displayMetadata(true))
        assertEquals("First caption", synthetic.displayMetadata(false).title)
        assertNull(synthetic.artist)
        assertEquals("metadata:first-caption", synthetic.trackIdentity)
        assertEquals(0L, synthetic.positionMs)

        val next = synthetic.receive(id = null, title = "Second caption", flagged = false)
        assertEquals(PlaybackDisplayMetadata("Actual Song", "Artist", "Album"), next.displayMetadata(true))
        assertEquals("Second caption", next.displayMetadata(false).title)
        assertNull(next.trackIdentity)
        assertSame(first.lyrics, next.lyrics)
    }

    @Test
    fun fallbackCaptionsRequireAnExactMatchAndCannotCarryEvidenceAcrossANewTrack() {
        val original = PlaybackSnapshot(protocol = XIAOMI_PROTOCOL).receive(
            id = "stable-song", title = "Actual Song",
            lrc = "[ti:Actual Song]\n[00:01]A long lyric caption",
        )
        val explicit = original.receive(
            id = "metadata:real-track", title = "A long lyric caption", flagged = false, idSource = "explicit",
        )
        assertEquals("A long lyric caption", explicit.displayMetadata(true).title)
        assertNull(explicit.lyrics)

        val differentLyrics = original.receive(
            id = "metadata:new-lyrics", title = "A long lyric caption", flagged = false, idSource = "metadata",
            lrc = "[ti:Actual Song]\n[00:01]An unrelated new lyric",
        )
        assertEquals("A long lyric caption", differentLyrics.displayMetadata(true).title)
        val fragment = original.receive(
            id = "metadata:fragment", title = "long lyric", flagged = false, idSource = "metadata",
        )
        assertEquals("long lyric", fragment.displayMetadata(true).title)
        assertNull(fragment.lyrics)
    }

    @Test
    fun shortWordsRequireBoundariesAndPlaybackProximity() {
        val lrc = "[ti:Night Walk]\n[00:10.00]Now we are going home"
        val blank = PlaybackSnapshot(protocol = XIAOMI_PROTOCOL)
        assertEquals("home", blank.receive(id = "id", title = "home", position = 1_000L, lrc = lrc).displayMetadata(true).title)
        assertEquals("going", blank.receive(id = "id", title = "going", lrc = lrc).displayMetadata(true).title)
        assertEquals("ome", blank.receive(id = "id", title = "ome", position = 10_000L, lrc = lrc).displayMetadata(true).title)
        assertEquals("Night Walk", blank.receive(id = "id", title = "home", position = 10_000L, lrc = lrc).displayMetadata(true).title)
    }

    @Test
    fun conflictingHeadersNeverInventATitleAndRealMetadataClearsCaptionHint() {
        val conflict = "[ti:One][ti:Two][ar:Artist]\n[00:00.00]A lyric caption"
        val caption = PlaybackSnapshot(protocol = XIAOMI_PROTOCOL).receive(
            id = "stable", title = "A lyric caption", lrc = conflict, flagged = true,
        )
        assertEquals(PlaybackDisplayMetadata("", "Artist", null), caption.displayMetadata(true))
        val regular = caption.receive(id = "stable", title = "Real Song", flagged = false)
        assertEquals("Real Song", regular.displayMetadata(true).title)
        assertNull(regular.lyricTitleCorrection?.title)
        assertEquals(false, regular.lyricCaptionHint)
    }

    private fun PlaybackSnapshot.receive(
        id: String?, title: String? = null, artist: String? = null, album: String? = null,
        position: Long? = null, lrc: String? = null, flagged: Boolean? = null, replace: Boolean = true,
        idSource: String? = null,
        trackTransition: String? = null,
        senderMetadata: PlaybackDisplayMetadata? = null,
        sdkMetadata: PlaybackDisplayMetadata? = null,
    ): PlaybackSnapshot = applyXiaomiMediaInfo(
        trackId = id, title = title, artist = artist, album = album, artworkUrl = null,
        durationMs = 120_000, positionMs = position, replaceTrack = replace,
        lyrics = lrc?.let { LrcParser.parse(it) }, lyricHeaders = lrc?.let(::parseLrcDisplayHeaders), titleIsLyric = flagged,
        trackIdSource = idSource,
        trackTransition = trackTransition, senderMetadata = senderMetadata, sdkDisplayMetadata = sdkMetadata,
    )
}
