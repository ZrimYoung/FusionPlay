package com.fusionplay.android

import com.fusionplay.android.NativePlayerLayout.Mode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlayerLayoutTest {
    @Test
    fun `tv lyrics split keeps the cover and playback details in the same compact column`() {
        val lyrics = NativePlayerPreferences()
        val compactDetails = 154f
        val wrappedDetails = 248f
        val compact = NativePlayerLayout.fit(
            960f, 482f, lyrics, largeText = false, showsLyrics = true, playbackHeight = compactDetails, television = true,
        )
        val wrapped = NativePlayerLayout.fit(
            960f, 482f, lyrics, largeText = false, showsLyrics = true, playbackHeight = wrappedDetails, television = true,
        )
        assertEquals(Mode.ARTWORK_AND_LYRICS, compact.mode)
        assertEquals(228f, compact.coverSide, 0.01f)
        assertEquals(compact.coverSide, compact.leadingWidth, 0.01f)
        assertEquals(wrapped.coverSide, wrapped.leadingWidth, 0.01f)
        assertEquals(compact.contentWidth, wrapped.contentWidth, 0.01f)
        assertTrue(compact.coverSide > wrapped.coverSide)
        assertTrue(compact.coverSide + compactDetails < compact.lyricsHeight)
        assertTrue(compact.contentWidth - compact.leadingWidth - compact.gap > compact.leadingWidth)
        assertEquals(wrapped.lyricsHeight, wrapped.coverSide + wrappedDetails, 0.01f)
    }

    @Test
    fun `tv without lyrics keeps both sides compact and narrow windows keep the stacked controls aligned`() {
        val wide = NativePlayerLayout.fit(960f, 482f, NativePlayerPreferences(), largeText = false, television = true)
        val narrow = NativePlayerLayout.fit(
            540f, 720f, NativePlayerPreferences(narrowLyricsPaging = true), largeText = false, showsLyrics = true, television = true,
        )

        assertEquals(Mode.ARTWORK_AND_CONTROLS, wide.mode)
        assertEquals(wide.coverSide, wide.leadingWidth, 0.01f)
        assertEquals(wide.coverSide * 2 + wide.gap, wide.contentWidth, 0.01f)
        assertEquals(Mode.STACKED, narrow.mode)
        assertEquals(narrow.coverSide, narrow.leadingWidth, 0.01f)
        assertTrue(narrow.contentWidth > narrow.leadingWidth)
    }

    @Test
    fun `wide tablet gives artwork and lyrics separate columns`() {
        val layout = NativePlayerLayout.fit(1024f, 680f, NativePlayerPreferences(), largeText = false, showsLyrics = true)

        assertEquals(Mode.ARTWORK_AND_LYRICS, layout.mode)
        assertTrue(layout.coverSide in 1f..layout.leadingWidth)
        assertTrue(layout.contentWidth - layout.leadingWidth - layout.gap > layout.leadingWidth)
        assertTrue(layout.lyricsHeight <= 680f - 2 * layout.verticalInset)
    }

    @Test
    fun `narrow touch paging is independent from automatic lyric visibility`() {
        val lyrics = NativePlayerPreferences(narrowLyricsPaging = true)
        val split = NativePlayerLayout.fit(530f, 760f, lyrics, largeText = false, showsLyrics = false)
        val largeText = NativePlayerLayout.fit(530f, 760f, lyrics, largeText = true, showsLyrics = true)
        val disabled = NativePlayerLayout.fit(530f, 760f, NativePlayerPreferences(), largeText = false, showsLyrics = true)

        assertEquals(Mode.PAGED_LYRICS, split.mode)
        assertEquals(760f - 2 * split.verticalInset, split.lyricsHeight, 0.01f)
        assertTrue(split.coverSide in 1f..split.contentWidth)
        assertEquals(Mode.STACKED, largeText.mode)
        assertTrue(largeText.coverSide in 1f..largeText.contentWidth)
        assertTrue(largeText.lyricsHeight in 280f..520f)
        assertEquals(Mode.STACKED, disabled.mode)
    }

    @Test
    fun `ultrawide lyrics expand the centered canvas and cover without consuming the lyric column`() {
        val preferences = NativePlayerPreferences()
        val tablet = NativePlayerLayout.fit(1280f, 900f, preferences, largeText = false, showsLyrics = true)
        val expanded = NativePlayerLayout.fit(1510f, 900f, preferences, largeText = false, showsLyrics = true)
        val ultrawide = NativePlayerLayout.fit(2048f, 900f, preferences, largeText = false, showsLyrics = true)

        assertTrue(tablet.contentWidth < expanded.contentWidth)
        assertTrue(expanded.contentWidth < ultrawide.contentWidth)
        assertEquals(1440f, ultrawide.contentWidth, 0.01f)
        assertTrue(ultrawide.coverSide > tablet.coverSide)
        assertTrue(ultrawide.contentWidth - ultrawide.leadingWidth - ultrawide.gap > ultrawide.leadingWidth * 1.5f)
    }

    @Test
    fun `without lyrics landscape puts controls beside the cover`() {
        val preferences = NativePlayerPreferences()
        val landscape = NativePlayerLayout.fit(1280f, 660f, preferences, largeText = false)
        val portrait = NativePlayerLayout.fit(730f, 1000f, preferences, largeText = false)

        assertEquals(Mode.ARTWORK_AND_CONTROLS, landscape.mode)
        assertEquals(Mode.STACKED, portrait.mode)
        assertTrue(2 * landscape.leadingWidth + landscape.gap <= landscape.contentWidth)
        assertTrue(landscape.coverSide <= landscape.leadingWidth)
    }
}
