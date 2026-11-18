package com.fusionplay.android

import android.app.AlertDialog
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.graphics.drawable.StateListDrawable
import android.os.Build
import android.text.InputFilter
import android.text.InputType
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.Switch
import android.widget.TextView
import com.airplayreceiver.desktop.backend.AppSettings
import com.airplayreceiver.desktop.backend.AppState
import com.airplayreceiver.desktop.backend.MiPlayDeviceIdentity
import com.airplayreceiver.desktop.backend.ReceiverProtocol
import com.fusionplay.android.cast.NativeCastState
import kotlin.math.roundToInt

sealed interface NativeSettingsAction {
    data class ReceiverName(val value: String) : NativeSettingsAction
    data class Startup(val value: Boolean) : NativeSettingsAction
    data class AutoWake(val value: Boolean) : NativeSettingsAction
    data class KeepScreenOn(val value: Boolean) : NativeSettingsAction
    data class AdvancedEffects(val value: Boolean) : NativeSettingsAction
    data class NativeCast(val value: Boolean) : NativeSettingsAction
    data class AudioAdvance(val value: Int) : NativeSettingsAction
    data class Protocol(val protocol: ReceiverProtocol, val enabled: Boolean) : NativeSettingsAction
    data class Identity(val value: MiPlayDeviceIdentity) : NativeSettingsAction
    data class PlayerPreferences(val value: NativePlayerPreferences) : NativeSettingsAction
    data object ExportLogs : NativeSettingsAction
}

