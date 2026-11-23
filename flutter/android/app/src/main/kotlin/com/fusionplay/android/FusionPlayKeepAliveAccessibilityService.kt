package com.fusionplay.android

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import androidx.core.content.ContextCompat
import com.fusionplay.android.media.FusionPlayMediaChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class FusionPlayKeepAliveAccessibilityService : AccessibilityService() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val runtime get() = (application as FusionPlayApplication).runtime
    private var settingsJob: Job? = null
    private var previousPlaying = false
    private var lastWakeElapsedRealtime = 0L
    private val mediaStateListener: () -> Unit = {
        val playing = FusionPlayMediaChannel.currentSnapshot().playing
        mainHandler.post { handlePlaybackState(playing) }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        settingsJob?.cancel()
        settingsJob = serviceScope.launch {
            val settings = runtime.uiState.first { it.state.initialized }.state.settings
            if (settings.startupEnabled || settings.autoWakeEnabled) {
                previousPlaying = FusionPlayMediaChannel.currentSnapshot().playing
                FusionPlayMediaChannel.addStateListener(mediaStateListener)
                if (settings.startupEnabled) startReceiverAtBoot()
                runtime.uiState.first {
                    !it.state.settings.startupEnabled && !it.state.settings.autoWakeEnabled
                }
            }
            disableSelf()
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        FusionPlayMediaChannel.removeStateListener(mediaStateListener)
        mainHandler.removeCallbacksAndMessages(null)
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun handlePlaybackState(playing: Boolean) {
        val playbackStarted = playing && !previousPlaying
        previousPlaying = playing
        if (!playbackStarted || MainActivity.isAppInForeground()) return
        if (!runtime.uiState.value.state.settings.autoWakeEnabled) return
        if (!FusionPlayMediaChannel.currentSnapshot().playing) return
        wakeApplication(debounce = true)
    }

    private fun startReceiverAtBoot() {
        if (AccessibilityKeepAliveController.wasAppLaunchedThisBoot(this)) return
        if (startReceiverService()) {
            AccessibilityKeepAliveController.markAppLaunchedThisBoot(this)
        }
    }

    private fun startReceiverService(): Boolean =
        runCatching {
            ContextCompat.startForegroundService(
                this,
                Intent(this, ReceiverForegroundService::class.java),
            )
        }.isSuccess

    private fun wakeApplication(debounce: Boolean) {
        if (MainActivity.isAppInForeground()) return
        val now = SystemClock.elapsedRealtime()
        if (
            debounce &&
            lastWakeElapsedRealtime != 0L &&
            now - lastWakeElapsedRealtime < AUTO_WAKE_DEBOUNCE_MS
        ) {
            return
        }
        lastWakeElapsedRealtime = now
        runCatching {
            startActivity(
                Intent(this, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                ),
            )
        }
    }

    companion object {
        private const val AUTO_WAKE_DEBOUNCE_MS = 2_000L
    }
}
