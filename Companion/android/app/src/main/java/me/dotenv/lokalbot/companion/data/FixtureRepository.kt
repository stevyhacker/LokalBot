package me.dotenv.lokalbot.companion.data

import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import me.dotenv.lokalbot.companion.data.model.ActionRow
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.data.model.AskExchange
import me.dotenv.lokalbot.companion.data.model.AskRequest
import me.dotenv.lokalbot.companion.data.model.DayRecord
import me.dotenv.lokalbot.companion.data.model.Manifest
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.model.Person
import me.dotenv.lokalbot.companion.data.model.Project
import me.dotenv.lokalbot.companion.data.model.RecordEnvelope
import me.dotenv.lokalbot.companion.data.model.RecordJson
import me.dotenv.lokalbot.companion.data.model.RecordKind
import me.dotenv.lokalbot.companion.data.model.Transcript

/**
 * The library from record envelopes held in memory: the built-in sample
 * library ("Try it without a Mac"), previews and tests. Status changes stay
 * on this device and show as waiting for the Mac, since there is none.
 */
class FixtureRepository(
    envelopes: List<RecordEnvelope>,
    private val fixedNow: Instant? = null,
    private val streamDelayMillis: Long = 18,
    override val id: String = "sample",
) : CompanionRepository {

    private val lock = Any()
    private val manifest: Manifest?
    private val meetings: Map<String, Meeting>
    private val transcripts: Map<String, Transcript>
    private val days: Map<String, DayRecord>
    private val people: Map<String, Person>
    private val projects: Map<String, Project>
    private val localStatus = mutableMapOf<Pair<String, String>, ActionStatus>()
    private val history = mutableListOf<AskExchange>()
    private val queued = mutableListOf<AskRequest>()
    private val answerer: SampleAnswerer

    init {
        // Keep the highest version of each record and drop tombstones.
        val live = envelopes.groupBy { it.kind to it.key }
            .mapValues { (_, versions) -> versions.maxBy { it.version } }
            .values.filterNot { it.deleted }
        fun <T> decode(kind: String, serializer: KSerializer<T>): Map<String, T> =
            live.filter { it.kind == kind }.associate { it.key to RecordJson.decodeFromJsonElement(serializer, it.body) }
        manifest = decode(RecordKind.MANIFEST, Manifest.serializer()).values.firstOrNull()
        meetings = decode(RecordKind.MEETING, Meeting.serializer())
        transcripts = decode(RecordKind.TRANSCRIPT, Transcript.serializer())
        days = decode(RecordKind.DAY, DayRecord.serializer())
        people = decode(RecordKind.PERSON, Person.serializer())
        projects = decode(RecordKind.PROJECT, Project.serializer())
        answerer = SampleAnswerer(this)
    }

    override val isSample: Boolean = true

    private val _revision = MutableStateFlow(0L)
    override val revision: StateFlow<Long> = _revision.asStateFlow()

    private val _syncState = MutableStateFlow<SyncState>(SyncState.Idle(statusInfo()))
    override val syncState: StateFlow<SyncState> = _syncState.asStateFlow()

    private fun statusInfo() = SyncStatusInfo(
        paired = false,
        macName = manifest?.macName,
        lastSyncAt = null,
        lastAddress = null,
        pendingOps = synchronized(lock) { localStatus.size },
    )

    override fun now(): Instant =
        fixedNow ?: manifest?.generatedAt?.let { runCatching { Instant.parse(it) }.getOrNull() } ?: Instant.now()

    override fun zone(): ZoneId {
        val offset = meetings.values.maxByOrNull { it.startedAt }?.timeZoneOffsetMinutes ?: 0
        return ZoneOffset.ofTotalSeconds(offset * 60)
    }

    override suspend fun manifest(): Manifest? = manifest

    override suspend fun meetings(fromDay: String?, toDay: String?, limit: Int): List<Meeting> =
        meetings.values
            .filter { it.mergedInto == null }
            .filter { fromDay == null || it.day >= fromDay }
            .filter { toDay == null || it.day <= toDay }
            .sortedByDescending { it.startedAt }
            .take(limit)
            .map(::withLocalStatus)

    override suspend fun meeting(id: String): Meeting? = meetings[id]?.let(::withLocalStatus)

    override suspend fun transcript(meetingId: String): Transcript? = transcripts[meetingId]

    override suspend fun days(limit: Int): List<String> = days.keys.sortedDescending().take(limit)

    override suspend fun day(date: String): DayRecord? = days[date]

    override suspend fun actions(filter: ActionFilter): List<ActionRow> {
        val pending = synchronized(lock) { localStatus.keys.toSet() }
        val rows = meetings(limit = Int.MAX_VALUE).flatMap { meeting ->
            meeting.actions.map { action ->
                ActionRow(
                    meetingId = meeting.id,
                    meetingTitle = meeting.title,
                    meetingStartedAt = meeting.startedAt,
                    action = action,
                    pending = (meeting.id to action.id) in pending,
                )
            }
        }
        return ActionOrdering.sorted(rows.filter { ActionOrdering.matches(it, filter) }, today())
    }

    override suspend fun people(): List<Person> = people.values.sortedByDescending { it.lastMetAt ?: "" }

    override suspend fun person(id: String): Person? = people[id]

    override suspend fun projects(): List<Project> = projects.values.sortedByDescending { it.timeThisWeekSeconds }

    override suspend fun project(id: String): Project? = projects[id]

    override suspend fun search(query: String, limit: Int): List<SearchHit> =
        LocalSearch.search(query, meetings(limit = Int.MAX_VALUE), transcripts, days.values.toList(), limit)

    override suspend fun setActionStatus(meetingId: String, actionId: String, status: ActionStatus) {
        val original = meetings[meetingId]?.actions?.firstOrNull { it.id == actionId }?.status
        synchronized(lock) {
            if (status == original) localStatus.remove(meetingId to actionId) else localStatus[meetingId to actionId] = status
        }
        _syncState.value = SyncState.Idle(statusInfo())
        _revision.value += 1
    }

    override fun ask(request: AskRequest): Flow<AskEvent> = flow {
        val result = answerer.answer(request, today())
        val words = result.answer.split(' ')
        words.forEachIndexed { index, word ->
            emit(AskEvent.Delta(if (index == 0) word else " $word"))
            if (streamDelayMillis > 0) delay(streamDelayMillis)
        }
        synchronized(lock) { history.add(0, AskExchange(request, result)) }
        emit(AskEvent.Done(result))
    }

    override suspend fun queueQuestion(request: AskRequest) {
        synchronized(lock) { queued.add(request) }
    }

    override suspend fun queuedQuestions(): List<AskRequest> = synchronized(lock) { queued.toList() }

    override suspend fun askHistory(limit: Int): List<AskExchange> = synchronized(lock) { history.take(limit) }

    /** The sample library has no Mac to reach; syncing just finishes. */
    override suspend fun sync(): SyncOutcome = SyncOutcome.Synced(received = 0, deleted = 0, address = null)

    private fun withLocalStatus(meeting: Meeting): Meeting {
        val overrides = synchronized(lock) { localStatus.filterKeys { it.first == meeting.id } }
        if (overrides.isEmpty()) return meeting
        return meeting.copy(actions = meeting.actions.map { action ->
            overrides[meeting.id to action.id]?.let { action.copy(status = it) } ?: action
        })
    }

    companion object {
        fun fromJson(json: String, fixedNow: Instant? = null, streamDelayMillis: Long = 18): FixtureRepository =
            FixtureRepository(
                RecordJson.decodeFromString(ListSerializer(RecordEnvelope.serializer()), json),
                fixedNow = fixedNow,
                streamDelayMillis = streamDelayMillis,
                id = "sample-" + UUID.nameUUIDFromBytes(json.toByteArray()).toString().take(8),
            )
    }
}
