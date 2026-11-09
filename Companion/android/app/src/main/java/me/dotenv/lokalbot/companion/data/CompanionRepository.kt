package me.dotenv.lokalbot.companion.data

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import me.dotenv.lokalbot.companion.data.model.ActionRow
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.data.model.AskExchange
import me.dotenv.lokalbot.companion.data.model.AskRequest
import me.dotenv.lokalbot.companion.data.model.AskResult
import me.dotenv.lokalbot.companion.data.model.DayRecord
import me.dotenv.lokalbot.companion.data.model.Manifest
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.model.Person
import me.dotenv.lokalbot.companion.data.model.Project
import me.dotenv.lokalbot.companion.data.model.Transcript

/**
 * The phone's copy of the Mac's shared library, mirroring the `SyncClient`
 * API in Companion/protocol/ffi.md. Lists are newest first.
 */
interface CompanionRepository {
    /** Identifies this library; view models are scoped to it. */
    val id: String

    val isSample: Boolean

    /** Increases whenever the stored records change. */
    val revision: StateFlow<Long>

    val syncState: StateFlow<SyncState>

    /** "Now" for this library: the sample library is pinned to its own day. */
    fun now(): Instant

    /** The zone the Mac's calendar days are in. */
    fun zone(): ZoneId

    fun today(): LocalDate = now().atZone(zone()).toLocalDate()

    suspend fun manifest(): Manifest?
    suspend fun meetings(fromDay: String? = null, toDay: String? = null, limit: Int = 1000): List<Meeting>
    suspend fun meeting(id: String): Meeting?
    suspend fun transcript(meetingId: String): Transcript?
    suspend fun days(limit: Int = 1000): List<String>
    suspend fun day(date: String): DayRecord?
    suspend fun actions(filter: ActionFilter): List<ActionRow>
    suspend fun people(): List<Person>
    suspend fun person(id: String): Person?
    suspend fun projects(): List<Project>
    suspend fun project(id: String): Project?
    suspend fun search(query: String, limit: Int = 40): List<SearchHit>

    /** Queues `action.setStatus` for the Mac and shows it locally as pending. */
    suspend fun setActionStatus(meetingId: String, actionId: String, status: ActionStatus)

    /**
     * Streams the Mac's answer. Ends with [AskEvent.Done], [AskEvent.Failed] or
     * [AskEvent.Interrupted]. Asking the same request again after an
     * interruption picks the answer up; its first delta is the text so far.
     */
    fun ask(request: AskRequest): Flow<AskEvent>
    suspend fun queueQuestion(request: AskRequest)
    suspend fun queuedQuestions(): List<AskRequest>
    suspend fun askHistory(limit: Int = 100): List<AskExchange>

    /** Connects to the Mac, sends queued changes and catches up. */
    suspend fun sync(): SyncOutcome

    /** Whether recordings can start here: they need a paired computer to go to. */
    val canRecord: Boolean

    /** Recordings on this device or just sent, newest first. */
    val recordings: StateFlow<List<DeviceRecording>>

    /** How far the recording being sent right now has got. */
    val uploadProgress: StateFlow<UploadProgress?>

    /** Adds a recording and says where the recorder writes; null when this library can't record. */
    suspend fun beginRecording(title: String? = null): DeviceRecording?

    /** The recorder stopped, so it can go. False when the file was empty, which leaves no recording. */
    suspend fun finishRecording(id: String, durationSeconds: Double): Boolean

    /** Keeps what an app that died while recording wrote. Never call it while recording. Returns how many. */
    suspend fun recoverRecordings(): Int

    /** Deletes the recording and its file, whatever its state. */
    suspend fun discardRecording(id: String)

    suspend fun setRecordingTitle(id: String, title: String)

    /** A recording the computer refused goes round again. */
    suspend fun retryRecording(id: String)

    /** Sends every waiting recording; when any arrive, syncs so their meetings do too. */
    suspend fun uploadRecordings(): UploadOutcome
}

data class ActionFilter(
    val mineOnly: Boolean = false,
    val othersOnly: Boolean = false,
    val ownerUnclearOnly: Boolean = false,
    val status: ActionStatus? = ActionStatus.Open,
    val dueBefore: String? = null,
)

enum class RecordingState { Recording, Waiting, Failed, Uploaded }

/** A recording on this device or just sent (`RecordingInfo` in Companion/protocol/ffi.md). */
data class DeviceRecording(
    val id: String,
    /** Empty until the person names it; the computer then picks one. */
    val title: String,
    val state: RecordingState,
    val startedAt: String,
    val durationSeconds: Double? = null,
    val byteCount: Long = 0,
    val sentBytes: Long = 0,
    /** What's holding it up, or what went wrong. */
    val message: String? = null,
    val filePath: String = "",
)

data class UploadProgress(val recordingId: String, val sentBytes: Long, val totalBytes: Long)

sealed interface UploadOutcome {
    data class Finished(val uploaded: Int, val waiting: Int, val failed: Int) : UploadOutcome
    data class Failed(val reason: SyncFailure, val message: String) : UploadOutcome
}

enum class SearchHitKind { Meeting, Action, Decision, Transcript, Digest }

data class SearchHit(
    val kind: SearchHitKind,
    val key: String,
    val meetingId: String?,
    val title: String,
    val snippet: String,
    val at: Double? = null,
    val date: String? = null,
)

/** How this device last reached the Mac. */
enum class MacRoute { Wifi, Tailscale }

data class SyncStatusInfo(
    val paired: Boolean,
    val macName: String?,
    val lastSyncAt: Instant?,
    val lastAddress: String?,
    val pendingOps: Int,
) {
    val route: MacRoute? get() = lastAddress?.let(::routeForAddress)
}

sealed interface SyncState {
    val status: SyncStatusInfo

    data class Idle(override val status: SyncStatusInfo) : SyncState
    data class Syncing(override val status: SyncStatusInfo) : SyncState
    data class Failed(override val status: SyncStatusInfo, val reason: SyncFailure, val message: String) : SyncState
}

enum class SyncFailure { Unreachable, Revoked, NotPaired, Other }

sealed interface SyncOutcome {
    data class Synced(val received: Int, val deleted: Int, val address: String?) : SyncOutcome
    data class Failed(val reason: SyncFailure, val message: String) : SyncOutcome
}

sealed interface AskEvent {
    data class Delta(val text: String) : AskEvent
    data class Done(val result: AskResult) : AskEvent
    data class Failed(val message: String, val macUnreachable: Boolean) : AskEvent

    /** The connection dropped after the Mac had the question; it keeps answering and the question is queued. */
    data object Interrupted : AskEvent
}

/** Tailscale's CGNAT and ULA ranges and MagicDNS names; everything else is the local network. */
fun routeForAddress(address: String): MacRoute {
    val host = hostOf(address).lowercase()
    if (host.endsWith(".ts.net")) return MacRoute.Tailscale
    if (host.startsWith("fd7a:115c:a1e0:")) return MacRoute.Tailscale
    val octets = host.split('.').mapNotNull { it.toIntOrNull() }
    if (octets.size == 4 && octets[0] == 100 && octets[1] in 64..127) return MacRoute.Tailscale
    return MacRoute.Wifi
}

/** "host:port", "[v6]:port" or a bare host. */
fun hostOf(address: String): String = when {
    address.startsWith("[") -> address.substringAfter('[').substringBefore(']')
    address.count { it == ':' } == 1 -> address.substringBefore(':')
    else -> address
}
