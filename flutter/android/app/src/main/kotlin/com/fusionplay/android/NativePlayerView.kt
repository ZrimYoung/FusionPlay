package com.fusionplay.android

import android.animation.ValueAnimator
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.RenderEffect
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.SystemClock
import android.text.TextUtils
import android.transition.AutoTransition
import android.transition.TransitionManager
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityManager
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import com.airplayreceiver.desktop.backend.AppState
import com.airplayreceiver.desktop.backend.MediaControlAvailability
import com.airplayreceiver.desktop.backend.PlaybackCommand
import com.airplayreceiver.desktop.backend.PlaybackSnapshot
import com.airplayreceiver.desktop.backend.displayMetadata
import com.airplayreceiver.desktop.backend.mediaControlAvailability
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/** Native counterpart of the iPad player. Network and media state stay in the receiver runtime. */
internal class NativePlayerView(
    context: Context,
    private val onPlayback: (PlaybackCommand) -> Unit,
    private val onSeek: (Long) -> Unit,
    private val onVolume: (Int) -> Unit,
    private val onOpenSettings: () -> Unit,
    private val onUpdatePreferences: (NativePlayerPreferences) -> Unit,
) : FrameLayout(context) {
    private var preferences = NativePlayerPreferences()
    private var state = AppState()
    private var hasTrack = false
    private var playbackAvailability = MediaControlAvailability(false, false, false, false)
    private var volumePercent = 100
    private var layout: NativePlayerLayout? = null
    private var inputIsDirectional = false
    private val television = context.getSystemService(UiModeManager::class.java)
        ?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    private val accessibility = context.getSystemService(AccessibilityManager::class.java)

    private val ambientImage = artworkImage().apply {
        alpha = 0.49f
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            setRenderEffect(RenderEffect.createBlurEffect(dp(44f).toFloat(), dp(44f).toFloat(), Shader.TileMode.CLAMP))
        }
    }
    private var lastArtwork: Bitmap? = null
    private var presentedArtwork: Bitmap? = null
    private val oldArtwork = artworkImage()
    private val coverArtwork = artworkImage()
    private val cover = FrameLayout(context).apply {
        clipToOutline = true
        elevation = dp(10f).toFloat()
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private val coverFallback = NativePlayerGlyph(context, NativePlayerIcon.MUSIC, 58f).apply {
        ink = Color.argb(168, 145, 242, 227)
    }
    private val coverSlot = FrameLayout(context).apply { clipChildren = false }
    private val content = vertical()
    private val playback = vertical().apply { clipChildren = false }
    private val header = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(58f)
    }
    private val brand = vertical()
    private val brandTitle = label(17f, NativePlayerColors.text, semibold = true).apply { text = "FusionPlay" }
    private val headerStatus = label(12f, NativePlayerColors.secondaryText).apply { maxLines = 2 }
    private val toolbar = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }
    private val lyricsButton = action(NativePlayerIcon.LYRICS, "显示歌词", 18f, 18) {
        onUpdatePreferences(preferences.copy(showLyrics = !preferences.showLyrics))
    }
    private val volumeButton = action(NativePlayerIcon.VOLUME, "接收音量", 18f, 18, ::showVolume)
    private val settingsButton = action(NativePlayerIcon.SETTINGS, "接收设置", 18f, 18, onOpenSettings)
    private val hideToolbar = Runnable { if (toolbarCanHide()) setToolbarVisible(false) }
    private var toolbarVisible = true
    private var volumePopup: PopupWindow? = null
    private var volumeSlider: SeekBar? = null
    private var volumeLabel: TextView? = null
    private var volumeDragging = false

    private val viewport = ScrollView(context).apply {
        isFillViewport = true
        isVerticalScrollBarEnabled = false
        clipToPadding = false
        overScrollMode = OVER_SCROLL_IF_CONTENT_SCROLLS
        descendantFocusability = FOCUS_AFTER_DESCENDANTS
    }
    private val canvasContent = FrameLayout(context) // A centered reading area that can outgrow the viewport.
    private val idle = vertical().apply { gravity = Gravity.CENTER }
    private val idleTitle = label(25f, NativePlayerColors.text, semibold = true).apply { gravity = Gravity.CENTER }
    private val idleHint = label(15f, NativePlayerColors.secondaryText).apply { gravity = Gravity.CENTER }
    private val idleError = label(14f, NativePlayerColors.warning).apply { gravity = Gravity.CENTER }
    private val idleBusy = ProgressBar(context).apply { indeterminateTintList = ColorStateList.valueOf(NativePlayerColors.accent) }

    private val details = vertical()
    private val metadata = vertical()
    private val title = label(27f, NativePlayerColors.text, semibold = true)
    private val subtitle = label(16f, NativePlayerColors.secondaryText)
    private val detailsError = label(14f, NativePlayerColors.warning)
    private val timeline = vertical()
    private val seek = slider("播放进度", TIMELINE_STEPS)
    private val elapsed = label(12f, NativePlayerColors.secondaryText).apply { setTypeface(Typeface.MONOSPACE) }
    private val total = label(12f, NativePlayerColors.secondaryText).apply { setTypeface(Typeface.MONOSPACE) }
    private var touchTracking = false
    private var draggingTimeline: TimelineKey? = null
    private var lastTimeline: TimelineKey? = null
    private var pendingSeek: PendingSeek? = null
    private val expireSeek = Runnable {
        pendingSeek = null
        renderTimeline()
    }
    private val transport = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER
    }
    private val previous = action(NativePlayerIcon.PREVIOUS, "上一曲", 22f) { onPlayback(PlaybackCommand.PREVIOUS_TRACK) }
    private val playPause = action(NativePlayerIcon.PLAY, "播放", 27f, 36) { onPlayback(PlaybackCommand.PLAY_PAUSE) }
    private val next = action(NativePlayerIcon.NEXT, "下一曲", 22f) { onPlayback(PlaybackCommand.NEXT_TRACK) }
    private val lyrics = NativeLyricsView(context, onSeek)

    private data class TimelineKey(val source: String?, val epoch: Long?, val track: String?, val duration: Long)
    private data class PendingSeek(val identity: TimelineKey, val target: Long, val until: Long)

    init {
        background = GradientDrawable(GradientDrawable.Orientation.TL_BR, intArrayOf(NativePlayerColors.backgroundTop, NativePlayerColors.background))
        addView(ambientImage, fullFrame())
        addView(View(context).apply {
            background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(0x1F0B1114, 0xD10B1114.toInt()))
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }, fullFrame())

        val foreground = vertical()
        addView(foreground, fullFrame())
        foreground.addView(header, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        foreground.addView(viewport, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        viewport.addView(canvasContent, LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        canvasContent.addView(content, LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER))
        canvasContent.addView(idle, LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER))
        viewport.addOnLayoutChangeListener { _, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
            if (right - left != oldRight - oldLeft || bottom - top != oldBottom - oldTop) updateLayout()
        }

        brand.addView(brandTitle)
        brand.addView(headerStatus, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = dp(4f) })
        header.addView(brand, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        header.addView(toolbar, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
        listOf(lyricsButton, volumeButton, settingsButton).forEach { button ->
            toolbar.addView(button, LinearLayout.LayoutParams(dp(44f), dp(44f)).apply { marginStart = dp(6f) })
        }

        idle.setPadding(dp(16f), dp(24f), dp(16f), dp(24f))
        idle.addView(NativePlayerGlyph(context, NativePlayerIcon.WAVEFORM, 49f).apply {
            ink = NativePlayerColors.accent
            background = card(0x0FFFFFFF, 28f, 0x22FFFFFF)
        }, LinearLayout.LayoutParams(dp(106f), dp(106f)))
        idle.addView(idleTitle, idleRow(16f))
        idle.addView(idleHint, idleRow(10f))
        idle.addView(idleError, idleRow(12f))
        idle.addView(idleBusy, LinearLayout.LayoutParams(dp(28f), dp(28f)).apply { topMargin = dp(14f) })

        content.addView(playback)
        content.addView(lyrics)
        coverSlot.addView(cover, LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER))
        cover.addView(coverFallback, fullFrame())
        cover.addView(oldArtwork, fullFrame())
        cover.addView(coverArtwork, fullFrame())
        playback.addView(coverSlot)
        playback.addView(details)
        details.addView(metadata, detailsRow())
        metadata.addView(title, detailsRow())
        metadata.addView(subtitle, detailsRow(5f))
        details.addView(timeline, detailsRow(12f))
        timeline.addView(seek, LinearLayout.LayoutParams(MATCH_PARENT, dp(34f)))
        val timestamps = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
        timestamps.addView(elapsed, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        timestamps.addView(total)
        timeline.addView(timestamps, detailsRow())
        details.addView(transport, LinearLayout.LayoutParams(MATCH_PARENT, dp(62f)).apply { topMargin = dp(10f) })
        transport.addView(previous, LinearLayout.LayoutParams(dp(52f), dp(52f)))
        transport.addView(playPause, LinearLayout.LayoutParams(dp(62f), dp(62f)).apply { marginStart = dp(24f); marginEnd = dp(24f) })
        transport.addView(next, LinearLayout.LayoutParams(dp(52f), dp(52f)))
        details.addView(detailsError, detailsRow(10f))

        previous.nextFocusRightId = playPause.id
        playPause.nextFocusLeftId = previous.id
        playPause.nextFocusRightId = next.id
        next.nextFocusLeftId = playPause.id
        seek.nextFocusDownId = playPause.id
        settingsButton.nextFocusDownId = playPause.id
        lyricsButton.nextFocusRightId = volumeButton.id
        volumeButton.nextFocusLeftId = lyricsButton.id
        volumeButton.nextFocusRightId = settingsButton.id
        settingsButton.nextFocusLeftId = volumeButton.id
        playPause.nextFocusUpId = seek.id
        bindSeek()
        render(state, volumePercent, preferences)
    }

    fun render(state: AppState, volumePercent: Int, preferences: NativePlayerPreferences) {
        val hadTrack = hasTrack
        val oldPreferences = this.preferences
        val wasPlayable = playbackAvailability.canPlayPause
        this.state = state
        this.volumePercent = volumePercent.coerceIn(0, 100)
        this.preferences = preferences
        val current = state.playback
        hasTrack = current.streamActive || current.protocol.present() || current.title.present() ||
            current.artist.present() || current.mediaUrl.present() || current.trackIdentity.present() || (current.durationMs ?: 0L) > 0
        val local = current.mediaUrl.present() && current.protocol.equals("AirPlay", ignoreCase = true)
        playbackAvailability = state.mediaControlAvailability(controlsLocalMedia = local)

        if (hadTrack && hasTrack && isLaidOut && animations() && explicitDisplayChange(oldPreferences, preferences)) {
            animateDisplayChange()
        }
        setVisible(content, hasTrack)
        setVisible(idle, !hasTrack)
        // Keep the empty brand slot so the toolbar alignment is identical during playback.
        val brandVisibility = if (hasTrack) INVISIBLE else VISIBLE
        if (brand.visibility != brandVisibility) brand.visibility = brandVisibility
        setVisible(lyricsButton, hasTrack)
        setVisible(volumeButton, hasTrack)
        setVisible(timeline, preferences.showProgress)
        setVisible(transport, preferences.showTransport)
        setVisible(lyrics, preferences.showLyrics && hasTrack)
        setVisible(idleBusy, state.busy || !state.initialized)

        lyricsButton.isSelected = preferences.showLyrics
        phrases(lyricsButton, if (preferences.showLyrics) "隐藏歌词" else "显示歌词")
        phrases(playPause, if (current.isPlaying) "暂停" else "播放")
        phrases(volumeButton, "接收音量，${this.volumePercent}%")
        playPause.icon = if (current.isPlaying) NativePlayerIcon.PAUSE else NativePlayerIcon.PLAY
        volumeButton.isEnabled = state.initialized && !state.busy
        previous.isEnabled = hasTrack && playbackAvailability.canPrevious
        playPause.isEnabled = hasTrack && playbackAvailability.canPlayPause
        next.isEnabled = hasTrack && playbackAvailability.canNext
        playPause.nextFocusUpId = if (preferences.showProgress && playbackAvailability.canSeek) seek.id else settingsButton.id

        if (hasTrack) {
            if (oldPreferences.wrapMetadata != preferences.wrapMetadata) {
                title.maxLines = if (preferences.wrapMetadata) 3 else 1
                subtitle.maxLines = if (preferences.wrapMetadata) 2 else 1
            }
            val metadata = current.displayMetadata(preferences.correctLyricTitles)
            updateText(title, metadata.title?.trim().takeIf { it.present() } ?: "等待曲目信息")
            val credit = listOfNotNull(metadata.artist?.trim().takeIf { it.present() }, metadata.album?.trim().takeIf { it.present() })
                .joinToString(" · ").ifEmpty { current.protocol.orEmpty() }
            updateText(subtitle, credit)
            setVisible(subtitle, credit.isNotEmpty())
            status(detailsError, state.lastError)
            if (preferences.showLyrics) lyrics.render(
                playback = current,
                canSeek = playbackAvailability.canSeek,
                advancedEffects = state.settings.advancedEffectsEnabled,
                staggerEnabled = preferences.staggerLyricMotion,
                staggerMilliseconds = preferences.lyricStaggerMilliseconds,
            )
        } else {
            renderIdle()
        }
        renderTimeline()
        renderVolume()
        if (hadTrack != hasTrack) {
            if (!hasTrack) volumePopup?.dismiss()
            applyArtwork()
            revealToolbar()
        }
        if (oldPreferences != preferences || hadTrack != hasTrack) {
            val oldMode = layout?.mode
            updateLayout()
            if (oldPreferences.showLyrics != preferences.showLyrics && layout?.mode == NativePlayerLayout.Mode.STACKED && hasTrack) {
                moveToLyrics(preferences.showLyrics)
            } else if (oldMode != layout?.mode && !preferences.showLyrics) {
                viewport.scrollTo(0, 0)
            }
            if (oldPreferences.toolbarAlwaysVisible != preferences.toolbarAlwaysVisible) revealToolbar()
        }
        if (television && (!hadTrack && hasTrack || !wasPlayable && playPause.isEnabled)) post {
            // Never steal focus from a settings surface or from an existing playback control.
            if (hasWindowFocus() && (findFocus() == null || findFocus() === settingsButton)) focusPrimaryControl()
        }
    }

    fun setArtwork(artwork: Bitmap?) {
        if (lastArtwork === artwork) return
        lastArtwork = artwork
        applyArtwork()
    }

    fun focusPrimaryControl() {
        if (!television && !inputIsDirectional) return
        revealToolbar()
        if (hasTrack && preferences.showTransport && playPause.isEnabled) playPause.requestFocus()
        else if (hasTrack && preferences.showProgress && seek.isEnabled) seek.requestFocus()
        else settingsButton.requestFocus()
    }

    fun revealToolbar() {
        removeCallbacks(hideToolbar)
        setToolbarVisible(true)
        if (toolbarCanHide() && isAttachedToWindow) postDelayed(hideToolbar, TOOLBAR_DELAY_MS)
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        val handled = super.dispatchTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_DOWN || event.actionMasked == MotionEvent.ACTION_UP) {
            inputIsDirectional = false
            revealToolbar()
        }
        return handled
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN && event.keyCode in DIRECTIONAL_KEYS) {
            inputIsDirectional = true
            revealToolbar()
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        revealToolbar()
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(hideToolbar)
        removeCallbacks(expireSeek)
        pendingSeek = null
        draggingTimeline = null
        touchTracking = false
        volumePopup?.dismiss()
        coverArtwork.animate().cancel()
        coverArtwork.alpha = 1f
        oldArtwork.setImageDrawable(null)
        toolbar.animate().cancel()
        super.onDetachedFromWindow()
    }

    private fun renderIdle() {
        val protocols = listOfNotNull(
            "妙播".takeIf { state.settings.miPlayEnabled },
            "AirPlay".takeIf { state.settings.airPlayEnabled },
            "DLNA".takeIf { state.settings.dlnaEnabled },
        )
        val ready = state.receiverReady || state.coreRunning
        val status = when {
            !state.initialized || state.busy -> "正在准备接收"
            protocols.isEmpty() -> "接收已关闭"
            ready -> "等待连接"
            else -> "正在启动接收"
        }
        updateText(headerStatus, status)
        updateText(idleTitle, state.settings.receiverName?.trim().takeIf { it.present() } ?: "FusionPlay")
        val hint = when {
            protocols.isEmpty() -> "在接收设置中开启投放方式"
            ready -> "在 ${protocols.joinToString("、")} 的设备列表中选择上方名称"
            else -> status
        }
        updateText(idleHint, hint)
        status(idleError, state.lastError)
    }

    private fun updateLayout() {
        if (viewport.width <= 0 || viewport.height <= 0) return
        val density = resources.displayMetrics.density
        val widthDp = viewport.width / density
        val heightDp = viewport.height / density
        val nextLayout = NativePlayerLayout.fit(widthDp, heightDp, preferences, resources.configuration.fontScale >= 1.35f)
        if (layout == nextLayout) return
        val previousMode = layout?.mode
        layout = nextLayout
        val gutter = dp(NativePlayerLayout.horizontalInset(widthDp))
        header.setPadding(gutter, dp(5f), gutter, dp(5f))
        val side = dp(nextLayout.coverSide).coerceAtLeast(1)
        val leading = dp(nextLayout.leadingWidth).coerceAtLeast(1)
        val contentWidth = dp(nextLayout.contentWidth).coerceAtLeast(1)
        val gap = dp(nextLayout.gap)
        val horizontal = LinearLayout.HORIZONTAL
        val vertical = LinearLayout.VERTICAL
        val lyricsBeside = nextLayout.mode == NativePlayerLayout.Mode.ARTWORK_AND_LYRICS
        val controlsBeside = nextLayout.mode == NativePlayerLayout.Mode.ARTWORK_AND_CONTROLS
        content.orientation = if (lyricsBeside) horizontal else vertical
        content.gravity = Gravity.CENTER
        content.setPadding(0, dp(nextLayout.verticalInset), 0, dp(nextLayout.verticalInset))
        content.layoutParams = LayoutParams(contentWidth, WRAP_CONTENT, Gravity.CENTER)
        playback.orientation = if (controlsBeside) horizontal else vertical
        playback.gravity = Gravity.CENTER
        playback.layoutParams = LinearLayout.LayoutParams(if (lyricsBeside) leading else MATCH_PARENT, WRAP_CONTENT)
        coverSlot.layoutParams = LinearLayout.LayoutParams(if (controlsBeside) leading else side, side)
        cover.layoutParams = LayoutParams(side, side, Gravity.CENTER)
        val radius = minOf(25f, nextLayout.coverSide * 0.058f)
        cover.background = card(0xFF20323B.toInt(), radius, 0x22FFFFFF)
        details.layoutParams = LinearLayout.LayoutParams(if (controlsBeside) minOf(dp(420f), contentWidth - leading - gap).coerceAtLeast(1) else MATCH_PARENT, WRAP_CONTENT).apply {
            if (controlsBeside) marginStart = gap else topMargin = dp(if (lyricsBeside) 22f else 24f)
        }
        lyrics.layoutParams = LinearLayout.LayoutParams(
            if (lyricsBeside) (contentWidth - leading - gap).coerceAtLeast(1) else MATCH_PARENT,
            dp(nextLayout.lyricsHeight).coerceAtLeast(1),
        ).apply {
            if (lyricsBeside) marginStart = gap else topMargin = dp(30f)
        }
        idle.layoutParams = LayoutParams(minOf(contentWidth, dp(440f)), WRAP_CONTENT, Gravity.CENTER)
        if (previousMode == NativePlayerLayout.Mode.ARTWORK_AND_LYRICS && nextLayout.mode == NativePlayerLayout.Mode.STACKED && preferences.showLyrics && hasTrack) moveToLyrics(true)
    }

    private fun moveToLyrics(shown: Boolean) {
        viewport.post {
            if (!hasTrack || layout?.mode != NativePlayerLayout.Mode.STACKED || preferences.showLyrics != shown) return@post
            val scrollEnd = (canvasContent.height - viewport.height).coerceAtLeast(0)
            val target = if (shown) scrollEnd else 0
            if (animations()) viewport.smoothScrollTo(0, target) else viewport.scrollTo(0, target)
        }
    }

    private fun explicitDisplayChange(old: NativePlayerPreferences, current: NativePlayerPreferences): Boolean =
        old.showLyrics != current.showLyrics || old.showProgress != current.showProgress || old.showTransport != current.showTransport

    private fun animateDisplayChange() {
        val transition = AutoTransition().apply {
            duration = 120L // AutoTransition runs fade-out, resize and fade-in in sequence.
            interpolator = PathInterpolator(0.22f, 0.61f, 0.36f, 1f)
            listOf(coverSlot, details, lyrics, timeline, transport).forEach { addTarget(it) }
        }
        TransitionManager.beginDelayedTransition(content, transition)
    }

    private fun toolbarCanHide(): Boolean = hasTrack && !preferences.toolbarAlwaysVisible && !television &&
        !inputIsDirectional && accessibility?.isTouchExplorationEnabled != true && volumePopup == null && !toolbar.hasFocus()

    private fun setToolbarVisible(visible: Boolean) {
        if (toolbarVisible == visible && toolbar.alpha == if (visible) 1f else 0f) return
        toolbarVisible = visible
        toolbar.animate().cancel()
        if (visible) toolbar.visibility = VISIBLE
        val target = if (visible) 1f else 0f
        if (animations()) {
            toolbar.animate().alpha(target).setDuration(220).withEndAction {
                if (!toolbarVisible) toolbar.visibility = INVISIBLE
            }.start()
        } else {
            toolbar.alpha = target
            toolbar.visibility = if (visible) VISIBLE else INVISIBLE
        }
    }

    private fun applyArtwork() {
        val artwork = lastArtwork.takeIf { hasTrack }
        if (artwork === presentedArtwork) return
        coverArtwork.animate().cancel()
        val outgoing = presentedArtwork
        presentedArtwork = artwork
        coverArtwork.setImageBitmap(artwork)
        if (artwork != null && outgoing != null && isAttachedToWindow && animations()) {
            oldArtwork.setImageBitmap(outgoing)
            coverArtwork.alpha = 0f
            coverArtwork.animate().alpha(1f).setDuration(310).withEndAction { oldArtwork.setImageDrawable(null) }.start()
        } else {
            oldArtwork.setImageDrawable(null)
            coverArtwork.alpha = 1f
        }
        val ambient = artwork?.let { original ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) original else {
                // A tiny filtered bitmap gives older Android TVs a color wash without a shader.
                Bitmap.createScaledBitmap(original, 10, 10, true)
            }
        }
        ambientImage.setImageBitmap(ambient)
    }

    private fun timelineKey(playback: PlaybackSnapshot): TimelineKey = TimelineKey(
        playback.protocol,
        playback.sourceEpoch,
        playback.trackIdentity?.takeIf(String::isNotBlank) ?: playback.mediaUrl?.takeIf(String::isNotBlank) ?: playback.title,
        playback.durationMs?.coerceAtLeast(0) ?: 0,
    )

    private fun renderTimeline() {
        val playback = state.playback
        val current = timelineKey(playback)
        if (current != lastTimeline) {
            lastTimeline = current
            draggingTimeline = null
            clearPendingSeek()
        }
        val enabled = hasTrack && preferences.showProgress && playbackAvailability.canSeek && current.duration > 0L
        if (seek.isEnabled != enabled) seek.isEnabled = enabled
        if (!enabled) {
            draggingTimeline = null
            clearPendingSeek()
        }
        val duration = current.duration
        val reported = playback.positionMs.coerceIn(0, duration)
        if (draggingTimeline == current) return
        val pending = pendingSeek
        if (pending != null && (pending.identity != current || abs(reported - pending.target) <= 1_500 || SystemClock.elapsedRealtime() >= pending.until)) clearPendingSeek()
        val position = pendingSeek?.target ?: reported
        val progress = if (duration > 0) (position.toDouble() / duration * TIMELINE_STEPS).roundToInt() else 0
        if (seek.progress != progress) seek.progress = progress
        val increment = if (duration > 0) ((5_000.0 / duration) * TIMELINE_STEPS).roundToInt().coerceIn(1, TIMELINE_STEPS) else 1
        if (seek.keyProgressIncrement != increment) seek.keyProgressIncrement = increment
        updateText(elapsed, if (duration > 0) formatTime(position) else "–:––")
        updateText(total, if (duration > 0) formatTime(duration) else "–:––")
    }

    private fun bindSeek() {
        seek.setOnTouchListener { _, event ->
            if (event.actionMasked == MotionEvent.ACTION_CANCEL) draggingTimeline = null
            false
        }
        seek.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onStartTrackingTouch(bar: SeekBar) {
                touchTracking = true
                draggingTimeline = lastTimeline?.takeIf { bar.isEnabled }
                clearPendingSeek()
            }
            override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {
                if (!fromUser || !bar.isEnabled) return
                revealToolbar()
                val identity = (if (touchTracking) draggingTimeline else lastTimeline) ?: return
                val position = seekPosition(identity, progress)
                updateText(elapsed, formatTime(position))
                if (!touchTracking) submitSeek(identity, position)
            }
            override fun onStopTrackingTouch(bar: SeekBar) {
                val identity = draggingTimeline
                draggingTimeline = null
                touchTracking = false
                if (identity != null && bar.isEnabled && identity == lastTimeline) submitSeek(identity, seekPosition(identity, bar.progress))
                else renderTimeline()
            }
        })
    }

    private fun seekPosition(key: TimelineKey, progress: Int): Long =
        (progress.toDouble() / TIMELINE_STEPS * key.duration).roundToLong().coerceIn(0, key.duration)

    private fun submitSeek(key: TimelineKey, target: Long) {
        if (!seek.isEnabled || key != lastTimeline || !playbackAvailability.canSeek) return
        clearPendingSeek()
        pendingSeek = PendingSeek(key, target, SystemClock.elapsedRealtime() + SEEK_CONFIRMATION_MS)
        postDelayed(expireSeek, SEEK_CONFIRMATION_MS)
        onSeek(target)
    }

    private fun clearPendingSeek() {
        pendingSeek = null
        removeCallbacks(expireSeek)
    }

    private fun showVolume() {
        if (volumePopup != null) {
            volumePopup?.dismiss()
            return
        }
        if (!hasTrack || !volumeButton.isEnabled || !volumeButton.isAttachedToWindow) return
        val container = vertical().apply {
            setPadding(dp(17f), dp(12f), dp(17f), dp(10f))
            background = card(0xFF29373E.toInt(), 18f, 0x29FFFFFF)
        }
        val titleRow = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
        titleRow.addView(label(14f, NativePlayerColors.text, semibold = true).apply { text = "接收音量" }, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        val percentage = label(13f, NativePlayerColors.secondaryText).apply { text = "$volumePercent%" }
        titleRow.addView(percentage)
        container.addView(titleRow, detailsRow())
        val control = slider("接收音量", 100).apply {
            progress = volumePercent
            keyProgressIncrement = 5
        }
        container.addView(control, LinearLayout.LayoutParams(MATCH_PARENT, dp(42f)))
        val popup = PopupWindow(container, minOf(dp(250f), viewport.width - dp(24f)).coerceAtLeast(1), WRAP_CONTENT, true).apply {
            elevation = dp(14f).toFloat()
            setBackgroundDrawable(card(Color.TRANSPARENT, 18f))
            isOutsideTouchable = true
        }
        volumePopup = popup
        volumeButton.isSelected = true
        volumeSlider = control
        volumeLabel = percentage
        popup.setOnDismissListener {
            volumePopup = null
            volumeButton.isSelected = false
            volumeDragging = false
            volumeSlider = null
            volumeLabel = null
            if (television || inputIsDirectional) volumeButton.requestFocus()
            revealToolbar()
        }
        control.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onStartTrackingTouch(bar: SeekBar) { volumeDragging = true }
            override fun onStopTrackingTouch(bar: SeekBar) {
                volumeDragging = false
                volumePercent = bar.progress
                if (volumeButton.isEnabled) onVolume(bar.progress)
            }
            override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {
                updateText(percentage, "$progress%")
                if (fromUser && !volumeDragging) {
                    volumePercent = progress
                    if (volumeButton.isEnabled) onVolume(progress)
                }
            }
        })
        revealToolbar()
        popup.showAsDropDown(volumeButton, 0, dp(6f), Gravity.END)
        if (television || inputIsDirectional) control.requestFocus()
    }

    private fun renderVolume() {
        volumeSlider?.isEnabled = volumeButton.isEnabled
        if (volumeDragging) return
        volumeSlider?.let { if (it.progress != volumePercent) it.progress = volumePercent }
        volumeLabel?.let { updateText(it, "$volumePercent%") }
    }

    private fun slider(name: String, maximum: Int): SeekBar = SeekBar(context).apply {
        id = generateViewId()
        contentDescription = name
        max = maximum
        progressTintList = ColorStateList.valueOf(NativePlayerColors.text)
        progressBackgroundTintList = ColorStateList.valueOf(0x4AFFFFFF)
        thumbTintList = ColorStateList.valueOf(NativePlayerColors.text)
    }

    private fun label(sizeSp: Float, color: Int, semibold: Boolean = false) = TextView(context).apply {
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
        setTextColor(color)
        includeFontPadding = false
        if (semibold) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }

    private fun action(icon: NativePlayerIcon, name: String, side: Float, prominence: Int = 0, onClick: () -> Unit) =
        NativePlayerGlyph(context, icon, side, prominence) { revealToolbar(); onClick() }.apply {
            id = generateViewId()
            contentDescription = name
        }

    private fun phrases(view: View, next: String) {
        if (view.contentDescription != next) view.contentDescription = next
    }

    private fun updateText(view: TextView, next: String) {
        if (view.text != next) view.text = next
    }

    private fun status(view: TextView, message: String?) {
        updateText(view, message.orEmpty())
        setVisible(view, message.present())
    }

    private fun setVisible(view: View, visible: Boolean) {
        val next = if (visible) VISIBLE else GONE
        if (view.visibility != next) view.visibility = next
    }

    private fun card(color: Int, radius: Float, stroke: Int = Color.TRANSPARENT) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radius).toFloat()
        if (stroke != Color.TRANSPARENT) setStroke(dp(1f), stroke)
    }

    private fun artworkImage() = ImageView(context).apply {
        scaleType = ImageView.ScaleType.CENTER_CROP
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    private fun fullFrame() = LayoutParams(MATCH_PARENT, MATCH_PARENT)
    private fun idleRow(top: Float) = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = dp(top) }
    private fun detailsRow(top: Float = 0f) = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = dp(top) }
    private fun vertical() = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private fun dp(value: Float) = (value * resources.displayMetrics.density).roundToInt()
    private fun animations(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.O || ValueAnimator.areAnimatorsEnabled()
    private fun String?.present(): Boolean = !this.isNullOrBlank()

    private fun formatTime(ms: Long): String {
        val seconds = ms / 1_000
        val hours = seconds / 3_600
        val minutes = seconds / 60 % 60
        return if (hours > 0) String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, seconds % 60)
        else String.format(Locale.ROOT, "%d:%02d", minutes, seconds % 60)
    }

    companion object {
        private const val MATCH_PARENT = ViewGroup.LayoutParams.MATCH_PARENT
        private const val WRAP_CONTENT = ViewGroup.LayoutParams.WRAP_CONTENT
        private const val TOOLBAR_DELAY_MS = 3_000L
        private const val SEEK_CONFIRMATION_MS = 3_000L
        private const val TIMELINE_STEPS = 10_000
        private val DIRECTIONAL_KEYS = setOf(KeyEvent.KEYCODE_TAB, KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT,
            KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_DPAD_CENTER)
    }
}
