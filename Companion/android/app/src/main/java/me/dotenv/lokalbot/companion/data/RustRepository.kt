package me.dotenv.lokalbot.companion.data

import java.time.Instant
import java.time.ZoneId
import java.util.Base64
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
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
import me.dotenv.lokalbot.companion.data.model.RecordJson
import me.dotenv.lokalbot.companion.data.model.Transcript
import me.dotenv.lokalbot.sync.AskListener
import me.dotenv.lokalbot.sync.SyncClient
import me.dotenv.lokalbot.sync.SyncException
import me.dotenv.lokalbot.sync.keyFingerprint
import me.dotenv.lokalbot.sync.ActionFilter as RustActionFilter

/**
 * The synced library: the Rust sync core's store on this device
 * (Companion/protocol/ffi.md). Every call into the core blocks, so they all
 * run on [io]. Bonjour results are passed to each connection.
 */
class RustRepository(
    private val client: SyncClient,
    private val discover: suspend (fingerprint: String?) -> List<String>,
    private val onQueuedAnswer: (AskRequest, AskResult) -> Unit = { _, _ -> },
    /** The Mac removed this device; the core has already erased its copy. */
    private val onRevoked: () -> Unit = {},
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : CompanionRepository {

    private val scope = CoroutineScope(SupervisorJob() + io)
    private val syncLock = Mutex()
    private val macKey: ByteArray? = client.pairedMac()?.macKeyB64?.let(::decodeKey)

    override val id: String = "paired-" + (macKey?.let { keyFingerprint(it) } ?: "unpaired")
    override val isSample: Boolean = client.isSample()

    private val _revision = MutableStateFlow(0L)
    override val revision: StateFlow<Long> = _revision.asStateFlow()

    private val _syncState = MutableStateFlow<SyncState>(SyncState.Idle(statusInfo()))
    override val syncState: StateFlow<SyncState> = _syncState.asStateFlow()

    override fun now(): Instant = Instant.now()

    override fun zone(): ZoneId = ZoneId.systemDefault()

    private suspend fun <T> core(block: () -> T): T = withContext(io) { block() }

    private fun <T> String.decode(serializer: KSerializer<T>): T = RecordJson.decodeFromString(serializer, this)

    override suspend fun manifest(): Manifest? = core { client.manifest()?.decode(Manifest.serializer()) }

    override suspend fun meetings(fromDay: String?, toDay: String?, limit: Int): List<Meeting> = core {
        client.meetings(fromDay, toDay, limit.toUInt()).map { it.decode(Meeting.serializer()) }.filter { it.mergedInto == null }
    }

    override suspend fun meeting(id: String): Meeting? = core { client.meeting(id)?.decode(Meeting.serializer()) }

    override suspend fun transcript(meetingId: String): Transcript? = core { client.transcript(meetingId)?.decode(Transcript.serializer()) }

    override suspend fun days(limit: Int): List<String> = core { client.days(limit.toUInt()) }

    override suspend fun day(date: String): DayRecord? = core { client.day(date)?.decode(DayRecord.serializer()) }

    override suspend fun actions(filter: ActionFilter): List<ActionRow> = core {
        val rows = client.actions(
            RustActionFilter(
                mineOnly = filter.mineOnly,
                status = filter.status?.wireName,
                ownerUnclearOnly = filter.ownerUnclearOnly,
                dueBefore = filter.dueBefore,
            ),
        ).map { it.decode(ActionRow.serializer()) }
        // The core sorts; "others" is a phone-side filter on top.
        if (filter.othersOnly) rows.filter { ActionOrdering.matches(it, filter) } else rows
    }

    override suspend fun people(): List<Person> = core { client.people().map { it.decode(Person.serializer()) } }

    override suspend fun person(id: String): Person? = core { client.person(id)?.decode(Person.serializer()) }

    override suspend fun projects(): List<Project> = core { client.projects().map { it.decode(Project.serializer()) } }

    override suspend fun project(id: String): Project? = core { client.project(id)?.decode(Project.serializer()) }

    override suspend fun search(query: String, limit: Int): List<SearchHit> = core {
        client.search(query, limit.toUInt()).map { hit ->
            SearchHit(
                kind = SearchHitKind.entries.firstOrNull { it.name.equals(hit.kind, ignoreCase = true) } ?: SearchHitKind.Meeting,
                key = hit.key,
                meetingId = hit.meetingId,
                title = hit.title,
                snippet = hit.snippet,
                at = hit.at,
                date = hit.date,
            )
        }
    }

    override suspend fun setActionStatus(meetingId: String, actionId: String, status: ActionStatus) {
        core { client.setActionStatus(meetingId, actionId, status.wireName) }
        changed()
        // Send it now if the Mac is reachable; otherwise it waits in the queue.
        scope.launch { sync() }
    }

    override fun ask(request: AskRequest): Flow<AskEvent> = channelFlow {
        val listener = object : AskListener {
            override fun onDelta(text: String) {
                trySend(AskEvent.Delta(text))
            }
        }
        var revoked = false
        val event = try {
            val json = RecordJson.encodeToString(AskRequest.serializer(), request)
            val addresses = discover(fingerprint())
            val result = core { client.ask(json, addresses, listener) }.decode(AskResult.serializer())
            AskEvent.Done(result)
        } catch (e: SyncException) {
            val reason = failureOf(e)
            revoked = reason == SyncFailure.Revoked
            if (reason == SyncFailure.Unreachable || revoked) {
                _syncState.value = SyncState.Failed(statusInfo(), reason, e.message.orEmpty())
            }
            AskEvent.Failed(e.message.orEmpty(), macUnreachable = reason == SyncFailure.Unreachable)
        }
        // Deltas arrive on the core's thread while ask() blocks; the flow ends with this event.
        send(event)
        if (revoked) onRevoked()
    }

    override suspend fun queueQuestion(request: AskRequest) {
        core { client.queueQuestion(RecordJson.encodeToString(AskRequest.serializer(), request)) }
    }

    override suspend fun queuedQuestions(): List<AskRequest> = core {
        client.queuedQuestions().map { it.decode(AskRequest.serializer()) }
    }

    override suspend fun askHistory(limit: Int): List<AskExchange> = core {
        client.askHistory(limit.toUInt()).map { it.decode(AskExchange.serializer()) }
    }

    override suspend fun sync(): SyncOutcome = syncLock.withLock {
        _syncState.value = SyncState.Syncing(statusInfo())
        val outcome = try {
            val addresses = discover(fingerprint())
            val report = core { client.sync(addresses) }
            if (report.received > 0u || report.deleted > 0u || report.opsApplied > 0u) changed()
            SyncOutcome.Synced(report.received.toInt(), report.deleted.toInt(), report.address)
        } catch (e: SyncException) {
            SyncOutcome.Failed(failureOf(e), e.message.orEmpty())
        }
        _syncState.value = when (outcome) {
            is SyncOutcome.Synced -> SyncState.Idle(statusInfo())
            is SyncOutcome.Failed -> SyncState.Failed(statusInfo(), outcome.reason, outcome.message)
        }
        if (outcome is SyncOutcome.Synced) askQueuedQuestions()
        if (outcome is SyncOutcome.Failed && outcome.reason == SyncFailure.Revoked) onRevoked()
        outcome
    }

    /** Questions asked while the Mac was away: ask them now and announce each answer. */
    private suspend fun askQueuedQuestions() {
        val answered = askHistory(500).map { it.request.requestId }.toSet()
        for (request in queuedQuestions().filter { it.requestId !in answered }) {
            val addresses = discover(fingerprint())
            val result = runCatching {
                core { client.ask(RecordJson.encodeToString(AskRequest.serializer(), request), addresses, NoDeltas) }
            }.getOrNull() ?: break
            onQueuedAnswer(request, result.decode(AskResult.serializer()))
            changed()
        }
    }

    /** Erases the store and the pairing on this device, then closes the core. */
    fun unpairAndClose() {
        client.unpair()
        close()
    }

    fun close() {
        scope.cancel()
        client.close()
    }

    private fun changed() = _revision.update { it + 1 }

    private fun fingerprint(): String? = macKey?.let { keyFingerprint(it) }

    private fun statusInfo(): SyncStatusInfo {
        val status = client.status()
        return SyncStatusInfo(
            paired = status.paired,
            macName = status.macName,
            lastSyncAt = status.lastSyncAt?.let { runCatching { Instant.parse(it) }.getOrNull() },
            lastAddress = status.lastAddress,
            pendingOps = status.pendingOps.toInt(),
        )
    }

    private object NoDeltas : AskListener {
        override fun onDelta(text: String) = Unit
    }

    companion object {
        fun failureOf(e: SyncException): SyncFailure = when (e) {
            is SyncException.Unreachable, is SyncException.Io -> SyncFailure.Unreachable
            is SyncException.Revoked -> SyncFailure.Revoked
            is SyncException.NotPaired -> SyncFailure.NotPaired
            else -> SyncFailure.Other
        }

        /** The Mac's key as stored at pairing: base64url (the QR form) or standard base64. */
        fun decodeKey(value: String): ByteArray? =
            runCatching { Base64.getUrlDecoder().decode(value) }.getOrNull()
                ?: runCatching { Base64.getDecoder().decode(value) }.getOrNull()
    }
}
