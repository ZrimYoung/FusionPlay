package com.fusionplay.android

import com.fusionplay.android.NativePlayerLayout.Mode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlayerLayoutTest {
    @Test
    fun `wide tablet gives artwork and lyrics separate columns`() {
        val lyrics = NativePlayerPreferences(showLyrics = true)
        val layout = NativePlayerLayout.fit(1024f, 680f, lyrics, largeText = false)

        assertEquals(Mode.ARTWORK_AND_LYRICS, layout.mode)
        assertTrue(layout.coverSide in 1f..layout.leadingWidth)
        assertTrue(layout.contentWidth - layout.leadingWidth - layout.gap > layout.leadingWidth)
        assertTrue(layout.lyricsHeight <= 680f - 2 * layout.verticalInset)
    }

    @Test
    fun `split view and larger text stack the same player content`() {
        val lyrics = NativePlayerPreferences(showLyrics = true)
        val split = NativePlayerLayout.fit(530f, 760f, lyrics, largeText = false)
        val largeText = NativePlayerLayout.fit(1024f, 680f, lyrics, largeText = true)

        for (layout in listOf(split, largeText)) {
            assertEquals(Mode.STACKED, layout.mode)
            assertTrue(layout.coverSide in 1f..layout.contentWidth)
            assertTrue(layout.lyricsHeight in 280f..520f)
        }
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
