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

    /** Streams the Mac's answer. Ends with [AskEvent.Done] or [AskEvent.Failed]. */
    fun ask(request: AskRequest): Flow<AskEvent>
    suspend fun queueQuestion(request: AskRequest)
    suspend fun queuedQuestions(): List<AskRequest>
    suspend fun askHistory(limit: Int = 100): List<AskExchange>

    /** Connects to the Mac, sends queued changes and catches up. */
    suspend fun sync(): SyncOutcome
}

data class ActionFilter(
    val mineOnly: Boolean = false,
    val othersOnly: Boolean = false,
    val ownerUnclearOnly: Boolean = false,
    val status: ActionStatus? = ActionStatus.Open,
    val dueBefore: String? = null,
)

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
