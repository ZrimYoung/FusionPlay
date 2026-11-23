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
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
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
    private var stateJob: Job? = null
    private var settingsDialog: Dialog? = null
    private var settingsView: NativeSettingsView? = null
    private var hasShownPlayback = false
    private var restoreSettings = false
    private var restoreSettingsPage: NativeSettingsPage? = null
    private var observing = false
    private val runtime get() = (application as FusionPlayApplication).runtime
    private val isTelevision by lazy(LazyThreadSafetyMode.NONE) {
        getSystemService(UiModeManager::class.java)?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }
    private lateinit var player: NativePlayerView
    private var lyricBackCallback: OnBackInvokedCallback? = null
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

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(NativePlayerPreferenceStore(newBase).language().applyTo(newBase))
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
        player.onLyricBackAvailabilityChanged = ::setLyricBackCallback
        if (savedInstanceState?.getBoolean(STATE_COMPACT_LYRICS) == true) player.restoreCompactLyricsPage()
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.rgb(14, 17, 22))
            addView(player, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        }
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val safe = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
            )
            if (isTelevision) {
                view.setPadding(safe.left, safe.top, safe.right, safe.bottom)
            } else {
                player.setContentInsets(safe.left, safe.top, safe.right, safe.bottom)
            }
            WindowInsetsCompat.CONSUMED
        }
        setContentView(root)
        restoreSettings = savedInstanceState?.getBoolean(STATE_SETTINGS_OPEN) == true
        restoreSettingsPage = NativeSettingsPage.entries.firstOrNull {
            it.name == savedInstanceState?.getString(STATE_SETTINGS_PAGE)
        }
        if (savedInstanceState?.getBoolean(STATE_RECEIVER_RUNNING) ?: runtime.autoReceiveOnLaunch) {
            requestReceiverPermissions()
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(STATE_SETTINGS_OPEN, settingsDialog?.isShowing == true)
        outState.putString(STATE_SETTINGS_PAGE, settingsView?.page?.name)
        outState.putBoolean(STATE_RECEIVER_RUNNING, runtime.uiState.value.receiverRunning)
        outState.putBoolean(STATE_COMPACT_LYRICS, player.isCompactLyricsPageOpen())
        super.onSaveInstanceState(outState)
    }

    private fun showSettings() {
        if (settingsDialog != null || isFinishing || isDestroyed) return
        player.exitRemoteLyrics()
        val configuration = resources.configuration
        val fullScreen = !isTelevision && (configuration.screenWidthDp < 600 || configuration.smallestScreenWidthDp in 1..599)
        val light = configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK != Configuration.UI_MODE_NIGHT_YES
        val theme = when {
            fullScreen && light -> android.R.style.Theme_Material_Light_NoActionBar
            fullScreen -> android.R.style.Theme_Material_NoActionBar
            light -> android.R.style.Theme_Material_Light_Dialog_Alert
            else -> android.R.style.Theme_Material_Dialog_Alert
        }
        val dialog = Dialog(this, theme)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
        val content = NativeSettingsView(dialog.context, ::applySettingsAction, dialog::dismiss, restoreSettingsPage, fullScreen)
        restoreSettingsPage = null
        settingsView = content
        settingsDialog = dialog
        dialog.setContentView(content)
        dialog.setCanceledOnTouchOutside(!fullScreen)
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
        runtime.refreshReceiverDiagnostics()
        render(runtime.uiState.value)
        dialog.show()
        dialog.window?.let { settingsWindow ->
            settingsWindow.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            settingsWindow.setGravity(Gravity.CENTER)
            if (fullScreen) {
                configureFullScreenSettings(settingsWindow, content, light)
            } else {
                val density = resources.displayMetrics.density
                val width = (minOf(632, configuration.screenWidthDp - 24) * density).toInt()
                val height = (minOf(740, configuration.screenHeightDp - 24) * density).toInt()
                settingsWindow.setLayout(width.coerceAtLeast(1), height.coerceAtLeast(1))
            }
            @Suppress("DEPRECATION")
            settingsWindow.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
        if (isTelevision) content.focusEntry()
    }

    @Suppress("DEPRECATION")
    private fun configureFullScreenSettings(window: Window, view: NativeSettingsView, light: Boolean) {
        window.setLayout(MATCH_PARENT, MATCH_PARENT)
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= 29) {
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = light
            isAppearanceLightNavigationBars = light
        }
        ViewCompat.setOnApplyWindowInsetsListener(view) { content, insets ->
            val safe = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout() or WindowInsetsCompat.Type.ime(),
            )
            content.setPadding(safe.left, safe.top, safe.right, safe.bottom)
            WindowInsetsCompat.CONSUMED
        }
        ViewCompat.requestApplyInsets(view)
    }

    private fun applySettingsAction(action: NativeSettingsAction) {
        when (action) {
            is NativeSettingsAction.ReceiverName -> runtime.setReceiverName(action.value)
            is NativeSettingsAction.Startup -> runtime.setStartupEnabled(action.value)
            is NativeSettingsAction.AutoWake -> runtime.setAutoWakeEnabled(action.value)
            is NativeSettingsAction.KeepScreenOn -> runtime.setKeepScreenOnWhilePlaying(action.value)
            is NativeSettingsAction.AdvancedEffects -> runtime.setAdvancedEffectsEnabled(action.value)
            is NativeSettingsAction.NativeCast -> runtime.setNativeCastPaused(action.value)
            is NativeSettingsAction.AudioAdvance -> runtime.setMiPlaySyncOffset(action.value)
            is NativeSettingsAction.ReceiverRunning -> {
                if (action.enabled) requestReceiverPermissions() else runtime.stopReceiving()
            }
            is NativeSettingsAction.AutoReceiveOnLaunch -> runtime.setAutoReceiveOnLaunch(action.enabled)
            is NativeSettingsAction.Protocol -> runtime.setProtocolEnabled(action.protocol, action.enabled)
            is NativeSettingsAction.Identity -> runtime.setMiPlayDeviceIdentity(action.value)
            NativeSettingsAction.ExportLogs -> runtime.exportLogs()
            NativeSettingsAction.RefreshDiagnostics -> runtime.refreshReceiverDiagnostics()
            is NativeSettingsAction.PlayerPreferences -> updatePreferences(action.value)
        }
    }

    private fun updatePreferences(value: NativePlayerPreferences) {
        if (value == preferences) return
        val previous = preferences
        preferences = value
        preferenceStore.save(value)
        if (value.correctLyricTitles != previous.correctLyricTitles) runtime.setCorrectLyricTitles(value.correctLyricTitles)
        if (value.appLanguage != previous.appLanguage) recreate() else render(runtime.uiState.value)
    }

    private fun render(ui: ReceiverUiState) {
        // Project the backend's effective default receiver name without writing it to disk.
        val playerState = if (ui.state.settings.receiverName != null) ui.state else
            ui.state.copy(settings = ui.state.settings.copy(receiverName = ui.receiverName))
        player.render(playerState, ui.volumePercent, preferences,
            receiverRunning = ui.receiverRunning, playerError = ui.playerError)
        val state = ui.state
        settingsView?.render(ui, preferences)
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
        setLyricBackCallback(false)
        settingsDialog?.dismiss()
        super.onDestroy()
    }

    private fun setLyricBackCallback(available: Boolean) {
        if (Build.VERSION.SDK_INT < 33) return
        if (available && lyricBackCallback == null) {
            val callback = OnBackInvokedCallback { player.navigateBackFromLyrics() }
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback)
            lyricBackCallback = callback
        } else if (!available) {
            lyricBackCallback?.let(onBackInvokedDispatcher::unregisterOnBackInvokedCallback)
            lyricBackCallback = null
        }
    }

    @Deprecated("Back dispatcher handles API 33 and higher")
    override fun onBackPressed() {
        if (!player.navigateBackFromLyrics()) super.onBackPressed()
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
    }

    companion object {
        private const val RECEIVER_PERMISSION_REQUEST = 1201
        private const val STATE_SETTINGS_OPEN = "settings_open"
        private const val STATE_SETTINGS_PAGE = "settings_page"
        private const val STATE_RECEIVER_RUNNING = "receiver_running"
        private const val STATE_COMPACT_LYRICS = "compact_lyrics"

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
        if (Build.VERSION.SDK_INT >= 29) {
            window.isNavigationBarContrastEnforced = false
            if (!isTelevision) {
                @Suppress("DEPRECATION")
                window.isStatusBarContrastEnforced = false
            }
        }
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
