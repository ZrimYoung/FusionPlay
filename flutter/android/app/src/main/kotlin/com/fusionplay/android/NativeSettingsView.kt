package com.fusionplay.android

import android.app.AlertDialog
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.text.InputFilter
import android.text.InputType
import android.widget.ArrayAdapter
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.Switch
import android.widget.TextView
import androidx.core.widget.doAfterTextChanged
import com.airplayreceiver.desktop.backend.AppSettings
import com.airplayreceiver.desktop.backend.MiPlayDeviceIdentity
import com.airplayreceiver.desktop.backend.ReceiverProtocol
import com.fusionplay.android.cast.NativeCastState
import java.util.Locale
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal sealed interface NativeSettingsAction {
    data class ReceiverName(val value: String) : NativeSettingsAction
    data class Startup(val value: Boolean) : NativeSettingsAction
    data class AutoWake(val value: Boolean) : NativeSettingsAction
    data class KeepScreenOn(val value: Boolean) : NativeSettingsAction
    data class AdvancedEffects(val value: Boolean) : NativeSettingsAction
    data class NativeCast(val value: Boolean) : NativeSettingsAction
    data class AudioAdvance(val value: Int) : NativeSettingsAction
    data class ReceiverRunning(val enabled: Boolean) : NativeSettingsAction
    data class AutoReceiveOnLaunch(val enabled: Boolean) : NativeSettingsAction
    data class Protocol(val protocol: ReceiverProtocol, val enabled: Boolean) : NativeSettingsAction
    data class Identity(val value: MiPlayDeviceIdentity) : NativeSettingsAction
    data class PlayerPreferences(val value: NativePlayerPreferences) : NativeSettingsAction
    data object ExportLogs : NativeSettingsAction
    data object RefreshDiagnostics : NativeSettingsAction
}

internal enum class NativeSettingsPage(val title: Int) {
    RECEIVER(R.string.native_settings_tab_receiver),
    APPEARANCE(R.string.native_settings_tab_appearance),
    AUDIO(R.string.native_settings_tab_audio),
    ABOUT(R.string.native_settings_about),
}

