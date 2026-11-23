package com.fusionplay.android

import com.airplayreceiver.desktop.backend.LrcParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NativeLyricFollowTest {
    private val lyrics = requireNotNull(LrcParser.parse("[00:05]First\n[00:10]Second\n[00:17]Third"))

    @Test
    fun `width changes keep the visible line and height changes preserve its viewport position`() {
        assertEquals(160, NativeLyricFollow.resizeAnchorTop(160f, 500, 500, proportional = true))
        assertEquals(96, NativeLyricFollow.resizeAnchorTop(160f, 500, 300, proportional = true))
        assertEquals(112, NativeLyricFollow.resizeAnchorTop(112f, 500, 300, proportional = false))
        assertEquals(0, NativeLyricFollow.resizeAnchorTop(350f, 500, 300, proportional = false))
    }

    @Test
    fun `late sender samples do not make an active line oscillate`() {
        val positions = listOf(9_900L, 10_100L, 9_600L, 10_300L, 17_500L)
        var active: Int? = null
        val result = positions.map { position ->
            NativeLyricFollow.activeIndex(lyrics, position, active, continuousPlayback = true).also { active = it }
        }

        assertEquals(listOf(0, 1, 1, 1, 2), result)
        assertEquals(0, NativeLyricFollow.activeIndex(lyrics, 4_800L, 0, continuousPlayback = true))
    }

    @Test
    fun `real rewind and explicit seek still move to the reported line`() {
        assertEquals(0, NativeLyricFollow.activeIndex(lyrics, 8_500L, 1, continuousPlayback = true))
        assertEquals(0, NativeLyricFollow.activeIndex(lyrics, 9_700L, 1, continuousPlayback = false))
        assertNull(NativeLyricFollow.activeIndex(lyrics, 4_800L, 0, continuousPlayback = false))
    }
}
