package com.fusionplay.android

import com.airplayreceiver.desktop.backend.LyricsDocument
import kotlin.math.roundToInt

internal object NativeLyricFollow {
    // MiPlay extrapolates in 500 ms ticks. A delayed sender sample may briefly
    // fall just before a line the receiver has already reached.
    private const val BACKWARD_TOLERANCE_MS = 750L

    /** Keep a followed or selected line at its viewport fraction, and preserve a scrolled row's offset. */
    fun resizeAnchorTop(top: Float, oldHeight: Int, newHeight: Int, proportional: Boolean): Int {
        val offset = if (proportional && oldHeight > 0) top * (newHeight.toFloat() / oldHeight) else top
        return offset.roundToInt().takeIf { it < newHeight } ?: 0
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
