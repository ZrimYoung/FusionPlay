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

    fun offsetDp(
        elapsedMs: Long,
        rowPosition: Float,
        spanMs: Int,
        direction: Int,
        residualDp: Float = 0f,
        durationMs: Int = FOLLOW_DURATION_MS,
    ): Float {
        if (!rowPosition.isFinite()) return 0f
        val rank = (rowPosition.coerceIn(0f, 1f) * RANK_STEPS).roundToInt() / RANK_STEPS
        val delay = clampSpan(spanMs) * rank
        val progress = scrollFraction(elapsedMs, durationMs)
        val wave = direction * MAX_OFFSET_DP * (progress - ease(elapsedMs - delay, durationMs))
        val residual = residualDp.coerceIn(-MAX_OFFSET_DP, MAX_OFFSET_DP) * (1f - progress)
        val sameDirection = (if (wave >= 0f) residual else -residual).coerceAtLeast(0f)
        return residual + wave * (1f - sameDirection / MAX_OFFSET_DP)
    }

    fun scrollFraction(elapsedMs: Long, durationMs: Int = FOLLOW_DURATION_MS): Float = ease(elapsedMs.toFloat(), durationMs)

    private fun ease(elapsedMs: Float, durationMs: Int): Float {
        val progress = (elapsedMs / durationMs.coerceIn(NativeLyricAppearance.MOVE_RANGE)).coerceIn(0f, 1f)
        val sample = progress * CURVE_STEPS
        val index = sample.toInt().coerceAtMost(CURVE_STEPS - 1)
        return verticalMove[index] + (verticalMove[index + 1] - verticalMove[index]) * (sample - index)
    }

    private const val MAX_OFFSET_DP = 36f
    private const val RANK_STEPS = 32f
    private const val CURVE_STEPS = 256

    // Same cubic Bézier as iPad's lyric scroll. Invert x once so evaluating every row is cheap.
    private val verticalMove = FloatArray(CURVE_STEPS + 1) { index ->
        when (index) {
            0 -> 0f
            CURVE_STEPS -> 1f
            else -> {
                val progress = index.toFloat() / CURVE_STEPS
                var low = 0f
                var high = 1f
                repeat(16) {
                    val t = (low + high) * .5f
                    val u = 1f - t
                    val x = 3f * u * t * (.32f * u + .24f * t) + t * t * t
                    if (x < progress) low = t else high = t
                }
                val t = (low + high) * .5f
                t * t * (3f - 2f * t)
            }
        }
    }
}
