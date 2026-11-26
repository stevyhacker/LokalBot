package me.dotenv.lokalbot.companion.data

import android.util.Log
import java.time.Instant
import java.time.ZoneId
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
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
import me.dotenv.lokalbot.sync.RecordingInfo
import me.dotenv.lokalbot.sync.SyncClient
import me.dotenv.lokalbot.sync.SyncException
import me.dotenv.lokalbot.sync.UploadListener
import me.dotenv.lokalbot.sync.keyFingerprint
import me.dotenv.lokalbot.sync.ActionFilter as RustActionFilter

class RustRepository(
    private val client: SyncClient,
    private val discover: suspend (fingerprint: String?) -> List<String>,
    private val onQueuedAnswer: (AskRequest, AskResult) -> Unit = { _, _ -> },
    private val onRevoked: () -> Unit = {},
    private val onRecordingsWaiting: () -> Unit = {},
    private val unpairedStore: UnpairedRecordingsStore? = null,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : CompanionRepository {

    private val scope = CoroutineScope(SupervisorJob() + io)
    private val syncLock = Mutex()

    private val uploadLock = Mutex()

    private val questionsLock = Mutex()

    private val asking: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val macKey: ByteArray? = client.pairedMac()?.macKeyB64?.let(::decodeKey)

    override val id: String = "paired-" + (macKey?.let { keyFingerprint(it) } ?: "unpaired")
    override val isSample: Boolean = client.isSample()

    private val _revision = MutableStateFlow(0L)
    override val revision: StateFlow<Long> = _revision.asStateFlow()

    private val _syncState = MutableStateFlow<SyncState>(SyncState.Idle(statusInfo()))
    override val syncState: StateFlow<SyncState> = _syncState.asStateFlow()

    override val canRecord: Boolean = (!isSample && macKey != null) || unpairedStore != null

    private val _recordings = MutableStateFlow(loadRecordings())
    override val recordings: StateFlow<List<DeviceRecording>> = _recordings.asStateFlow()

    private val _uploadProgress = MutableStateFlow<UploadProgress?>(null)
    override val uploadProgress: StateFlow<UploadProgress?> = _uploadProgress.asStateFlow()

    override fun now(): Instant = Instant.now()

    override fun zone(): ZoneId = ZoneId.systemDefault()

    @Volatile
    private var closed = false

    private suspend fun <T> core(block: () -> T): T = withContext(io) { alive(block) }

    private inline fun <T> alive(block: () -> T): T = try {
        block()
    } catch (e: IllegalStateException) {
        if (closed) throw CancellationException("The library closed.", e) else throw e
    }

    private fun <T> String.decode(serializer: KSerializer<T>): T = RecordJson.decodeFromString(serializer, this)

    override suspend fun manifest(): Manifest? = core { client.manifest()?.let { decodeOrNull(it, Manifest.serializer()) } }

    override suspend fun meetings(fromDay: String?, toDay: String?, limit: Int): List<Meeting> = core {
        decodeAll(client.meetings(fromDay, toDay, limit.toUInt()), Meeting.serializer()).filter { it.mergedInto == null }
    }

    override suspend fun newestMeetings(limit: Int): MeetingsPage = core {
        newestMeetingsPage(client.meetings(null, null, (limit + 1).toUInt()), limit)
    }

    override suspend fun meeting(id: String): Meeting? = core { client.meeting(id)?.let { decodeOrNull(it, Meeting.serializer()) } }

    override suspend fun transcript(meetingId: String): Transcript? = core {
        client.transcript(meetingId)?.let { decodeOrNull(it, Transcript.serializer()) }
    }

    override suspend fun days(limit: Int): List<String> = core { client.days(limit.toUInt()) }

    override suspend fun day(date: String): DayRecord? = core { client.day(date)?.let { decodeOrNull(it, DayRecord.serializer()) } }

    override suspend fun actions(filter: ActionFilter): List<ActionRow> = core {
        val rows = decodeAll(
            client.actions(
                RustActionFilter(
                    mineOnly = filter.mineOnly,
                    status = filter.status?.wireName,
                    ownerUnclearOnly = filter.ownerUnclearOnly,
                    dueBefore = filter.dueBefore,
                ),
            ),
            ActionRow.serializer(),
        )
        if (filter.othersOnly) rows.filter { ActionOrdering.matches(it, filter) } else rows
    }

    override suspend fun people(): List<Person> = core { decodeAll(client.people(), Person.serializer()) }

    override suspend fun person(id: String): Person? = core { client.person(id)?.let { decodeOrNull(it, Person.serializer()) } }

    override suspend fun projects(): List<Project> = core { decodeAll(client.projects(), Project.serializer()) }

    override suspend fun project(id: String): Project? = core { client.project(id)?.let { decodeOrNull(it, Project.serializer()) } }

    override suspend fun search(query: String, limit: Int): List<SearchHit> = core {
        client.search(query, limit.toUInt()).map { hit ->
            SearchHit(
                kind = SearchHitKind.fromCore(hit.kind),
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
        scope.launch { sync() }
    }

    override fun ask(request: AskRequest): Flow<AskEvent> = channelFlow {
        val listener = object : AskListener {
            override fun onDelta(text: String) {
                trySend(AskEvent.Delta(text))
            }
        }
        var revoked = false
        val started = System.nanoTime()
        asking += request.requestId
        val event = try {
            val json = RecordJson.encodeToString(AskRequest.serializer(), request)
            val addresses = discover(fingerprint())
            val result = core { client.ask(json, addresses, listener) }.decode(AskResult.serializer())
            AskEvent.Done(result)
        } catch (e: SyncException.Interrupted) {
            Log.i(TAG, "ask interrupted after ${(System.nanoTime() - started) / 1_000_000_000} s: ${e.message}")
            AskEvent.Interrupted
        } catch (e: SyncException) {
            Log.w(TAG, "ask failed: ${e::class.simpleName}: ${e.message}")
            val reason = failureOf(e)
            revoked = reason == SyncFailure.Revoked
            if (reason == SyncFailure.Unreachable || revoked) {
                _syncState.value = SyncState.Failed(statusInfo(), reason, e.message.orEmpty())
            }
            AskEvent.Failed(e.message.orEmpty(), macUnreachable = reason == SyncFailure.Unreachable)
        } finally {
            asking -= request.requestId
        }
        send(event)
        if (revoked) onRevoked()
    }

    override suspend fun queueQuestion(request: AskRequest) {
        core { client.queueQuestion(RecordJson.encodeToString(AskRequest.serializer(), request)) }
    }

    override suspend fun queuedQuestions(): List<AskRequest> = core {
        decodeAll(client.queuedQuestions(), AskRequest.serializer())
    }

    override suspend fun askHistory(limit: Int): List<AskExchange> = core {
        decodeAll(client.askHistory(limit.toUInt()), AskExchange.serializer())
    }

    override suspend fun sync(): SyncOutcome {
        val outcome = syncLock.withLock {
            _syncState.value = SyncState.Syncing(statusInfo())
            val outcome = try {
                val addresses = discover(fingerprint())
                val report = core { client.sync(addresses) }
                if (report.received > 0u || report.deleted > 0u || report.opsApplied > 0u) changed()
                SyncOutcome.Synced(report.received.toInt(), report.deleted.toInt(), report.address)
            } catch (e: SyncException) {
                Log.w(TAG, "sync failed: ${e::class.simpleName}: ${e.message}")
                SyncOutcome.Failed(failureOf(e), e.message.orEmpty())
            }
            _syncState.value = when (outcome) {
                is SyncOutcome.Synced -> SyncState.Idle(statusInfo())
                is SyncOutcome.Failed -> SyncState.Failed(statusInfo(), outcome.reason, outcome.message)
            }
            refreshRecordings()
            outcome
        }
        if (outcome is SyncOutcome.Synced) {
            scope.launch { uploadRecordings() }
            askQueuedQuestions()
        }
        if (outcome is SyncOutcome.Failed && outcome.reason == SyncFailure.Revoked) onRevoked()
        return outcome
    }

    private suspend fun askQueuedQuestions() = questionsLock.withLock {
        val answered = askHistory(500).map { it.request.requestId }.toSet()
        for (request in queuedQuestions().filter { it.requestId !in answered && it.requestId !in asking }) {
            val addresses = discover(fingerprint())
            if (!asking.add(request.requestId)) continue
            val result = try {
                runCatching {
                    core { client.ask(RecordJson.encodeToString(AskRequest.serializer(), request), addresses, NoDeltas) }
                }.getOrNull()
            } finally {
                asking -= request.requestId
            }
            if (result == null) break
            onQueuedAnswer(request, result.decode(AskResult.serializer()))
            changed()
        }
    }

    override suspend fun beginRecording(title: String?): DeviceRecording? {
        if (macKey == null || isSample) {
            val local = unpairedStore?.beginRecording(title) ?: return null
            recordingsChanged()
            return local
        }
        val recording = try {
            core { client.beginRecording(title) }
        } catch (e: SyncException) {
            Log.w(TAG, "begin recording failed: ${e::class.simpleName}: ${e.message}")
            return null
        }
        recordingsChanged()
        return deviceRecording(recording)
    }

    override suspend fun finishRecording(id: String, durationSeconds: Double): Boolean {
        if (unpairedStore?.contains(id) == true) {
            val kept = unpairedStore.finishRecording(id, durationSeconds)
            recordingsChanged()
            return kept
        }
        val kept = try {
            core { client.finishRecording(id, durationSeconds) }
            true
        } catch (_: SyncException.InvalidInput) {
            false
        }
        recordingsChanged()
        if (kept) sendWaitingRecordings()
        return kept
    }

    override suspend fun recoverRecordings(): Int {
        val keptCore = core { client.recoverRecordings() }.toInt()
        val keptLocal = unpairedStore?.recoverRecordings() ?: 0
        recordingsChanged()
        if (keptCore > 0) sendWaitingRecordings()
        return keptCore + keptLocal
    }

    override suspend fun discardRecording(id: String) {
        if (unpairedStore?.contains(id) == true) {
            unpairedStore.discardRecording(id)
        } else {
            core { client.discardRecording(id) }
        }
        recordingsChanged()
    }

    override suspend fun setRecordingTitle(id: String, title: String) {
        if (unpairedStore?.contains(id) == true) {
            unpairedStore.setRecordingTitle(id, title)
        } else {
            core { client.setRecordingTitle(id, title) }
        }
        recordingsChanged()
    }

    override suspend fun retryRecording(id: String) {
        if (unpairedStore?.contains(id) == true) return
        core { client.retryRecording(id) }
        recordingsChanged()
        sendWaitingRecordings()
    }

    override suspend fun uploadRecordings(): UploadOutcome {
        val outcome = uploadLock.withLock { uploadWaiting() }
        when {
            outcome is UploadOutcome.Finished && outcome.uploaded > 0 -> sync()
            outcome is UploadOutcome.Failed && outcome.reason == SyncFailure.Revoked -> onRevoked()
        }
        return outcome
    }

    private suspend fun uploadWaiting(): UploadOutcome {
        val rows = core { loadRecordings() }
        if (rows.none { it.state == RecordingState.Waiting }) {
            return UploadOutcome.Finished(uploaded = 0, waiting = 0, failed = rows.count { it.state == RecordingState.Failed })
        }
        val listener = object : UploadListener {
            override fun onProgress(recordingId: String, sentBytes: ULong, totalBytes: ULong) {
                if (_uploadProgress.value?.recordingId != recordingId) scope.launch { refreshRecordings() }
                _uploadProgress.value = UploadProgress(recordingId, sentBytes.toLong(), totalBytes.toLong())
            }
        }
        val outcome = try {
            val addresses = discover(fingerprint())
            val report = core { client.uploadRecordings(addresses, listener) }
            UploadOutcome.Finished(report.uploaded.toInt(), report.waiting.toInt(), report.failed.toInt())
        } catch (e: SyncException) {
            Log.w(TAG, "upload failed: ${e::class.simpleName}: ${e.message}")
            UploadOutcome.Failed(failureOf(e), e.message.orEmpty())
        } finally {
            _uploadProgress.value = null
        }
        if (outcome !is UploadOutcome.Failed || outcome.reason != SyncFailure.Revoked) recordingsChanged()
        return outcome
    }

    private fun sendWaitingRecordings() {
        onRecordingsWaiting()
        scope.launch { uploadRecordings() }
    }

    private suspend fun refreshRecordings() {
        _recordings.value = core { loadRecordings() }
    }

    private suspend fun recordingsChanged() {
        refreshRecordings()
        changed()
    }

    private fun loadRecordings(): List<DeviceRecording> {
        val coreRows = runCatching { client.recordings().map(::deviceRecording) }.getOrDefault(emptyList())
        val localRows = unpairedStore?.recordings?.value.orEmpty()
        return (coreRows + localRows).sortedByDescending { it.startedAt }
    }

    private fun deviceRecording(info: RecordingInfo) = DeviceRecording(
        id = info.id,
        title = info.title,
        state = RecordingState.entries.firstOrNull { it.name.equals(info.state, ignoreCase = true) } ?: RecordingState.Waiting,
        startedAt = info.startedAt,
        durationSeconds = info.durationSeconds,
        byteCount = info.byteCount.toLong(),
        sentBytes = info.sentBytes.toLong(),
        message = info.message,
        filePath = info.filePath,
    )

    fun heldAfterRevocation(): Int {
        runCatching { client.recoverRecordings() }
        return runCatching { client.recordings().count { it.state != "uploaded" } }.getOrDefault(0)
    }

    fun unpairAndClose() {
        client.unpair()
        close()
    }

    fun close() {
        closed = true
        scope.cancel()
        client.close()
    }

    private fun changed() = _revision.update { it + 1 }

    private fun fingerprint(): String? = macKey?.let { keyFingerprint(it) }

    private fun statusInfo(): SyncStatusInfo {
        val status = alive { client.status() }
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
        private const val TAG = "LokalBot"

        fun failureOf(e: SyncException): SyncFailure = when (e) {
            is SyncException.Unreachable, is SyncException.Io -> SyncFailure.Unreachable
            is SyncException.Revoked -> SyncFailure.Revoked
            is SyncException.NotPaired -> SyncFailure.NotPaired
            else -> SyncFailure.Other
        }

        fun decodeKey(value: String): ByteArray? =
            runCatching { Base64.getUrlDecoder().decode(value) }.getOrNull()
                ?: runCatching { Base64.getDecoder().decode(value) }.getOrNull()

        internal fun <T> decodeOrNull(json: String, serializer: KSerializer<T>): T? =
            runCatching { RecordJson.decodeFromString(serializer, json) }.getOrNull()

        internal fun <T> decodeAll(rows: List<String>, serializer: KSerializer<T>): List<T> =
            rows.mapNotNull { decodeOrNull(it, serializer) }

        internal fun newestMeetingsPage(rows: List<String>, limit: Int): MeetingsPage =
            MeetingsPage(decodeAll(rows.take(limit), Meeting.serializer()), hasMore = rows.size > limit)
    }
}
