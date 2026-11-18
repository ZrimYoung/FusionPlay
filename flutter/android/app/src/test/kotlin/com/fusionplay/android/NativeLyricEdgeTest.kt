package com.fusionplay.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeLyricEdgeTest {
    @Test
    fun `center stays clear and blur gets stronger toward both edges`() {
        assertEquals(0, NativeLyricEdge.blurLevel(.32f, stronger = false))
        assertEquals(0, NativeLyricEdge.blurLevel(.50f, stronger = true))
        assertTrue(NativeLyricEdge.blurLevel(.05f, false) > NativeLyricEdge.blurLevel(.24f, false))
        assertTrue(NativeLyricEdge.blurLevel(.94f, false) > NativeLyricEdge.blurLevel(.70f, false))
        assertTrue(NativeLyricEdge.blurLevel(.98f, false) > NativeLyricEdge.blurLevel(.02f, false))
        assertTrue(NativeLyricEdge.blurLevel(.94f, true) > NativeLyricEdge.blurLevel(.94f, false))
        assertEquals(NativeLyricEdge.MAX_BLUR_LEVEL, NativeLyricEdge.blurLevel(1.1f, stronger = true))
    }

    @Test
    fun `opacity fades only near the viewport edges and clamps outside`() {
        assertEquals(0f, NativeLyricEdge.opacity(-.02f), .001f)
        assertEquals(.5f, NativeLyricEdge.opacity(.045f), .001f)
        assertEquals(1f, NativeLyricEdge.opacity(.09f), .001f)
        assertEquals(1f, NativeLyricEdge.opacity(.90f), .001f)
        assertEquals(.5f, NativeLyricEdge.opacity(.95f), .001f)
        assertEquals(0f, NativeLyricEdge.opacity(1.02f), .001f)
    }
}
