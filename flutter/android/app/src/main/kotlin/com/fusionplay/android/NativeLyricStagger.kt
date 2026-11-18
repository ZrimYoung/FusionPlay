package com.fusionplay.android

import kotlin.math.roundToInt

/** The iPad lyric follow wave, applied over Android's regular list scroll. */
internal object NativeLyricStagger {
    const val MIN_SPAN_MS = 0
    const val MAX_SPAN_MS = 240
    const val DEFAULT_SPAN_MS = 140
    const val STEP_MS = 10
    const val FOLLOW_DURATION_MS = 420

    fun clampSpan(milliseconds: Int): Int = milliseconds.coerceIn(MIN_SPAN_MS, MAX_SPAN_MS)

    fun direction(previousIndex: Int?, nextIndex: Int): Int? {
        if (previousIndex == null) return null
        return when (nextIndex - previousIndex) {
            1, 2 -> 1
            -1, -2 -> -1
            else -> null
        }
    }

    fun offsetDp(elapsedMs: Long, rowPosition: Float, spanMs: Int, direction: Int): Float {
        if (!rowPosition.isFinite()) return 0f
        val rank = (rowPosition.coerceIn(0f, 1f) * RANK_STEPS).roundToInt() / RANK_STEPS
        val delay = clampSpan(spanMs) * rank
        return direction * MAX_OFFSET_DP * (ease(elapsedMs.toFloat()) - ease(elapsedMs - delay))
    }

    private fun ease(elapsedMs: Float): Float {
        val progress = (elapsedMs / FOLLOW_DURATION_MS).coerceIn(0f, 1f)
        return progress * progress * (3f - 2f * progress)
    }

    private const val MAX_OFFSET_DP = 36f
    private const val RANK_STEPS = 32f
}
