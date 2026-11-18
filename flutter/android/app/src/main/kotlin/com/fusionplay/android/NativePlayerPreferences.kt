package com.fusionplay.android

import android.content.Context

/** Settings that affect the player without restarting any receiver. */
data class NativePlayerPreferences(
    val showLyrics: Boolean = false,
    val showProgress: Boolean = true,
    val showTransport: Boolean = true,
    val toolbarAlwaysVisible: Boolean = false,
    val wrapMetadata: Boolean = false,
    val staggerLyricMotion: Boolean = true,
    val lyricStaggerMilliseconds: Int = NativeLyricStagger.DEFAULT_SPAN_MS,
    val correctLyricTitles: Boolean = false,
)

internal class NativePlayerPreferenceStore(context: Context) {
    private val store = context.getSharedPreferences("native_player", Context.MODE_PRIVATE)

    fun load(): NativePlayerPreferences = NativePlayerPreferences(
        showLyrics = store.getBoolean("lyrics", false),
        showProgress = store.getBoolean("timeline", true),
        showTransport = store.getBoolean("transport", true),
        toolbarAlwaysVisible = store.getBoolean("keep_toolbar_visible", false),
        wrapMetadata = store.getBoolean("wrap_metadata", false),
        staggerLyricMotion = store.getBoolean("lyric_stagger_enabled", true),
        lyricStaggerMilliseconds = NativeLyricStagger.clampSpan(
            store.getInt("lyric_stagger_ms", NativeLyricStagger.DEFAULT_SPAN_MS),
        ),
        correctLyricTitles = store.getBoolean("correct_lyric_titles", false),
    )

    fun save(value: NativePlayerPreferences) {
        store.edit()
            .putBoolean("lyrics", value.showLyrics)
            .putBoolean("timeline", value.showProgress)
            .putBoolean("transport", value.showTransport)
            .putBoolean("keep_toolbar_visible", value.toolbarAlwaysVisible)
            .putBoolean("wrap_metadata", value.wrapMetadata)
            .putBoolean("lyric_stagger_enabled", value.staggerLyricMotion)
            .putInt("lyric_stagger_ms", NativeLyricStagger.clampSpan(value.lyricStaggerMilliseconds))
            .putBoolean("correct_lyric_titles", value.correctLyricTitles)
            .apply()
    }
}
