package com.fusionplay.android

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.text.InputFilter
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.Switch
import android.widget.TextView
import androidx.core.widget.doAfterTextChanged
import com.fusionplay.android.FusionPlayRuntime.Companion.SYNC_OFFSET_MAX
import com.fusionplay.android.FusionPlayRuntime.Companion.SYNC_OFFSET_MIN
import kotlin.math.roundToInt

internal class NativeReceiverSettingsControls(
    private val context: Context,
    private val onReceiverRunning: (Boolean) -> Unit,
    private val onAutoReceiveOnLaunch: (Boolean) -> Unit,
    private val onSyncOffset: (Int) -> Unit,
    private val onRefreshDiagnostics: () -> Unit,
    onExportLogs: () -> Unit,
) {
    private val dark = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
        Configuration.UI_MODE_NIGHT_YES
    private val primary = if (dark) Color.rgb(240, 241, 245) else Color.rgb(24, 25, 29)
    private val secondary = if (dark) Color.rgb(181, 184, 194) else Color.rgb(81, 85, 95)
    private var state: ReceiverUiState? = null
    private var binding = false
    private var trackingOffset = false
    private var offset = 0
    private var lastDiagnostics: NativeReceiverDiagnostics? = null

    private val receiverToggle = button(R.string.native_receiver_start) {
        state?.let { onReceiverRunning(!it.receiverRunning) }
    }
    private val automatic = Switch(context).apply {
        setText(R.string.native_receiver_auto_open)
        setTextColor(primary)
        textSize = 15f
        minHeight = dp(48)
        setOnCheckedChangeListener { _, enabled -> if (!binding) onAutoReceiveOnLaunch(enabled) }
    }
    private val lanAddress = label()
    private val lanInterface = label()
    val receiver: View = column().apply {
        addView(receiverToggle, rowParams())
        addView(automatic, rowParams())
        addView(lanAddress, rowParams())
        addView(lanInterface, rowParams())
    }

    private val enteredOffset = EditText(context).apply {
        setSingleLine(true)
        setTextColor(primary)
        setHintTextColor(secondary)
        inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_SIGNED
        imeOptions = EditorInfo.IME_ACTION_DONE
        filters = arrayOf(InputFilter.LengthFilter(5))
        gravity = Gravity.END or Gravity.CENTER_VERTICAL
        contentDescription = context.getString(R.string.native_receiver_sync_numeric)
        doAfterTextChanged { error = null }
        setOnEditorActionListener { _, action, _ ->
            if (action == EditorInfo.IME_ACTION_DONE) {
                applyEnteredOffset()
                true
            } else false
        }
    }
    private val applyOffset = button(R.string.native_receiver_sync_apply, ::applyEnteredOffset)
    private val minus = button(R.string.native_receiver_sync_earlier) { setOffset(offset - 10) }
    private val plus = button(R.string.native_receiver_sync_later) { setOffset(offset + 10) }
    private val reset = button(R.string.native_receiver_sync_reset) { setOffset(0) }
    private val slider = SeekBar(context).apply {
        max = SYNC_OFFSET_MAX - SYNC_OFFSET_MIN
        keyProgressIncrement = 10
        contentDescription = context.getString(R.string.native_receiver_sync_title)
        setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onStartTrackingTouch(bar: SeekBar) { trackingOffset = true }
            override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {
                if (!fromUser) return
                val value = progress + SYNC_OFFSET_MIN
                if (trackingOffset) bindDraftText(value) else setOffset(value)
            }
            override fun onStopTrackingTouch(bar: SeekBar) {
                trackingOffset = false
                setOffset(bar.progress + SYNC_OFFSET_MIN)
            }
        })
    }
    private val outputRoute = label()
    private val buffer = label()
    private val latency = label()
    private val scheduling = label()
    private val underruns = label()
    private val recoveries = label()
    private val synchronization = label()
    private val coverState = label()
    private val refresh = button(R.string.native_receiver_refresh_diagnostics, onRefreshDiagnostics)
    private val details = column().apply {
        visibility = View.GONE
        listOf(buffer, latency, scheduling, underruns, recoveries, synchronization, coverState).forEach {
            addView(it, rowParams())
        }
    }
    private val disclosure = button(R.string.native_receiver_diagnostics_title) {
        val expanded = details.visibility != View.VISIBLE
        details.visibility = if (expanded) View.VISIBLE else View.GONE
        if (Build.VERSION.SDK_INT >= 30) disclosureExpanded(expanded)
        if (expanded) onRefreshDiagnostics()
    }

    val audio: View = column().apply {
        addView(section(R.string.native_receiver_sync_title, column().apply {
            addView(label(R.string.native_receiver_sync_hint), rowParams())
            addView(horizontal().apply {
                addView(enteredOffset, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
                addView(label(R.string.native_receiver_unit_ms), LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
                addView(applyOffset, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { marginStart = dp(8) })
            }, rowParams())
            addView(slider, rowParams())
            addView(horizontal().apply {
                addView(minus, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
                addView(plus, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
            }, rowParams())
            addView(reset, rowParams())
        }), rowParams())
        addView(section(R.string.native_receiver_output_diagnostics, column().apply {
            addView(outputRoute, rowParams())
            addView(disclosure, rowParams())
            addView(details, rowParams())
            addView(refresh, rowParams())
            addView(button(R.string.native_receiver_share_logs, onExportLogs), rowParams())
        }), rowParams())
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
        offset = ui.miPlaySyncOffsetMs
        if (!trackingOffset && previous?.miPlaySyncOffsetMs != offset) {
            slider.progress = offset - SYNC_OFFSET_MIN
            if (!enteredOffset.hasFocus() || previous == null) bindDraftText(offset)
        }
        slider.isEnabled = enabled
        enteredOffset.isEnabled = enabled
        applyOffset.isEnabled = enabled
        minus.isEnabled = enabled && offset > SYNC_OFFSET_MIN
        plus.isEnabled = enabled && offset < SYNC_OFFSET_MAX
        reset.isEnabled = enabled && offset != 0

        val measurements = ui.diagnostics
        if (lastDiagnostics == measurements) return
        lastDiagnostics = measurements
        val unavailable = context.getString(R.string.native_receiver_unavailable)
        lanAddress.text = context.getString(R.string.native_receiver_lan_ip, measurements.lanAddress ?: unavailable)
        lanInterface.text = context.getString(R.string.native_receiver_lan_interface, measurements.lanInterface ?: unavailable)
        val routeTitle = if (measurements.audioRouteObserved) R.string.native_receiver_audio_route_active
            else R.string.native_receiver_audio_route_system
        outputRoute.text = context.getString(routeTitle, measurements.audioRoute ?: unavailable)
        buffer.text = metric(R.string.native_receiver_audio_buffer, measurements.bufferedFrames?.div(48.0))
        val latencyFormat = if (measurements.endpointLatencyCalibrated == true) R.string.native_receiver_audio_latency
            else R.string.native_receiver_audio_latency_estimate
        latency.text = metric(latencyFormat, measurements.outputLatencyMs)
        scheduling.text = metric(R.string.native_receiver_audio_schedule, measurements.scheduleErrorMs)
        underruns.text = context.getString(R.string.native_receiver_audio_underruns, measurements.underrunCallbacks?.toString() ?: unavailable)
        recoveries.text = context.getString(R.string.native_receiver_audio_recoveries, measurements.outputRecoveries)
        val mode = when (measurements.synchronizationMode) {
            "sender_clock" -> context.getString(R.string.native_receiver_sync_sender_clock)
            "buffer_window" -> context.getString(R.string.native_receiver_sync_buffer_window)
            else -> unavailable
        }
        synchronization.text = context.getString(R.string.native_receiver_audio_mode, mode)
        val artwork = if (measurements.coverAvailable) R.string.native_receiver_cover_received else R.string.native_receiver_cover_missing
        coverState.text = context.getString(R.string.native_receiver_cover, context.getString(artwork))
    }

    private fun disclosureExpanded(expanded: Boolean) {
        disclosure.stateDescription = context.getString(
            if (expanded) R.string.native_receiver_diagnostics_open else R.string.native_receiver_diagnostics_closed,
        )
    }

    private fun metric(template: Int, milliseconds: Double?): String = context.getString(
        template,
        milliseconds?.let { context.getString(R.string.native_receiver_ms_value, it) }
            ?: context.getString(R.string.native_receiver_unavailable),
    )

    private fun applyEnteredOffset() {
        val value = enteredOffset.text.toString().trim().toIntOrNull()
        if (value == null || value !in SYNC_OFFSET_MIN..SYNC_OFFSET_MAX) {
            enteredOffset.error = context.getString(R.string.native_receiver_sync_range, SYNC_OFFSET_MIN, SYNC_OFFSET_MAX)
            return
        }
        enteredOffset.clearFocus()
        setOffset(value)
    }

    private fun setOffset(value: Int) {
        val clamped = value.coerceIn(SYNC_OFFSET_MIN, SYNC_OFFSET_MAX)
        bindDraftText(clamped)
        if (slider.progress != clamped - SYNC_OFFSET_MIN) slider.progress = clamped - SYNC_OFFSET_MIN
        if (clamped != offset) onSyncOffset(clamped)
    }

    private fun bindDraftText(value: Int) {
        val text = value.toString()
        if (enteredOffset.text.toString() != text) enteredOffset.setText(text)
        if (Build.VERSION.SDK_INT >= 30) {
            slider.stateDescription = context.getString(R.string.native_receiver_signed_ms_value, value)
        }
    }

    private fun column(): LinearLayout = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }

    private fun horizontal(): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }

    private fun button(id: Int, action: () -> Unit) = Button(context).apply {
        setText(id)
        isAllCaps = false
        setOnClickListener { action() }
    }

    private fun label(id: Int? = null) = TextView(context).apply {
        if (id != null) setText(id)
        textSize = 14f
        setTextColor(secondary)
        setPadding(dp(4), dp(4), dp(4), dp(4))
    }

    private fun section(id: Int, content: View): View = column().apply {
        addView(label(id).apply {
            setPadding(dp(12), dp(4), dp(12), dp(6))
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
        }, rowParams())
        addView(content.apply {
            background = GradientDrawable().apply {
                setColor(if (dark) Color.rgb(37, 39, 47) else Color.rgb(247, 247, 251))
                cornerRadius = dp(20).toFloat()
            }
            setPadding(dp(12), dp(5), dp(12), dp(7))
        }, rowParams().apply { bottomMargin = dp(16) })
    }

    private fun rowParams() = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT)

    private fun dp(value: Int): Int = (value * context.resources.displayMetrics.density).roundToInt()
}
