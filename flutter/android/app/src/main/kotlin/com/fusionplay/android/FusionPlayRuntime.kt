package com.fusionplay.android

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.os.Build
import com.airplayreceiver.desktop.backend.AppEvent
import com.airplayreceiver.desktop.backend.AppState
import com.airplayreceiver.desktop.backend.AppViewModel
import com.airplayreceiver.desktop.backend.CorePlaybackStateSideEffect
import com.airplayreceiver.desktop.backend.FusionPlayDiagnosticLogger
import com.airplayreceiver.desktop.backend.MediaSource
import com.airplayreceiver.desktop.backend.MediaSourceArbiter
import com.airplayreceiver.desktop.backend.MiPlayDeviceIdentity
import com.airplayreceiver.desktop.backend.NetworkMediaEventGate
import com.airplayreceiver.desktop.backend.PlaybackCommand
import com.airplayreceiver.desktop.backend.PlaybackSnapshot
import com.airplayreceiver.desktop.backend.ReceiverProtocol
import com.airplayreceiver.desktop.backend.RemoteControlState
import com.airplayreceiver.desktop.backend.displayMetadata
import com.airplayreceiver.desktop.backend.SourceTakeoverPolicy
import com.airplayreceiver.desktop.backend.XiaomiTakeoverGate
import com.airplayreceiver.desktop.bridge.WindowsBridgeDiagnostic
import com.airplayreceiver.desktop.bridge.WindowsBridgeClient
import com.airplayreceiver.desktop.bridge.WindowsBridgeError
import com.airplayreceiver.desktop.bridge.WindowsBridgeProcessExit
import com.airplayreceiver.desktop.bridge.WindowsBridgeSmtcCommand
import com.airplayreceiver.desktop.bridge.WindowsBridgeXiaomiEvent
import com.airplayreceiver.desktop.bridge.WindowsBridgeXiaomiExit
import com.airplayreceiver.desktop.bridge.WindowsBridgeXiaomiLog
import com.airplayreceiver.desktop.bridge.XiaomiPlaybackMutation
import com.airplayreceiver.desktop.bridge.XiaomiPlaybackReducer
import com.airplayreceiver.desktop.bridge.XiaomiReduction
import com.airplayreceiver.desktop.bridge.toVolumePercentOrNull
import com.airplayreceiver.desktop.bridge.toXiaomiMiPlayUserMessage
import com.fusionplay.android.cast.NativeCastState
import com.fusionplay.android.media.FusionPlayMediaChannel
import com.fusionplay.android.media.FusionPlayMediaCommand
import java.io.Closeable
import java.net.URI
import java.nio.file.Paths
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

data class ReceiverUiState(
    val state: AppState,
    val nativeCast: NativeCastState,
    val miPlaySyncOffsetMs: Int,
    val volumePercent: Int,
    val receiverName: String,
    val receiverRunning: Boolean,
    val autoReceiveOnLaunch: Boolean,
    val diagnostics: NativeReceiverDiagnostics,
    val playerError: String?,
)

data class NativeReceiverDiagnostics(
    val lanInterface: String? = null,
    val lanAddress: String? = null,
    val audioRoute: String? = null,
    val audioRouteObserved: Boolean = false,
    val bufferedFrames: Long? = null,
    val outputLatencyMs: Double? = null,
    val endpointLatencyCalibrated: Boolean? = null,
    val scheduleErrorMs: Double? = null,
    val underrunCallbacks: Long? = null,
    val synchronizationMode: String? = null,
    val outputRecoveries: Int = 0,
    val coverAvailable: Boolean = false,
    val receiverError: String? = null,
)

