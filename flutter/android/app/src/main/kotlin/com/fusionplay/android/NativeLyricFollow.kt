package com.fusionplay.android

import com.airplayreceiver.desktop.backend.LyricsDocument
import kotlin.math.roundToInt

internal object NativeLyricFollow {
    // MiPlay extrapolates in 500 ms ticks. A delayed sender sample may briefly
    // fall just before a line the receiver has already reached.
    private const val BACKWARD_TOLERANCE_MS = 750L

    fun anchorTop(height: Int, compactMaximum: Int? = null): Int = if (compactMaximum == null) {
        (height * .32f).roundToInt()
    } else {
        (height * .18f).roundToInt().coerceAtMost(compactMaximum)
    }

    /** Keep a followed or selected line at its viewport fraction, and preserve a scrolled row's offset. */
    fun resizeAnchorTop(top: Float, oldHeight: Int, newHeight: Int, proportional: Boolean): Int {
        val offset = if (proportional && oldHeight > 0) top * (newHeight.toFloat() / oldHeight) else top
        return offset.roundToInt().takeIf { it < newHeight } ?: 0
    }

    fun lineAlpha(position: Int, activeIndex: Int?, synchronized: Boolean, highContrast: Boolean): Int = when {
        !synchronized -> 224
        position == activeIndex -> 255
        highContrast -> 189
        activeIndex == null -> if (position == 0) 184 else 107
        kotlin.math.abs(position - activeIndex) <= 1 -> 145
        else -> 82
    }

    fun activeIndex(
        document: LyricsDocument?,
        reportedPositionMs: Long,
        previousIndex: Int?,
        continuousPlayback: Boolean,
    ): Int? {
        val positionMs = reportedPositionMs.coerceAtLeast(0L)
        val reportedIndex = document?.activeLineIndex(positionMs)
        if (!continuousPlayback || previousIndex == null || (reportedIndex ?: -1) >= previousIndex) {
            return reportedIndex
        }
        val activeStartMs = document?.lines?.getOrNull(previousIndex)?.startMs ?: return reportedIndex
        return if (activeStartMs - positionMs in 1L..BACKWARD_TOLERANCE_MS) previousIndex else reportedIndex
    }
}
