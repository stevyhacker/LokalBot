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

interface CompanionRepository {
    val id: String

    val isSample: Boolean

    val revision: StateFlow<Long>

    val syncState: StateFlow<SyncState>

    fun now(): Instant

    fun zone(): ZoneId

    fun today(): LocalDate = now().atZone(zone()).toLocalDate()

    suspend fun manifest(): Manifest?
    suspend fun meetings(fromDay: String? = null, toDay: String? = null, limit: Int = 1000): List<Meeting>

    suspend fun newestMeetings(limit: Int): MeetingsPage {
        val rows = meetings(limit = limit + 1)
        return MeetingsPage(rows.take(limit), hasMore = rows.size > limit)
    }

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

    suspend fun setActionStatus(meetingId: String, actionId: String, status: ActionStatus)

    fun ask(request: AskRequest): Flow<AskEvent>
    suspend fun queueQuestion(request: AskRequest)
    suspend fun queuedQuestions(): List<AskRequest>
    suspend fun askHistory(limit: Int = 100): List<AskExchange>

    suspend fun sync(): SyncOutcome

    val canRecord: Boolean

    val recordings: StateFlow<List<DeviceRecording>>

    val uploadProgress: StateFlow<UploadProgress?>

    suspend fun beginRecording(title: String? = null): DeviceRecording?

    suspend fun finishRecording(id: String, durationSeconds: Double): Boolean

    suspend fun recoverRecordings(): Int

    suspend fun discardRecording(id: String)

    suspend fun setRecordingTitle(id: String, title: String)

    suspend fun retryRecording(id: String)

    suspend fun uploadRecordings(): UploadOutcome
}

data class MeetingsPage(val meetings: List<Meeting>, val hasMore: Boolean)

suspend fun CompanionRepository.meetingsById(ids: Collection<String>): List<Meeting> =
    ids.distinct().mapNotNull { meeting(it) }.filter { it.mergedInto == null }.sortedByDescending { it.startedAt }

data class ActionFilter(
    val mineOnly: Boolean = false,
    val othersOnly: Boolean = false,
    val ownerUnclearOnly: Boolean = false,
    val status: ActionStatus? = ActionStatus.Open,
    val dueBefore: String? = null,
)

enum class RecordingState { Recording, Waiting, Failed, Uploaded }

data class DeviceRecording(
    val id: String,
    val title: String,
    val state: RecordingState,
    val startedAt: String,
    val durationSeconds: Double? = null,
    val byteCount: Long = 0,
    val sentBytes: Long = 0,
    val message: String? = null,
    val filePath: String = "",
)

data class UploadProgress(val recordingId: String, val sentBytes: Long, val totalBytes: Long)

sealed interface UploadOutcome {
    data class Finished(val uploaded: Int, val waiting: Int, val failed: Int) : UploadOutcome
    data class Failed(val reason: SyncFailure, val message: String) : UploadOutcome
}

enum class SearchHitKind {
    Meeting, Action, Decision, Transcript, Digest;

    companion object {
        fun fromCore(kind: String): SearchHitKind = when (kind) {
            "day" -> Digest
            else -> SearchHitKind.entries.firstOrNull { it.name.equals(kind, ignoreCase = true) } ?: Meeting
        }
    }
}

data class SearchHit(
    val kind: SearchHitKind,
    val key: String,
    val meetingId: String?,
    val title: String,
    val snippet: String,
    val at: Double? = null,
    val date: String? = null,
)

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

    data object Interrupted : AskEvent
}

fun routeForAddress(address: String): MacRoute {
    val host = hostOf(address).lowercase()
    if (host.endsWith(".ts.net")) return MacRoute.Tailscale
    if (host.startsWith("fd7a:115c:a1e0:")) return MacRoute.Tailscale
    val octets = host.split('.').mapNotNull { it.toIntOrNull() }
    if (octets.size == 4 && octets[0] == 100 && octets[1] in 64..127) return MacRoute.Tailscale
    return MacRoute.Wifi
}

fun hostOf(address: String): String = when {
    address.startsWith("[") -> address.substringAfter('[').substringBefore(']')
    address.count { it == ':' } == 1 -> address.substringBefore(':')
    else -> address
}
