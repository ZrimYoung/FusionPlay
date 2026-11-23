package com.fusionplay.android

import kotlin.math.max
import kotlin.math.min

/** Resolves the player layout from the available window size in dp. */
internal data class NativePlayerLayout(
    val mode: Mode,
    val gap: Float,
    val coverSide: Float,
    val leadingWidth: Float,
    val contentWidth: Float,
    val lyricsHeight: Float,
    val verticalInset: Float,
) {
    enum class Mode { STACKED, ARTWORK_AND_CONTROLS, ARTWORK_AND_LYRICS, PAGED_LYRICS }

    companion object {
        private const val TV_COVER_MAX_DP = 228f

        fun horizontalInset(width: Float): Float = min(width / 4, (width * 0.052f).coerceIn(18f, 64f))

        fun fit(
            width: Float,
            height: Float,
            preferences: NativePlayerPreferences,
            largeText: Boolean,
            showsLyrics: Boolean = false,
            playbackHeight: Float? = null,
            television: Boolean = false,
        ): NativePlayerLayout {
            val canUseColumns = width >= 660f && !largeText
            val mode = when {
                !television && !largeText && width < 660f && preferences.narrowLyricsPaging -> Mode.PAGED_LYRICS
                canUseColumns && showsLyrics && height >= 360f -> Mode.ARTWORK_AND_LYRICS
                canUseColumns && !showsLyrics && width >= height * 1.12f -> Mode.ARTWORK_AND_CONTROLS
                else -> Mode.STACKED
            }
            val availableWidth = width - horizontalInset(width) * 2
            val expansion = if (mode == Mode.ARTWORK_AND_LYRICS && !television) {
                val t = ((availableWidth - 1_180f) / 420f).coerceIn(0f, 1f)
                t * t * (3f - 2f * t)
            } else 0f
            val verticalInset = (12f + (height - 360f) * 0.1f).coerceIn(12f, 24f)
            val availableHeight = max(0f, height - verticalInset * 2)
            val estimatedPlaybackHeight = 120f + (if (preferences.showProgress) 58f else 0f) +
                (if (preferences.showTransport) 72f else 0f) + (if (mode == Mode.PAGED_LYRICS) 44f else 0f)
            val maxContentWidth = when (mode) {
                Mode.STACKED, Mode.PAGED_LYRICS -> 470f
                Mode.ARTWORK_AND_CONTROLS -> 920f
                Mode.ARTWORK_AND_LYRICS -> if (television) min(width * 0.84f, 1_080f) else 1_180f + 260f * expansion
            }
            val contentWidth = min(availableWidth, maxContentWidth)
            val gapBasis = if (mode == Mode.ARTWORK_AND_LYRICS && !television) contentWidth else availableWidth
            val gap = (gapBasis * 0.058f).coerceIn(28f, 64f + 32f * expansion)
            val leadingWidth = when (mode) {
                Mode.STACKED, Mode.PAGED_LYRICS -> contentWidth
                Mode.ARTWORK_AND_CONTROLS -> min(440f, (contentWidth - gap) / 2)
                Mode.ARTWORK_AND_LYRICS -> min(400f + 160f * expansion, (contentWidth - gap) * (0.43f - 0.05f * expansion))
            }
            val coverSide = when (mode) {
                Mode.STACKED, Mode.PAGED_LYRICS ->
                    min(min(contentWidth, 420f), max(148f, availableHeight - (playbackHeight ?: estimatedPlaybackHeight)))
                Mode.ARTWORK_AND_CONTROLS -> min(leadingWidth, availableHeight)
                Mode.ARTWORK_AND_LYRICS -> min(leadingWidth, max(144f, availableHeight - (playbackHeight ?: (estimatedPlaybackHeight - 25f))))
            }
            val lyricsHeight = when (mode) {
                Mode.ARTWORK_AND_LYRICS, Mode.PAGED_LYRICS -> availableHeight
                else -> (height * 0.64f).coerceIn(280f, 520f)
            }
            if (!television) {
                return NativePlayerLayout(mode, gap, coverSide, leadingWidth, contentWidth, lyricsHeight, verticalInset)
            }

            // Give the square cover and the details the same width on a TV.
            val tvSide = min(coverSide, TV_COVER_MAX_DP)
            val tvContentWidth = if (mode == Mode.ARTWORK_AND_CONTROLS) tvSide * 2 + gap else contentWidth
            return NativePlayerLayout(mode, gap, tvSide, tvSide, tvContentWidth, lyricsHeight, verticalInset)
        }
    }
}