/** Process-scoped owner of protocol lifecycle, routing, and Android media state. */
class FusionPlayRuntime(
    private val context: Context,
    private val diagnosticLogger: FusionPlayDiagnosticLogger,
) : Closeable {
    private val job = SupervisorJob()
    private val scope = CoroutineScope(Dispatchers.Main.immediate + job)
    private val viewModel = AppViewModel(
        diagnosticLogger = diagnosticLogger,
        parentScope = scope,
    )
    private val bridge = WindowsBridgeClient(parentScope = scope, stopXiaomiOnClose = false)
    private val xiaomiReducer = XiaomiPlaybackReducer()
    private val xiaomiTakeoverGate = XiaomiTakeoverGate()
    private val mediaSourceArbiter = MediaSourceArbiter()
    private val coreLifecycleMutex = Mutex()
    private val miPlayLifecycleMutex = Mutex()
    private var receiverServiceActive = false
    internal val receiving: Boolean get() = receiverServiceActive
    private var diagnostics = NativeReceiverDiagnostics()
    private var miPlayAudioDeviceId: Int? = null
    private var diagnosticsRefreshJob: Job? = null
    private var coreReceiverError: String? = null
    private var miPlayReceiverError: String? = null
    private var miPlayAudioError: String? = null
    private var miPlaySourceSwitchError: String? = null
    private var networkPlaybackError: String? = null
    private var bridgeInitializationError: String? = null
    private val networkPlayer = NativeNetworkPlayer(context) { message ->
        val failure = "网络媒体播放失败：$message"
        networkPlaybackError = failure
        viewModel.reportExternalLog(failure, isError = true)
    }
    private val closed = AtomicBoolean(false)

    private var lastDesiredCoreConfiguration: CoreReceiverConfiguration? = null
    private var lastDesiredMiPlayConfiguration: MiPlayReceiverConfiguration? = null
    private var appliedMiPlayConfiguration: MiPlayReceiverConfiguration? = null
    private var lastPublishedArtwork: String? = null
    private var lastPublishedMetadata: MediaMetadataProjection? = null
    private var lastPublishedPlaying: Boolean? = null
    private var lastPublishedCapabilities: MediaCapabilitiesProjection? = null
    private var mediaSessionHasMedia = false
    private var artworkJob: Job? = null
    private var xiaomiRestartGeneration = 0L
    private var pendingManualXiaomiStop = false
    private var lastMiPlayProgressLogNanos = 0L
    private val nativeCast = com.fusionplay.android.cast.NativeCastManager(context, scope)
    private val audioCalibration = context.getSharedPreferences("audio_sync", Context.MODE_PRIVATE)
    private var miPlaySyncOffsetMs = audioCalibration.getInt(
        SYNC_OFFSET_KEY,
        -audioCalibration.getInt("advance_ms", 0).coerceIn(0, SYNC_OFFSET_MAX),
    ).coerceIn(SYNC_OFFSET_MIN, SYNC_OFFSET_MAX)
    private val receiverPreferences = context.getSharedPreferences("receiver_lifecycle", Context.MODE_PRIVATE)
    val autoReceiveOnLaunch: Boolean get() = receiverPreferences.getBoolean("auto_receive_on_launch", true)
    private var correctLyricTitles = NativePlayerPreferenceStore(context).load().correctLyricTitles
    private val mutableUiState = MutableStateFlow(projectUiState(viewModel.state.value))
    val uiState = mutableUiState.asStateFlow()

    init {
        com.airplayreceiver.desktop.nativebridge.FusionPlayNative
            .nativeSetMiPlaySyncOffset(miPlaySyncOffsetMs)
        scope.launch { nativeCast.state.collect { publishState(viewModel.state.value) } }
        scope.launch {
            viewModel.awaitInitialized()
            runCatching { bridge.initialize() }.onFailure {
                bridgeInitializationError = reportError("媒体桥初始化失败", it)
            }
            observeDesiredReceivers(viewModel.state.value)
        }
        scope.launch {
            viewModel.state.collect { state ->
                publishState(state)
                publishMediaSession(state)
                observeDesiredReceivers(state)
            }
        }
        scope.launch { bridge.events.collect(::handleBridgeEvent) }
        scope.launch { viewModel.events.collect(::handleCoreEvent) }
        scope.launch {
            FusionPlayMediaChannel.commands.collect { event ->
                when (event.command) {
                    FusionPlayMediaCommand.PLAY -> dispatchPlayback(PlaybackCommand.PLAY)
                    FusionPlayMediaCommand.PAUSE -> dispatchPlayback(PlaybackCommand.PAUSE)
                    FusionPlayMediaCommand.PREVIOUS -> dispatchPlayback(PlaybackCommand.PREVIOUS_TRACK)
                    FusionPlayMediaCommand.NEXT -> dispatchPlayback(PlaybackCommand.NEXT_TRACK)
                    FusionPlayMediaCommand.SEEK -> event.positionMs?.let { dispatchSeek(it) }
                }
            }
        }
        scope.launch {
            var lastTickNanos = System.nanoTime()
            while (isActive) {
                delay(PROGRESS_TICK_MS)
                val nowNanos = System.nanoTime()
                val elapsedMs = ((nowNanos - lastTickNanos) / 1_000_000L).coerceAtLeast(0L)
                lastTickNanos = nowNanos

                val networkSource = networkPlayer.source
                if (networkSource != null) {
                    val networkPlayback = viewModel.playbackForSource(networkSource)
                    if (networkPlayback.mediaUrl != null) {
                        val position = networkPlayer.positionMs
                        val playing = networkPlayer.playing
                        if (playing) {
                            viewModel.clearErrorIfMatches(networkPlaybackError)
                            networkPlaybackError = null
                        }
                        val duration = networkPlayer.durationMs.takeIf { it > 0 }
                            ?: networkPlayback.durationMs
                            ?: 0L
                        viewModel.updateNetworkMediaState(
                            positionMs = position,
                            durationMs = duration,
                            playing = playing,
                            source = networkSource,
                            sourceEpoch = networkPlayer.sourceEpoch,
                        )
                        runCatching {
                            viewModel.sendVideoState(
                                positionMs = position,
                                durationMs = duration,
                                rate = if (playing) networkPlayer.rate else 0.0,
                                ready = networkPlayer.ready,
                                source = when (networkSource) {
                                    MediaSource.AIRPLAY -> "AirPlay"
                                    MediaSource.DLNA -> "DLNA"
                                    MediaSource.XIAOMI_MIPLAY -> null
                                },
                            )
                        }
                    }
                }

                xiaomiReducer.expireClosedMedia()?.let { applyXiaomiReduction(it) }
                val playback = viewModel.state.value.playback
                if (
                    playback.protocol.equals(XIAOMI_PROTOCOL, ignoreCase = true) &&
                    playback.isPlaying &&
                    (playback.durationMs ?: 0L) > 0L
                ) {
                    viewModel.advanceXiaomiProgress(elapsedMs)
                }
            }
        }
    }

    private fun runUiAction(action: suspend () -> Unit) {
        scope.launch {
            try {
                action()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                reportError("操作失败", error)
            } finally {
                publishState(viewModel.state.value)
            }
        }
    }

    fun setReceiverName(name: String) = runUiAction { viewModel.setReceiverName(name) }

    fun setStartupEnabled(enabled: Boolean) = runUiAction {
        viewModel.setStartupEnabled(enabled)
        if (enabled && viewModel.state.value.settings.startupEnabled) {
            AccessibilityKeepAliveController.requestAuthorization(context)
        }
    }

    fun setAutoWakeEnabled(enabled: Boolean) = runUiAction {
        viewModel.setAutoWakeEnabled(enabled)
        if (enabled && viewModel.state.value.settings.autoWakeEnabled) {
            AccessibilityKeepAliveController.requestAuthorization(context)
        }
    }

    fun setKeepScreenOnWhilePlaying(enabled: Boolean) = runUiAction {
        viewModel.setKeepScreenOnWhilePlaying(enabled)
    }

    fun setAdvancedEffectsEnabled(enabled: Boolean) = runUiAction {
        viewModel.setAdvancedEffectsEnabled(enabled)
    }

    fun setNativeCastPaused(paused: Boolean) {
        scope.launch { nativeCast.setPaused(paused) }
    }

    fun setMiPlaySyncOffset(millis: Int) = runUiAction {
        require(millis in SYNC_OFFSET_MIN..SYNC_OFFSET_MAX)
        com.airplayreceiver.desktop.nativebridge.FusionPlayNative.nativeSetMiPlaySyncOffset(millis)
        audioCalibration.edit().putInt(SYNC_OFFSET_KEY, millis).apply()
        miPlaySyncOffsetMs = millis
    }

    fun setAutoReceiveOnLaunch(enabled: Boolean) = runUiAction {
        receiverPreferences.edit().putBoolean("auto_receive_on_launch", enabled).apply()
    }

    fun stopReceiving() {
        setReceiverServiceActive(false)
        context.stopService(Intent(context, ReceiverForegroundService::class.java))
    }

    internal fun setReceiverServiceActive(active: Boolean) {
        if (receiverServiceActive == active) return
        receiverServiceActive = active
        if (!active) {
            networkPlayer.stop()
            viewModel.clearErrorIfMatches(networkPlaybackError)
            networkPlaybackError = null
            viewModel.clearErrorIfMatches(miPlayAudioError)
            miPlayAudioError = null
            resetMiPlayDiagnostics()
        }
        val state = viewModel.state.value
        if (!active) publishMediaSession(state)
        observeDesiredReceivers(state)
        publishState(state)
        if (active) refreshReceiverDiagnostics()
    }

    fun setProtocolEnabled(protocol: ReceiverProtocol, enabled: Boolean) = runUiAction {
        viewModel.setProtocolEnabled(protocol, enabled)
    }

    fun setMiPlayDeviceIdentity(identity: MiPlayDeviceIdentity) = runUiAction {
        viewModel.setMiPlayDeviceIdentity(identity)
    }

    fun playback(command: PlaybackCommand) = runUiAction { dispatchPlayback(command) }
    fun seek(positionMs: Long) = runUiAction { dispatchSeek(positionMs) }
    fun setVolume(percent: Int) = runUiAction { dispatchVolume(percent, applyLocal = true) }

    fun exportLogs() = runUiAction {
        viewModel.reportExternalLog("用户请求导出诊断日志。")
        val intent = withContext(Dispatchers.IO) {
            FusionPlayLogExporter.createShareIntent(context, diagnosticLogger)
        }
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        viewModel.reportExternalLog("已打开系统日志导出菜单。")
    }

    fun clearError() = viewModel.clearError()

    private fun routesControlsToXiaomi(state: AppState): Boolean {
        if (state.activeMediaSource == MediaSource.XIAOMI_MIPLAY) return true
        if (state.activeMediaSource != null) return false
        return state.playback.streamActive &&
            state.playback.protocol.equals(XIAOMI_PROTOCOL, ignoreCase = true)
    }

    private suspend fun sendXiaomiControl(action: String, positionMs: Long? = null): Boolean =
        runCatching { bridge.controlXiaomi(action, positionMs) }
            .fold(
                onSuccess = { response ->
                    val handled = response.accepted || response.dispatched
                    logMiPlay(
                        event = "remote_control",
                        outcome = if (handled) "success" else "failure",
                        details = mapOf(
                            "action" to response.action,
                            "position_ms" to positionMs,
                            "dispatched" to response.dispatched,
                            "confirmed" to response.confirmed,
                            "connection_preserved" to response.connectionPreserved,
                            "method" to response.method,
                            "message" to response.message,
                        ),
                    )
                    if (!response.accepted && !response.dispatched) {
                        viewModel.reportExternalLog(
                            "小米妙播${response.action}控制未执行：${response.message}",
                        )
                    }
                    handled
                },
                onFailure = { error ->
                    logMiPlayFailure("remote_control", error, mapOf("action" to action))
                    viewModel.reportExternalLog(
                        error.toXiaomiMiPlayUserMessage("小米妙播控制失败"),
                        isError = true,
                    )
                    false
                },
            )

    private suspend fun pauseSourceForTakeover(
        source: MediaSource,
        remoteAlreadySuspended: Boolean = false,
    ) {
        val playback = viewModel.playbackForSource(source)
        if (networkPlayer.source == source) {
            viewModel.updateNetworkMediaState(
                positionMs = networkPlayer.positionMs,
                durationMs = networkPlayer.durationMs,
                playing = false,
                source = source,
                sourceEpoch = networkPlayer.sourceEpoch,
            )
            networkPlayer.pause()
        }
        if (remoteAlreadySuspended && source != MediaSource.XIAOMI_MIPLAY) {
            viewModel.markSourcePaused(source)
            return
        }
        when (source) {
            MediaSource.XIAOMI_MIPLAY -> {
                xiaomiTakeoverGate.arm(playback.isPlaying)
                runCatching { bridge.suspendXiaomiOutput() }
                    .onFailure { reportError("小米妙播本机输出暂停失败", it) }
                runCatching { bridge.pauseXiaomi() }
                    .onFailure { reportError("小米妙播暂停失败", it) }
            }
            MediaSource.AIRPLAY -> if (playback.mediaUrl == null) {
                runCatching { viewModel.sendPlayback(PlaybackCommand.PAUSE) }
            }
            MediaSource.DLNA -> runCatching { viewModel.sendPlayback(PlaybackCommand.PAUSE) }
        }
        if (
            source != MediaSource.XIAOMI_MIPLAY ||
            playback.streamActive ||
            playback.isPlaying
        ) {
            viewModel.markSourcePaused(source)
        }
    }

    private suspend fun activatePlaybackSource(
        source: MediaSource,
        previousAlreadySuspendedByCore: Boolean = false,
        projectSource: Boolean = true,
    ) {
        if (source != MediaSource.XIAOMI_MIPLAY) {
            // Do not rely solely on the projected arbiter source here. Xiaomi
            // state and core events are collected independently, so the local
            // projection can briefly be empty while its RTSP audio is still
            // live. Receiver-side suspension is idempotent and survives a
            // concurrent Xiaomi media-session replacement.
            pauseSourceForTakeover(MediaSource.XIAOMI_MIPLAY)
        }
        mediaSourceArbiter.activate(source) { transition ->
            transition.previous
                ?.takeUnless { it == MediaSource.XIAOMI_MIPLAY }
                ?.let {
                pauseSourceForTakeover(it, previousAlreadySuspendedByCore)
            }
        }
        if (projectSource) viewModel.activateSourceProjection(source)
    }

    private fun resumeCachedNetworkSource(source: MediaSource, rate: Double) {
        val playback = viewModel.playbackForSource(source)
        val url = playback.mediaUrl ?: return
        if (networkPlayer.source == source && networkPlayer.url == url) {
            networkPlayer.setRate(rate)
        } else {
            networkPlayer.open(
                source = source,
                url = url,
                epoch = playback.sourceEpoch,
                positionMs = playback.positionMs,
                autoPlay = rate > 0.0,
            )
        }
    }

    private suspend fun dispatchPlayback(command: PlaybackCommand) {
        val state = viewModel.state.value
        val playback = state.playback
        when {
            routesControlsToXiaomi(state) -> when (command) {
                PlaybackCommand.PLAY -> {
                    xiaomiTakeoverGate.explicitResume()
                    if (sendXiaomiControl("play")) {
                        viewModel.activateXiaomiPlayback(
                            sourceName = null,
                            rawState = 2,
                            claimPlayback = true,
                        )
                        mediaSourceArbiter.activate(MediaSource.XIAOMI_MIPLAY) { }
                    }
                }
                PlaybackCommand.PAUSE -> if (sendXiaomiControl("pause")) {
                    xiaomiTakeoverGate.confirmPaused()
                    viewModel.pauseConnectedXiaomiAndExposeIfForegroundIdle()
                    mediaSourceArbiter.deactivate(MediaSource.XIAOMI_MIPLAY)
                }
                PlaybackCommand.PLAY_PAUSE -> dispatchPlayback(
                    if (playback.isPlaying) PlaybackCommand.PAUSE else PlaybackCommand.PLAY,
                )
                PlaybackCommand.PREVIOUS_TRACK -> sendXiaomiControl("previous")
                PlaybackCommand.NEXT_TRACK -> sendXiaomiControl("next")
            }
            playback.mediaUrl != null &&
                playback.protocol.equals("AirPlay", ignoreCase = true) -> when (command) {
                    PlaybackCommand.PLAY -> resumeCachedNetworkSource(MediaSource.AIRPLAY, 1.0)
                    PlaybackCommand.PAUSE -> networkPlayer.pause()
                    PlaybackCommand.PLAY_PAUSE -> if (networkPlayer.playing) {
                        networkPlayer.pause()
                    } else {
                        resumeCachedNetworkSource(MediaSource.AIRPLAY, 1.0)
                    }
                    else -> viewModel.sendPlayback(command)
                }
            else -> viewModel.sendPlayback(command)
        }
    }

    private suspend fun dispatchSeek(positionMs: Long) {
        val state = viewModel.state.value
        when {
            routesControlsToXiaomi(state) -> if (sendXiaomiControl("seek", positionMs)) {
                xiaomiReducer.beginSeek(positionMs)
                viewModel.updateXiaomiMediaInfo(
                    trackId = null,
                    title = null,
                    artist = null,
                    album = null,
                    artworkUrl = null,
                    durationMs = null,
                    positionMs = positionMs,
                )
            }
            state.playback.mediaUrl != null &&
                state.playback.protocol.equals("AirPlay", ignoreCase = true) ->
                networkPlayer.seek(positionMs)
            else -> viewModel.seek(positionMs)
        }
    }

    /**
     * Synchronizes a hardware-key volume change back to the current sender.
     * Sender-originated volume frames only call setSystemMediaVolumePercent,
     * so they never enter this path and cannot form a feedback loop.
     */
    fun syncVolumeFromReceiver() {
        val percent = FusionPlayMediaChannel.currentSystemMediaVolumePercent()
        runUiAction { dispatchVolume(percent, applyLocal = false) }
    }

    private suspend fun dispatchVolume(percent: Int, applyLocal: Boolean) {
        val normalized = percent.coerceIn(0, 100)
        if (applyLocal && !FusionPlayMediaChannel.setSystemMediaVolumePercent(normalized)) {
            viewModel.reportExternalLog("无法将被控端媒体音量调整到 $normalized%。", isError = true)
        }
        val state = viewModel.state.value
        when {
            routesControlsToXiaomi(state) -> {
                if (!bridge.setXiaomiVolume(normalized)) {
                    viewModel.reportExternalLog("小米妙播发送端音量同步失败。", isError = true)
                }
            }
            state.activeMediaSource == MediaSource.AIRPLAY ||
                (state.activeMediaSource == null &&
                    state.playback.streamActive &&
                    state.playback.protocol.equals("AirPlay", ignoreCase = true)) ->
                runCatching { viewModel.sendVolume(normalized) }
                    .onFailure { reportError("AirPlay 发送端音量同步失败", it) }
            state.activeMediaSource == MediaSource.DLNA ||
                (state.activeMediaSource == null &&
                    state.playback.streamActive &&
                    state.playback.protocol.equals("DLNA", ignoreCase = true)) ->
                runCatching { viewModel.sendVolume(normalized) }
                    .onFailure { reportError("DLNA 渲染音量同步失败", it) }
        }
    }

    private fun eventTargetsSourcePlayback(protocol: String, source: String?, epoch: Long?): Boolean {
        val mediaSource = when {
            protocol.equals("AirPlay", ignoreCase = true) -> MediaSource.AIRPLAY
            protocol.equals("DLNA", ignoreCase = true) -> MediaSource.DLNA
            else -> return false
        }
        val playback = viewModel.playbackForSource(mediaSource)
        if (!playback.protocol.equals(protocol, ignoreCase = true)) return false
        val expectedSource = if (mediaSource == MediaSource.AIRPLAY) CORE_SOURCE_AIRPLAY else CORE_SOURCE_DLNA
        if (source != null && !source.equals(expectedSource, ignoreCase = true)) return false
        return epoch == null || playback.sourceEpoch == null || epoch == playback.sourceEpoch
    }

    private fun observeDesiredReceivers(state: AppState) {
        if (!state.initialized) return
        if (!receiverServiceActive && lastDesiredCoreConfiguration == null) return
        val desiredCore = CoreReceiverConfiguration(
            name = viewModel.receiverName,
            airPlayEnabled = receiverServiceActive && state.settings.airPlayEnabled,
            dlnaEnabled = receiverServiceActive && state.settings.dlnaEnabled,
            running = receiverServiceActive,
        )
        if (desiredCore != lastDesiredCoreConfiguration) {
            lastDesiredCoreConfiguration = desiredCore
            logCoreConfiguration("airplay", desiredCore.airPlayEnabled, "requested")
            logCoreConfiguration("dlna", desiredCore.dlnaEnabled, "requested")
            scope.launch {
                coreLifecycleMutex.withLock {
                    if (desiredCore != lastDesiredCoreConfiguration) return@withLock
                    runCatching {
                        if (desiredCore.running) viewModel.reconcileCoreProtocols() else viewModel.stopReceiver()
                    }.fold(
                        onSuccess = {
                            viewModel.clearErrorIfMatches(coreReceiverError)
                            coreReceiverError = null
                            logCoreConfiguration(
                                "airplay",
                                desiredCore.airPlayEnabled,
                                "applied",
                            )
                            logCoreConfiguration(
                                "dlna",
                                desiredCore.dlnaEnabled,
                                "applied",
                            )
                        },
                        onFailure = { error ->
                            logProtocolFailure("airplay", "receiver_configuration", error)
                            logProtocolFailure("dlna", "receiver_configuration", error)
                            coreReceiverError = reportError(
                                if (desiredCore.running) "AirPlay/DLNA 启动失败" else "AirPlay/DLNA 停止失败", error,
                            )
                        },
                    )
                    publishState(viewModel.state.value)
                }
            }
        }

        val desiredMiPlay = MiPlayReceiverConfiguration(
            name = viewModel.receiverName,
            enabled = receiverServiceActive && state.settings.miPlayEnabled,
            identity = state.settings.miPlayDeviceIdentity,
        )
        if (desiredMiPlay != lastDesiredMiPlayConfiguration) {
            lastDesiredMiPlayConfiguration = desiredMiPlay
            scope.launch {
                miPlayLifecycleMutex.withLock {
                    if (desiredMiPlay != lastDesiredMiPlayConfiguration) return@withLock
                    val previous = appliedMiPlayConfiguration
                    val restartGeneration = ++xiaomiRestartGeneration
                    if (previous?.enabled == true) {
                        pendingManualXiaomiStop = true
                        logMiPlay("receiver_stop", "requested")
                        runCatching { bridge.stopXiaomi() }.fold(
                            onSuccess = {
                                clearRecoveredMiPlayError()
                                logMiPlay("receiver_stop", "success")
                            },
                            onFailure = { error ->
                                logMiPlayFailure("receiver_stop", error)
                                miPlayReceiverError = reportError("小米妙播停止失败", error)
                            },
                        )
                    }
                    if (desiredMiPlay.enabled) {
                        pendingManualXiaomiStop = false
                        val started = startMiPlay(desiredMiPlay, reportFailure = true)
                        appliedMiPlayConfiguration = desiredMiPlay.copy(enabled = started)
                        if (!started) {
                            scheduleMiPlayRecovery(desiredMiPlay, restartGeneration)
                        }
                    } else {
                        if (previous?.enabled != true) clearRecoveredMiPlayError()
                        logMiPlay(
                            event = "receiver_configuration",
                            outcome = "disabled",
                            details = mapOf(
                                "identity" to desiredMiPlay.identity.persistedValue,
                            ),
                        )
                        xiaomiReducer.reset()
                        xiaomiTakeoverGate.reset()
                        miPlayAudioError = null
                        resetMiPlayDiagnostics()
                        mediaSourceArbiter.deactivate(MediaSource.XIAOMI_MIPLAY) {
                            viewModel.deactivateXiaomiPlayback()
                        }
                        appliedMiPlayConfiguration = desiredMiPlay
                    }
                    publishState(viewModel.state.value)
                }
            }
        }
    }

    private suspend fun startMiPlay(
        configuration: MiPlayReceiverConfiguration,
        reportFailure: Boolean,
    ): Boolean {
        val details = mapOf(
            "identity" to configuration.identity.persistedValue,
            "device_type" to configuration.identity.protocolValue,
            "receiver_name_present" to configuration.name.isNotBlank(),
        )
        logMiPlay("receiver_start", "requested", details)
        return runCatching {
            bridge.startXiaomi(
                receiverName = configuration.name,
                networkAdapterId = null,
                outputDeviceId = null,
                deviceType = configuration.identity.protocolValue,
            )
        }.fold(
            onSuccess = { response ->
                viewModel.clearErrorIfMatches(bridgeInitializationError)
                bridgeInitializationError = null
                clearRecoveredMiPlayError()
                val result = response.result as? JsonObject
                diagnostics = diagnostics.copy(
                    lanInterface = result?.text("interface") ?: diagnostics.lanInterface,
                    lanAddress = result?.text("ipv4") ?: diagnostics.lanAddress,
                )
                logMiPlay("receiver_start", "success", details)
                true
            },
            onFailure = { error ->
                logMiPlayFailure("receiver_start", error, details)
                if (reportFailure) miPlayReceiverError = reportError("小米妙播启动失败", error)
                false
            },
        )
    }

    private fun scheduleMiPlayRecovery(
        configuration: MiPlayReceiverConfiguration,
        restartGeneration: Long,
    ) {
        scope.launch {
            for (retryDelay in XIAOMI_RESTART_DELAYS_MS) {
                delay(retryDelay)
                if (
                    bridge.shuttingDown ||
                    restartGeneration != xiaomiRestartGeneration ||
                    configuration != lastDesiredMiPlayConfiguration
                ) {
                    return@launch
                }
                var started = false
                miPlayLifecycleMutex.withLock {
                    if (
                        restartGeneration == xiaomiRestartGeneration &&
                        configuration == lastDesiredMiPlayConfiguration &&
                        appliedMiPlayConfiguration?.enabled != true
                    ) {
                        started = startMiPlay(configuration, reportFailure = false)
                        if (started) appliedMiPlayConfiguration = configuration
                    }
                }
                if (started) {
                    logMiPlay("receiver_recovery", "success")
                    viewModel.reportExternalLog("小米妙播接收器已自动恢复。")
                    publishState(viewModel.state.value)
                    return@launch
                }
            }
            if (
                restartGeneration == xiaomiRestartGeneration &&
                configuration == lastDesiredMiPlayConfiguration
            ) {
                logMiPlay("receiver_recovery", "failure")
                val failure = miPlayReceiverError ?: "小米妙播接收器自动恢复失败。"
                miPlayReceiverError = failure
                viewModel.reportExternalLog(failure, isError = true)
                publishState(viewModel.state.value)
            }
        }
    }

    private suspend fun handleBridgeEvent(event: Any) {
        when (event) {
            is WindowsBridgeSmtcCommand -> when (event.command.lowercase()) {
                "play" -> dispatchPlayback(PlaybackCommand.PLAY)
                "pause" -> dispatchPlayback(PlaybackCommand.PAUSE)
                "previous" -> dispatchPlayback(PlaybackCommand.PREVIOUS_TRACK)
                "next" -> dispatchPlayback(PlaybackCommand.NEXT_TRACK)
                "seek" -> event.positionMs?.let { dispatchSeek(it) }
            }
            is WindowsBridgeXiaomiLog -> {
                logMiPlay(
                    event = "bridge_log",
                    outcome = if (event.isError) "failure" else "observed",
                    details = mapOf("message" to event.message),
                )
                viewModel.reportExternalLog(event.message, event.isError, persist = false)
            }
            is WindowsBridgeError -> {
                logMiPlay(
                    event = "bridge_error",
                    outcome = "failure",
                    details = mapOf(
                        "code" to event.code,
                        "hresult" to event.hresult,
                        "message" to event.message,
                    ),
                )
                viewModel.reportExternalLog("媒体桥错误：${event.message}", isError = true)
            }
            is WindowsBridgeProcessExit -> {
                logMiPlay(
                    event = "bridge_process_exit",
                    outcome = if (event.expected || event.exitCode == 0) {
                        "success"
                    } else {
                        "failure"
                    },
                    details = mapOf(
                        "exit_code" to event.exitCode,
                        "expected" to event.expected,
                    ),
                )
                if (!event.expected) {
                    xiaomiReducer.reset(resetEventSequence = true)
                    xiaomiTakeoverGate.reset()
                    viewModel.reportExternalLog(
                        "媒体桥意外退出（代码 ${event.exitCode}）。",
                        isError = true,
                    )
                }
            }
            is WindowsBridgeDiagnostic -> {
                logMiPlay(
                    event = "bridge_diagnostic",
                    outcome = "observed",
                    details = mapOf(
                        "source" to event.source,
                        "message" to event.message,
                    ),
                )
                viewModel.reportExternalLog("${event.source}：${event.message}")
            }
            is WindowsBridgeXiaomiExit -> handleXiaomiExit(event)
            is WindowsBridgeXiaomiEvent -> handleXiaomiEvent(event)
        }
    }

    private suspend fun handleXiaomiExit(event: WindowsBridgeXiaomiExit) {
        val expectedStop = pendingManualXiaomiStop
        pendingManualXiaomiStop = false
        xiaomiReducer.reset()
        xiaomiTakeoverGate.reset()
        mediaSourceArbiter.deactivate(MediaSource.XIAOMI_MIPLAY) {
            viewModel.deactivateXiaomiPlayback()
        }
        miPlayAudioError = null
        resetMiPlayDiagnostics()
        logMiPlay(
            event = "receiver_exit",
            outcome = if (expectedStop || event.exitCode == null || event.exitCode == 0) {
                "success"
            } else {
                "failure"
            },
            details = mapOf(
                "exit_code" to event.exitCode,
                "expected" to expectedStop,
            ),
        )
        if (expectedStop || !receiverServiceActive) return
        val message = "小米妙播进程已退出（代码 ${event.exitCode ?: -1}）。"
        miPlayReceiverError = message.takeIf { event.exitCode != null && event.exitCode != 0 }
        viewModel.reportExternalLog(message, isError = miPlayReceiverError != null)
        if (event.exitCode == 2 || !viewModel.state.value.settings.miPlayEnabled) return
        val state = viewModel.state.value
        val configuration = MiPlayReceiverConfiguration(
            name = viewModel.receiverName,
            enabled = true,
            identity = state.settings.miPlayDeviceIdentity,
        )
        val restartGeneration = ++xiaomiRestartGeneration
        appliedMiPlayConfiguration = configuration.copy(enabled = false)
        scheduleMiPlayRecovery(configuration, restartGeneration)
    }

    private suspend fun handleXiaomiEvent(event: WindowsBridgeXiaomiEvent) {
        if (!receiverServiceActive) return
        updateMiPlayDiagnostics(event)
        event.toVolumePercentOrNull()?.let { percent ->
            if (!FusionPlayMediaChannel.setSystemMediaVolumePercent(percent)) {
                viewModel.reportExternalLog("无法将被控端媒体音量同步到 $percent%。", isError = true)
            }
            publishState(viewModel.state.value)
        }
        val xiaomiPlayback = viewModel.playbackForSource(MediaSource.XIAOMI_MIPLAY)
        val reduction = xiaomiReducer.reduce(event, displayedPositionMs = xiaomiPlayback.positionMs)
        if (shouldPersistMiPlayEvent(event.eventName)) {
            val payload = (event.payload as? JsonObject).orEmpty()
            val mediaUpdate = reduction.mutations.lastOrNull() as? XiaomiPlaybackMutation.ApplyMediaInfo
            logMiPlay(
                event = "protocol_event",
                outcome = reduction.outcome.name.lowercase(),
                details = mapOf(
                    "event_name" to event.eventName,
                    "event_sequence" to reduction.eventSequence,
                    "session_sequence" to reduction.sessionSequence,
                    "reason" to reduction.reason,
                    "mutation_count" to reduction.mutations.size,
                    "volume_percent" to event.toVolumePercentOrNull(),
                    "replace_track" to mediaUpdate?.replaceTrack,
                    "previous_position_ms" to xiaomiPlayback.positionMs.takeIf { mediaUpdate != null },
                    "accepted_position_ms" to mediaUpdate?.mediaInfo?.positionMs,
                    "caption_reported" to (payload["title_is_lyric"] as? JsonPrimitive)?.booleanOrNull,
                ) + payload
                    .filterKeys { it in MIPLAY_DIAGNOSTIC_FIELDS }
                    .mapKeys { (key, _) -> "protocol_$key" }
                    .mapValues { (_, value) ->
                        when (value) {
                            is JsonPrimitive -> if (value.isString) value.content else {
                                value.booleanOrNull ?: value.longOrNull ?: value.content
                            }
                            else -> value.toString()
                        }
                    },
            )
        }
        applyXiaomiReduction(reduction)
    }

    private suspend fun applyXiaomiReduction(reduction: XiaomiReduction) {
        for (mutation in reduction.mutations) {
            when (mutation) {
                is XiaomiPlaybackMutation.Activate -> {
                    viewModel.activateXiaomiPlayback(
                        sourceName = mutation.sourceName,
                        newSession = mutation.newSession,
                        rawState = mutation.rawState,
                        claimPlayback = false,
                    )
                    when (mutation.rawState) {
                        2 -> {
                            if (!xiaomiTakeoverGate.acceptPlaying()) {
                                viewModel.markSourcePaused(MediaSource.XIAOMI_MIPLAY)
                                continue
                            }
                            val takeover = runCatching {
                                viewModel.takeOverWithExternalSource(CORE_SOURCE_XIAOMI, "audio")
                            }.onFailure { reportMiPlaySourceSwitchError("小米妙播切换播放源失败", it) }
                            if (takeover.isSuccess) {
                                val resumed = runCatching { bridge.resumeXiaomiOutput() }
                                    .onFailure { reportMiPlaySourceSwitchError("小米妙播恢复输出失败", it) }
                                if (resumed.isSuccess) {
                                    activatePlaybackSource(
                                        MediaSource.XIAOMI_MIPLAY,
                                        previousAlreadySuspendedByCore = true,
                                    )
                                    clearMiPlaySourceSwitchError()
                                }
                            }
                        }
                        null -> Unit
                        else -> {
                            clearMiPlaySourceSwitchError()
                            xiaomiTakeoverGate.confirmPaused()
                            viewModel.pauseConnectedXiaomiAndExposeIfForegroundIdle()
                            mediaSourceArbiter.deactivate(MediaSource.XIAOMI_MIPLAY)
                        }
                    }
                }
                is XiaomiPlaybackMutation.Deactivate -> {
                    clearMiPlaySourceSwitchError()
                    xiaomiTakeoverGate.reset()
                    // Pause already releases the arbiter; still remove the cached/UI
                    // session when its media route subsequently ends.
                    mediaSourceArbiter.deactivate(MediaSource.XIAOMI_MIPLAY)
                    viewModel.deactivateXiaomiPlayback()
                }
                is XiaomiPlaybackMutation.ApplyMediaInfo -> mutation.mediaInfo.let { media ->
                    viewModel.updateXiaomiMediaInfo(
                        trackId = media.trackId,
                        title = media.title,
                        artist = media.artist,
                        album = media.album,
                        artworkUrl = media.artworkUrl,
                        durationMs = media.durationMs,
                        positionMs = media.positionMs,
                        replaceTrack = mutation.replaceTrack,
                        codec = media.codec,
                        bitrateBps = media.bitrateBps,
                        sampleRate = media.sampleRate,
                        bitsPerSample = media.bitsPerSample,
                        channels = media.channels,
                        lyricsText = media.lyricsText,
                        titleIsLyric = media.titleIsLyric,
                        trackIdSource = media.trackIdSource,
                        trackTransition = media.trackTransition,
                        senderMetadata = media.senderMetadata,
                        sdkDisplayMetadata = media.sdkDisplayMetadata,
                    )
                }
            }
        }
        runCatching {
            bridge.reportDiagnostic(
                component = "android_xiaomi",
                event = "event_reduced",
                outcome = reduction.outcome.name.lowercase(),
                reason = reduction.reason,
                bridgeSequence = reduction.eventSequence,
                sessionSequence = reduction.sessionSequence,
            )
        }
    }

    private suspend fun handleCoreEvent(event: AppEvent) {
        if (!receiverServiceActive) return
        when (event) {
            is AppEvent.SourceTakeover -> if (
                SourceTakeoverPolicy.shouldSuspend(
                    previousSource = event.previousSource,
                    newSource = event.source,
                    candidateSource = CORE_SOURCE_XIAOMI,
                )
            ) {
                mediaSourceArbiter.suspendObserved(MediaSource.XIAOMI_MIPLAY) {
                    pauseSourceForTakeover(MediaSource.XIAOMI_MIPLAY)
                }
            }
            is AppEvent.StreamStarted -> activatePlaybackSource(MediaSource.AIRPLAY)
            is AppEvent.StreamStopped -> if (
                eventTargetsSourcePlayback("AirPlay", event.source, event.epoch)
            ) {
                mediaSourceArbiter.deactivate(MediaSource.AIRPLAY)
            }
            is AppEvent.PlaybackState -> {
                val source = sourceFromCore(event.source)
                if (source != null && CorePlaybackStateSideEffect.isCurrent(viewModel.state.value, event)) {
                    if (event.playing) {
                        activatePlaybackSource(source, projectSource = false)
                    } else {
                        mediaSourceArbiter.deactivate(source)
                    }
                }
            }
            is AppEvent.VideoPlay -> if (
                eventTargetsSourcePlayback("AirPlay", event.source, event.epoch)
            ) {
                activatePlaybackSource(MediaSource.AIRPLAY)
                networkPlayer.open(
                    MediaSource.AIRPLAY,
                    event.url,
                    event.epoch,
                    event.startPositionMs,
                    true,
                )
            }
            is AppEvent.VideoSeek -> if (
                eventTargetsSourcePlayback("AirPlay", event.source, event.epoch) &&
                networkPlayer.source == MediaSource.AIRPLAY
            ) {
                networkPlayer.seek(event.positionMs)
            }
            is AppEvent.VideoRate -> if (
                eventTargetsSourcePlayback("AirPlay", event.source, event.epoch)
            ) {
                if (event.rate > 0.0) {
                    activatePlaybackSource(MediaSource.AIRPLAY)
                    resumeCachedNetworkSource(MediaSource.AIRPLAY, event.rate)
                } else if (networkPlayer.source == MediaSource.AIRPLAY) {
                    networkPlayer.pause()
                }
            }
            is AppEvent.VideoStop -> if (
                eventTargetsSourcePlayback("AirPlay", event.source, event.epoch)
            ) {
                if (networkPlayer.source == MediaSource.AIRPLAY) networkPlayer.stop()
                mediaSourceArbiter.deactivate(MediaSource.AIRPLAY)
            }
            is AppEvent.DlnaMedia -> if (
                event.source == null || event.source.equals(CORE_SOURCE_DLNA, ignoreCase = true)
            ) {
                activatePlaybackSource(MediaSource.DLNA)
                if (!NetworkMediaEventGate.selectsCurrentResource(
                        activeSource = networkPlayer.source,
                        activeUrl = networkPlayer.url,
                        activeEpoch = networkPlayer.sourceEpoch,
                        eventSource = MediaSource.DLNA,
                        eventUrl = event.url,
                        eventEpoch = event.epoch,
                    )
                ) {
                    networkPlayer.open(
                        MediaSource.DLNA,
                        event.url,
                        event.epoch,
                        event.startPositionMs,
                        true,
                    )
                }
            }
            is AppEvent.DlnaSeek -> if (networkEventMatches(
                    MediaSource.DLNA,
                    CORE_SOURCE_DLNA,
                    event.source,
                    event.epoch,
                )
            ) {
                networkPlayer.seek(event.positionMs)
            }
            is AppEvent.DlnaRate -> if (networkEventMatches(
                    MediaSource.DLNA,
                    CORE_SOURCE_DLNA,
                    event.source,
                    event.epoch,
                )
            ) {
                if (event.rate > 0.0) {
                    activatePlaybackSource(MediaSource.DLNA)
                    if (networkPlayer.source == MediaSource.DLNA && networkPlayer.url != null) {
                        networkPlayer.setRate(event.rate)
                    } else {
                        resumeCachedNetworkSource(MediaSource.DLNA, event.rate)
                    }
                } else if (networkPlayer.source == MediaSource.DLNA) {
                    networkPlayer.pause()
                }
            }
            is AppEvent.DlnaStop -> if (networkEventMatches(
                    MediaSource.DLNA,
                    CORE_SOURCE_DLNA,
                    event.source,
                    event.epoch,
                )
            ) {
                if (networkPlayer.source == MediaSource.DLNA) networkPlayer.pause()
                mediaSourceArbiter.deactivate(MediaSource.DLNA)
            }
            is AppEvent.DlnaVolume -> if (
                eventTargetsSourcePlayback("DLNA", event.source, event.epoch) &&
                networkPlayer.source == MediaSource.DLNA
            ) {
                event.percent?.let(networkPlayer::setVolumePercent)
                event.muted?.let(networkPlayer::setMuted)
            }
            else -> Unit
        }
    }

    private fun networkEventMatches(
        expectedSource: MediaSource,
        expectedWireSource: String,
        eventSource: String?,
        eventEpoch: Long?,
    ): Boolean = NetworkMediaEventGate.matches(
        activeSource = networkPlayer.source,
        activeEpoch = networkPlayer.sourceEpoch,
        expectedSource = expectedSource,
        expectedWireSource = expectedWireSource,
        eventSource = eventSource,
        eventEpoch = eventEpoch,
    )

    private fun sourceFromCore(source: String?): MediaSource? = when (source?.trim()?.lowercase()) {
        CORE_SOURCE_AIRPLAY -> MediaSource.AIRPLAY
        CORE_SOURCE_DLNA -> MediaSource.DLNA
        CORE_SOURCE_XIAOMI -> MediaSource.XIAOMI_MIPLAY
        else -> null
    }

    private fun projectUiState(state: AppState) = ReceiverUiState(
        state = if (receiverServiceActive) state.copy(
            receiverReady = state.receiverReady || appliedMiPlayConfiguration?.enabled == true,
        ) else state.copy(
            playback = PlaybackSnapshot(),
            remoteControl = RemoteControlState(),
            connectedClient = null,
            coreRunning = false,
            receiverReady = false,
        ),
        nativeCast = nativeCast.state.value,
        miPlaySyncOffsetMs = miPlaySyncOffsetMs,
        volumePercent = FusionPlayMediaChannel.currentSystemMediaVolumePercent(),
        receiverName = viewModel.receiverName,
        receiverRunning = receiverServiceActive,
        autoReceiveOnLaunch = autoReceiveOnLaunch,
        diagnostics = diagnostics.copy(
            coverAvailable = FusionPlayMediaChannel.currentArtwork() != null,
            receiverError = listOfNotNull(
                coreReceiverError, miPlayReceiverError, miPlayAudioError, miPlaySourceSwitchError, networkPlaybackError,
                bridgeInitializationError,
            ).distinct().joinToString("\n").ifEmpty { null },
        ),
        playerError = if (!receiverServiceActive) {
            null
        } else if (state.playback.protocol.equals(XIAOMI_PROTOCOL, ignoreCase = true)) {
            miPlayAudioError ?: miPlayReceiverError
        } else if (state.playback.streamActive || state.playback.mediaUrl != null) {
            networkPlaybackError
        } else {
            coreReceiverError ?: miPlayReceiverError ?: bridgeInitializationError
        },
    )

    private fun publishState(state: AppState) {
        mutableUiState.value = projectUiState(state)
    }

    fun refreshUiState() = publishState(viewModel.state.value)

    fun refreshReceiverDiagnostics() {
        if (diagnosticsRefreshJob?.isActive == true) return
        diagnosticsRefreshJob = scope.launch {
            val boundInterface = diagnostics.lanInterface.takeIf { appliedMiPlayConfiguration?.enabled == true }
            val boundAddress = diagnostics.lanAddress.takeIf { boundInterface != null }
            val adapter = withContext(Dispatchers.IO) {
                runCatching { bridge.listXiaomiNetworkAdapters() }.getOrNull()?.let { list ->
                    val selected = list.adapters.firstOrNull {
                        it.name == boundInterface && it.ipv4Address == boundAddress
                    }
                    selected ?: list.adapters.firstOrNull { it.id == list.autoSelectedAdapterId }
                }
            }
            if (appliedMiPlayConfiguration?.enabled != true || diagnostics.lanInterface == boundInterface) {
                diagnostics = diagnostics.copy(lanInterface = adapter?.name, lanAddress = adapter?.ipv4Address)
            }
            updateAudioRoute()
            publishState(viewModel.state.value)
        }
    }

    private fun updateAudioRoute() {
        val audioManager = context.getSystemService(AudioManager::class.java) ?: return
        val device = miPlayAudioDeviceId?.let { id ->
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.id == id }
        }
        val name = device?.productName?.toString()?.takeIf(String::isNotBlank)
        val systemRoute = if (name == null && Build.VERSION.SDK_INT >= 33) {
            runCatching {
                audioManager.getAudioDevicesForAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                ).map { it.productName.toString() }.filter(String::isNotBlank).distinct()
                    .joinToString(" / ").ifEmpty { null }
            }.getOrNull()
        } else null
        diagnostics = diagnostics.copy(audioRoute = name ?: systemRoute, audioRouteObserved = name != null)
    }

    private fun clearRecoveredMiPlayError() {
        viewModel.clearErrorIfMatches(miPlayReceiverError)
        miPlayReceiverError = null
    }

    private fun resetMiPlayDiagnostics() {
        clearMiPlaySourceSwitchError()
        miPlayAudioDeviceId = null
        diagnostics = NativeReceiverDiagnostics(
            lanInterface = diagnostics.lanInterface,
            lanAddress = diagnostics.lanAddress,
        )
        updateAudioRoute()
    }

    private fun updateMiPlayDiagnostics(event: WindowsBridgeXiaomiEvent) {
        val payload = event.payload as? JsonObject ?: return
        when (event.eventName) {
            "receiver_ready" -> clearRecoveredMiPlayError()
            "media_session_replaced", "media_channel_closed" -> {
                viewModel.clearErrorIfMatches(miPlayAudioError)
                miPlayAudioError = null
                resetMiPlayDiagnostics()
            }
            "audio_output_route_recovered" -> {
                diagnostics = diagnostics.copy(outputRecoveries = diagnostics.outputRecoveries + 1)
                viewModel.clearErrorIfMatches(miPlayAudioError)
                miPlayAudioError = null
            }
            "audio_output_signal_started" -> {
                viewModel.clearErrorIfMatches(miPlayAudioError)
                miPlayAudioError = null
            }
            "audio_output_callback_started", "audio_synchronization_started", "audio_presentation_schedule" -> {
                payload.int("audio_device_id")?.let { reportedId ->
                    val id = reportedId.takeIf { it > 0 }
                    if (miPlayAudioDeviceId != id) {
                        miPlayAudioDeviceId = id
                        updateAudioRoute()
                    }
                }
                diagnostics = diagnostics.copy(
                    bufferedFrames = (payload["buffered_frames"] as? JsonPrimitive)?.longOrNull ?: diagnostics.bufferedFrames,
                    outputLatencyMs = payload.double("output_latency_ms") ?: diagnostics.outputLatencyMs,
                    endpointLatencyCalibrated = (payload["output_latency_calibrated"] as? JsonPrimitive)?.booleanOrNull
                        ?: diagnostics.endpointLatencyCalibrated,
                    scheduleErrorMs = if (event.eventName == "audio_presentation_schedule") {
                        payload.double("schedule_error_us")?.div(1_000.0)
                    } else diagnostics.scheduleErrorMs,
                    underrunCallbacks = (payload["underrun_callbacks"] as? JsonPrimitive)?.longOrNull
                        ?: diagnostics.underrunCallbacks,
                    synchronizationMode = payload.text("synchronization_mode") ?: diagnostics.synchronizationMode,
                )
            }
            "error" -> if (payload.text("code") == "miplay_audio_output_failed") {
                val message = payload.text("message") ?: return
                miPlayAudioError = message
                viewModel.reportExternalLog(message, isError = true)
            } else return
            else -> return
        }
        publishState(viewModel.state.value)
    }

    private fun JsonObject.text(key: String) = (get(key) as? JsonPrimitive)?.contentOrNull

    private fun JsonObject.int(key: String) = (get(key) as? JsonPrimitive)?.intOrNull

    private fun JsonObject.double(key: String) = (get(key) as? JsonPrimitive)?.doubleOrNull?.takeIf(Double::isFinite)

    fun setCorrectLyricTitles(enabled: Boolean) {
        if (correctLyricTitles == enabled) return
        correctLyricTitles = enabled
        publishMediaSession(viewModel.state.value)
    }

    private fun publishMediaSession(state: AppState) {
        val playback = state.playback
        val hasMedia = receiverServiceActive &&
            (playback.title != null || playback.streamActive || playback.mediaUrl != null)
        if (!hasMedia) {
            if (mediaSessionHasMedia) {
                artworkJob?.cancel()
                artworkJob = null
                FusionPlayMediaChannel.clear()
                mediaSessionHasMedia = false
                lastPublishedArtwork = null
                lastPublishedMetadata = null
                lastPublishedPlaying = null
                lastPublishedCapabilities = null
            }
            return
        }
        mediaSessionHasMedia = true
        val labels = playback.displayMetadata(correctLyricTitles)
        val metadata = MediaMetadataProjection(
            title = labels.title?.takeIf { it.isNotBlank() } ?: playback.protocol ?: "FusionPlay",
            artist = labels.artist,
            album = labels.album,
            mediaIdentity = playback.trackIdentity ?: playback.mediaUrl ?: playback.title,
        )
        if (metadata != lastPublishedMetadata) {
            lastPublishedMetadata = metadata
            FusionPlayMediaChannel.setMetadata(
                title = metadata.title,
                artist = metadata.artist,
                album = metadata.album,
                mediaIdentity = metadata.mediaIdentity,
            )
        }
        if (playback.isPlaying != lastPublishedPlaying) {
            lastPublishedPlaying = playback.isPlaying
            FusionPlayMediaChannel.setPlayback(playback.isPlaying)
        }
        FusionPlayMediaChannel.setTimeline(playback.positionMs, playback.durationMs ?: 0)
        val capabilities = MediaCapabilitiesProjection(
            canPlayPause = true,
            canPrevious = state.remoteControl.commands.any { it.contains("previous", true) },
            canNext = state.remoteControl.commands.any { it.contains("next", true) },
            canSeek = state.remoteControl.commands.any { it.contains("seek", true) },
        )
        if (capabilities != lastPublishedCapabilities) {
            lastPublishedCapabilities = capabilities
            FusionPlayMediaChannel.setCapabilities(
                canPlayPause = capabilities.canPlayPause,
                canPrevious = capabilities.canPrevious,
                canNext = capabilities.canNext,
                canSeek = capabilities.canSeek,
            )
        }
        val artwork = playback.coverArt
        if (artwork != lastPublishedArtwork) {
            lastPublishedArtwork = artwork
            artworkJob?.cancel()
            artworkJob = scope.launch {
                if (artwork.isNullOrBlank()) {
                    FusionPlayMediaChannel.clearArtwork()
                } else {
                    runCatching {
                        when {
                            artwork.startsWith("data:", ignoreCase = true) ->
                                bridge.setArtworkDataUri(artwork)
                            artwork.startsWith("http://", ignoreCase = true) ||
                                artwork.startsWith("https://", ignoreCase = true) ||
                                artwork.startsWith("file:", ignoreCase = true) ->
                                bridge.setArtwork(URI.create(artwork))
                            else -> bridge.setArtwork(Paths.get(artwork))
                        }
                    }.onFailure {
                        // A newer cover or session replaces this job normally.
                        // Preserve cancellation instead of surfacing it as a failed download.
                        if (it is CancellationException) throw it
                        reportError("媒体封面更新失败", it)
                    }
                }
            }
        }
    }

    private fun reportMiPlaySourceSwitchError(prefix: String, error: Throwable) {
        val message = failureMessage(prefix, error)
        if (miPlaySourceSwitchError == message) return
        miPlaySourceSwitchError = message
        viewModel.reportExternalLog(message, isError = true)
    }

    private fun clearMiPlaySourceSwitchError() {
        val previous = miPlaySourceSwitchError
        miPlaySourceSwitchError = null
        viewModel.clearErrorIfMatches(previous)
    }

    private fun reportError(prefix: String, error: Throwable): String = failureMessage(prefix, error).also {
        viewModel.reportExternalLog(it, isError = true)
    }

    private fun failureMessage(prefix: String, error: Throwable): String {
        if (error is CancellationException) throw error
        return "$prefix：${error.message ?: error.javaClass.simpleName}"
    }

    private fun logCoreConfiguration(
        component: String,
        enabled: Boolean,
        outcome: String,
    ) {
        diagnosticLogger.write(
            component = component,
            event = "receiver_configuration",
            outcome = outcome,
            details = mapOf("enabled" to enabled),
        )
    }

    private fun logProtocolFailure(
        component: String,
        event: String,
        error: Throwable,
    ) {
        diagnosticLogger.write(
            component = component,
            event = event,
            outcome = "failure",
            details = mapOf(
                "error_type" to error::class.java.simpleName,
                "message" to error.message,
            ),
        )
    }

    private fun logMiPlay(
        event: String,
        outcome: String,
        details: Map<String, Any?> = emptyMap(),
    ) {
        diagnosticLogger.write(
            component = "xiaomi_miplay",
            event = event,
            outcome = outcome,
            details = details,
        )
    }

    private fun logMiPlayFailure(
        event: String,
        error: Throwable,
        details: Map<String, Any?> = emptyMap(),
    ) {
        logMiPlay(
            event = event,
            outcome = "failure",
            details = details + mapOf(
                "error_type" to error::class.java.simpleName,
                "message" to error.message,
            ),
        )
    }

    private fun shouldPersistMiPlayEvent(eventName: String): Boolean {
        if (!eventName.equals("progress", ignoreCase = true)) return true
        val now = System.nanoTime()
        if (now - lastMiPlayProgressLogNanos < MIPLAY_PROGRESS_LOG_INTERVAL_NANOS) {
            return false
        }
        lastMiPlayProgressLogNanos = now
        return true
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        nativeCast.close()
        networkPlayer.close()
        bridge.close()
        viewModel.close()
        scope.cancel()
    }

    fun setAppForeground(value: Boolean) = nativeCast.setForeground(value)

    private data class CoreReceiverConfiguration(
        val name: String,
        val airPlayEnabled: Boolean,
        val dlnaEnabled: Boolean,
        val running: Boolean,
    )

    private data class MiPlayReceiverConfiguration(
        val name: String,
        val enabled: Boolean,
        val identity: MiPlayDeviceIdentity,
    )

    private data class MediaMetadataProjection(
        val title: String,
        val artist: String?,
        val album: String?,
        val mediaIdentity: String?,
    )

    private data class MediaCapabilitiesProjection(
        val canPlayPause: Boolean,
        val canPrevious: Boolean,
        val canNext: Boolean,
        val canSeek: Boolean,
    )

    companion object {
        // Keep useful discovery outcomes while excluding wire packets,
        // authentication material and device/account identities. The logger
        // applies its existing address and secret redaction to these values.
        private val MIPLAY_DIAGNOSTIC_FIELDS = setOf(
            "source", "destination", "service", "success", "unicast",
            "address_family", "profile", "port", "control_port", "code", "message",
            "stage", "state", "playing", "raw_state", "session_active",
            "position_ms", "duration_ms", "track_id_source", "metadata_change_type",
            "group_target_delay_ms", "queue_delay_ms", "output_latency_ms",
            "output_callback_frames", "output_sample_rate", "synchronization_mode",
            "time_offset_us", "clock_synchronized", "server_minus_local_us",
            "target_server_minus_local_us", "phase_error_us", "frequency_ppm",
            "round_trip_us", "latency_ms", "arrival_residual_ms", "media_generation",
            "front_pts_us", "server_now_us", "schedule_error_us", "buffered_frames",
            "timed_playback_started", "channel",
            "observed_output_latency_ms", "underrun_callbacks",
            "output_latency_calibrated",
            "output_advance_ms", "sync_offset_ms", "audio_device_id",
        )
        internal const val SYNC_OFFSET_MIN = -500
        internal const val SYNC_OFFSET_MAX = 500
        private const val SYNC_OFFSET_KEY = "offset_ms"
        private const val XIAOMI_PROTOCOL = "小米妙播"
        private const val CORE_SOURCE_AIRPLAY = "airplay"
        private const val CORE_SOURCE_DLNA = "dlna"
        private const val CORE_SOURCE_XIAOMI = "xiaomi_miplay"
        private const val PROGRESS_TICK_MS = 500L
        private const val MIPLAY_PROGRESS_LOG_INTERVAL_NANOS = 3_000_000_000L
        private val XIAOMI_RESTART_DELAYS_MS = longArrayOf(1_000L, 2_000L, 4_000L)
    }
}
