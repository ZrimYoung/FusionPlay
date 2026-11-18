package com.fusionplay.android

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.SystemClock
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityManager
import android.widget.AbsListView
import android.widget.BaseAdapter
import android.widget.FrameLayout
import android.widget.ListView
import android.widget.TextView
import com.airplayreceiver.desktop.backend.LyricsDocument
import com.airplayreceiver.desktop.backend.PlaybackSnapshot
import kotlin.math.roundToInt

/** A recycled lyric list which follows the current line approximately one third down. */
internal class NativeLyricsView(context: Context, private val onSeek: (Long) -> Unit) : FrameLayout(context) {
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
    private val resumeFollow = Runnable { followCurrent(animate = true) }

    init {
        list.apply {
            divider = null
            dividerHeight = 0
            isVerticalScrollBarEnabled = false
            isNestedScrollingEnabled = true
            overScrollMode = View.OVER_SCROLL_NEVER
            setFadingEdgeLength(dp(24))
            addHeaderView(topSpace, null, false)
            addFooterView(bottomSpace, null, false)
            adapter = rows
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

    fun render(playback: PlaybackSnapshot, canSeek: Boolean, advancedEffects: Boolean) {
        val nextTrack = Track(
            playback.protocol,
            playback.sourceEpoch,
            playback.trackIdentity ?: playback.mediaUrl ?: playback.title,
        )
        val nextDocument = playback.lyrics
        val trackChanged = nextTrack != track
        val rowsChanged = trackChanged || document !== nextDocument
        val seekChanged = seeking != canSeek
        val previousIndex = playingIndex
        track = nextTrack
        document = nextDocument
        seeking = canSeek
        playingIndex = nextDocument?.activeLineIndex(playback.positionMs)

        val hasLines = !nextDocument?.lines.isNullOrEmpty()
        list.visibility = if (hasLines) View.VISIBLE else View.GONE
        val emptyLabel = if (playback.lyricsLoading) "正在载入歌词…" else "发送设备未提供歌词"
        if (empty.text.toString() != emptyLabel) empty.text = emptyLabel
        empty.visibility = if (hasLines) View.GONE else View.VISIBLE
        list.isVerticalFadingEdgeEnabled = advancedEffects && accessibility?.isTouchExplorationEnabled != true

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
            post { followCurrent(animate = false) }
        } else if (playingIndex != previousIndex) {
            followCurrent(animate = true)
        }
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        updateScrollInsets()
        if (width != oldWidth) rows.notifyDataSetChanged()
        post { followCurrent(animate = false) }
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(resumeFollow)
        super.onDetachedFromWindow()
    }

    private fun updateScrollInsets() {
        val canFollow = document?.isSynchronized == true && accessibility?.isTouchExplorationEnabled != true
        topSpace.layoutParams = AbsListView.LayoutParams(LayoutParams.MATCH_PARENT, if (canFollow) (height * ANCHOR).roundToInt() else dp(12))
        bottomSpace.layoutParams = AbsListView.LayoutParams(LayoutParams.MATCH_PARENT, if (canFollow) (height * (1 - ANCHOR)).roundToInt() else dp(16))
    }

    private fun pauseFollow() {
        browsingUntil = SystemClock.uptimeMillis() + FOLLOW_PAUSE_MS
        removeCallbacks(resumeFollow)
        postDelayed(resumeFollow, FOLLOW_PAUSE_MS)
    }

    private fun followCurrent(animate: Boolean) {
        val index = playingIndex ?: return
        if (!isShown || height == 0 || userScrolling || touchBrowsing || SystemClock.uptimeMillis() < browsingUntil ||
            accessibility?.isTouchExplorationEnabled == true || list.hasFocus()
        ) return
        val target = index + 1 // The timed list has a blank header above its first row.
        val offset = (height * ANCHOR).roundToInt()
        val motionEnabled = Build.VERSION.SDK_INT < 26 || ValueAnimator.areAnimatorsEnabled()
        if (animate && motionEnabled) list.smoothScrollToPositionFromTop(target, offset, 330)
        else list.setSelectionFromTop(target, offset)
    }

    private inner class LyricList : ListView(context) {
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
            if (!gainFocus) pauseFollow()
        }
    }

    private inner class LyricRows : BaseAdapter() {
        override fun getCount(): Int = document?.lines?.size ?: 0
        override fun getItem(position: Int) = document?.lines?.getOrNull(position)
        override fun getItemId(position: Int): Long = position.toLong()
        override fun areAllItemsEnabled(): Boolean = false
        override fun isEnabled(position: Int): Boolean = seeking && getItem(position)?.startMs != null

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val row = (convertView as? TextView) ?: TextView(context).apply {
                typeface = Typeface.create("sans-serif", Typeface.BOLD)
                setPadding(dp(8), dp(8), dp(8), dp(8))
                setLineSpacing(dp(3).toFloat(), 1f)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            }
            row.textSize = (width / resources.displayMetrics.density * .076f).coerceIn(24f, 36f)
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

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    private companion object {
        const val ANCHOR = .32f
        const val FOLLOW_PAUSE_MS = 5_000L
    }
}
