package com.fusionplay.android

internal data class NativeLyricAppearance(
    val scalePercent: Int = 100,
    val moveMilliseconds: Int = NativeLyricStagger.FOLLOW_DURATION_MS,
    val shadowEnabled: Boolean = false,
    val shadowOpacityPercent: Int = 45,
    val shadowSpreadDp: Int = 8,
) {
    fun normalized() = copy(
        scalePercent = scalePercent.coerceIn(SCALE_RANGE),
        moveMilliseconds = moveMilliseconds.coerceIn(MOVE_RANGE),
        shadowOpacityPercent = shadowOpacityPercent.coerceIn(SHADOW_OPACITY_RANGE),
        shadowSpreadDp = shadowSpreadDp.coerceIn(SHADOW_SPREAD_RANGE),
    )

    companion object {
        val SCALE_RANGE = 75..200
        val MOVE_RANGE = 100..1500
        val SHADOW_OPACITY_RANGE = 0..100
        val SHADOW_SPREAD_RANGE = 0..24
    }
}
