package com.fusionplay.android

import kotlin.math.max
import kotlin.math.min

/** Resolves the iPad player's three layouts from the available window size in dp. */
internal data class NativePlayerLayout(
    val mode: Mode,
    val gap: Float,
    val coverSide: Float,
    val leadingWidth: Float,
    val contentWidth: Float,
    val lyricsHeight: Float,
    val verticalInset: Float,
) {
    enum class Mode { STACKED, ARTWORK_AND_CONTROLS, ARTWORK_AND_LYRICS }

    companion object {
        fun horizontalInset(width: Float): Float = min(width / 4, (width * 0.052f).coerceIn(18f, 64f))

        fun fit(width: Float, height: Float, preferences: NativePlayerPreferences, largeText: Boolean): NativePlayerLayout {
            val canUseColumns = width >= 660f && !largeText
            val mode = when {
                canUseColumns && preferences.showLyrics && height >= 360f -> Mode.ARTWORK_AND_LYRICS
                canUseColumns && !preferences.showLyrics && width >= height * 1.12f -> Mode.ARTWORK_AND_CONTROLS
                else -> Mode.STACKED
            }
            val availableWidth = width - horizontalInset(width) * 2
            val gap = (availableWidth * 0.058f).coerceIn(28f, 64f)
            val verticalInset = (12f + (height - 360f) * 0.1f).coerceIn(12f, 24f)
            val availableHeight = max(0f, height - verticalInset * 2)
            val playbackHeight = 120f + (if (preferences.showProgress) 58f else 0f) +
                (if (preferences.showTransport) 72f else 0f)
            val contentWidth = min(availableWidth, when (mode) {
                Mode.STACKED -> 470f
                Mode.ARTWORK_AND_CONTROLS -> 920f
                Mode.ARTWORK_AND_LYRICS -> 1_180f
            })
            val leadingWidth = when (mode) {
                Mode.STACKED -> contentWidth
                Mode.ARTWORK_AND_CONTROLS -> min(440f, (contentWidth - gap) / 2)
                Mode.ARTWORK_AND_LYRICS -> min(400f, (contentWidth - gap) * 0.43f)
            }
            val coverSide = when (mode) {
                Mode.STACKED -> min(min(contentWidth, 420f), max(148f, availableHeight - playbackHeight))
                Mode.ARTWORK_AND_CONTROLS -> min(leadingWidth, availableHeight)
                Mode.ARTWORK_AND_LYRICS -> min(leadingWidth, max(144f, availableHeight - playbackHeight + 25f))
            }
            val lyricsHeight = if (mode == Mode.ARTWORK_AND_LYRICS) availableHeight
                else (height * 0.64f).coerceIn(280f, 520f)
            return NativePlayerLayout(mode, gap, coverSide, leadingWidth, contentWidth, lyricsHeight, verticalInset)
        }
    }
}