/** The receiver's settings form, hosted as an overlay by the player Activity. */
class NativeSettingsView(
    context: Context,
    private val onAction: (NativeSettingsAction) -> Unit,
    onClose: () -> Unit,
) : LinearLayout(context) {
    private data class RenderKey(
        val settings: AppSettings,
        val canEditReceiver: Boolean,
        val status: Int,
        val error: String?,
        val nativeCast: NativeCastState,
        val advanceMs: Int,
        val preferences: NativePlayerPreferences,
    )

    private val colors = SettingsColors(context)
    private var currentSettings = AppSettings()
    private var playerPreferences = NativePlayerPreferences()
    private var draftName = ""
    private var canEditReceiver = false
    private var binding = false
    private var openDialog: AlertDialog? = null
    private var lastRender: RenderKey? = null

    private val body = SettingsColumn(context)
    private val statusValue = label(size = 16)
    private val warning = label(size = 14, color = colors.warning).apply {
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        visibility = GONE
    }
    private val editName = button(R.string.native_settings_default_name) { editName() }
    private val applyName = button(R.string.native_settings_apply_name, emphasized = true) {
        onAction(NativeSettingsAction.ReceiverName(draftName.trim()))
    }
    private val resetName = button(R.string.native_settings_reset_name) {
        draftName = ""
        bindName()
        onAction(NativeSettingsAction.ReceiverName(""))
    }

    private val miPlay = toggle(R.string.native_settings_miplay) {
        onAction(NativeSettingsAction.Protocol(ReceiverProtocol.MIPLAY, it))
    }
    private val airPlay = toggle(R.string.native_settings_airplay) {
        onAction(NativeSettingsAction.Protocol(ReceiverProtocol.AIRPLAY, it))
    }
    private val dlna = toggle(R.string.native_settings_dlna) {
        onAction(NativeSettingsAction.Protocol(ReceiverProtocol.DLNA, it))
    }
    private val identity = button(R.string.native_settings_identity) { chooseIdentity() }
    private var displayedAdvance = 0
    private val audioValue = label(size = 17, color = colors.text, bold = true)
    private val decreaseAdvance = button(R.string.native_settings_decrease) {
        onAction(NativeSettingsAction.AudioAdvance((displayedAdvance - 10).coerceAtLeast(0)))
    }.apply { contentDescription = context.getString(R.string.native_settings_decrease_description) }
    private val increaseAdvance = button(R.string.native_settings_increase) {
        onAction(NativeSettingsAction.AudioAdvance((displayedAdvance + 10).coerceAtMost(500)))
    }.apply { contentDescription = context.getString(R.string.native_settings_increase_description) }
    private val resetAdvance = button(R.string.native_settings_zero) {
        onAction(NativeSettingsAction.AudioAdvance(0))
    }
    private val castSwitch = toggle(R.string.native_settings_cast_pause) {
        onAction(NativeSettingsAction.NativeCast(it))
    }
    private val castNote = label(size = 14, color = colors.secondary)
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
    private val lyrics = toggle(R.string.native_settings_lyrics) { enabled ->
        changePlayerPreferences { copy(showLyrics = enabled) }
    }
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
        progressTintList = ColorStateList.valueOf(colors.action)
        thumbTintList = ColorStateList.valueOf(colors.action)
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
    private val exportLogs = button(R.string.native_settings_export) {
        onAction(NativeSettingsAction.ExportLogs)
    }
    private val done = button(R.string.native_settings_done, emphasized = true, action = onClose)

    init {
        orientation = VERTICAL
        setBackgroundColor(colors.background)
        val header = SettingsColumn(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(8), dp(16), dp(8))
            val heading = label(R.string.native_settings_title, size = 22, bold = true)
            if (Build.VERSION.SDK_INT >= 28) heading.isAccessibilityHeading = true
            addView(heading, LayoutParams(0, WRAP, 1f))
            addView(done, LayoutParams(WRAP, WRAP).apply { marginStart = dp(12) })
        }
        addView(centered(header), LayoutParams(MATCH, WRAP))

        val version = label(size = 16).apply {
            text = context.getString(R.string.native_settings_version, BuildConfig.VERSION_NAME)
        }
        body.orientation = VERTICAL
        body.setPadding(dp(16), 0, dp(16), dp(24))
        body.addView(section(R.string.native_settings_receiver_status, statusValue, warning))
        body.addView(section(R.string.native_settings_device_name, editName, buttonRow(resetName, applyName)))
        body.addView(section(R.string.native_settings_protocols, miPlay, airPlay, dlna, identity))
        body.addView(section(
            R.string.native_settings_audio_sync,
            audioValue,
            label(R.string.native_settings_audio_hint, size = 14, color = colors.secondary),
            buttonRow(decreaseAdvance, increaseAdvance, resetAdvance),
        ))
        body.addView(castGroup)
        body.addView(section(R.string.native_settings_device_behavior, startup, autoWake, keepScreenOn, advanced))
        body.addView(section(
            R.string.native_settings_player,
            progress, transport, wrapMetadata, lyrics, staggerLyrics, staggerControl, toolbar, correctTitles,
        ))
        body.addView(section(R.string.native_settings_about, version, exportLogs))

        addView(ScrollView(context).apply {
            clipToPadding = false
            isFillViewport = true
            isVerticalFadingEdgeEnabled = false
            addView(centered(body), FrameLayout.LayoutParams(MATCH, WRAP))
        }, LayoutParams(MATCH, 0, 1f))
        render(AppState(), NativeCastState(), 0, NativePlayerPreferences())
    }

    fun render(state: AppState, cast: NativeCastState, advanceMs: Int, preferences: NativePlayerPreferences) {
        val status = when {
            !state.initialized -> R.string.native_settings_initializing
            state.busy -> R.string.native_settings_working
            state.playback.isPlaying -> R.string.native_settings_playing
            state.playback.streamActive -> R.string.native_settings_connected
            !state.settings.miPlayEnabled && !state.settings.airPlayEnabled && !state.settings.dlnaEnabled ->
                R.string.native_settings_protocols_off
            else -> R.string.native_settings_waiting
        }
        val next = RenderKey(
            state.settings,
            state.initialized && !state.busy,
            status,
            state.lastError,
            cast,
            advanceMs.coerceIn(0, 500),
            preferences,
        )
        if (next == lastRender) return
        lastRender = next
        binding = true
        try {
            val oldName = currentSettings.receiverName.orEmpty()
            if (draftName == oldName) draftName = next.settings.receiverName.orEmpty()
            currentSettings = next.settings
            playerPreferences = preferences
            canEditReceiver = next.canEditReceiver
            displayedAdvance = next.advanceMs
            bindName()

            statusValue.setText(next.status)
            warning.bindNote(next.error.orEmpty())

            miPlay.bind(currentSettings.miPlayEnabled, canEditReceiver)
            airPlay.bind(currentSettings.airPlayEnabled, canEditReceiver)
            dlna.bind(currentSettings.dlnaEnabled, canEditReceiver)
            identity.text = context.getString(R.string.native_settings_current_identity, currentSettings.miPlayDeviceIdentity.displayName)
            identity.isEnabled = canEditReceiver
            audioValue.text = context.getString(R.string.native_settings_advance_value, displayedAdvance)
            decreaseAdvance.isEnabled = canEditReceiver && displayedAdvance > 0
            increaseAdvance.isEnabled = canEditReceiver && displayedAdvance < 500
            resetAdvance.isEnabled = canEditReceiver && displayedAdvance != 0

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
            lyrics.bind(preferences.showLyrics)
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
            if (isShown && !isInTouchMode) (if (editName.isEnabled) editName else done).requestFocus()
        }
    }

    override fun onDetachedFromWindow() {
        openDialog?.dismiss()
        super.onDetachedFromWindow()
    }

    private fun bindName() {
        val saved = currentSettings.receiverName.orEmpty()
        editName.text = draftName.ifBlank { context.getString(R.string.native_settings_default_name) }
        editName.contentDescription = context.getString(R.string.native_settings_edit_name, editName.text)
        editName.isEnabled = canEditReceiver
        applyName.isEnabled = canEditReceiver && draftName.trim() != saved
        resetName.isEnabled = canEditReceiver && (saved.isNotEmpty() || draftName.isNotEmpty())
    }

    private fun editName() {
        if (!canEditReceiver || openDialog != null) return
        val editor = EditText(context).apply {
            setSingleLine(true)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI
            filters = arrayOf(InputFilter.LengthFilter(AppSettings.MAX_RECEIVER_NAME_LENGTH))
            hint = context.getString(R.string.native_settings_default_name)
            setText(draftName)
            setSelection(text.length)
        }
        val dialog = AlertDialog.Builder(context)
            .setTitle(R.string.native_settings_device_name)
            .setView(FrameLayout(context).apply {
                setPadding(dp(20), dp(8), dp(20), 0)
                addView(editor, FrameLayout.LayoutParams(MATCH, WRAP))
            })
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.native_settings_done) { _, _ ->
                draftName = editor.text.toString()
                bindName()
            }
            .create()
        editor.setOnEditorActionListener { _, action, _ ->
            if (action != EditorInfo.IME_ACTION_DONE) return@setOnEditorActionListener false
            dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.performClick() == true
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
        playerPreferences = playerPreferences.change()
        onAction(NativeSettingsAction.PlayerPreferences(playerPreferences))
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

    private fun section(title: Int, vararg rows: View): LinearLayout = LinearLayout(context).apply {
        orientation = VERTICAL
        layoutParams = LayoutParams(MATCH, WRAP).apply { bottomMargin = dp(18) }
        addView(label(title, size = 15, color = colors.secondary, bold = true).apply {
            setPadding(dp(12), dp(3), dp(12), dp(6))
            if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
        }, LayoutParams(MATCH, WRAP))
        val card = LinearLayout(context).apply {
            orientation = VERTICAL
            background = shape(colors.card, 20)
            setPadding(dp(12), dp(4), dp(12), dp(4))
            rows.forEach { row ->
                addView(row, LayoutParams(MATCH, WRAP).apply { topMargin = dp(2); bottomMargin = dp(2) })
            }
        }
        addView(card, LayoutParams(MATCH, WRAP))
    }

    private fun buttonRow(vararg buttons: Button): LinearLayout = LinearLayout(context).apply {
        orientation = HORIZONTAL
        buttons.forEachIndexed { index, action ->
            addView(action, LayoutParams(0, WRAP, 1f).apply { if (index > 0) marginStart = dp(8) })
        }
    }

    private fun label(id: Int? = null, size: Int, color: Int = colors.text, bold: Boolean = false): TextView = TextView(context).apply {
        if (id != null) setText(id)
        textSize = size.toFloat()
        setTextColor(color)
        if (bold) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setPadding(dp(4), dp(6), dp(4), dp(6))
    }

    private fun button(id: Int, emphasized: Boolean = false, action: () -> Unit): Button = Button(context).apply {
        setText(id)
        textSize = 15f
        setTextColor(ColorStateList(
            arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()),
            intArrayOf(colors.disabledText, if (emphasized) colors.actionText else colors.text),
        ))
        setAllCaps(false)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        maxLines = 2
        ellipsize = TextUtils.TruncateAt.END
        minHeight = dp(48)
        minimumHeight = dp(48)
        minWidth = 0
        minimumWidth = 0
        setPadding(dp(10), dp(5), dp(10), dp(5))
        background = interactiveBackground(if (emphasized) colors.action else colors.button)
        stateListAnimator = null
        isFocusable = true
        setOnClickListener { action() }
    }

    private fun toggle(id: Int, onChanged: (Boolean) -> Unit): Switch = Switch(context).apply {
        setText(id)
        textSize = 16f
        setTextColor(ColorStateList(
            arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()),
            intArrayOf(colors.disabledText, colors.text),
        ))
        minHeight = dp(52)
        setPadding(dp(8), dp(6), dp(8), dp(6))
        switchPadding = dp(12)
        showText = false
        splitTrack = false
        isFocusable = true
        background = interactiveBackground(colors.card)
        thumbTintList = checkedColors(colors.thumbOn, colors.thumbOff, colors.trackOff)
        trackTintList = checkedColors(colors.switchOn, colors.trackOff, colors.button)
        setOnCheckedChangeListener { _, enabled -> if (!binding) onChanged(enabled) }
    }

    private fun checkedColors(on: Int, off: Int, disabled: Int) = ColorStateList(
        arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf(android.R.attr.state_checked), intArrayOf()),
        intArrayOf(disabled, on, off),
    )

    private fun interactiveBackground(fill: Int) = RippleDrawable(
        ColorStateList.valueOf(colors.ripple),
        StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_focused), shape(fill, 12, colors.focus))
            addState(intArrayOf(), shape(fill, 12))
        },
        shape(-1, 12),
    )

    private fun shape(fill: Int, radius: Int, stroke: Int? = null) = GradientDrawable().apply {
        setColor(fill)
        cornerRadius = dp(radius).toFloat()
        if (stroke != null) setStroke(dp(2), stroke)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).roundToInt()

    private class SettingsColumn(context: Context) : LinearLayout(context) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val cap = (560 * resources.displayMetrics.density).roundToInt()
            val width = when (MeasureSpec.getMode(widthMeasureSpec)) {
                MeasureSpec.UNSPECIFIED -> cap
                else -> MeasureSpec.getSize(widthMeasureSpec).coerceAtMost(cap)
            }
            super.onMeasure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY), heightMeasureSpec)
        }
    }

    private class SettingsColors(context: Context) {
        private val night = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val background = if (night) 0xFF141416.toInt() else 0xFFF2F2F7.toInt()
        val card = if (night) 0xFF222225.toInt() else 0xFFFFFFFF.toInt()
        val button = if (night) 0xFF303037.toInt() else 0xFFECECF1.toInt()
        val text = if (night) 0xFFF6F6FA.toInt() else 0xFF19191C.toInt()
        val secondary = if (night) 0xFFB7B7C2.toInt() else 0xFF5E5E69.toInt()
        val warning = if (night) 0xFFFFBB89.toInt() else 0xFF993D1A.toInt()
        val disabledText = if (night) 0xFF9D9DA5.toInt() else 0xFF6F6F7B.toInt()
        val action = if (night) 0xFF18416C.toInt() else 0xFFDFECFF.toInt()
        val actionText = if (night) 0xFFE5F1FF.toInt() else 0xFF074A95.toInt()
        val focus = if (night) 0xFF9ACCFF.toInt() else 0xFF1260AF.toInt()
        val ripple = if (night) 0x30FFFFFF else 0x22000000
        val thumbOn = 0xFFFFFFFF.toInt()
        val thumbOff = if (night) 0xFFEBEBEF.toInt() else 0xFFFFFFFF.toInt()
        val trackOff = if (night) 0xFF626268.toInt() else 0xFF73737E.toInt()
        val switchOn = if (night) 0xFF53A3FF.toInt() else 0xFF1460B9.toInt()
    }

    private companion object {
        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
    }
}
