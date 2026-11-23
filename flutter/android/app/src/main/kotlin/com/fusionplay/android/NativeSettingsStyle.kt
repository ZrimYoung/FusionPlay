package com.fusionplay.android

import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.graphics.drawable.StateListDrawable
import android.os.Build
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView
import kotlin.math.roundToInt

/** Shared surfaces and controls for the receiver's settings. */
internal class NativeSettingsStyle(private val context: Context) {
    val dark = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    val background = tone(0x101619, 0xF2F6F5)
    val card = tone(0x1B2529, 0xFFFFFF)
    val control = tone(0x2B3C40, 0xDFEFEB)
    val text = tone(0xF1F7F6, 0x172624)
    val secondary = tone(0xB2C4C4, 0x4E6461)
    val accent = tone(0xA5E4D7, 0x15635A)
    val warning = tone(0xFFC298, 0x85411E)
    val disabledText = tone(0x829491, 0x677873)
    val divider = tone(0x314044, 0xDBE6E3)
    private val trackOff = tone(0x53666A, 0x6D827E)
    private val switchOn = tone(0x82C7BA, 0x286F66)
    private val ripple = if (dark) 0x26D0FBF2 else 0x17115B52

    fun dp(value: Int): Int = (value * context.resources.displayMetrics.density).roundToInt()

    fun label(id: Int? = null, size: Int = 16, color: Int = text, bold: Boolean = false): TextView =
        TextView(context).apply {
            if (id != null) setText(id)
            textSize = size.toFloat()
            setTextColor(color)
            if (bold) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        }

    fun action(id: Int, onClick: () -> Unit): Button = Button(context).apply {
        setText(id)
        textSize = 16f
        setTextColor(enabledColors(this@NativeSettingsStyle.text))
        isAllCaps = false
        gravity = Gravity.START or Gravity.CENTER_VERTICAL
        maxLines = 2
        ellipsize = TextUtils.TruncateAt.END
        minHeight = dp(52)
        minimumHeight = dp(52)
        minWidth = 0
        minimumWidth = 0
        setPaddingRelative(dp(16), dp(7), dp(16), dp(7))
        background = interactive()
        stateListAnimator = null
        isFocusable = true
        setOnClickListener { onClick() }
    }

    fun toggle(id: Int, onChanged: (Boolean) -> Unit): Switch = Switch(context).apply {
        setText(id)
        textSize = 16f
        setTextColor(enabledColors(this@NativeSettingsStyle.text))
        minHeight = dp(56)
        gravity = Gravity.CENTER_VERTICAL
        setPaddingRelative(dp(16), dp(8), dp(16), dp(8))
        switchPadding = dp(16)
        showText = false
        splitTrack = false
        isFocusable = true
        background = interactive()
        thumbTintList = switchColors(if (dark) this@NativeSettingsStyle.background else Color.WHITE, Color.WHITE, disabledText)
        trackTintList = switchColors(switchOn, trackOff, control)
        setOnCheckedChangeListener { _, enabled -> onChanged(enabled) }
    }

    fun choice(id: Int, onClick: () -> Unit): NativeSettingsChoiceRow = NativeSettingsChoiceRow(context, this, id, onClick)

    fun back(onClick: () -> Unit): View = icon(back = true, tint = text).apply {
        contentDescription = context.getString(R.string.native_settings_back)
        isFocusable = true
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        background = interactive(radius = 24)
        setOnClickListener { onClick() }
    }

