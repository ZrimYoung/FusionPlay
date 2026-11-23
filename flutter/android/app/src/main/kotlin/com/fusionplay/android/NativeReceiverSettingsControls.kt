package com.fusionplay.android

import android.app.AlertDialog
import android.content.Context
import android.content.res.ColorStateList
import android.os.Build
import android.text.InputFilter
import android.text.InputType
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.SeekBar
import androidx.core.widget.doAfterTextChanged
import com.fusionplay.android.FusionPlayRuntime.Companion.SYNC_OFFSET_MAX
import com.fusionplay.android.FusionPlayRuntime.Companion.SYNC_OFFSET_MIN

internal class NativeReceiverSettingsControls(
    private val context: Context,
    private val onReceiverRunning: (Boolean) -> Unit,
    private val onAutoReceiveOnLaunch: (Boolean) -> Unit,
    private val onSyncOffset: (Int) -> Unit,
    private val onRefreshDiagnostics: () -> Unit,
    onExportLogs: () -> Unit,
) {
    private val style = NativeSettingsStyle(context)
    private var state: ReceiverUiState? = null
    private var binding = false
    private var trackingOffset = false
    private var cancelledOffsetGesture = false
    private var offset = 0
    private var offsetEditor: AlertDialog? = null
    private var lastDiagnostics: NativeReceiverDiagnostics? = null

    private val receiverToggle = style.action(R.string.native_receiver_start) {
        state?.let { onReceiverRunning(!it.receiverRunning) }
    }
    private val automatic = style.toggle(R.string.native_receiver_auto_open) { enabled ->
        if (!binding) onAutoReceiveOnLaunch(enabled)
    }
    private val lanAddress = ValueRow(R.string.native_receiver_lan_ip)
    private val lanInterface = ValueRow(R.string.native_receiver_lan_interface)
    val receiver: View = column().apply { addRows(receiverToggle, automatic, lanAddress, lanInterface) }

    private val offsetRow = style.choice(R.string.native_receiver_sync_numeric, ::editOffset)
    private val minus = style.action(R.string.native_receiver_sync_earlier) { setOffset(offset - 10) }.apply {
        gravity = Gravity.CENTER
        background = style.interactive(style.control)
    }
    private val plus = style.action(R.string.native_receiver_sync_later) { setOffset(offset + 10) }.apply {
        gravity = Gravity.CENTER
        background = style.interactive(style.control)
    }
    private val reset = style.action(R.string.native_receiver_sync_reset) { setOffset(0) }
    private val slider = SeekBar(context).apply {
        max = SYNC_OFFSET_MAX - SYNC_OFFSET_MIN
        keyProgressIncrement = 10
        minimumHeight = dp(44)
        setPadding(dp(16), paddingTop, dp(16), paddingBottom)
        contentDescription = context.getString(R.string.native_receiver_sync_title)
        progressTintList = ColorStateList.valueOf(style.accent)
        thumbTintList = progressTintList
        setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> cancelledOffsetGesture = false
                MotionEvent.ACTION_CANCEL -> cancelledOffsetGesture = true
            }
            false
        }
        setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onStartTrackingTouch(bar: SeekBar) { trackingOffset = true }
            override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {
                if (!fromUser) return
                val value = progress + SYNC_OFFSET_MIN
                if (trackingOffset) displayOffset(value, updateSlider = false) else setOffset(value)
            }
            override fun onStopTrackingTouch(bar: SeekBar) {
                trackingOffset = false
                if (cancelledOffsetGesture) displayOffset(offset) else setOffset(bar.progress + SYNC_OFFSET_MIN)
            }
        })
    }
    private val outputRoute = ValueRow(R.string.native_receiver_audio_route_system)
    private val buffer = ValueRow(R.string.native_receiver_audio_buffer)
    private val latency = ValueRow(R.string.native_receiver_audio_latency_estimate)
    private val scheduling = ValueRow(R.string.native_receiver_audio_schedule)
    private val underruns = ValueRow(R.string.native_receiver_audio_underruns)
    private val recoveries = ValueRow(R.string.native_receiver_audio_recoveries)
    private val synchronization = ValueRow(R.string.native_receiver_audio_mode)
    private val coverState = ValueRow(R.string.native_receiver_cover)
    private val refresh = style.action(R.string.native_receiver_refresh_diagnostics, onClick = onRefreshDiagnostics)
    private val details = column().apply {
        visibility = View.GONE
        addRows(buffer, latency, scheduling, underruns, recoveries, synchronization, coverState)
    }
    private val disclosure = style.choice(R.string.native_receiver_diagnostics_title, ::toggleDiagnostics)

    private fun toggleDiagnostics() {
        val expanded = details.visibility != View.VISIBLE
        details.visibility = if (expanded) View.VISIBLE else View.GONE
        bindDisclosure(expanded)
        if (expanded) onRefreshDiagnostics()
    }

    val audio: View = column().apply {
        bindDisclosure(expanded = false)
        val calibration = column().apply {
            addView(offsetRow, rowParams())
            addView(slider, rowParams())
            addView(horizontal().apply {
                setPaddingRelative(dp(16), 0, dp(16), 0)
                addView(minus, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f).apply { marginEnd = dp(4) })
                addView(plus, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f).apply { marginStart = dp(4) })
            }, rowParams())
            addView(style.label(R.string.native_receiver_sync_hint, size = 13, color = style.secondary).apply {
                setPadding(dp(16), dp(6), dp(16), dp(12))
            }, rowParams())
        }
        val diagnostics = column().apply {
            addView(disclosure, rowParams())
            addView(details, rowParams())
        }
        addView(style.section(R.string.native_receiver_sync_title, calibration, reset))
        addView(style.section(R.string.native_receiver_output_diagnostics,
            outputRoute, diagnostics, refresh, style.action(R.string.native_receiver_share_logs, onClick = onExportLogs),
        ))
        addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: View) = Unit
            override fun onViewDetachedFromWindow(view: View) { offsetEditor?.dismiss() }
        })
    }

    fun render(ui: ReceiverUiState) {
        val previous = state
        state = ui
        val enabled = ui.state.initialized && !ui.state.busy
        if (previous == null || previous.receiverRunning != ui.receiverRunning) {
            receiverToggle.setText(if (ui.receiverRunning) R.string.native_receiver_stop else R.string.native_receiver_start)
        }
        receiverToggle.isEnabled = enabled
        automatic.isEnabled = enabled
        if (automatic.isChecked != ui.autoReceiveOnLaunch) {
            binding = true
            automatic.isChecked = ui.autoReceiveOnLaunch
            binding = false
        }
        val offsetChanged = offset != ui.miPlaySyncOffsetMs
        offset = ui.miPlaySyncOffsetMs
        if (!trackingOffset && (previous == null || offsetChanged)) displayOffset(offset)
        slider.isEnabled = enabled
        offsetRow.isEnabled = enabled
        minus.isEnabled = enabled && offset > SYNC_OFFSET_MIN
        plus.isEnabled = enabled && offset < SYNC_OFFSET_MAX
        reset.isEnabled = enabled && offset != 0

        val measurements = ui.diagnostics
        if (lastDiagnostics == measurements) return
        lastDiagnostics = measurements
        val unavailable = context.getString(R.string.native_receiver_unavailable)
        lanAddress.value = measurements.lanAddress ?: unavailable
        lanInterface.value = measurements.lanInterface ?: unavailable
        val routeTitle = if (measurements.audioRouteObserved) R.string.native_receiver_audio_route_active
            else R.string.native_receiver_audio_route_system
        outputRoute.setTitle(routeTitle)
        outputRoute.value = measurements.audioRoute ?: unavailable
        buffer.value = metric(measurements.bufferedFrames?.div(48.0))
        val latencyFormat = if (measurements.endpointLatencyCalibrated == true) R.string.native_receiver_audio_latency
            else R.string.native_receiver_audio_latency_estimate
        latency.setTitle(latencyFormat)
        latency.value = metric(measurements.outputLatencyMs)
        scheduling.value = metric(measurements.scheduleErrorMs)
        underruns.value = measurements.underrunCallbacks?.toString() ?: unavailable
        recoveries.value = measurements.outputRecoveries.toString()
        synchronization.value = when (measurements.synchronizationMode) {
            "sender_clock" -> context.getString(R.string.native_receiver_sync_sender_clock)
            "buffer_window" -> context.getString(R.string.native_receiver_sync_buffer_window)
            else -> unavailable
        }
        val artwork = if (measurements.coverAvailable) R.string.native_receiver_cover_received else R.string.native_receiver_cover_missing
        coverState.value = context.getString(artwork)
    }

    private fun bindDisclosure(expanded: Boolean) {
        disclosure.setValue(context.getString(
            if (expanded) R.string.native_receiver_diagnostics_open else R.string.native_receiver_diagnostics_closed,
        ))
    }

    private fun metric(milliseconds: Double?): String = milliseconds?.let { context.getString(R.string.native_receiver_ms_value, it) }
        ?: context.getString(R.string.native_receiver_unavailable)

    private fun setOffset(value: Int) {
        if (state?.state?.let { it.initialized && !it.busy } != true) {
            displayOffset(offset)
            return
        }
        val clamped = value.coerceIn(SYNC_OFFSET_MIN, SYNC_OFFSET_MAX)
        displayOffset(clamped)
        if (clamped != offset) onSyncOffset(clamped)
    }

    private fun displayOffset(value: Int, updateSlider: Boolean = true) {
        val formatted = context.getString(R.string.native_receiver_signed_ms_value, value)
        offsetRow.setValue(formatted)
        if (updateSlider && slider.progress != value - SYNC_OFFSET_MIN) slider.progress = value - SYNC_OFFSET_MIN
        if (Build.VERSION.SDK_INT >= 30) {
            slider.stateDescription = formatted
        } else {
            slider.contentDescription = context.getString(R.string.native_settings_text_value,
                context.getString(R.string.native_receiver_sync_title), formatted)
        }
    }

    private fun editOffset() {
        if (!offsetRow.isEnabled || offsetEditor != null) return
        val field = EditText(context).apply {
            setSingleLine(true)
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_SIGNED
            imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI
            filters = arrayOf(InputFilter.LengthFilter(5))
            setTextColor(style.text)
            setText(offset.toString())
            contentDescription = context.getString(R.string.native_receiver_sync_numeric)
            doAfterTextChanged { error = null }
        }
        val editor = AlertDialog.Builder(context)
            .setTitle(R.string.native_receiver_sync_numeric)
            .setView(column().apply {
                setPadding(dp(24), dp(4), dp(24), 0)
                addView(field, rowParams())
            })
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.native_settings_done, null)
            .create()
        fun completeInput() {
            if (offsetEditor !== editor) return
            val value = field.text.toString().trim().toIntOrNull()
            if (value == null || value !in SYNC_OFFSET_MIN..SYNC_OFFSET_MAX) {
                field.error = context.getString(R.string.native_receiver_sync_range, SYNC_OFFSET_MIN, SYNC_OFFSET_MAX)
                return
            }
            offsetEditor = null
            setOffset(value)
            editor.dismiss()
        }
        field.setOnEditorActionListener { _, action, event ->
            val hardwareDone = event?.let { it.keyCode == KeyEvent.KEYCODE_ENTER && it.action == KeyEvent.ACTION_UP } == true
            val done = action == EditorInfo.IME_ACTION_DONE || hardwareDone
            if (done) completeInput()
            done
        }
        editor.setOnShowListener {
            editor.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { completeInput() }
            field.requestFocus()
            field.selectAll()
            editor.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE)
        }
        editor.setOnDismissListener {
            if (offsetEditor === editor) offsetEditor = null
            if (offsetRow.isShown && offsetRow.isEnabled && !offsetRow.isInTouchMode) offsetRow.requestFocus()
        }
        offsetEditor = editor
        editor.show()
    }

    private fun column(): LinearLayout = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }

    private fun horizontal(): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }

    private fun LinearLayout.addRows(vararg rows: View) {
        rows.forEachIndexed { index, row ->
            if (index != 0) addView(View(context).apply {
                setBackgroundColor(style.divider)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(MATCH_PARENT, 1).apply {
                marginStart = dp(16)
                marginEnd = dp(16)
            })
            addView(row, rowParams())
        }
    }

    private inner class ValueRow(titleId: Int) : LinearLayout(context) {
        private val title = style.label(titleId, size = 15)
        private val valueLabel = style.label(size = 14, color = style.secondary).apply { gravity = Gravity.END }
        private var currentTitleId = titleId

        var value: CharSequence
            get() = valueLabel.text
            set(text) { if (valueLabel.text != text) valueLabel.text = text }

        init {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(52)
            setPaddingRelative(dp(16), dp(10), dp(16), dp(10))
            if (Build.VERSION.SDK_INT >= 28) isScreenReaderFocusable = true
            addView(title, LayoutParams(0, WRAP_CONTENT, 1.2f).apply { marginEnd = dp(12) })
            addView(valueLabel, LayoutParams(0, WRAP_CONTENT, 1f))
        }

        fun setTitle(id: Int) {
            if (currentTitleId == id) return
            currentTitleId = id
            title.setText(id)
        }
    }

    private fun rowParams() = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT)

    private fun dp(value: Int): Int = style.dp(value)
}
