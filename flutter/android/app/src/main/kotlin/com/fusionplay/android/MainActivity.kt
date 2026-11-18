package com.fusionplay.android

import android.Manifest
import android.app.Activity
import android.app.Dialog
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.KeyEvent
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.Window
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.fusionplay.android.media.FusionPlayMediaChannel
import com.fusionplay.android.media.FusionPlayMediaCommand
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

class MainActivity : Activity() {
    private val consumedMediaKeys = mutableSetOf<Int>()
    private var pendingAccessibilityKeepAlivePrompt = false
    private var stateJob: Job? = null
    private var settingsDialog: Dialog? = null
    private var settingsView: NativeSettingsView? = null
    private var hasShownPlayback = false
    private var restoreSettings = false
    private var observing = false
    private val runtime get() = (application as FusionPlayApplication).runtime
    private val isTelevision by lazy(LazyThreadSafetyMode.NONE) {
        getSystemService(UiModeManager::class.java)?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }
    private lateinit var player: NativePlayerView
    private lateinit var preferenceStore: NativePlayerPreferenceStore
    private lateinit var preferences: NativePlayerPreferences
    private val uiHandler = Handler(Looper.getMainLooper())
    private val updateArtwork = Runnable {
        if (observing) player.setArtwork(FusionPlayMediaChannel.currentArtwork())
    }
    private val mediaListener: () -> Unit = {
        uiHandler.removeCallbacks(updateArtwork)
        uiHandler.post(updateArtwork)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        configureWindow(window)
        AccessibilityKeepAliveController.markAppLaunchedThisBoot(this)
        volumeControlStream = AudioManager.STREAM_MUSIC
        preferenceStore = NativePlayerPreferenceStore(this)
        preferences = preferenceStore.load()
        player = NativePlayerView(
            context = this,
            onPlayback = runtime::playback,
            onSeek = runtime::seek,
            onVolume = runtime::setVolume,
            onOpenSettings = ::showSettings,
            onUpdatePreferences = ::updatePreferences,
        )
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.rgb(14, 17, 22))
            addView(player, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        }
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val safe = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
            )
            view.setPadding(safe.left, safe.top, safe.right, safe.bottom)
            WindowInsetsCompat.CONSUMED
        }
        setContentView(root)
        restoreSettings = savedInstanceState?.getBoolean(STATE_SETTINGS_OPEN) == true
        pendingAccessibilityKeepAlivePrompt = shouldShowAccessibilityKeepAlivePrompt()
        requestReceiverPermissions()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(STATE_SETTINGS_OPEN, settingsDialog?.isShowing == true)
        super.onSaveInstanceState(outState)
    }

    private fun showSettings() {
        if (settingsDialog != null || isFinishing || isDestroyed) return
        val dialog = Dialog(this)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
        val content = NativeSettingsView(this, ::applySettingsAction, dialog::dismiss)
        settingsView = content
        settingsDialog = dialog
        dialog.setContentView(content)
        dialog.setCanceledOnTouchOutside(true)
        dialog.setOnDismissListener {
            settingsDialog = null
            settingsView = null
            if (observing && isTelevision) player.focusPrimaryControl()
        }
        dialog.setOnKeyListener { _, key, event ->
            val menu = key == KeyEvent.KEYCODE_MENU
            if (menu && event.action == KeyEvent.ACTION_UP) dialog.dismiss()
            menu
        }
        render(runtime.uiState.value)
        dialog.show()
        dialog.window?.let { settingsWindow ->
            settingsWindow.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            settingsWindow.setGravity(Gravity.CENTER)
            val density = resources.displayMetrics.density
            val width = (minOf(560, resources.configuration.screenWidthDp - 24) * density).toInt()
            val height = (minOf(740, resources.configuration.screenHeightDp - 24) * density).toInt()
            settingsWindow.setLayout(width.coerceAtLeast(1), height.coerceAtLeast(1))
            settingsWindow.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
        if (isTelevision) content.focusEntry()
    }

    private fun applySettingsAction(action: NativeSettingsAction) {
        when (action) {
            is NativeSettingsAction.ReceiverName -> runtime.setReceiverName(action.value)
            is NativeSettingsAction.Startup -> runtime.setStartupEnabled(action.value)
            is NativeSettingsAction.AutoWake -> runtime.setAutoWakeEnabled(action.value)
            is NativeSettingsAction.KeepScreenOn -> runtime.setKeepScreenOnWhilePlaying(action.value)
            is NativeSettingsAction.AdvancedEffects -> runtime.setAdvancedEffectsEnabled(action.value)
            is NativeSettingsAction.NativeCast -> runtime.setNativeCastPaused(action.value)
            is NativeSettingsAction.AudioAdvance -> runtime.setMiPlayOutputAdvance(action.value)
            is NativeSettingsAction.Protocol -> runtime.setProtocolEnabled(action.protocol, action.enabled)
            is NativeSettingsAction.Identity -> runtime.setMiPlayDeviceIdentity(action.value)
            NativeSettingsAction.ExportLogs -> runtime.exportLogs()
            is NativeSettingsAction.PlayerPreferences -> updatePreferences(action.value)
        }
    }

    private fun updatePreferences(value: NativePlayerPreferences) {
        if (value == preferences) return
        preferences = value
        preferenceStore.save(value)
        render(runtime.uiState.value)
    }

    private fun render(ui: ReceiverUiState) {
        // Project the backend's effective default receiver name without writing it to disk.
        val playerState = if (ui.state.settings.receiverName != null) ui.state else
            ui.state.copy(settings = ui.state.settings.copy(receiverName = ui.receiverName))
        player.render(playerState, ui.volumePercent, preferences)
        val state = ui.state
        settingsView?.render(state, ui.nativeCast, ui.miPlayOutputAdvanceMs, preferences)
        setKeepScreenOn(observing && state.settings.keepScreenOnWhilePlaying && state.playback.isPlaying)
        val playback = state.playback
        val hasPlayback = playback.streamActive || playback.protocol != null ||
            playback.title != null || playback.mediaUrl != null || playback.durationMs != null
        if (!hasShownPlayback && hasPlayback && settingsDialog == null && isTelevision) {
            player.focusPrimaryControl()
        }
        hasShownPlayback = hasPlayback
    }

    override fun onStart() {
        super.onStart()
        observing = true
        appInForeground = true
        runtime.setAppForeground(true)
        FusionPlayMediaChannel.addStateListener(mediaListener)
        updateArtwork.run()
        runtime.refreshUiState()
        stateJob?.cancel()
        stateJob = CoroutineScope(Dispatchers.Main.immediate).launch {
            runtime.uiState.collect(::render)
        }
        if (restoreSettings) {
            restoreSettings = false
            showSettings()
        } else if (isTelevision && settingsDialog == null && currentFocus == null) {
            player.focusPrimaryControl()
        }
    }

    override fun onStop() {
        observing = false
        stateJob?.cancel()
        stateJob = null
        FusionPlayMediaChannel.removeStateListener(mediaListener)
        uiHandler.removeCallbacks(updateArtwork)
        setKeepScreenOn(false)
        appInForeground = false
        runtime.setAppForeground(false)
        super.onStop()
    }

    override fun onDestroy() {
        settingsDialog?.dismiss()
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) configureWindow(window)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (isVolumeKey(event.keyCode)) {
            val handled = super.dispatchKeyEvent(event)
            if (event.action == KeyEvent.ACTION_UP) {
                runtime.syncVolumeFromReceiver()
            }
            return handled
        }
        if (event.keyCode == KeyEvent.KEYCODE_MENU) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                showSettings()
            }
            return true
        }
        if (!isMediaKey(event.keyCode)) {
            return super.dispatchKeyEvent(event)
        }
        return when (event.action) {
            KeyEvent.ACTION_DOWN -> {
                if (event.repeatCount > 0 && event.keyCode in consumedMediaKeys) {
                    true
                } else if (dispatchMediaKey(event.keyCode)) {
                    consumedMediaKeys += event.keyCode
                    true
                } else {
                    super.dispatchKeyEvent(event)
                }
            }

            KeyEvent.ACTION_UP -> {
                if (consumedMediaKeys.remove(event.keyCode)) {
                    true
                } else {
                    super.dispatchKeyEvent(event)
                }
            }

            else -> super.dispatchKeyEvent(event)
        }
    }

    private fun dispatchMediaKey(keyCode: Int): Boolean {
        val state = FusionPlayMediaChannel.currentSnapshot()
        val command = when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_HEADSETHOOK,
            -> if (state.canPlayPause) {
                if (state.playing) FusionPlayMediaCommand.PAUSE else FusionPlayMediaCommand.PLAY
            } else {
                null
            }

            KeyEvent.KEYCODE_MEDIA_PLAY ->
                FusionPlayMediaCommand.PLAY.takeIf { state.canPlayPause }
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_STOP,
            -> FusionPlayMediaCommand.PAUSE.takeIf { state.canPlayPause }
            KeyEvent.KEYCODE_MEDIA_PREVIOUS ->
                FusionPlayMediaCommand.PREVIOUS.takeIf { state.canPrevious }
            KeyEvent.KEYCODE_MEDIA_NEXT ->
                FusionPlayMediaCommand.NEXT.takeIf { state.canNext }
            else -> null
        } ?: return false
        FusionPlayMediaChannel.dispatch(command)
        return true
    }

    private fun requestReceiverPermissions() {
        if (Build.VERSION.SDK_INT < 33) {
            startReceiverService()
            return
        }
        val permissions = listOf(
            Manifest.permission.POST_NOTIFICATIONS,
            Manifest.permission.NEARBY_WIFI_DEVICES,
        ).filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (permissions.isEmpty()) {
            startReceiverService()
        } else {
            requestPermissions(permissions.toTypedArray(), RECEIVER_PERMISSION_REQUEST)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == RECEIVER_PERMISSION_REQUEST) startReceiverService()
    }

    private fun startReceiverService() {
        ContextCompat.startForegroundService(this, Intent(this, ReceiverForegroundService::class.java))
        promptAccessibilityKeepAliveIfNeeded()
    }

    private fun shouldShowAccessibilityKeepAlivePrompt(): Boolean {
        val preferences = getSharedPreferences(
            ACCESSIBILITY_PROMPT_PREFERENCES,
            Context.MODE_PRIVATE,
        )
        if (preferences.getBoolean(ACCESSIBILITY_PROMPT_SHOWN_KEY, false)) {
            return false
        }
        if (AccessibilityKeepAliveController.isServiceEnabled(this)) {
            preferences.edit().putBoolean(ACCESSIBILITY_PROMPT_SHOWN_KEY, true).apply()
            return false
        }
        return true
    }

    private fun promptAccessibilityKeepAliveIfNeeded() {
        if (!pendingAccessibilityKeepAlivePrompt) return
        pendingAccessibilityKeepAlivePrompt = false
        getSharedPreferences(ACCESSIBILITY_PROMPT_PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(ACCESSIBILITY_PROMPT_SHOWN_KEY, true)
            .apply()
        AccessibilityKeepAliveController.requestAuthorization(this)
    }

    companion object {
        private const val RECEIVER_PERMISSION_REQUEST = 1201
        private const val STATE_SETTINGS_OPEN = "settings_open"
        private const val ACCESSIBILITY_PROMPT_PREFERENCES = "accessibility_keep_alive_prompt"
        private const val ACCESSIBILITY_PROMPT_SHOWN_KEY = "shown_v1"

        @Volatile
        private var appInForeground = false

        internal fun isAppInForeground(): Boolean = appInForeground

        private fun isMediaKey(keyCode: Int): Boolean =
            keyCode == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE ||
                keyCode == KeyEvent.KEYCODE_HEADSETHOOK ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PLAY ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PAUSE ||
                keyCode == KeyEvent.KEYCODE_MEDIA_STOP ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PREVIOUS ||
                keyCode == KeyEvent.KEYCODE_MEDIA_NEXT

        private fun isVolumeKey(keyCode: Int): Boolean =
            keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
                keyCode == KeyEvent.KEYCODE_VOLUME_DOWN ||
                keyCode == KeyEvent.KEYCODE_VOLUME_MUTE

    }

    private fun configureWindow(window: Window) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        @Suppress("DEPRECATION")
        window.statusBarColor = Color.TRANSPARENT
        @Suppress("DEPRECATION")
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= 29) window.isNavigationBarContrastEnforced = false
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.isAppearanceLightStatusBars = false
        controller.isAppearanceLightNavigationBars = false
        if (isTelevision) {
            controller.hide(WindowInsetsCompat.Type.systemBars())
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun setKeepScreenOn(keepOn: Boolean) {
        val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        if (((window.attributes.flags and flag) != 0) == keepOn) return
        if (keepOn) window.addFlags(flag) else window.clearFlags(flag)
    }
}
