package com.fusionplay.android

import kotlin.math.roundToInt

/** Viewport edge treatment based on the iPad lyric pane. Positions are fractions of pane height. */
internal object NativeLyricEdge {
    const val MAX_BLUR_LEVEL = 13

    fun keepsRowClear(active: Boolean, browsing: Boolean, remoteFocused: Boolean): Boolean =
        remoteFocused || (active && !browsing)

    fun opacity(center: Float): Float = minOf(center / .09f, (1f - center) / .10f).coerceIn(0f, 1f)

    fun blurLevel(center: Float, stronger: Boolean): Int {
        val top = smoothEdge(center / .30f) * 3.5f
        val bottom = smoothEdge((1f - center) / .45f) * 10f
        val scale = if (stronger) 1.3f else 1f
        // Whole-dp steps let rows share the small cache of render effects.
        return (maxOf(top, bottom) * scale).roundToInt().coerceIn(0, MAX_BLUR_LEVEL)
    }

    private fun smoothEdge(distance: Float): Float {
        val t = 1f - distance.coerceIn(0f, 1f)
        return t * t * (3f - 2f * t)
    }
}