/** The receiver's settings form, hosted as an overlay by the player Activity. */
internal class NativeSettingsView(
    context: Context,
    private val onAction: (NativeSettingsAction) -> Unit,
    onClose: () -> Unit,
    initialPage: NativeSettingsPage? = null,
    fullScreen: Boolean,
) : LinearLayout(context) {
    private data class RenderKey(
        val settings: AppSettings,
        val effectiveReceiverName: String,
        val canEditReceiver: Boolean,
        val status: Int,
        val error: String?,
        val nativeCast: NativeCastState,
        val preferences: NativePlayerPreferences,
    )

    private val colors = NativeSettingsStyle(context)
    private var currentSettings = AppSettings()
    private var playerPreferences = NativePlayerPreferences()
    private var canEditReceiver = false
    private var binding = false
    private var openDialog: AlertDialog? = null
    private var lastRender: RenderKey? = null
    private val chooserScope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
    private var fontChooser: Job? = null
    private var fontFamilies: List<NativePlayerFonts.Family> = emptyList()
    var page = initialPage ?: NativeSettingsPage.RECEIVER
        private set

    private val pages = NativeSettingsPage.entries.associateWith {
        SettingsColumn(context).apply {
            orientation = VERTICAL
            setPaddingRelative(dp(16), dp(20), dp(16), dp(8))
        }
    }
    private val scrollPages = pages.mapValues { (_, body) ->
        ScrollView(context).apply {
            clipToPadding = false
            isFillViewport = true
            isVerticalFadingEdgeEnabled = false
            isFocusable = false
            addView(centered(body), FrameLayout.LayoutParams(MATCH, WRAP))
        }
    }
    private val tabBar = LinearLayout(context).apply {
        orientation = HORIZONTAL
    }
    private val tabs = NativeSettingsPage.entries.associateWith { SettingsTab(it) }
    private val heading = colors.label(R.string.native_settings_title, size = 24, bold = true).apply {
        if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
    }
    private val back = colors.back(onClose)
    private val statusValue = note(size = 16, color = colors.accent)
    private val warning = note(size = 14, color = colors.warning).apply {
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        visibility = GONE
    }
    private val editName = colors.choice(R.string.native_settings_device_name, ::showReceiverNameEditor)

    private val miPlay = toggle(R.string.native_settings_miplay) {
        onAction(NativeSettingsAction.Protocol(ReceiverProtocol.MIPLAY, it))
    }
    private val airPlay = toggle(R.string.native_settings_airplay) {
        onAction(NativeSettingsAction.Protocol(ReceiverProtocol.AIRPLAY, it))
    }
    private val dlna = toggle(R.string.native_settings_dlna) {
        onAction(NativeSettingsAction.Protocol(ReceiverProtocol.DLNA, it))
    }
    private val identity = colors.choice(R.string.native_settings_identity, ::chooseIdentity)
    private val receiverControls = NativeReceiverSettingsControls(
        context,
        { onAction(NativeSettingsAction.ReceiverRunning(it)) },
        { onAction(NativeSettingsAction.AutoReceiveOnLaunch(it)) },
        { onAction(NativeSettingsAction.AudioAdvance(it)) },
        { onAction(NativeSettingsAction.RefreshDiagnostics) },
        { onAction(NativeSettingsAction.ExportLogs) },
    )
    private val castSwitch = toggle(R.string.native_settings_cast_pause) {
        onAction(NativeSettingsAction.NativeCast(it))
    }
    private val castNote = note(size = 14, color = colors.secondary)
    private val castGroup = section(R.string.native_settings_native_cast, castSwitch, castNote)

    private val startup = toggle(R.string.native_settings_startup) {
        onAction(NativeSettingsAction.Startup(it))
    }
    private val autoWake = toggle(R.string.native_settings_auto_wake) {
        onAction(NativeSettingsAction.AutoWake(it))
    }
    private val keepScreenOn = toggle(R.string.native_settings_keep_screen_on) {
        onAction(NativeSettingsAction.KeepScreenOn(it))
    }
    private val advanced = toggle(R.string.native_settings_advanced) {
        onAction(NativeSettingsAction.AdvancedEffects(it))
    }

    private val progress = toggle(R.string.native_settings_progress) { enabled ->
        changePlayerPreferences { copy(showProgress = enabled) }
    }
    private val transport = toggle(R.string.native_settings_transport) { enabled ->
        changePlayerPreferences { copy(showTransport = enabled) }
    }
    private val wrapMetadata = toggle(R.string.native_settings_wrap_metadata) { enabled ->
        changePlayerPreferences { copy(wrapMetadata = enabled) }
    }
    private val lyrics: NativeSettingsChoiceRow = colors.choice(R.string.native_settings_lyrics, ::chooseLyricsMode)
    private val progressColor: NativeSettingsChoiceRow = colors.choice(R.string.native_settings_progress_color, ::chooseProgressColor)
    private val customColor = colors.choice(R.string.native_settings_custom_color, ::editProgressColor)
    private val backdrop = PreferenceSlider(R.string.native_settings_backdrop_blur, 0..100, R.string.native_settings_percent) {
        changePlayerPreferences { copy(backgroundBlurPercent = it) }
    }
    private val lyricScale = PreferenceSlider(R.string.native_settings_lyric_scale, NativeLyricAppearance.SCALE_RANGE,
        R.string.native_settings_percent) { value ->
        changePlayerPreferences { copy(lyricAppearance = lyricAppearance.copy(scalePercent = value)) }
    }
    private val lyricMove = PreferenceSlider(R.string.native_settings_lyric_move, NativeLyricAppearance.MOVE_RANGE,
        R.string.native_settings_lyric_stagger_value) { value ->
        changePlayerPreferences { copy(lyricAppearance = lyricAppearance.copy(moveMilliseconds = value)) }
    }
    private val lyricShadow = toggle(R.string.native_settings_lyric_shadow) { enabled ->
        changePlayerPreferences { copy(lyricAppearance = lyricAppearance.copy(shadowEnabled = enabled)) }
    }
    private val shadowOpacity = PreferenceSlider(R.string.native_settings_shadow_opacity,
        NativeLyricAppearance.SHADOW_OPACITY_RANGE, R.string.native_settings_percent) { value ->
        changePlayerPreferences { copy(lyricAppearance = lyricAppearance.copy(shadowOpacityPercent = value)) }
    }
    private val shadowSpread = PreferenceSlider(R.string.native_settings_shadow_spread,
        NativeLyricAppearance.SHADOW_SPREAD_RANGE, R.string.native_settings_dp) { value ->
        changePlayerPreferences { copy(lyricAppearance = lyricAppearance.copy(shadowSpreadDp = value)) }
    }
    private val narrowPaging = toggle(R.string.native_settings_narrow_paging) { enabled ->
        changePlayerPreferences { copy(narrowLyricsPaging = enabled) }
    }
    private val pageArtwork = toggle(R.string.native_settings_page_artwork) { enabled ->
        changePlayerPreferences { copy(lyricsPageShowsArtwork = enabled) }
    }
    private val pageTrack = toggle(R.string.native_settings_page_track_info) { enabled ->
        changePlayerPreferences { copy(lyricsPageShowsTrackInfo = enabled) }
    }
    private val font = colors.choice(R.string.native_settings_player_font, ::chooseFont)
    private val fontSample = note(R.string.native_settings_font_sample, size = 17).apply { maxLines = 2 }
    private val language: NativeSettingsChoiceRow = colors.choice(R.string.native_settings_language, ::chooseLanguage)
    private val staggerLyrics = toggle(R.string.native_settings_lyric_stagger) { enabled ->
        changePlayerPreferences { copy(staggerLyricMotion = enabled) }
    }
    private val staggerValue = label(size = 15, color = colors.secondary).apply {
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private val staggerSlider = SeekBar(context).apply {
        max = NativeLyricStagger.MAX_SPAN_MS / NativeLyricStagger.STEP_MS
        keyProgressIncrement = 1
        minimumHeight = dp(48)
        isFocusable = true
        contentDescription = context.getString(R.string.native_settings_lyric_stagger_span)
        progressTintList = ColorStateList.valueOf(colors.accent)
        thumbTintList = progressTintList
        setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onStartTrackingTouch(seekBar: SeekBar) = Unit
            override fun onStopTrackingTouch(seekBar: SeekBar) = Unit

            override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                if (fromUser && !binding) {
                    changePlayerPreferences { copy(lyricStaggerMilliseconds = progress * NativeLyricStagger.STEP_MS) }
                }
            }
        })
    }
    private val staggerControl = LinearLayout(context).apply {
        orientation = VERTICAL
        setPaddingRelative(dp(12), dp(4), dp(12), 0)
        addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            addView(label(R.string.native_settings_lyric_stagger_span, size = 15), LayoutParams(0, WRAP, 1f))
            addView(staggerValue, LayoutParams(WRAP, WRAP))
        }, LayoutParams(MATCH, WRAP))
        addView(staggerSlider, LayoutParams(MATCH, WRAP))
    }
    private val toolbar = toggle(R.string.native_settings_toolbar) { enabled ->
        changePlayerPreferences { copy(toolbarAlwaysVisible = enabled) }
    }
    private val correctTitles = toggle(R.string.native_settings_correct_lyric_titles) { enabled ->
        changePlayerPreferences { copy(correctLyricTitles = enabled) }
    }
    private val exportLogs = colors.action(R.string.native_settings_export) {
        onAction(NativeSettingsAction.ExportLogs)
    }
    init {
        orientation = VERTICAL
        background = colors.shape(colors.background, if (fullScreen) 0 else 24)
        clipToOutline = !fullScreen
        val header = SettingsColumn(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPaddingRelative(dp(10), dp(4), dp(16), dp(2))
            addView(back, LayoutParams(dp(48), dp(48)).apply { marginEnd = dp(8) })
            addView(heading, LayoutParams(0, WRAP, 1f))
        }
        addView(centered(header), LayoutParams(MATCH, WRAP))
        tabs.values.forEach { tabBar.addView(it, LayoutParams(WRAP, WRAP, 1f)) }
        val navigation = HorizontalScrollView(context).apply {
            isFillViewport = true
            isHorizontalScrollBarEnabled = false
            overScrollMode = OVER_SCROLL_NEVER
            isFocusable = false
            setPaddingRelative(dp(12), 0, dp(12), 0)
            addView(tabBar, FrameLayout.LayoutParams(WRAP, WRAP))
        }
        addView(centered(SettingsColumn(context).apply {
            orientation = VERTICAL
            addView(navigation, LayoutParams(MATCH, WRAP))
            addView(View(context).apply { setBackgroundColor(colors.divider) }, LayoutParams(MATCH, dp(1)).apply {
                marginStart = dp(16)
                marginEnd = dp(16)
            })
        }), LayoutParams(MATCH, WRAP))

        val version = note(size = 17).apply {
            text = context.getString(R.string.native_settings_version, BuildConfig.VERSION_NAME)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        }
        val receiver = pages.getValue(NativeSettingsPage.RECEIVER)
        receiver.addView(section(R.string.native_settings_receiver_status, statusValue, receiverControls.receiver, warning))
        receiver.addView(section(R.string.native_settings_device, editName, identity))
        receiver.addView(section(R.string.native_settings_protocols, miPlay, airPlay, dlna))
        receiver.addView(castGroup)
        receiver.addView(section(R.string.native_settings_device_behavior, startup, autoWake,
            note(R.string.native_settings_automatic_behavior_hint, size = 14, color = colors.secondary), keepScreenOn))

        val appearance = pages.getValue(NativeSettingsPage.APPEARANCE)
        appearance.addView(section(R.string.native_settings_player,
            progress, progressColor, customColor, backdrop, transport, wrapMetadata, toolbar))
        appearance.addView(section(R.string.native_settings_lyric_group, lyrics, lyricScale, lyricMove, lyricShadow,
            shadowOpacity, shadowSpread, staggerLyrics, staggerControl, correctTitles, advanced))
        appearance.addView(section(R.string.native_settings_narrow_layout, narrowPaging, pageArtwork, pageTrack))
        appearance.addView(section(R.string.native_settings_typography, font, fontSample, language))
        pages.getValue(NativeSettingsPage.AUDIO).addView(receiverControls.audio, LayoutParams(MATCH, WRAP))
        pages.getValue(NativeSettingsPage.ABOUT).addView(section(null, version,
            note(R.string.native_settings_license, size = 15, color = colors.secondary), exportLogs))

        val content = FrameLayout(context)
        scrollPages.values.forEach { content.addView(it, FrameLayout.LayoutParams(MATCH, MATCH)) }
        addView(content, LayoutParams(MATCH, 0, 1f))
        selectPage(page)
    }

    fun render(ui: ReceiverUiState, preferences: NativePlayerPreferences) {
        receiverControls.render(ui)
        val state = ui.state
        val cast = ui.nativeCast
        val status = when {
            !state.initialized -> R.string.native_settings_initializing
            state.busy -> R.string.native_settings_working
            !ui.receiverRunning -> R.string.native_settings_stopped
            state.playback.isPlaying -> R.string.native_settings_playing
            state.playback.streamActive -> R.string.native_settings_connected
            !state.settings.miPlayEnabled && !state.settings.airPlayEnabled && !state.settings.dlnaEnabled ->
                R.string.native_settings_protocols_off
            else -> R.string.native_settings_waiting
        }
        val next = RenderKey(
            state.settings,
            ui.receiverName,
            state.initialized && !state.busy,
            status,
            state.lastError,
            cast,
            preferences,
        )
        if (next == lastRender) return
        lastRender = next
        binding = true
        try {
            currentSettings = next.settings
            playerPreferences = preferences
            canEditReceiver = next.canEditReceiver
            editName.setValue(next.effectiveReceiverName.ifBlank { context.getString(R.string.native_settings_default_name) })
            editName.isEnabled = canEditReceiver

            statusValue.setText(next.status)
            warning.bindNote(next.error.orEmpty())

            miPlay.bind(currentSettings.miPlayEnabled, canEditReceiver)
            airPlay.bind(currentSettings.airPlayEnabled, canEditReceiver)
            dlna.bind(currentSettings.dlnaEnabled, canEditReceiver)
            identity.setValue(currentSettings.miPlayDeviceIdentity.displayName)
            identity.isEnabled = canEditReceiver
            castGroup.visibility = if (cast.supported) VISIBLE else GONE
            castSwitch.bind(cast.paused, canEditReceiver && !cast.busy)
            castNote.bindNote(if (cast.busy) context.getString(R.string.native_settings_working) else cast.message)

            startup.bind(currentSettings.startupEnabled, canEditReceiver)
            autoWake.bind(currentSettings.autoWakeEnabled, canEditReceiver)
            keepScreenOn.bind(currentSettings.keepScreenOnWhilePlaying, canEditReceiver)
            advanced.bind(currentSettings.advancedEffectsEnabled, canEditReceiver)
            exportLogs.isEnabled = canEditReceiver

            progress.bind(preferences.showProgress)
            transport.bind(preferences.showTransport)
            wrapMetadata.bind(preferences.wrapMetadata)
            bindAppearance(preferences)
            staggerLyrics.bind(preferences.staggerLyricMotion)
            bindStagger(preferences)
            toolbar.bind(preferences.toolbarAlwaysVisible)
            correctTitles.bind(preferences.correctLyricTitles)
        } finally {
            binding = false
        }
    }

    fun focusEntry() {
        post {
            if (isShown && !isInTouchMode) tabs.getValue(page).button.requestFocus()
        }
    }

    private fun selectPage(item: NativeSettingsPage) {
        page = item
        scrollPages.forEach { (key, view) -> view.visibility = if (key == item) VISIBLE else GONE }
        tabs.forEach { (key, tab) -> tab.bind(key == item) }
    }

    override fun onDetachedFromWindow() {
        chooserScope.cancel()
        openDialog?.dismiss()
        super.onDetachedFromWindow()
    }

    private fun showReceiverNameEditor() {
        if (!canEditReceiver || openDialog != null) return
        val savedName = currentSettings.receiverName.orEmpty()
        val editor = EditText(context).apply {
            setSingleLine(true)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI
            filters = arrayOf(InputFilter.LengthFilter(AppSettings.MAX_RECEIVER_NAME_LENGTH))
            hint = lastRender?.effectiveReceiverName?.takeIf(String::isNotBlank)
                ?: context.getString(R.string.native_settings_default_name)
            setText(savedName)
            setSelection(text.length)
        }
        fun saveName(value: String) {
            val name = value.trim()
            if (name != currentSettings.receiverName.orEmpty()) {
                onAction(NativeSettingsAction.ReceiverName(name))
            }
        }
        val dialog = AlertDialog.Builder(context)
            .setTitle(R.string.native_settings_device_name)
            .setView(FrameLayout(context).apply {
                setPadding(dp(20), dp(8), dp(20), 0)
                addView(editor, FrameLayout.LayoutParams(MATCH, WRAP))
            })
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.native_settings_done) { _, _ -> saveName(editor.text.toString()) }
            .apply { if (savedName.isNotEmpty()) setNeutralButton(R.string.native_settings_reset_name) { _, _ -> saveName("") } }
            .create()
        editor.setOnEditorActionListener { _, action, event ->
            val enter = event?.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN
            if (action == EditorInfo.IME_ACTION_DONE || enter) {
                dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.performClick() == true
            } else false
        }
        dialog.setOnShowListener {
            editor.requestFocus()
            dialog.window?.setSoftInputMode(
                WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE or
                    WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE,
            )
            editor.postDelayed({
                if (dialog.isShowing && editor.hasFocus()) {
                    context.getSystemService(InputMethodManager::class.java)
                        ?.showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT)
                }
            }, 150)
        }
        show(dialog)
    }

    private fun chooseIdentity() {
        if (!canEditReceiver || openDialog != null) return
        val options = MiPlayDeviceIdentity.entries
        show(AlertDialog.Builder(context)
            .setTitle(R.string.native_settings_identity)
            .setSingleChoiceItems(
                options.map { it.displayName }.toTypedArray(),
                options.indexOf(currentSettings.miPlayDeviceIdentity),
            ) { dialog, index ->
                dialog.dismiss()
                if (canEditReceiver && options[index] != currentSettings.miPlayDeviceIdentity) {
                    onAction(NativeSettingsAction.Identity(options[index]))
                }
            }
            .setNegativeButton(android.R.string.cancel, null)
            .create(), identity)
    }

    private fun show(dialog: AlertDialog, focusAfter: View = editName) {
        openDialog = dialog
        dialog.setOnDismissListener {
            if (openDialog === dialog) openDialog = null
            if (isShown && !isInTouchMode && focusAfter.isEnabled) focusAfter.requestFocus()
        }
        dialog.show()
    }

    private fun changePlayerPreferences(change: NativePlayerPreferences.() -> NativePlayerPreferences) {
        val updated = playerPreferences.change()
        if (updated == playerPreferences) return
        playerPreferences = updated
        onAction(NativeSettingsAction.PlayerPreferences(updated))
    }

    private fun bindAppearance(preferences: NativePlayerPreferences) {
        lyrics.setValue(context.getText(lyricsModeLabel(preferences.lyricsDisplayMode)))
        progressColor.setValue(context.getText(progressColorLabel(preferences.progressColorMode)))
        val custom = preferences.progressColorMode == NativeProgressColorMode.CUSTOM
        customColor.visibility = if (custom) VISIBLE else GONE
        customColor.setValue(colorHex(preferences.customProgressColor))
        backdrop.bind(preferences.backgroundBlurPercent)
        lyricScale.bind(preferences.lyricAppearance.scalePercent)
        lyricMove.bind(preferences.lyricAppearance.moveMilliseconds)
        val hasShadow = preferences.lyricAppearance.shadowEnabled
        lyricShadow.bind(hasShadow)
        shadowOpacity.visibility = if (hasShadow) VISIBLE else GONE
        shadowSpread.visibility = shadowOpacity.visibility
        shadowOpacity.bind(preferences.lyricAppearance.shadowOpacityPercent)
        shadowSpread.bind(preferences.lyricAppearance.shadowSpreadDp)
        narrowPaging.bind(preferences.narrowLyricsPaging)
        pageArtwork.bind(preferences.lyricsPageShowsArtwork)
        pageTrack.bind(preferences.lyricsPageShowsTrackInfo)
        pageArtwork.visibility = if (preferences.narrowLyricsPaging) VISIBLE else GONE
        pageTrack.visibility = pageArtwork.visibility
        val face = NativePlayerFonts.typeface(preferences.fontFaceId)
        val fontName = NativePlayerFonts.faceLabel(preferences.fontFaceId)
        font.setValue(fontName ?: context.getText(R.string.native_settings_system_font))
        font.isEnabled = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && fontChooser?.isActive != true
        fontSample.typeface = face ?: Typeface.DEFAULT
        fontSample.visibility = if (face != null) VISIBLE else GONE
        language.setValue(context.getText(languageLabel(preferences.appLanguage)))
    }

    private fun lyricsModeLabel(value: NativeLyricsDisplayMode) = when (value) {
        NativeLyricsDisplayMode.AUTOMATIC -> R.string.native_settings_lyrics_automatic
        NativeLyricsDisplayMode.NEVER -> R.string.native_settings_lyrics_never
    }

    private fun progressColorLabel(value: NativeProgressColorMode) = when (value) {
        NativeProgressColorMode.SYSTEM -> R.string.native_settings_follow_system
        NativeProgressColorMode.WHITE -> R.string.native_settings_white
        NativeProgressColorMode.CUSTOM -> R.string.native_settings_custom_color
    }

    private fun languageLabel(value: NativeAppLanguage) = when (value) {
        NativeAppLanguage.SYSTEM -> R.string.native_settings_follow_system
        NativeAppLanguage.CHINESE -> R.string.native_settings_chinese
        NativeAppLanguage.ENGLISH -> R.string.native_settings_english
    }

    private fun chooseLyricsMode() = chooseOption(R.string.native_settings_lyrics, NativeLyricsDisplayMode.entries,
        playerPreferences.lyricsDisplayMode, ::lyricsModeLabel, lyrics) { value ->
        changePlayerPreferences { copy(lyricsDisplayMode = value) }
    }

    private fun chooseProgressColor() = chooseOption(R.string.native_settings_progress_color, NativeProgressColorMode.entries,
        playerPreferences.progressColorMode, ::progressColorLabel, progressColor) { value ->
        changePlayerPreferences { copy(progressColorMode = value) }
    }

    private fun chooseLanguage() = chooseOption(R.string.native_settings_language, NativeAppLanguage.entries,
        playerPreferences.appLanguage, ::languageLabel, language) { value ->
        changePlayerPreferences { copy(appLanguage = value) }
    }

    private fun <T> chooseOption(title: Int, values: List<T>, selection: T, label: (T) -> Int, anchor: View, onPick: (T) -> Unit) {
        if (openDialog != null) return
        show(AlertDialog.Builder(context).setTitle(title)
            .setSingleChoiceItems(values.map { context.getString(label(it)) }.toTypedArray(), values.indexOf(selection)) { dialog, index ->
                dialog.dismiss()
                onPick(values[index])
            }
            .setNegativeButton(android.R.string.cancel, null).create(), anchor)
    }

    private fun colorHex(color: Int) = String.format(Locale.ROOT, "#%06X", color and 0x00ffffff)

    private fun editProgressColor() {
        if (openDialog != null) return
        val swatch = View(context)
        val editor = EditText(context).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            setSingleLine(true)
            imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI
            filters = arrayOf(InputFilter.LengthFilter(7))
            hint = "#83BFE3"
            contentDescription = context.getString(R.string.native_settings_hex_color)
            setText(colorHex(playerPreferences.customProgressColor))
            setSelectAllOnFocus(true)
        }
        fun parsed(): Int? {
            val digits = editor.text.toString().trim().removePrefix("#")
            return digits.takeIf { it.length == 6 }?.toIntOrNull(16)?.takeIf { it >= 0 }?.or(Color.BLACK)
        }
        val fields = dialogColumn().apply {
            addView(swatch, LayoutParams(MATCH, dp(36)))
            addView(editor, LayoutParams(MATCH, WRAP))
        }
        fun updateSwatch() {
            swatch.background = colors.shape(parsed() ?: playerPreferences.customProgressColor, 10)
        }
        updateSwatch()
        editor.doAfterTextChanged { updateSwatch() }
        val dialog = AlertDialog.Builder(context).setTitle(R.string.native_settings_custom_color)
            .setView(fields).setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.native_settings_done, null).create()
        editor.setOnEditorActionListener { _, action, event ->
            val enter = event?.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN
            if (action == EditorInfo.IME_ACTION_DONE || enter) {
                dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.performClick() == true
            } else false
        }
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val color = parsed()
                if (color == null) editor.error = context.getString(R.string.native_settings_hex_error)
                else {
                    dialog.dismiss()
                    changePlayerPreferences { copy(customProgressColor = color) }
                }
            }
        }
        show(dialog, customColor)
    }

    private fun chooseFont() {
        if (openDialog != null || fontChooser?.isActive == true) return
        font.isEnabled = false
        fontChooser = chooserScope.launch {
            fontFamilies = withContext(Dispatchers.IO) { NativePlayerFonts.installedFamilies() }
            font.isEnabled = true
            if (isAttachedToWindow) showFontFamilies()
        }
    }

    private fun showFontFamilies() {
        val search = EditText(context).apply {
            hint = context.getString(R.string.native_settings_search_fonts)
            setSingleLine(true)
        }
        val names = ArrayAdapter<String>(context, android.R.layout.simple_list_item_1)
        val list = ListView(context).apply { adapter = names }
        var matches = fontFamilies
        fun filter(query: String) {
            matches = fontFamilies.filter { it.name.contains(query.trim(), ignoreCase = true) }
            names.clear()
            names.add(context.getString(R.string.native_settings_system_font))
            names.addAll(matches.map(NativePlayerFonts.Family::name))
        }
        filter("")
        search.doAfterTextChanged { filter(it.toString()) }
        val fields = dialogColumn().apply {
            isFocusableInTouchMode = true
            addView(search, LayoutParams(MATCH, WRAP))
            addView(list, LayoutParams(MATCH, dp(minOf(360, resources.configuration.screenHeightDp / 2))))
        }
        val dialog = AlertDialog.Builder(context).setTitle(R.string.native_settings_font_family)
            .setView(fields).setNegativeButton(android.R.string.cancel, null).create()
        list.setOnItemClickListener { _, _, index, _ ->
            val selection = matches.getOrNull(index - 1)
            dialog.dismiss()
            if (selection == null) changePlayerPreferences { copy(fontFaceId = "") } else chooseFontFace(selection)
        }
        show(dialog, font)
        fields.requestFocus()
    }

    private fun chooseFontFace(family: NativePlayerFonts.Family) {
        val selected = family.faces.indexOfFirst { it.id == playerPreferences.fontFaceId }
        val sampleIndex = if (selected >= 0) selected else family.faces.indexOfFirst { it.weight == 400 && !it.italic }.coerceAtLeast(0)
        val sample = label(R.string.native_settings_font_sample, size = 22)
        val choices = ListView(context).apply {
            choiceMode = ListView.CHOICE_MODE_SINGLE
            adapter = ArrayAdapter(context, android.R.layout.simple_list_item_single_choice, family.faces.map { it.style })
            if (selected >= 0) setItemChecked(selected, true)
            setOnItemClickListener { _, _, index, _ ->
                val faceId = family.faces[index].id
                sample.typeface = NativePlayerFonts.typeface(faceId) ?: Typeface.DEFAULT
                changePlayerPreferences { copy(fontFaceId = faceId) }
            }
        }
        sample.typeface = NativePlayerFonts.typeface(family.faces[sampleIndex].id) ?: Typeface.DEFAULT
        show(AlertDialog.Builder(context).setTitle(family.name)
            .setView(dialogColumn().apply {
                addView(choices, LayoutParams(MATCH, dp((family.faces.size * 48).coerceIn(48, 240))))
                addView(sample, LayoutParams(MATCH, WRAP))
            })
            .setPositiveButton(R.string.native_settings_done, null).create(), font)
    }

    private fun dialogColumn() = LinearLayout(context).apply {
        orientation = VERTICAL
        setPadding(dp(20), dp(6), dp(20), dp(8))
    }

    private inner class PreferenceSlider(title: Int, private val range: IntRange, private val format: Int,
        onChange: (Int) -> Unit) : LinearLayout(context) {
        private val value = label(size = 15, color = colors.secondary).apply {
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        private val slider = SeekBar(context).apply {
            max = range.last - range.first
            keyProgressIncrement = (max / 25).coerceAtLeast(1)
            minimumHeight = dp(48)
            isFocusable = true
            contentDescription = context.getString(title)
            progressTintList = ColorStateList.valueOf(colors.accent)
            thumbTintList = progressTintList
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onStartTrackingTouch(seekBar: SeekBar) = Unit
                override fun onStopTrackingTouch(seekBar: SeekBar) = Unit
                override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                    if (fromUser && !binding) onChange(range.first + progress)
                }
            })
        }

        init {
            orientation = VERTICAL
            setPaddingRelative(dp(12), dp(4), dp(12), 0)
            addView(LinearLayout(context).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(label(title, size = 15), LayoutParams(0, WRAP, 1f))
                addView(value, LayoutParams(WRAP, WRAP))
            }, LayoutParams(MATCH, WRAP))
            addView(slider, LayoutParams(MATCH, WRAP))
        }

        fun bind(current: Int) {
            val clamped = current.coerceIn(range)
            slider.progress = clamped - range.first
            val formatted = context.getString(format, clamped)
            value.text = formatted
            if (Build.VERSION.SDK_INT >= 30) slider.stateDescription = formatted
        }

    }

    private fun bindStagger(preferences: NativePlayerPreferences) {
        val enabled = preferences.staggerLyricMotion
        if (!enabled && staggerControl.hasFocus()) staggerLyrics.requestFocus()
        staggerControl.visibility = if (enabled) VISIBLE else GONE
        val span = NativeLyricStagger.clampSpan(preferences.lyricStaggerMilliseconds)
        staggerSlider.progress = span / NativeLyricStagger.STEP_MS
        val value = context.getString(R.string.native_settings_lyric_stagger_value, span)
        staggerValue.text = value
        if (Build.VERSION.SDK_INT >= 30) staggerSlider.stateDescription = value
    }

    private fun TextView.bindNote(note: String) {
        if (text.toString() != note) text = note
        visibility = if (note.isBlank()) GONE else VISIBLE
    }

    private fun Switch.bind(value: Boolean, enabled: Boolean = true) {
        isChecked = value
        isEnabled = enabled
    }

    private fun centered(child: View): FrameLayout = FrameLayout(context).apply {
        addView(child, FrameLayout.LayoutParams(MATCH, WRAP, Gravity.TOP or Gravity.CENTER_HORIZONTAL))
    }

    private fun section(title: Int?, vararg rows: View) = colors.section(title, *rows)

    private fun label(id: Int? = null, size: Int, color: Int = colors.text): TextView = colors.label(id, size, color).apply {
        setPaddingRelative(dp(4), dp(6), dp(4), dp(6))
    }

    private fun note(id: Int? = null, size: Int, color: Int = colors.text): TextView = colors.label(id, size, color).apply {
        setPaddingRelative(dp(16), dp(14), dp(16), dp(14))
    }

    private fun toggle(id: Int, onChanged: (Boolean) -> Unit): Switch = colors.toggle(id) { enabled ->
        if (!binding) onChanged(enabled)
    }

    private fun dp(value: Int) = colors.dp(value)

    private inner class SettingsTab(item: NativeSettingsPage) : FrameLayout(context) {
        val button = colors.action(item.title) { selectPage(item) }.apply {
            textSize = 15f
            gravity = Gravity.CENTER
            minimumWidth = dp(64)
            maxLines = 1
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setPaddingRelative(dp(12), dp(6), dp(12), dp(9))
        }
        private val indicator = View(context).apply {
            background = colors.shape(colors.accent, 2)
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }

        init {
            addView(button, LayoutParams(MATCH, WRAP))
            addView(indicator, LayoutParams(dp(23), dp(3), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))
        }

        fun bind(selected: Boolean) {
            button.isSelected = selected
            button.setTextColor(if (selected) colors.accent else colors.secondary)
            indicator.visibility = if (selected) VISIBLE else INVISIBLE
        }
    }

    private class SettingsColumn(context: Context) : LinearLayout(context) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val cap = (620 * resources.displayMetrics.density).roundToInt()
            val width = when (MeasureSpec.getMode(widthMeasureSpec)) {
                MeasureSpec.UNSPECIFIED -> cap
                else -> MeasureSpec.getSize(widthMeasureSpec).coerceAtMost(cap)
            }
            super.onMeasure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY), heightMeasureSpec)
        }
    }

    private companion object {
        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
    }
}
