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
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.util.SparseArray
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityManager
import android.view.animation.LinearInterpolator
import android.view.animation.PathInterpolator
import android.widget.AbsListView
import android.widget.BaseAdapter
import android.widget.FrameLayout
import android.widget.ListView
import android.widget.TextView
import com.airplayreceiver.desktop.backend.LyricsDocument
import com.airplayreceiver.desktop.backend.PlaybackSnapshot
import kotlin.math.abs
import kotlin.math.roundToInt

/** A recycled lyric list which follows the current line approximately one third down. */
internal class NativeLyricsView(
    context: Context,
    private val onSeek: (Long) -> Unit,
    private val television: Boolean = false,
) : FrameLayout(context) {
    private data class Track(val source: String?, val epoch: Long?, val id: String?)
    private data class ExpectedSeek(val positionMs: Long, val expiresAt: Long)
    private data class RowGeometry(val top: Float, val width: Int, val textSize: Float, val lineEnds: IntArray)
    private data class ReflowRow(val offset: Float, val previousLayout: StaticLayout?)

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
    private var expectedSeek: ExpectedSeek? = null
    private var seeking = false
    private var browsingUntil = 0L
    private var userScrolling = false
    private var touchBrowsing = false
    private var touchSession: Pair<Track?, LyricsDocument?>? = null
    private var remoteBrowsing = false
    var onRemoteLyricsBrowsingChanged: ((Boolean) -> Unit)? = null
    private var compactPage = false
    private var staggerSpan = 0
    private var appearance = NativeLyricAppearance()
    private val defaultTypeface = Typeface.create("sans-serif", Typeface.BOLD)
    private var lyricTypeface = defaultTypeface
    private var followAnimator: ValueAnimator? = null
    private var reflowAnimator: ValueAnimator? = null
    private var followAfterReflow = false
    private var documentAlignmentPending = false
    private var positioningIndex: Int? = null
    private val resumeFollow = Runnable {
        list.invalidate()
        followCurrent(animated = true)
    }
    private val alignCurrentLine = Runnable {
        documentAlignmentPending = false
        followCurrent()
    }

    init {
        if (television) {
            id = View.generateViewId()
            descendantFocusability = FOCUS_BLOCK_DESCENDANTS
            if (Build.VERSION.SDK_INT >= 26) defaultFocusHighlightEnabled = false
            foreground = StateListDrawable().apply {
                addState(intArrayOf(android.R.attr.state_focused), GradientDrawable().apply {
                    setColor(Color.TRANSPARENT)
                    cornerRadius = dp(12).toFloat()
                    setStroke(dp(2), 0xC7FFFFFF.toInt())
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
            selector = ColorDrawable(0x24FFFFFF)
            addHeaderView(topSpace, null, false)
            addFooterView(bottomSpace, null, false)
            adapter = rows
            setRecyclerListener {
                (it as? LyricRow)?.let { row ->
                    row.clearReflow()
                    row.finishHighlight()
                }
                it.translationY = 0f
            }
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
                document?.lines?.getOrNull(position - 1)?.startMs?.let { target ->
                    expectSeek(target)
                    onSeek(target)
                }
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
        appearance: NativeLyricAppearance = NativeLyricAppearance(),
        typeface: Typeface? = null,
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
        val nextAppearance = if (this.appearance == appearance) appearance else appearance.normalized()
        val nextTypeface = typeface ?: defaultTypeface
        val typographyChanged = nextAppearance.scalePercent != this.appearance.scalePercent || nextTypeface != lyricTypeface
        val previousAnchor = if (!rowsChanged && typographyChanged) resizeAnchor(height, height) else null
        val appearanceChanged = nextAppearance != this.appearance || typographyChanged
        val nextSpan = if (staggerEnabled) NativeLyricStagger.clampSpan(staggerMilliseconds) else 0
        if (rowsChanged || seekChanged || appearanceChanged || nextSpan != staggerSpan) cancelFollowMotion()
        if (rowsChanged || seekChanged || typographyChanged) cancelReflowMotion()
        if (trackChanged) expectedSeek = null
        this.appearance = nextAppearance
        lyricTypeface = nextTypeface
        staggerSpan = nextSpan
        track = nextTrack
        document = nextDocument
        seeking = canSeek
        val requestedJump = acceptExpectedSeek(playback.positionMs)
        if (requestedJump) cancelReflowMotion()
        val animateLineChange = !rowsChanged && !requestedJump && playback.isPlaying
        playingIndex = NativeLyricFollow.activeIndex(
            nextDocument,
            playback.positionMs,
            previousIndex,
            continuousPlayback = animateLineChange,
        )

        val hasLines = !nextDocument?.lines.isNullOrEmpty()
        if (television) {
            if (isFocusable != hasLines) isFocusable = hasLines
            if (remoteBrowsing && (trackChanged || !hasLines)) stopRemoteBrowse(returnToPane = hasLines)
        }
        list.visibility = if (hasLines) View.VISIBLE else View.GONE
        val emptyLabel = context.getString(if (playback.lyricsLoading) R.string.native_lyric_loading else R.string.native_lyric_unavailable)
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
        } else if (appearanceChanged || playingIndex != previousIndex) {
            val animateHighlight = animateLineChange && playingIndex != previousIndex && isShown &&
                accessibility?.isTouchExplorationEnabled != true && motionEnabled()
            for (child in 0 until list.childCount) {
                val position = list.firstVisiblePosition + child - 1
                val row = list.getChildAt(child) as? LyricRow ?: continue
                if (appearanceChanged) row.applyAppearance(typographyChanged)
                rows.updateHighlight(row, position, animateHighlight)
            }
        }
        if (rowsChanged) {
            if (trackChanged && playingIndex == null) list.setSelection(0)
            documentAlignmentPending = true
            scheduleLineAlignment()
        } else if (playingIndex != previousIndex) {
            followCurrent(previousIndex, animated = animateLineChange)
        } else if (typographyChanged) {
            if (previousAnchor == null) scheduleLineAlignment() else positionLine(previousAnchor.first, previousAnchor.second)
        }
    }

    fun currentLineText(): String? = playingIndex?.let { document?.lines?.getOrNull(it)?.text }

    fun setCompactPage(compact: Boolean) {
        if (compactPage == compact) return
        compactPage = compact
        cancelFollowMotion()
        cancelReflowMotion()
        updateScrollInsets()
        documentAlignmentPending = true
        scheduleLineAlignment()
    }

    fun expectSeek(positionMs: Long) {
        expectedSeek = ExpectedSeek(positionMs, SystemClock.uptimeMillis() + SEEK_WINDOW_MS)
    }

    private fun acceptExpectedSeek(positionMs: Long): Boolean {
        val seek = expectedSeek ?: return false
        if (SystemClock.uptimeMillis() >= seek.expiresAt) {
            expectedSeek = null
            return false
        }
        if (abs(positionMs - seek.positionMs) > SEEK_POSITION_TOLERANCE_MS ||
            document?.activeLineIndex(positionMs) != document?.activeLineIndex(seek.positionMs)
        ) return false
        expectedSeek = null
        return true
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        val anchor = if (!documentAlignmentPending && width > 0 && height > 0 && oldHeight > 0) {
            resizeAnchor(oldHeight, height)
        } else null
        cancelFollowMotion()
        list.reflowOnNextLayout = oldWidth > 0 && width > 0 && height > 0 && oldWidth != width && isShown &&
            !userScrolling && !touchBrowsing && !remoteBrowsing &&
            accessibility?.isTouchExplorationEnabled != true && motionEnabled()
        updateScrollInsets()
        if (anchor == null) {
            scheduleLineAlignment()
        } else {
            removeCallbacks(alignCurrentLine)
            val (index, top) = anchor
            positionLine(index, top)
        }
    }

    private fun resizeAnchor(oldHeight: Int, newHeight: Int): Pair<Int, Int>? {
        val lineCount = document?.lines?.size ?: return null
        val selected = list.selectedItemPosition.takeIf { remoteBrowsing && it in 1..lineCount }?.minus(1)
        val preferred = selected ?: playingIndex.takeUnless { isBrowsing() }
        val child = preferred?.let { list.getChildAt(it + 1 - list.firstVisiblePosition) } as? LyricRow
        if (preferred != null && child != null && child.bottom + child.translationY > 0f &&
            child.top + child.translationY < oldHeight
        ) {
            val top = child.top + child.translationY - list.paddingTop
            val adjustedTop = if (compactPage) top + followAnchor(newHeight) - followAnchor(oldHeight) else top
            return preferred to NativeLyricFollow.resizeAnchorTop(adjustedTop, oldHeight, newHeight, proportional = !compactPage)
        }
        if (selected != null) return selected to followAnchor(newHeight)
        if (!isBrowsing()) return null

        var firstVisible = -1
        for (index in 0 until list.childCount) {
            val row = list.getChildAt(index) as? LyricRow ?: continue
            if (row.bottom <= list.paddingTop || row.top >= oldHeight) continue
            if (firstVisible < 0) firstVisible = index
            // Keep the next fully visible row when the first is clipped by a long line.
            if (row.top >= list.paddingTop && row.bottom <= oldHeight) {
                firstVisible = index
                break
            }
        }
        val visible = list.getChildAt(firstVisible) ?: return null
        val position = list.firstVisiblePosition + firstVisible - 1
        if (position !in 0 until lineCount) return null
        val top = (visible.top - list.paddingTop).toFloat()
        return position to NativeLyricFollow.resizeAnchorTop(top, oldHeight, newHeight, proportional = false)
    }

    override fun onDetachedFromWindow() {
        stopRemoteBrowse(returnToPane = false)
        removeCallbacks(resumeFollow)
        removeCallbacks(alignCurrentLine)
        documentAlignmentPending = false
        cancelFollowMotion()
        cancelReflowMotion()
        expectedSeek = null
        super.onDetachedFromWindow()
    }

    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(isVisible)
        if (!isVisible) {
            stopRemoteBrowse(returnToPane = false)
            cancelFollowMotion()
            cancelReflowMotion()
        } else {
            scheduleLineAlignment()
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
        val offset = if (playingIndex == line) followAnchor(list.height) else dp(12)
        positionLine(line, offset)
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
        val top = if (canFollow) followAnchor(height) else dp(12)
        val bottom = if (canFollow) height - top else dp(16)
        if (topSpace.layoutParams?.height != top) {
            topSpace.layoutParams = AbsListView.LayoutParams(LayoutParams.MATCH_PARENT, top)
        }
        if (bottomSpace.layoutParams?.height != bottom) {
            bottomSpace.layoutParams = AbsListView.LayoutParams(LayoutParams.MATCH_PARENT, bottom)
        }
    }

    private fun pauseFollow() {
        cancelFollowMotion()
        cancelReflowMotion()
        browsingUntil = SystemClock.uptimeMillis() + FOLLOW_PAUSE_MS
        list.invalidate()
        removeCallbacks(resumeFollow)
        postDelayed(resumeFollow, FOLLOW_PAUSE_MS)
    }

    private fun scheduleLineAlignment() {
        removeCallbacks(alignCurrentLine)
        post(alignCurrentLine)
    }

    private fun isBrowsing(): Boolean = userScrolling || touchBrowsing ||
        SystemClock.uptimeMillis() < browsingUntil || accessibility?.isTouchExplorationEnabled == true ||
        list.hasFocus() || remoteBrowsing

    private fun positionLine(index: Int, top: Int) {
        // ListView otherwise advances past disabled rows when positioning with a remote.
        positioningIndex = index
        try {
            list.setSelectionFromTop(index + 1, top)
        } finally {
            positioningIndex = null
        }
    }

    private fun followCurrent(previousIndex: Int? = null, animated: Boolean = false) {
        val index = playingIndex ?: return
        if (!isShown || height == 0 || isBrowsing()) return
        if (reflowAnimator != null) {
            followAfterReflow = true
            return
        }
        val target = index + 1 // The timed list has a blank header above its first row.
        val offset = followAnchor(height)
        val row = list.getChildAt(target - list.firstVisiblePosition)
        if (animated && row != null && !list.isLayoutRequested && motionEnabled()) {
            val distance = row.top - offset - list.paddingTop
            val residual = captureResidualOffsets()
            if (distance == 0 && residual == null && followAnimator == null) return
            val direction = NativeLyricStagger.direction(previousIndex, index) ?: 0
            cancelFollowMotion(clearOffsets = residual == null)
            animateFollow(distance, direction, residual)
            return
        }
        cancelFollowMotion()
        positionLine(index, offset)
    }

    private fun captureResidualOffsets(): SparseArray<Float>? {
        if (followAnimator == null) return null
        val residual = SparseArray<Float>(list.childCount)
        val density = resources.displayMetrics.density
        for (index in 0 until list.childCount) {
            val row = list.getChildAt(index) as? LyricRow ?: continue
            if (row.translationY != 0f) residual.put(list.firstVisiblePosition + index, row.translationY / density)
        }
        return residual.takeIf { it.size() > 0 }
    }

    private fun animateFollow(distancePx: Int, direction: Int, residual: SparseArray<Float>?) {
        val span = if (direction == 0) 0 else staggerSpan
        val moveDuration = appearance.moveMilliseconds
        val density = resources.displayMetrics.density
        val rowRanks = if (span > 0) SparseArray<Float>(list.childCount) else null
        fun rowPosition(row: View): Float = (row.top + row.bottom) * .5f / list.height
        if (rowRanks != null) {
            for (index in 0 until list.childCount) {
                val row = list.getChildAt(index) as? LyricRow ?: continue
                rowRanks.put(list.firstVisiblePosition + index, rowPosition(row))
            }
        }
        var scrolled = 0
        val animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = (moveDuration + span).toLong()
            // The animator supplies elapsed time. The list and row delays share the iPad Bézier.
            interpolator = LinearInterpolator()
            addUpdateListener { motion ->
                if (!isShown || list.height == 0 || accessibility?.isTouchExplorationEnabled == true) {
                    cancelFollowMotion()
                    return@addUpdateListener
                }
                val elapsed = motion.currentPlayTime
                val position = distancePx * NativeLyricStagger.scrollFraction(elapsed, moveDuration)
                val integralOffset = position.roundToInt()
                if (integralOffset != scrolled) {
                    list.scrollListBy(integralOffset - scrolled)
                    scrolled = integralOffset
                }
                // ListView scrolls in whole pixels. Translate the remaining fraction on the rows.
                val subpixel = scrolled - position
                for (index in 0 until list.childCount) {
                    val row = list.getChildAt(index) as? LyricRow ?: continue
                    val adapterPosition = list.firstVisiblePosition + index
                    val rank = if (rowRanks == null) 0f else rowRanks.get(adapterPosition) ?: rowPosition(row).also {
                        rowRanks.put(adapterPosition, it)
                    }
                    val carry = residual?.get(adapterPosition, 0f) ?: 0f
                    row.translationY = subpixel + density * NativeLyricStagger.offsetDp(elapsed, rank, span, direction, carry, moveDuration)
                }
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    if (followAnimator !== animation) return
                    followAnimator = null
                    resetRowOffsets()
                }
            })
        }
        followAnimator = animator
        animator.start()
    }

    private fun cancelFollowMotion(clearOffsets: Boolean = true) {
        val animator = followAnimator ?: return
        followAnimator = null
        animator.removeAllUpdateListeners()
        animator.removeAllListeners()
        animator.cancel()
        if (clearOffsets) resetRowOffsets()
    }

    private fun resetRowOffsets() {
        for (index in 0 until list.childCount) list.getChildAt(index).translationY = 0f
    }

    private fun animateReflow(motion: List<Pair<LyricRow, ReflowRow>>) {
        val shouldContinueFollowing = followAfterReflow
        cancelReflowMotion()
        followAfterReflow = shouldContinueFollowing
        for ((row, frame) in motion) row.startReflow(frame)
        reflowAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = REWRAP_DURATION_MS
            addUpdateListener { animator ->
                val progress = animator.animatedValue as Float
                for ((row, frame) in motion) row.drawReflowAt(frame, progress)
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    if (reflowAnimator !== animation) return
                    val shouldAlign = followAfterReflow
                    cancelReflowMotion()
                    if (shouldAlign) scheduleLineAlignment()
                }
            })
        }
        reflowAnimator?.start()
    }

    private fun cancelReflowMotion() {
        list.reflowOnNextLayout = false
        followAfterReflow = false
        val animator = reflowAnimator ?: return
        reflowAnimator = null
        animator.removeAllUpdateListeners()
        animator.removeAllListeners()
        animator.cancel()
        for (index in 0 until list.childCount) (list.getChildAt(index) as? LyricRow)?.clearReflow()
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

        var reflowOnNextLayout = false

        var useStrongerEdgeBlur = false
            set(value) {
                if (field == value) return
                field = value
                invalidate()
            }

        override fun layoutChildren() {
            if (!reflowOnNextLayout) {
                super.layoutChildren()
                return
            }
            reflowOnNextLayout = false
            val previous = SparseArray<RowGeometry>(childCount)
            for (index in 0 until childCount) {
                val row = getChildAt(index) as? LyricRow ?: continue
                row.geometry()?.let { previous.put(firstVisiblePosition + index, it) }
            }
            super.layoutChildren()
            if (previous.size() == 0) return
            val candidates = ArrayList<Pair<LyricRow, ReflowRow>>(childCount)
            for (index in 0 until childCount) {
                val row = getChildAt(index) as? LyricRow ?: continue
                val old = previous.get(firstVisiblePosition + index) ?: continue
                val offset = (old.top - row.top).coerceIn(-height * .28f, height * .28f)
                val oldLayout = row.previousWrapping(old)
                if (oldLayout != null || abs(offset) >= 1f) candidates.add(row to ReflowRow(offset, oldLayout))
            }
            // Insets and small window adjustments should not replay motion without a line wrap.
            if (candidates.any { (_, frame) -> frame.previousLayout != null }) animateReflow(candidates)
        }

        override fun dispatchDraw(canvas: Canvas) {
            val paneHeight = height.toFloat()
            val allowEdges = paneHeight > 0 && accessibility?.isTouchExplorationEnabled != true
            val canBlur = allowEdges && rowBlur != null && canvas.isHardwareAccelerated
            val firstPosition = firstVisiblePosition
            val selectedPosition = if (remoteBrowsing && hasFocus()) selectedItemPosition else INVALID_POSITION
            val browsing = isBrowsing()

            // Draw-time geometry also tracks manual scrolling and recycled rows.
            for (index in 0 until childCount) {
                val row = getChildAt(index) as? LyricRow ?: continue
                val clear = !allowEdges || NativeLyricEdge.keepsRowClear(
                    active = row.isActivated,
                    browsing = browsing,
                    remoteFocused = firstPosition + index == selectedPosition,
                )
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
            if (gainFocus) cancelFollowMotion()
            else if (remoteBrowsing) stopRemoteBrowse(returnToPane = false)
            else if (!television) pauseFollow()
        }
    }

    private inner class LyricRows : BaseAdapter() {
        override fun getCount(): Int = document?.lines?.size ?: 0
        override fun getItem(position: Int) = document?.lines?.getOrNull(position)
        override fun getItemId(position: Int): Long = position.toLong()
        override fun areAllItemsEnabled(): Boolean = false
        override fun isEnabled(position: Int): Boolean = position == positioningIndex || remoteBrowsing ||
            (seeking && getItem(position)?.startMs != null)

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val row = (convertView as? LyricRow) ?: LyricRow(context).apply {
                setPadding(dp(8), dp(8), dp(8), dp(8))
                setLineSpacing(dp(3).toFloat(), 1f)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            }
            row.clearReflow()
            row.translationY = 0f
            row.text = getItem(position)?.text.orEmpty()
            row.applyAppearance()
            updateHighlight(row, position, animate = false, rebind = true)
            return row
        }

        fun updateHighlight(row: LyricRow, position: Int, animate: Boolean, rebind: Boolean = false) {
            val active = position == playingIndex
            val opacity = NativeLyricFollow.lineAlpha(
                position,
                playingIndex,
                synchronized = document?.isSynchronized == true,
                highContrast = television || accessibility?.isTouchExplorationEnabled == true,
            )
            val activeChanged = row.isActivated != active
            row.isActivated = active
            row.updateTextOpacity(opacity, animate && activeChanged, rebind)
        }
    }

    private inner class LyricRow(context: Context) : TextView(context) {
        var blurLevel = 0
        private var measuredTextSize = 0f
        private var reflow: ReflowRow? = null
        private var reflowProgress = 1f
        private var targetTextOpacity = 255
        private var highlightAnimator: ValueAnimator? = null

        fun updateTextOpacity(opacity: Int, animate: Boolean, rebind: Boolean) {
            if (!rebind && targetTextOpacity == opacity) return
            cancelHighlight()
            targetTextOpacity = opacity
            val previousOpacity = Color.alpha(currentTextColor)
            if (!animate || previousOpacity == opacity) {
                applyTextOpacity(opacity)
                return
            }
            highlightAnimator = ValueAnimator.ofInt(previousOpacity, opacity).apply {
                duration = HIGHLIGHT_DURATION_MS
                interpolator = HIGHLIGHT_CURVE
                addUpdateListener { applyTextOpacity(it.animatedValue as Int) }
                addListener(object : AnimatorListenerAdapter() {
                    override fun onAnimationEnd(animation: Animator) {
                        if (highlightAnimator === animation) highlightAnimator = null
                    }
                })
            }
            highlightAnimator?.start()
        }

        fun finishHighlight() {
            if (highlightAnimator == null) return
            cancelHighlight()
            applyTextOpacity(targetTextOpacity)
        }

        override fun onDetachedFromWindow() {
            finishHighlight()
            super.onDetachedFromWindow()
        }

        private fun cancelHighlight() {
            val animator = highlightAnimator ?: return
            highlightAnimator = null
            animator.removeAllUpdateListeners()
            animator.removeAllListeners()
            animator.cancel()
        }

        private fun applyTextOpacity(opacity: Int) {
            val color = Color.argb(opacity, 255, 255, 255)
            if (currentTextColor != color) setTextColor(color)
        }

        fun applyAppearance(remeasure: Boolean = false) {
            if (typeface != lyricTypeface) typeface = lyricTypeface
            val radius = if (appearance.shadowEnabled && appearance.shadowOpacityPercent > 0) {
                dp(appearance.shadowSpreadDp).toFloat()
            } else 0f
            val color = if (radius > 0f) {
                Color.argb((255 * appearance.shadowOpacityPercent / 100f).roundToInt(), 0, 0, 0)
            } else Color.TRANSPARENT
            if (shadowRadius != radius || shadowColor != color) {
                setShadowLayer(radius, 0f, if (radius > 0f) dp(2).toFloat() else 0f, color)
            }
            if (remeasure) requestLayout()
        }

        fun geometry(): RowGeometry? {
            val old = layout ?: return null
            if (text.length > MAX_REFLOW_TEXT_LENGTH || old.width <= 0) return null
            return RowGeometry(top + translationY, old.width, textSize, IntArray(old.lineCount, old::getLineEnd))
        }

        fun previousWrapping(old: RowGeometry): StaticLayout? {
            val current = layout ?: return null
            val layoutUnchanged = current.lineCount == old.lineEnds.size &&
                old.lineEnds.indices.all { current.getLineEnd(it) == old.lineEnds[it] }
            if (layoutUnchanged) return null
            val oldPaint = TextPaint(paint).apply { textSize = old.textSize }
            return StaticLayout.Builder.obtain(text, 0, text.length, oldPaint, old.width)
                .setAlignment(current.alignment)
                .setTextDirection(if (layoutDirection == LAYOUT_DIRECTION_RTL) TextDirectionHeuristics.FIRSTSTRONG_RTL
                    else TextDirectionHeuristics.FIRSTSTRONG_LTR)
                .setBreakStrategy(breakStrategy)
                .setHyphenationFrequency(hyphenationFrequency)
                .setIncludePad(includeFontPadding)
                .setLineSpacing(lineSpacingExtra, lineSpacingMultiplier)
                .build()
        }

        fun startReflow(frame: ReflowRow) {
            reflow = frame
            drawReflowAt(frame, 0f)
        }

        fun drawReflowAt(frame: ReflowRow, progress: Float) {
            if (reflow !== frame) return // The list may recycle the row while resizing.
            reflowProgress = progress
            translationY = frame.offset * (1f - progress)
            if (frame.previousLayout != null) invalidate()
        }

        fun clearReflow() {
            if (reflow == null) return
            reflow = null
            reflowProgress = 1f
            translationY = 0f
            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            val oldLayout = reflow?.previousLayout
            if (oldLayout == null || reflowProgress >= 1f) {
                super.onDraw(canvas)
                return
            }
            val oldPaint = oldLayout.paint
            val oldOpacity = 1f - reflowProgress
            oldPaint.color = currentTextColor
            oldPaint.alpha = (oldPaint.alpha * oldOpacity).roundToInt()
            if (shadowRadius > 0f) {
                oldPaint.setShadowLayer(shadowRadius, shadowDx, shadowDy,
                    Color.argb((Color.alpha(shadowColor) * oldOpacity).roundToInt(), 0, 0, 0))
            }
            val oldCanvas = canvas.save()
            canvas.translate(compoundPaddingLeft.toFloat(), extendedPaddingTop.toFloat())
            oldLayout.draw(canvas)
            canvas.restoreToCount(oldCanvas)
            if (reflowProgress > 0f) {
                val newCanvas = canvas.saveLayerAlpha(0f, 0f, width.toFloat(), height.toFloat(), (255 * reflowProgress).roundToInt())
                super.onDraw(canvas)
                canvas.restoreToCount(newCanvas)
            }
        }

        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            // A width change remeasures attached rows without invalidating the adapter.
            val widthDp = View.MeasureSpec.getSize(widthMeasureSpec) / resources.displayMetrics.density
            val baseSize = if (television) (widthDp * .065f).coerceIn(21f, 29f)
                else (widthDp * .076f).coerceIn(24f, 36f)
            val size = baseSize * appearance.scalePercent / 100f
            if (measuredTextSize != size) {
                measuredTextSize = size
                textSize = size
            }
            super.onMeasure(widthMeasureSpec, heightMeasureSpec)
        }
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

    private fun followAnchor(viewportHeight: Int): Int =
        NativeLyricFollow.anchorTop(viewportHeight, compactMaximum = if (compactPage) dp(88) else null)

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    private companion object {
        const val FOLLOW_PAUSE_MS = 5_000L
        const val HIGHLIGHT_DURATION_MS = 280L
        val HIGHLIGHT_CURVE = PathInterpolator(.42f, 0f, .58f, 1f)
        const val REWRAP_DURATION_MS = 330L
        const val MAX_REFLOW_TEXT_LENGTH = 1_024
        const val SEEK_WINDOW_MS = 3_000L
        const val SEEK_POSITION_TOLERANCE_MS = 250L
        val ENTER_KEYS = setOf(KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER)
    }
}
