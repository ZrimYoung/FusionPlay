package com.fusionplay.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeLyricStaggerTest {
    @Test
    fun `only nearby line changes start a directional wave`() {
        assertNull(NativeLyricStagger.direction(null, 4))
        assertNull(NativeLyricStagger.direction(4, 4))
        assertNull(NativeLyricStagger.direction(4, 7))
        assertNull(NativeLyricStagger.direction(4, 1))
        assertEquals(1, NativeLyricStagger.direction(4, 5))
        assertEquals(-1, NativeLyricStagger.direction(4, 2))
    }

    @Test
    fun `rows farther down lag more then settle without residual offsets`() {
        val span = NativeLyricStagger.DEFAULT_SPAN_MS
        val elapsed = 210L
        val top = NativeLyricStagger.offsetDp(elapsed, 0f, span, 1)
        val middle = NativeLyricStagger.offsetDp(elapsed, .5f, span, 1)
        val bottom = NativeLyricStagger.offsetDp(elapsed, 1f, span, 1)
        assertEquals(0f, top, .001f)
        assertTrue(bottom > middle && middle > top)
        assertEquals(-bottom, NativeLyricStagger.offsetDp(elapsed, 1f, span, -1), .001f)
        val end = (NativeLyricStagger.FOLLOW_DURATION_MS + span).toLong()
        assertEquals(0f, NativeLyricStagger.offsetDp(end, 1f, span, 1), .001f)
    }

    @Test
    fun `zero span is regular scrolling and out of range spans clamp`() {
        val elapsed = 210L
        assertEquals(0f, NativeLyricStagger.offsetDp(elapsed, 1f, 0, 1), .001f)
        assertEquals(0f, NativeLyricStagger.offsetDp(elapsed, 1f, -5, 1), .001f)
        val maximum = NativeLyricStagger.offsetDp(elapsed, 1f, 240, 1)
        assertEquals(maximum, NativeLyricStagger.offsetDp(elapsed, 1f, 500, 1), .001f)
        assertTrue(maximum > NativeLyricStagger.offsetDp(elapsed, 1f, 30, 1))
    }
}
