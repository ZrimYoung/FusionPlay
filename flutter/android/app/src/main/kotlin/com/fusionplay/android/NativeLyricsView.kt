package com.fusionplay.android

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.annotation.TargetApi
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.RenderEffect
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityManager
import android.view.animation.LinearInterpolator
import android.widget.AbsListView
import android.widget.BaseAdapter
import android.widget.FrameLayout
import android.widget.ListView
import android.widget.TextView
import com.airplayreceiver.desktop.backend.LyricsDocument
import com.airplayreceiver.desktop.backend.PlaybackSnapshot
import kotlin.math.roundToInt

/** A recycled lyric list which follows the current line approximately one third down. */
internal class NativeLyricsView(
    context: Context,
    private val onSeek: (Long) -> Unit,
    private val television: Boolean = false,
) : FrameLayout(context) {
    private data class Track(val source: String?, val epoch: Long?, val id: String?)

    private val accessibility = context.getSystemService(AccessibilityManager::class.java)
    private val list = LyricList()
    private val topSpace = View(context)
    private val bottomSpace = View(context)
    private val empty = TextView(context).apply {
        gravity = Gravity.CENTER
        textSize = 15f
        setTextColor(0xB8FFFFFF.toInt())
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
    }
    private val rows = LyricRows()
    private var document: LyricsDocument? = null
    private var track: Track? = null
    private var playingIndex: Int? = null
    private var seeking = false
    private var browsingUntil = 0L
    private var userScrolling = false
    private var touchBrowsing = false
    private var touchSession: Pair<Track?, LyricsDocument?>? = null
    private var remoteBrowsing = false
    var onRemoteLyricsBrowsingChanged: ((Boolean) -> Unit)? = null
    private var staggerSpan = 0
    private var staggerAnimator: ValueAnimator? = null
    private val resumeFollow = Runnable { followCurrent() }
    private val alignCurrentLine = Runnable { followCurrent() }

    init {
        if (television) {
            id = View.generateViewId()
            descendantFocusability = FOCUS_BLOCK_DESCENDANTS
            if (Build.VERSION.SDK_INT >= 26) defaultFocusHighlightEnabled = false
            foreground = StateListDrawable().apply {
                addState(intArrayOf(android.R.attr.state_focused), GradientDrawable().apply {
                    setColor(Color.TRANSPARENT)
                    cornerRadius = dp(12).toFloat()
                    setStroke(dp(2), NativePlayerColors.accent)
                })
                addState(intArrayOf(), ColorDrawable(Color.TRANSPARENT))
            }
        }
        list.apply {
            divider = null
            dividerHeight = 0
            isVerticalScrollBarEnabled = false
            isNestedScrollingEnabled = true
            overScrollMode = View.OVER_SCROLL_NEVER
            addHeaderView(topSpace, null, false)
            addFooterView(bottomSpace, null, false)
            adapter = rows
            setRecyclerListener { it.translationY = 0f }
            setOnScrollListener(object : AbsListView.OnScrollListener {
                override fun onScroll(view: AbsListView, first: Int, count: Int, total: Int) = Unit
                override fun onScrollStateChanged(view: AbsListView, scrollState: Int) {
                    if (!touchBrowsing) return
                    userScrolling = scrollState != AbsListView.OnScrollListener.SCROLL_STATE_IDLE
                    if (!userScrolling) {
                        touchBrowsing = false
                        pauseFollow()
                    }
                }
            })
            setOnItemClickListener { _, _, position, _ ->
                val gesture = touchSession
                touchSession = null
                if (!seeking || (gesture != null && gesture != (track to document))) {
                    return@setOnItemClickListener
                }
                document?.lines?.getOrNull(position - 1)?.startMs?.let(onSeek)
            }
        }
        addView(list, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(empty, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    }

    fun render(
        playback: PlaybackSnapshot,
        canSeek: Boolean,
        advancedEffects: Boolean,
        staggerEnabled: Boolean,
        staggerMilliseconds: Int,
    ) {
        val nextTrack = Track(
            playback.protocol,
            playback.sourceEpoch,
            playback.trackIdentity ?: playback.mediaUrl ?: playback.title,
        )
        val trackChanged = nextTrack != track
        val receivedDocument = playback.lyrics
        val nextDocument = if (!trackChanged && document?.lines == receivedDocument?.lines) {
            document
        } else receivedDocument
        val rowsChanged = trackChanged || document !== nextDocument
        val seekChanged = seeking != canSeek
        val previousIndex = playingIndex
        val nextSpan = if (staggerEnabled) NativeLyricStagger.clampSpan(staggerMilliseconds) else 0
        if (rowsChanged || seekChanged || nextSpan != staggerSpan) cancelStagger()
        staggerSpan = nextSpan
        track = nextTrack
        document = nextDocument
        seeking = canSeek
        playingIndex = nextDocument?.activeLineIndex(playback.positionMs)

        val hasLines = !nextDocument?.lines.isNullOrEmpty()
        if (television) {
            if (isFocusable != hasLines) isFocusable = hasLines
            if (remoteBrowsing && (trackChanged || !hasLines)) stopRemoteBrowse(returnToPane = hasLines)
        }
        list.visibility = if (hasLines) View.VISIBLE else View.GONE
        val emptyLabel = if (playback.lyricsLoading) "正在载入歌词…" else "发送设备未提供歌词"
        if (empty.text.toString() != emptyLabel) empty.text = emptyLabel
        empty.visibility = if (hasLines) View.GONE else View.VISIBLE
        list.useStrongerEdgeBlur = advancedEffects

        if (trackChanged) {
            removeCallbacks(resumeFollow)
            browsingUntil = 0L
            userScrolling = false
            touchBrowsing = false
        }
        if (rowsChanged || seekChanged) {
            rows.notifyDataSetChanged()
            updateScrollInsets()
        } else if (playingIndex != previousIndex) {
            for (child in 0 until list.childCount) {
                val position = list.firstVisiblePosition + child - 1
                if (position == previousIndex || position == playingIndex) {
                    (list.getChildAt(child) as? TextView)?.let { rows.updateHighlight(it, position) }
                }
            }
        }
        if (rowsChanged) {
            if (trackChanged && playingIndex == null) list.setSelection(0)
            scheduleLineAlignment()
        } else if (playingIndex != previousIndex) {
            followCurrent(previousIndex)
        }
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        cancelStagger()
        updateScrollInsets()
        if (width != oldWidth) rows.notifyDataSetChanged()
        scheduleLineAlignment()
    }

    override fun onDetachedFromWindow() {
        stopRemoteBrowse(returnToPane = false)
        removeCallbacks(resumeFollow)
        removeCallbacks(alignCurrentLine)
        cancelStagger()
        super.onDetachedFromWindow()
    }

    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(isVisible)
        if (!isVisible) {
            stopRemoteBrowse(returnToPane = false)
            cancelStagger()
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (television && isFocused && event.keyCode in ENTER_KEYS) {
            if (event.action == KeyEvent.ACTION_UP && !event.isCanceled) enterRemoteLyrics()
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    fun exitRemoteLyrics(): Boolean = stopRemoteBrowse(returnToPane = true)

    private fun enterRemoteLyrics() {
        val lineCount = document?.lines?.size ?: 0
        if (lineCount == 0 || remoteBrowsing || !isShown) return
        remoteBrowsing = true
        descendantFocusability = FOCUS_AFTER_DESCENDANTS
        if (!list.requestFocus()) {
            remoteBrowsing = false
            descendantFocusability = FOCUS_BLOCK_DESCENDANTS
            return
        }
        val firstVisibleLine = (list.firstVisiblePosition - 1).coerceIn(0, lineCount - 1)
        val line = playingIndex?.takeIf { it in 0 until lineCount } ?: firstVisibleLine
        val offset = if (playingIndex == line) (list.height * ANCHOR).roundToInt() else dp(12)
        list.setSelectionFromTop(line + 1, offset)
        onRemoteLyricsBrowsingChanged?.invoke(true)
    }

    private fun stopRemoteBrowse(returnToPane: Boolean): Boolean {
        if (!remoteBrowsing) return false
        remoteBrowsing = false
        descendantFocusability = FOCUS_BLOCK_DESCENDANTS
        if (!returnToPane || !isShown || !requestFocus()) {
            if (list.hasFocus()) list.clearFocus()
        }
        onRemoteLyricsBrowsingChanged?.invoke(false)
        browsingUntil = 0L
        removeCallbacks(resumeFollow)
        post(resumeFollow)
        return true
    }

    private fun updateScrollInsets() {
        val canFollow = document?.isSynchronized == true && accessibility?.isTouchExplorationEnabled != true
        topSpace.layoutParams = AbsListView.LayoutParams(LayoutParams.MATCH_PARENT, if (canFollow) (height * ANCHOR).roundToInt() else dp(12))
        bottomSpace.layoutParams = AbsListView.LayoutParams(LayoutParams.MATCH_PARENT, if (canFollow) (height * (1 - ANCHOR)).roundToInt() else dp(16))
    }

    private fun pauseFollow() {
        cancelStagger()
        browsingUntil = SystemClock.uptimeMillis() + FOLLOW_PAUSE_MS
        removeCallbacks(resumeFollow)
        postDelayed(resumeFollow, FOLLOW_PAUSE_MS)
    }

    private fun scheduleLineAlignment() {
        removeCallbacks(alignCurrentLine)
        post(alignCurrentLine)
    }

    private fun followCurrent(previousIndex: Int? = null) {
        cancelStagger()
        val index = playingIndex ?: return
        if (!isShown || height == 0 || userScrolling || touchBrowsing || SystemClock.uptimeMillis() < browsingUntil ||
            accessibility?.isTouchExplorationEnabled == true || list.hasFocus() || remoteBrowsing
        ) return
        val target = index + 1 // The timed list has a blank header above its first row.
        val offset = (height * ANCHOR).roundToInt()
        val direction = NativeLyricStagger.direction(previousIndex, index)
        if (direction != null && motionEnabled()) {
            list.smoothScrollToPositionFromTop(target, offset, NativeLyricStagger.FOLLOW_DURATION_MS)
            if (staggerSpan > 0) startStagger(direction)
        } else {
            list.setSelectionFromTop(target, offset)
        }
    }

    private fun startStagger(direction: Int) {
        val span = staggerSpan
        val density = resources.displayMetrics.density
        val animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = (NativeLyricStagger.FOLLOW_DURATION_MS + span).toLong()
            interpolator = LinearInterpolator()
            addUpdateListener { motion ->
                if (!isShown || list.height == 0 || accessibility?.isTouchExplorationEnabled == true) {
                    cancelStagger()
                    return@addUpdateListener
                }
                val elapsed = motion.currentPlayTime
                // ListView already lays out and recycles the rows. Only adjust
                // the presentation of the attached rows during this short wave.
                for (index in 0 until list.childCount) {
                    val row = list.getChildAt(index) as? TextView ?: continue
                    val center = (row.top + row.bottom) * .5f / list.height
                    row.translationY = density * NativeLyricStagger.offsetDp(elapsed, center, span, direction)
                }
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    if (staggerAnimator !== animation) return
                    staggerAnimator = null
                    resetRowOffsets()
                }
            })
        }
        staggerAnimator = animator
        animator.start()
    }

    private fun cancelStagger() {
        val animator = staggerAnimator ?: return
        staggerAnimator = null
        animator.removeAllUpdateListeners()
        animator.removeAllListeners()
        animator.cancel()
        resetRowOffsets()
    }

    private fun resetRowOffsets() {
        for (index in 0 until list.childCount) list.getChildAt(index).translationY = 0f
    }

    private fun motionEnabled(): Boolean = if (Build.VERSION.SDK_INT >= 26) {
        ValueAnimator.areAnimatorsEnabled()
    } else {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f
    }

    private inner class LyricList : ListView(context) {
        private val rowBlur = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            RowBlur(resources.displayMetrics.density)
        } else null

        var useStrongerEdgeBlur = false
            set(value) {
                if (field == value) return
                field = value
                invalidate()
            }

        override fun dispatchDraw(canvas: Canvas) {
            val paneHeight = height.toFloat()
            val allowEdges = paneHeight > 0 && accessibility?.isTouchExplorationEnabled != true
            val canBlur = allowEdges && rowBlur != null && canvas.isHardwareAccelerated
            val firstPosition = firstVisiblePosition
            val selectedPosition = if (hasFocus()) selectedItemPosition else INVALID_POSITION

            // Draw-time geometry also tracks manual scrolling and recycled rows.
            for (index in 0 until childCount) {
                val row = getChildAt(index) as? LyricRow ?: continue
                val clear = !allowEdges || row.isActivated || firstPosition + index == selectedPosition
                var alpha = 1f
                var blur = 0
                if (!clear) {
                    val center = ((row.top + row.bottom) * .5f + row.translationY) / paneHeight
                    alpha = NativeLyricEdge.opacity(center)
                    if (canBlur) blur = NativeLyricEdge.blurLevel(center, useStrongerEdgeBlur)
                }
                if (row.alpha != alpha) row.alpha = alpha
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) rowBlur?.setLevel(row, blur)
            }
            super.dispatchDraw(canvas)
        }

        override fun dispatchKeyEvent(event: KeyEvent): Boolean {
            if (!remoteBrowsing) return super.dispatchKeyEvent(event)
            return when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> true
                KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN -> {
                    super.dispatchKeyEvent(event)
                    true // Keep focus in the lyric pane even at the first and last lines.
                }
                else -> super.dispatchKeyEvent(event)
            }
        }

        override fun dispatchTouchEvent(event: MotionEvent): Boolean {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    touchSession = track to document
                    touchBrowsing = true
                    pauseFollow()
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (!userScrolling) touchBrowsing = false
                    if (event.actionMasked == MotionEvent.ACTION_CANCEL) touchSession = null
                    pauseFollow()
                }
            }
            return super.dispatchTouchEvent(event)
        }

        override fun onGenericMotionEvent(event: MotionEvent): Boolean {
            if (event.actionMasked == MotionEvent.ACTION_SCROLL) pauseFollow()
            return super.onGenericMotionEvent(event)
        }

        override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
            touchSession = null
            if (keyCode == KeyEvent.KEYCODE_DPAD_UP || keyCode == KeyEvent.KEYCODE_DPAD_DOWN) pauseFollow()
            return super.onKeyDown(keyCode, event)
        }

        override fun onFocusChanged(gainFocus: Boolean, direction: Int, oldRect: android.graphics.Rect?) {
            super.onFocusChanged(gainFocus, direction, oldRect)
            if (gainFocus) cancelStagger()
            else if (remoteBrowsing) stopRemoteBrowse(returnToPane = false)
            else if (!television) pauseFollow()
        }
    }

    private inner class LyricRows : BaseAdapter() {
        override fun getCount(): Int = document?.lines?.size ?: 0
        override fun getItem(position: Int) = document?.lines?.getOrNull(position)
        override fun getItemId(position: Int): Long = position.toLong()
        override fun areAllItemsEnabled(): Boolean = false
        override fun isEnabled(position: Int): Boolean = remoteBrowsing || (seeking && getItem(position)?.startMs != null)

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val row = (convertView as? LyricRow) ?: LyricRow(context).apply {
                typeface = Typeface.create("sans-serif", Typeface.BOLD)
                setPadding(dp(8), dp(8), dp(8), dp(8))
                setLineSpacing(dp(3).toFloat(), 1f)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            }
            row.translationY = 0f
            val widthDp = width / resources.displayMetrics.density
            row.textSize = if (television) (widthDp * .065f).coerceIn(21f, 29f)
            else (widthDp * .076f).coerceIn(24f, 36f)
            row.text = getItem(position)?.text.orEmpty()
            updateHighlight(row, position)
            return row
        }

        fun updateHighlight(row: TextView, position: Int) {
            val active = position == playingIndex
            row.setTextColor(when {
                active || document?.isSynchronized == false -> Color.WHITE
                playingIndex?.let { position < it } == true -> 0x91FFFFFF.toInt()
                else -> 0xB8FFFFFF.toInt()
            })
            row.isActivated = active
        }
    }

    private class LyricRow(context: Context) : TextView(context) {
        var blurLevel = 0
    }

    @TargetApi(Build.VERSION_CODES.S)
    private class RowBlur(private val density: Float) {
        private val effects = arrayOfNulls<RenderEffect>(NativeLyricEdge.MAX_BLUR_LEVEL + 1)

        fun setLevel(row: LyricRow, level: Int) {
            if (row.blurLevel == level) return
            row.blurLevel = level
            val effect = if (level == 0) null else effects[level] ?: run {
                val radius = level * density
                RenderEffect.createBlurEffect(radius, radius, Shader.TileMode.DECAL).also { effects[level] = it }
            }
            row.setRenderEffect(effect)
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    private companion object {
        const val ANCHOR = .32f
        const val FOLLOW_PAUSE_MS = 5_000L
        val ENTER_KEYS = setOf(KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER)
    }
}
