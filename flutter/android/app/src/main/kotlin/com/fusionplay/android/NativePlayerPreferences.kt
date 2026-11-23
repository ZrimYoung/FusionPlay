package com.fusionplay.android

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.os.Build
import android.os.LocaleList
import android.util.TypedValue
import java.util.Locale

enum class NativeLyricsDisplayMode { AUTOMATIC, NEVER }

enum class NativeProgressColorMode {
    SYSTEM, WHITE, CUSTOM;

    fun resolve(context: Context, customColor: Int): Int = when (this) {
        WHITE -> Color.WHITE
        CUSTOM -> customColor or Color.BLACK
        SYSTEM -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getColor(android.R.color.system_accent1_200)
        } else {
            val value = TypedValue()
            if (context.theme.resolveAttribute(android.R.attr.colorAccent, value, true)) {
                if (value.resourceId != 0) context.getColor(value.resourceId) else value.data
            } else Color.WHITE
        }
    }
}

enum class NativeAppLanguage(val tag: String?) {
    SYSTEM(null), CHINESE("zh-Hans"), ENGLISH("en");

    fun applyTo(context: Context): Context {
        val locale = tag?.let(Locale::forLanguageTag) ?: return context
        val configuration = Configuration(context.resources.configuration).apply {
            setLocales(LocaleList(locale))
            setLayoutDirection(locale)
        }
        return context.createConfigurationContext(configuration)
    }
}

/** Settings that affect the player without restarting any receiver. */
internal data class NativePlayerPreferences(
    val lyricsDisplayMode: NativeLyricsDisplayMode = NativeLyricsDisplayMode.NEVER,
    val narrowLyricsPaging: Boolean = false,
    val lyricsPageShowsArtwork: Boolean = true,
    val lyricsPageShowsTrackInfo: Boolean = true,
    val showProgress: Boolean = true,
    val showTransport: Boolean = true,
    val toolbarAlwaysVisible: Boolean = false,
    val wrapMetadata: Boolean = false,
    val staggerLyricMotion: Boolean = true,
    val lyricStaggerMilliseconds: Int = NativeLyricStagger.DEFAULT_SPAN_MS,
    val correctLyricTitles: Boolean = false,
    val lyricAppearance: NativeLyricAppearance = NativeLyricAppearance(),
    val progressColorMode: NativeProgressColorMode = NativeProgressColorMode.WHITE,
    val customProgressColor: Int = 0xFF83BFE3.toInt(),
    val backgroundBlurPercent: Int = 100,
    val fontFaceId: String = "",
    val appLanguage: NativeAppLanguage = NativeAppLanguage.SYSTEM,
)

internal class NativePlayerPreferenceStore(context: Context) {
    private val store = context.getSharedPreferences("native_player", Context.MODE_PRIVATE)

    fun load(): NativePlayerPreferences = NativePlayerPreferences(
        lyricsDisplayMode = choice("lyrics_display_mode", if (legacyLyrics()) NativeLyricsDisplayMode.AUTOMATIC else NativeLyricsDisplayMode.NEVER),
        narrowLyricsPaging = store.getBoolean("narrow_lyrics_paging", legacyLyrics()),
        lyricsPageShowsArtwork = store.getBoolean("lyrics_page_artwork", true),
        lyricsPageShowsTrackInfo = store.getBoolean("lyrics_page_track_info", true),
        showProgress = store.getBoolean("timeline", true),
        showTransport = store.getBoolean("transport", true),
        toolbarAlwaysVisible = store.getBoolean("keep_toolbar_visible", false),
        wrapMetadata = store.getBoolean("wrap_metadata", false),
        staggerLyricMotion = store.getBoolean("lyric_stagger_enabled", true),
        lyricStaggerMilliseconds = NativeLyricStagger.clampSpan(
            store.getInt("lyric_stagger_ms", NativeLyricStagger.DEFAULT_SPAN_MS),
        ),
        correctLyricTitles = store.getBoolean("correct_lyric_titles", false),
        lyricAppearance = NativeLyricAppearance(
            scalePercent = store.getInt("lyric_scale", 100),
            moveMilliseconds = store.getInt("lyric_move_ms", 420),
            shadowEnabled = store.getBoolean("lyric_shadow", false),
            shadowOpacityPercent = store.getInt("lyric_shadow_opacity", 45),
            shadowSpreadDp = store.getInt("lyric_shadow_spread", 8),
        ).normalized(),
        progressColorMode = choice("progress_color_mode", NativeProgressColorMode.WHITE),
        customProgressColor = store.getInt("progress_custom_color", 0xFF83BFE3.toInt()) or Color.BLACK,
        backgroundBlurPercent = store.getInt("backdrop_blur", 100).coerceIn(0, 100),
        fontFaceId = store.getString("font_face", "").orEmpty(),
        appLanguage = language(),
    )

    fun language(): NativeAppLanguage = choice("language", NativeAppLanguage.SYSTEM)

    fun save(value: NativePlayerPreferences) {
        val lyrics = value.lyricAppearance.normalized()
        store.edit()
            .putString("lyrics_display_mode", value.lyricsDisplayMode.name)
            .putBoolean("narrow_lyrics_paging", value.narrowLyricsPaging)
            .putBoolean("lyrics_page_artwork", value.lyricsPageShowsArtwork)
            .putBoolean("lyrics_page_track_info", value.lyricsPageShowsTrackInfo)
            .putBoolean("timeline", value.showProgress)
            .putBoolean("transport", value.showTransport)
            .putBoolean("keep_toolbar_visible", value.toolbarAlwaysVisible)
            .putBoolean("wrap_metadata", value.wrapMetadata)
            .putBoolean("lyric_stagger_enabled", value.staggerLyricMotion)
            .putInt("lyric_stagger_ms", NativeLyricStagger.clampSpan(value.lyricStaggerMilliseconds))
            .putBoolean("correct_lyric_titles", value.correctLyricTitles)
            .putInt("lyric_scale", lyrics.scalePercent)
            .putInt("lyric_move_ms", lyrics.moveMilliseconds)
            .putBoolean("lyric_shadow", lyrics.shadowEnabled)
            .putInt("lyric_shadow_opacity", lyrics.shadowOpacityPercent)
            .putInt("lyric_shadow_spread", lyrics.shadowSpreadDp)
            .putString("progress_color_mode", value.progressColorMode.name)
            .putInt("progress_custom_color", value.customProgressColor or Color.BLACK)
            .putInt("backdrop_blur", value.backgroundBlurPercent.coerceIn(0, 100))
            .putString("font_face", value.fontFaceId)
            .putString("language", value.appLanguage.name)
            .apply()
    }

    private fun legacyLyrics(): Boolean = store.getBoolean("lyrics", false)

    private inline fun <reified T : Enum<T>> choice(key: String, fallback: T): T {
        val raw = store.getString(key, null)
        return enumValues<T>().firstOrNull { it.name == raw } ?: fallback
    }
}
