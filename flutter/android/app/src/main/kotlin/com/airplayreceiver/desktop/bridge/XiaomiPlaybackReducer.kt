package com.airplayreceiver.desktop.bridge

import com.airplayreceiver.desktop.backend.LrcParser
import com.airplayreceiver.desktop.backend.LyricsDocument
import com.airplayreceiver.desktop.backend.PlaybackDisplayMetadata
import com.airplayreceiver.desktop.backend.containsExactTimedCaption
import com.airplayreceiver.desktop.backend.parseLrcDisplayHeaders
import com.airplayreceiver.desktop.backend.sameLabel
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * Reduces Xiaomi's two asynchronous event streams into ordered playback
 * mutations. New bridges attach monotonic bridge/session sequences. Older
 * Rust sidecars do not, so this reducer also synthesizes a session at the
 * inactive -> active boundary and reserves that same session for metadata
 * which arrives just before playback_state.
 */
class XiaomiPlaybackReducer(
    private val nowMillis: () -> Long = {
        System.nanoTime() / 1_000_000L
    },
) {
    private var lastEventSequence = 0L
    private var currentSessionSequence = 0L
    private var sessionActive = false
    private var currentMediaInfo: XiaomiMediaInfo? = null
    private var currentTrackAnchor: String? = null
    private var pendingMediaInfo: PendingMediaInfo? = null
    private var pendingSeek: PendingSeek? = null
    private var lyricsEvidenceCache: Pair<String, LyricsEvidence>? = null
    private var mediaGeneration: Long? = null
    private var mediaClosed = false
    private var mediaCloseDeadline: Long? = null

    /**
     * Records a seek accepted by the native MiPlay control channel. Position
     * updates arrive independently from the command channel, so
     * one or two already-sampled positions can arrive after the command and
     * otherwise snap the UI back to the old position.
     *
     * Keep the requested position until the vendor reports a nearby position,
     * a different track/session starts, or the short acknowledgement window
     * expires. This is an ordering barrier only; it does not turn dispatch
     * into a confirmed command result.
     */
    fun beginSeek(positionMs: Long) {
        if (!sessionActive || currentSessionSequence <= 0L) {
            return
        }
        val target = positionMs.coerceAtLeast(0L)
        pendingSeek = PendingSeek(
            sessionSequence = currentSessionSequence,
            targetPositionMs = target,
            startedAtMs = nowMillis(),
        )
        currentMediaInfo = currentMediaInfo?.copy(positionMs = target)
    }

    fun reduce(event: WindowsBridgeXiaomiEvent, displayedPositionMs: Long? = null): XiaomiReduction {
        reduceMediaLifecycle(event)?.let { return it }
        val playbackState = event.toPlaybackStateOrNull()
        if (mediaClosed && playbackState?.sessionActive == true) {
            return XiaomiReduction.ignored("closed_media_route", event.bridgeSequence, currentSessionSequence)
        }
        val mediaInfo = event.toMediaInfoOrNull()
        if (playbackState == null && mediaInfo == null) {
            return XiaomiReduction.ignored(
                reason = "unsupported_or_invalid_event",
                eventSequence = event.bridgeSequence,
                sessionSequence = event.sessionSequence,
            )
        }

        val eventSequence =
            playbackState?.eventSequence ?: mediaInfo?.eventSequence
        if (
            eventSequence != null &&
            eventSequence <= lastEventSequence
        ) {
            return XiaomiReduction.ignored(
                reason = "stale_event_sequence",
                eventSequence = eventSequence,
                sessionSequence =
                    playbackState?.sessionSequence ?: mediaInfo?.sessionSequence,
            )
        }
        if (eventSequence != null) {
            lastEventSequence = eventSequence
        }

        return if (playbackState != null) {
            reducePlaybackState(playbackState)
        } else {
            reduceMediaInfo(requireNotNull(mediaInfo), event.eventName.equals("media_info", ignoreCase = true), displayedPositionMs)
        }
    }

    /** Stop progress immediately on audio EOF, but retain metadata briefly for track handover. */
    private fun reduceMediaLifecycle(event: WindowsBridgeXiaomiEvent): XiaomiReduction? {
        val payload = event.payload as? JsonObject ?: return null
        val generation = payload["media_generation"]?.jsonPrimitive?.longOrNull ?: return null
        val opened = event.eventName == "interconnect_stage" &&
            payload["stage"]?.jsonPrimitive?.contentOrNull == "media_session_established"
        if (opened && generation > (mediaGeneration ?: 0L)) {
            mediaGeneration = generation
            mediaClosed = false
            mediaCloseDeadline = null
            return null
        }
        // RTSP control EOF alone does not prove that the independent audio socket ended.
        val ended = event.eventName == "stream_stopped" ||
            (event.eventName == "media_channel_closed" &&
                payload["channel"]?.jsonPrimitive?.contentOrNull == "audio") ||
            (event.eventName == "error" && payload["code"]?.jsonPrimitive?.contentOrNull == "miplay_audio_stream_failed")
        if (!ended) return null
        if (generation != mediaGeneration || mediaClosed) {
            return XiaomiReduction.ignored("stale_or_duplicate_media_close", event.bridgeSequence, currentSessionSequence)
        }
        mediaClosed = true
        mediaCloseDeadline = nowMillis() + 2_000L
        if (!sessionActive) return XiaomiReduction.ignored("inactive_media_closed", event.bridgeSequence, currentSessionSequence)
        return XiaomiReduction(
            mutations = listOf(XiaomiPlaybackMutation.Activate(currentSessionSequence, null, 3, false)),
            outcome = XiaomiReductionOutcome.APPLIED,
            reason = "audio_ended_waiting_for_replacement",
            eventSequence = event.bridgeSequence,
            sessionSequence = currentSessionSequence,
        )
    }

    fun expireClosedMedia(): XiaomiReduction? {
        val deadline = mediaCloseDeadline ?: return null
        if (nowMillis() < deadline) return null
        mediaCloseDeadline = null
        // Keep the generation tombstone until a new OPEN, so late control notifications
        // cannot resurrect a stream that no longer produces audio.
        return reducePlaybackState(XiaomiPlaybackState(false, null, 4, currentSessionSequence, null))
    }

    fun reset(resetEventSequence: Boolean = false): XiaomiReduction {
        val oldSession = currentSessionSequence.takeIf { it > 0L }
        if (resetEventSequence) {
            lastEventSequence = 0L
        }
        currentSessionSequence = 0L
        mediaGeneration = null
        mediaClosed = false
        mediaCloseDeadline = null
        sessionActive = false
        currentMediaInfo = null
        currentTrackAnchor = null
        pendingMediaInfo = null
        pendingSeek = null
        lyricsEvidenceCache = null
        return XiaomiReduction(
            mutations = oldSession
                ?.let { listOf(XiaomiPlaybackMutation.Deactivate(it)) }
                .orEmpty(),
            outcome = XiaomiReductionOutcome.APPLIED,
            reason = "reducer_reset",
            eventSequence = null,
            sessionSequence = oldSession,
        )
    }

    private fun reducePlaybackState(
        playbackState: XiaomiPlaybackState,
    ): XiaomiReduction {
        val explicitSession = playbackState.sessionSequence
        val resolvedSession = if (playbackState.sessionActive) {
            explicitSession ?: resolveLegacyActiveSession()
        } else {
            explicitSession
                ?: currentSessionSequence.takeIf { it > 0L }
                ?: return XiaomiReduction.ignored(
                    reason = "duplicate_inactive",
                    eventSequence = playbackState.eventSequence,
                    sessionSequence = null,
                )
        }

        if (resolvedSession < currentSessionSequence) {
            return XiaomiReduction.ignored(
                reason = "stale_session",
                eventSequence = playbackState.eventSequence,
                sessionSequence = resolvedSession,
            )
        }

        if (!playbackState.sessionActive) {
            if (
                !sessionActive ||
                resolvedSession != currentSessionSequence
            ) {
                return XiaomiReduction.ignored(
                    reason = "duplicate_or_future_inactive",
                    eventSequence = playbackState.eventSequence,
                    sessionSequence = resolvedSession,
                )
            }
            sessionActive = false
            pendingSeek = null
            currentMediaInfo = currentMediaInfo?.copy(lyricsText = null, titleIsLyric = null, trackIdSource = null)
            lyricsEvidenceCache = null
            pendingMediaInfo = pendingMediaInfo
                ?.takeIf { it.sessionSequence > resolvedSession }
            return XiaomiReduction(
                mutations = listOf(
                    XiaomiPlaybackMutation.Deactivate(resolvedSession),
                ),
                outcome = XiaomiReductionOutcome.APPLIED,
                reason = "session_inactive",
                eventSequence = playbackState.eventSequence,
                sessionSequence = resolvedSession,
            )
        }

        val startsNewSession =
            !sessionActive || resolvedSession > currentSessionSequence
        if (startsNewSession) {
            currentSessionSequence = resolvedSession
            sessionActive = true
            pendingSeek = null
            currentMediaInfo = currentMediaInfo?.copy(lyricsText = null, titleIsLyric = null, trackIdSource = null)
            lyricsEvidenceCache = null
        }

        val mutations = mutableListOf<XiaomiPlaybackMutation>(
            XiaomiPlaybackMutation.Activate(
                sessionSequence = resolvedSession,
                sourceName = playbackState.sourceName,
                rawState = playbackState.rawState,
                newSession = startsNewSession,
            ),
        )
        val pending = pendingMediaInfo
            ?.takeIf { it.sessionSequence == resolvedSession }
        if (pending != null) {
            pendingMediaInfo = null
            currentMediaInfo = pending.mediaInfo
            currentTrackAnchor = pending.trackAnchor
            mutations += XiaomiPlaybackMutation.ApplyMediaInfo(
                sessionSequence = resolvedSession,
                mediaInfo = pending.mediaInfo.copy(trackId = currentTrackAnchor),
                replaceTrack = pending.replaceTrack,
            )
        } else {
            pendingMediaInfo = pendingMediaInfo
                ?.takeIf { it.sessionSequence > resolvedSession }
        }

        return XiaomiReduction(
            mutations = mutations,
            outcome = XiaomiReductionOutcome.APPLIED,
            reason = if (startsNewSession) {
                if (pending == null) {
                    "session_activated"
                } else {
                    "session_activated_with_cached_media"
                }
            } else {
                "active_state_updated"
            },
            eventSequence = playbackState.eventSequence,
            sessionSequence = resolvedSession,
        )
    }

    private fun reduceMediaInfo(mediaInfo: XiaomiMediaInfo, fromMetadata: Boolean, displayedPositionMs: Long?): XiaomiReduction {
        val explicitSession = mediaInfo.sessionSequence
        val resolvedSession = explicitSession ?: when {
            sessionActive -> currentSessionSequence
            pendingMediaInfo != null ->
                requireNotNull(pendingMediaInfo).sessionSequence

            else -> currentSessionSequence + 1L
        }

        if (
            explicitSession != null &&
            resolvedSession < currentSessionSequence
        ) {
            return XiaomiReduction.ignored(
                reason = "stale_session",
                eventSequence = mediaInfo.eventSequence,
                sessionSequence = resolvedSession,
            )
        }

        if (!sessionActive || resolvedSession > currentSessionSequence) {
            if (
                explicitSession != null &&
                resolvedSession <= currentSessionSequence
            ) {
                return XiaomiReduction.ignored(
                    reason = "late_media_for_inactive_session",
                    eventSequence = mediaInfo.eventSequence,
                    sessionSequence = resolvedSession,
                )
            }
            val pending = pendingMediaInfo?.takeIf { it.sessionSequence == resolvedSession }
            val previous = pending?.mediaInfo
                ?: currentMediaInfo?.copy(lyricsText = null, titleIsLyric = null, trackIdSource = null)
            val replaceTrack = isNewTrack(previous, mediaInfo)
            val samePendingTrackHasProgress = (pending?.mediaInfo?.positionMs ?: 0L) > 0L
            val incoming = discardMetadataPositionZero(mediaInfo, fromMetadata, replaceTrack, samePendingTrackHasProgress)
            val merged = mergeMediaInfo(previous, incoming, replaceTrack)
            pendingMediaInfo = PendingMediaInfo(
                sessionSequence = resolvedSession,
                mediaInfo = merged,
                trackAnchor = trackAnchor(if (pending == null) currentTrackAnchor else pending.trackAnchor, merged, replaceTrack),
                replaceTrack = replaceTrack || pending?.replaceTrack == true,
            )
            return XiaomiReduction(
                mutations = emptyList(),
                outcome = XiaomiReductionOutcome.CACHED,
                reason = "media_cached_until_active",
                eventSequence = mediaInfo.eventSequence,
                sessionSequence = resolvedSession,
            )
        }

        if (resolvedSession < currentSessionSequence) {
            return XiaomiReduction.ignored(
                reason = "stale_session",
                eventSequence = mediaInfo.eventSequence,
                sessionSequence = resolvedSession,
            )
        }

        val replaceTrack = isNewTrack(currentMediaInfo, mediaInfo)
        val hasProgress = (currentMediaInfo?.positionMs ?: 0L) > 0L ||
            (displayedPositionMs ?: 0L) > 0L || pendingSeek?.targetPositionMs == 0L
        val incoming = discardMetadataPositionZero(mediaInfo, fromMetadata, replaceTrack, hasProgress)
        val reconciledMediaInfo = reconcilePendingSeek(
            incoming = incoming,
            replaceTrack = replaceTrack,
            sessionSequence = resolvedSession,
        )
        val mergedMediaInfo = mergeMediaInfo(
            currentMediaInfo,
            reconciledMediaInfo,
            replaceTrack,
        )
        // Progress and repeated metadata reuse the parsed lyrics already in the
        // playback snapshot, instead of parsing the same text on every tick.
        val updatedLyrics = reconciledMediaInfo.lyricsText?.takeIf {
            replaceTrack || it != currentMediaInfo?.lyricsText
        }
        currentMediaInfo = mergedMediaInfo
        currentTrackAnchor = trackAnchor(currentTrackAnchor, mergedMediaInfo, replaceTrack)
        return XiaomiReduction(
            mutations = listOf(
                XiaomiPlaybackMutation.ApplyMediaInfo(
                    sessionSequence = resolvedSession,
                    mediaInfo = mergedMediaInfo.copy(
                        trackId = currentTrackAnchor,
                        // Missing position leaves the locally advanced cursor alone.
                        positionMs = reconciledMediaInfo.positionMs,
                        lyricsText = updatedLyrics,
                        // Missing on progress ticks. Forward only evidence from this packet.
                        titleIsLyric = mediaInfo.titleIsLyric,
                        trackIdSource = mediaInfo.trackIdSource,
                    ),
                    replaceTrack = replaceTrack,
                ),
            ),
            outcome = XiaomiReductionOutcome.APPLIED,
            reason = if (replaceTrack) {
                "new_track_applied"
            } else {
                "media_update_applied"
            },
            eventSequence = mediaInfo.eventSequence,
            sessionSequence = resolvedSession,
        )
    }

    private fun resolveLegacyActiveSession(): Long {
        if (sessionActive && currentSessionSequence > 0L) {
            return currentSessionSequence
        }
        return pendingMediaInfo
            ?.sessionSequence
            ?.takeIf { it > currentSessionSequence }
            ?: (currentSessionSequence + 1L)
    }

    private fun isNewTrack(
        previous: XiaomiMediaInfo?,
        incoming: XiaomiMediaInfo,
    ): Boolean {
        val hasIncomingIdentity =
            incoming.trackId != null ||
                incoming.title != null ||
                incoming.artist != null ||
                incoming.album != null ||
                incoming.lyricsText != null
        if (!hasIncomingIdentity) {
            return false
        }
        if (previous == null) {
            return true
        }
        val previousExplicitId = previous.explicitTrackId()
        val incomingExplicitId = incoming.explicitTrackId()
        if (previousExplicitId != null && incomingExplicitId != null) {
            return previousExplicitId != incomingExplicitId
        }

        val previousLyrics = previous.lyricsText
        val incomingLyrics = incoming.lyricsText
        if (previousLyrics != null && incomingLyrics != null) {
            if (previousLyrics == incomingLyrics) return false
            val before = lyricsEvidence(previousLyrics)
            val after = lyricsEvidence(incomingLyrics)
            val previousLines = before.document?.lines
            return previousLines == null || previousLines != after.document?.lines ||
                before.metadata.conflictsWith(after.metadata)
        }
        if (previousLyrics != null && incoming.title != null) {
            val evidence = lyricsEvidence(previousLyrics)
            if (evidence.document.containsExactTimedCaption(incoming.title)) return false
            if (sameLabel(evidence.metadata.title, incoming.title) &&
                !evidence.metadata.conflictsWith(PlaybackDisplayMetadata(incoming.title, incoming.artist, incoming.album))
            ) return false
        }
        if (
            incoming.title != null &&
            !incoming.title.equals(previous.title)
        ) {
            return true
        }
        if (
            incoming.title != null &&
            incoming.artist != null &&
            previous.artist != null &&
            !incoming.artist.equals(previous.artist)
        ) {
            return true
        }
        return incoming.title != null &&
            incoming.album != null &&
            previous.album != null &&
            !incoming.album.equals(previous.album)
    }

    private fun XiaomiMediaInfo.explicitTrackId(): String? = trackId?.takeIf {
        when (trackIdSource) {
            "explicit" -> true
            "metadata", "lyrics_metadata", "lyrics" -> false
            else -> !it.startsWith("metadata:") && !it.startsWith("lyrics:")
        }
    }

    private fun lyricsEvidence(text: String): LyricsEvidence {
        val cached = lyricsEvidenceCache
        if (cached != null && cached.first == text) return cached.second
        // Scope the cache to the accepted track, rather than reparsing it on
        // every title update or replacing it with an unaccepted document.
        val evidence = LyricsEvidence(LrcParser.parse(text), parseLrcDisplayHeaders(text))
        if (text == currentMediaInfo?.lyricsText) lyricsEvidenceCache = text to evidence
        return evidence
    }

    private fun PlaybackDisplayMetadata.conflictsWith(other: PlaybackDisplayMetadata): Boolean =
        labelsConflict(title, other.title) || labelsConflict(artist, other.artist) || labelsConflict(album, other.album)

    private fun labelsConflict(previous: String?, incoming: String?): Boolean =
        previous != null && incoming != null && !sameLabel(previous, incoming)

    private fun trackAnchor(
        previousAnchor: String?,
        incoming: XiaomiMediaInfo,
        replaceTrack: Boolean,
    ): String? = previousAnchor.takeUnless { replaceTrack } ?: incoming.trackId

    private fun discardMetadataPositionZero(
        incoming: XiaomiMediaInfo,
        fromMetadata: Boolean,
        replaceTrack: Boolean,
        hasProgress: Boolean,
    ): XiaomiMediaInfo = if (fromMetadata && !replaceTrack && incoming.positionMs == 0L && hasProgress) {
        incoming.copy(positionMs = null)
    } else incoming

    private fun mergeMediaInfo(
        previous: XiaomiMediaInfo?,
        incoming: XiaomiMediaInfo,
        replaceTrack: Boolean,
    ): XiaomiMediaInfo {
        if (previous == null || replaceTrack) {
            return incoming
        }
        val keepPreviousTrackId = incoming.trackId == null ||
            (previous.explicitTrackId() != null && incoming.explicitTrackId() == null)
        return incoming.copy(
            trackId = if (keepPreviousTrackId) previous.trackId else incoming.trackId,
            title = incoming.title ?: previous.title,
            artist = incoming.artist ?: previous.artist,
            album = incoming.album ?: previous.album,
            artworkUrl = incoming.artworkUrl ?: previous.artworkUrl,
            durationMs = incoming.durationMs ?: previous.durationMs,
            positionMs = incoming.positionMs ?: previous.positionMs,
            codec = incoming.codec ?: previous.codec,
            bitrateBps = incoming.bitrateBps ?: previous.bitrateBps,
            sampleRate = incoming.sampleRate ?: previous.sampleRate,
            bitsPerSample =
                incoming.bitsPerSample ?: previous.bitsPerSample,
            channels = incoming.channels ?: previous.channels,
            metadataChangeType =
                incoming.metadataChangeType ?: previous.metadataChangeType,
            lyricsText = incoming.lyricsText ?: previous.lyricsText,
            titleIsLyric = incoming.titleIsLyric ?: previous.titleIsLyric.takeIf { incoming.title == null },
            trackIdSource = if (keepPreviousTrackId) previous.trackIdSource else incoming.trackIdSource,
        )
    }

    private fun reconcilePendingSeek(
        incoming: XiaomiMediaInfo,
        replaceTrack: Boolean,
        sessionSequence: Long,
    ): XiaomiMediaInfo {
        val pending = pendingSeek ?: return incoming
        if (
            replaceTrack ||
            pending.sessionSequence != sessionSequence
        ) {
            pendingSeek = null
            return incoming
        }

        val elapsedMs = (nowMillis() - pending.startedAtMs)
            .coerceAtLeast(0L)
        if (elapsedMs >= SEEK_ACKNOWLEDGEMENT_WINDOW_MS) {
            pendingSeek = null
            return incoming
        }

        val position = incoming.positionMs
        if (
            position != null &&
            kotlin.math.abs(position - pending.targetPositionMs) <=
            SEEK_CONFIRMATION_TOLERANCE_MS
        ) {
            pendingSeek = null
            return incoming
        }

        // Dispatch already applied the target once. Missing or rejected
        // samples must not rewind subsequent locally extrapolated playback.
        return if (position == null) incoming else incoming.copy(positionMs = null)
    }

    private data class PendingMediaInfo(
        val sessionSequence: Long,
        val mediaInfo: XiaomiMediaInfo,
        val trackAnchor: String?,
        val replaceTrack: Boolean,
    )

    private data class LyricsEvidence(val document: LyricsDocument?, val metadata: PlaybackDisplayMetadata)

    private data class PendingSeek(
        val sessionSequence: Long,
        val targetPositionMs: Long,
        val startedAtMs: Long,
    )

    private companion object {
        const val SEEK_CONFIRMATION_TOLERANCE_MS = 3_000L
        const val SEEK_ACKNOWLEDGEMENT_WINDOW_MS = 5_000L
    }
}

sealed interface XiaomiPlaybackMutation {
    data class Activate(
        val sessionSequence: Long,
        val sourceName: String?,
        val rawState: Int?,
        val newSession: Boolean,
    ) : XiaomiPlaybackMutation

    data class ApplyMediaInfo(
        val sessionSequence: Long,
        val mediaInfo: XiaomiMediaInfo,
        val replaceTrack: Boolean,
    ) : XiaomiPlaybackMutation

    data class Deactivate(
        val sessionSequence: Long,
    ) : XiaomiPlaybackMutation
}

enum class XiaomiReductionOutcome {
    APPLIED,
    CACHED,
    IGNORED,
}

data class XiaomiReduction(
    val mutations: List<XiaomiPlaybackMutation>,
    val outcome: XiaomiReductionOutcome,
    val reason: String,
    val eventSequence: Long?,
    val sessionSequence: Long?,
) {
    companion object {
        fun ignored(
            reason: String,
            eventSequence: Long?,
            sessionSequence: Long?,
        ) = XiaomiReduction(
            mutations = emptyList(),
            outcome = XiaomiReductionOutcome.IGNORED,
            reason = reason,
            eventSequence = eventSequence,
            sessionSequence = sessionSequence,
        )
    }
}