    fun section(title: Int?, vararg rows: View): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { bottomMargin = dp(20) }
        if (title != null) {
            addView(label(title, size = 14, color = secondary, bold = true).apply {
                setPaddingRelative(dp(16), 0, dp(16), dp(8))
                if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
            }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
        addView(SettingsCard(context, this@NativeSettingsStyle).apply {
            rows.forEach { addView(it, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT)) }
        }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
    }

    fun shape(fill: Int, radius: Int): GradientDrawable = GradientDrawable().apply {
        setColor(fill)
        cornerRadius = dp(radius).toFloat()
    }

    fun interactive(fill: Int = Color.TRANSPARENT, radius: Int = 12): RippleDrawable = RippleDrawable(
        ColorStateList.valueOf(ripple),
        StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_focused), shape(fill, radius).apply { setStroke(dp(2), accent) })
            addState(intArrayOf(), shape(fill, radius))
        },
        shape(Color.WHITE, radius),
    )

    internal fun icon(back: Boolean, tint: Int): View = object : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = tint
            strokeWidth = dp(2).toFloat()
            strokeCap = Paint.Cap.ROUND
        }

        init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

        override fun getAccessibilityClassName(): CharSequence =
            if (back) Button::class.java.name else super.getAccessibilityClassName()

        override fun onDraw(canvas: Canvas) {
            val direction = if (layoutDirection == LAYOUT_DIRECTION_RTL) -1f else 1f
            val x = width / 2f
            val y = height / 2f
            val wing = dp(if (back) 6 else 4).toFloat()
            val tip = x + if (back) -dp(8) * direction else dp(2) * direction
            val outer = tip + if (back) wing * direction else -wing * direction
            canvas.drawLine(tip, y, outer, y - wing, paint)
            canvas.drawLine(tip, y, outer, y + wing, paint)
            if (back) canvas.drawLine(tip, y, x + dp(8) * direction, y, paint)
        }
    }

    private fun enabledColors(enabled: Int) = ColorStateList(
        arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()), intArrayOf(disabledText, enabled),
    )

    private fun switchColors(on: Int, off: Int, disabled: Int) = ColorStateList(
        arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf(android.R.attr.state_checked), intArrayOf()),
        intArrayOf(disabled, on, off),
    )

    private fun tone(darkRgb: Int, lightRgb: Int): Int = (if (dark) darkRgb else lightRgb) or Color.BLACK

    private class SettingsCard(context: Context, private val palette: NativeSettingsStyle) : LinearLayout(context) {
        private val rule = Paint().apply { color = palette.divider }

        init {
            orientation = VERTICAL
            background = palette.shape(palette.card, 18)
            clipToOutline = true
            setWillNotDraw(false)
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val inset = palette.dp(16).toFloat()
            var previous: View? = null
            for (index in 0 until childCount) {
                val child = getChildAt(index)
                if (child.visibility != VISIBLE || child.height == 0) continue
                previous?.let { canvas.drawLine(inset, it.bottom.toFloat(), width - inset, it.bottom.toFloat(), rule) }
                previous = child
            }
        }
    }
}

internal class NativeSettingsChoiceRow(
    context: Context,
    private val style: NativeSettingsStyle,
    title: Int,
    onClick: () -> Unit,
) : LinearLayout(context) {
    private val heading = context.getText(title)
    private val valueLabel = style.label(size = 14, color = style.secondary).apply {
        maxLines = 2
        ellipsize = TextUtils.TruncateAt.END
        gravity = Gravity.END or Gravity.CENTER_VERTICAL
        visibility = GONE
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = style.dp(56)
        setPaddingRelative(style.dp(16), style.dp(8), style.dp(12), style.dp(8))
        addView(style.label(title).apply { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }, LayoutParams(0, WRAP_CONTENT, 1f))
        addView(valueLabel, LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { marginStart = style.dp(12) })
        addView(style.icon(back = false, tint = style.secondary), LayoutParams(style.dp(20), style.dp(24)).apply {
            marginStart = style.dp(4)
        })
        contentDescription = heading
        background = style.interactive()
        isFocusable = true
        setOnClickListener { onClick() }
    }

    fun setValue(value: CharSequence) {
        if (valueLabel.text == value) return
        valueLabel.text = value
        valueLabel.visibility = if (value.isEmpty()) GONE else VISIBLE
        contentDescription = if (value.isEmpty()) heading else context.getString(R.string.native_settings_text_value, heading, value)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val maximumValueWidth = (MeasureSpec.getSize(widthMeasureSpec) * .40f).toInt()
        if (maximumValueWidth > 0 && valueLabel.maxWidth != maximumValueWidth) valueLabel.maxWidth = maximumValueWidth
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
    }

    override fun setEnabled(enabled: Boolean) {
        super.setEnabled(enabled)
        alpha = if (enabled) 1f else .52f
    }

    override fun getAccessibilityClassName(): CharSequence = Button::class.java.name
}
