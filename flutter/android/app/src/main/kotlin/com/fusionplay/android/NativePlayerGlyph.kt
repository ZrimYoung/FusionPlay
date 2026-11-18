package com.fusionplay.android

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.graphics.drawable.StateListDrawable
import android.view.View
import kotlin.math.min
import kotlin.math.roundToInt

internal object NativePlayerColors {
    val background = Color.rgb(11, 17, 20)
    val backgroundTop = Color.rgb(23, 43, 51)
    val accent = Color.rgb(145, 242, 227)
    val text = Color.WHITE
    val secondaryText = Color.argb(183, 255, 255, 255)
    val warning = Color.rgb(255, 191, 126)
}

internal enum class NativePlayerIcon {
    PREVIOUS, PLAY, PAUSE, NEXT, LYRICS, VOLUME, SETTINGS, MUSIC, WAVEFORM,
}

/** Draws platform-independent symbols. Actions still use Android focus and accessibility. */
internal class NativePlayerGlyph(
    context: Context,
    icon: NativePlayerIcon,
    private val iconSizeDp: Float,
    private val prominence: Int = 0,
    action: (() -> Unit)? = null,
) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val path = Path()
    private val isAction = action != null
    var icon: NativePlayerIcon = icon
        set(value) {
            if (field == value) return
            field = value
            invalidate()
        }
    var ink: Int = Color.WHITE
        set(value) {
            if (field == value) return
            field = value
            invalidate()
        }

    init {
        if (action != null) {
            background = buttonBackground()
            isFocusable = true
            setOnClickListener { action() }
        } else {
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }
    }

    override fun getAccessibilityClassName(): CharSequence =
        if (isAction) android.widget.Button::class.java.name else super.getAccessibilityClassName()

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val size = min(min(width, height).toFloat(), iconSizeDp * resources.displayMetrics.density)
        canvas.save()
        canvas.translate((width - size) / 2, (height - size) / 2)
        canvas.scale(size / 24, size / 24)
        val baseAlpha = Color.alpha(ink)
        paint.color = ink
        paint.alpha = if (isEnabled) baseAlpha else (baseAlpha * 0.40f).roundToInt()
        when (icon) {
            NativePlayerIcon.PREVIOUS -> {
                canvas.translate(24f, 0f)
                canvas.scale(-1f, 1f)
                drawNext(canvas)
            }
            NativePlayerIcon.NEXT -> drawNext(canvas)
            NativePlayerIcon.PLAY -> {
                paint.style = Paint.Style.FILL
                polygon(canvas, 7f, 3.8f, 20f, 12f, 7f, 20.2f)
            }
            NativePlayerIcon.PAUSE -> {
                paint.style = Paint.Style.FILL
                canvas.drawRoundRect(5.3f, 4f, 10.2f, 20f, 1.4f, 1.4f, paint)
                canvas.drawRoundRect(13.8f, 4f, 18.7f, 20f, 1.4f, 1.4f, paint)
            }
            NativePlayerIcon.LYRICS -> {
                stroke(1.7f)
                canvas.drawRoundRect(3f, 4.3f, 21f, 17f, 3.8f, 3.8f, paint)
                path.reset()
                path.moveTo(8f, 17f)
                path.lineTo(8f, 20.3f)
                path.lineTo(12.6f, 17f)
                canvas.drawPath(path, paint)
                canvas.drawLine(7f, 9f, 17f, 9f, paint)
                canvas.drawLine(7f, 12.6f, 13.2f, 12.6f, paint)
            }
            NativePlayerIcon.VOLUME -> {
                stroke(1.7f)
                polygon(canvas, 3f, 9f, 7f, 9f, 12f, 5f, 12f, 19f, 7f, 15f, 3f, 15f)
                canvas.drawArc(5.5f, 6.5f, 17.8f, 17.5f, -50f, 100f, false, paint)
                canvas.drawArc(2.4f, 3.5f, 21.7f, 20.5f, -48f, 96f, false, paint)
            }
            NativePlayerIcon.SETTINGS -> {
                stroke(1.8f)
                canvas.drawCircle(12f, 12f, 7f, paint)
                canvas.drawCircle(12f, 12f, 2.75f, paint)
                repeat(8) {
                    canvas.drawLine(12f, 2.5f, 12f, 5f, paint)
                    canvas.rotate(45f, 12f, 12f)
                }
            }
            NativePlayerIcon.MUSIC -> {
                stroke(1.3f)
                canvas.drawLine(12.5f, 17f, 12.5f, 3.8f, paint)
                canvas.drawLine(12.5f, 3.8f, 19f, 6.5f, paint)
                canvas.drawLine(12.5f, 7.6f, 19f, 10.3f, paint)
                canvas.drawLine(19f, 6.5f, 19f, 10.3f, paint)
                canvas.drawOval(5.5f, 15.3f, 12.5f, 20.5f, paint)
            }
            NativePlayerIcon.WAVEFORM -> {
                stroke(1.65f)
                canvas.drawLine(4f, 10.2f, 4f, 13.8f, paint)
                canvas.drawLine(8f, 6.8f, 8f, 17.2f, paint)
                canvas.drawLine(12f, 3.4f, 12f, 20.6f, paint)
                canvas.drawLine(16f, 7f, 16f, 17f, paint)
                canvas.drawLine(20f, 10f, 20f, 14f, paint)
            }
        }
        canvas.restore()
    }

    private fun drawNext(canvas: Canvas) {
        paint.style = Paint.Style.FILL
        polygon(canvas, 4.6f, 4.8f, 15.7f, 12f, 4.6f, 19.2f)
        canvas.drawRoundRect(17.2f, 4.5f, 20.6f, 19.5f, 1.1f, 1.1f, paint)
    }

    private fun stroke(width: Float) {
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = width
    }

    private fun polygon(canvas: Canvas, vararg coordinates: Float) {
        path.reset()
        path.moveTo(coordinates[0], coordinates[1])
        var point = 2
        while (point + 1 < coordinates.size) {
            path.lineTo(coordinates[point], coordinates[point + 1])
            point += 2
        }
        path.close()
        canvas.drawPath(path, paint)
    }

    private fun buttonBackground(): RippleDrawable {
        fun circle(alpha: Int, focus: Boolean = false) = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.argb(alpha, 255, 255, 255))
            if (focus) setStroke((2 * resources.displayMetrics.density).roundToInt(), NativePlayerColors.accent)
        }
        val states = StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_focused), circle(35, focus = true))
            addState(intArrayOf(android.R.attr.state_selected), circle(31))
            addState(intArrayOf(), circle(prominence))
        }
        return RippleDrawable(ColorStateList.valueOf(0x36FFFFFF), states, circle(255))
    }
}
