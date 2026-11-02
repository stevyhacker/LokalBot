package me.dotenv.lokalbot.companion.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

// Companion records, schema version 1 (Companion/protocol/records.md).
// Optional fields are omitted by the Mac, never null, so every optional
// property has a default. Unknown keys and enum values are ignored.

val RecordJson = Json {
    ignoreUnknownKeys = true
    coerceInputValues = true
    explicitNulls = false
    encodeDefaults = true
}

@Serializable
data class RecordEnvelope(
    val kind: String,
    val key: String,
    val version: Long = 0,
    val seq: Long = 0,
    val deleted: Boolean = false,
    val sortKey: String? = null,
    val body: JsonObject = JsonObject(emptyMap()),
)

object RecordKind {
    const val MANIFEST = "manifest"
    const val MEETING = "meeting"
    const val TRANSCRIPT = "transcript"
    const val DAY = "day"
    const val PERSON = "person"
    const val PROJECT = "project"
}

@Serializable
data class Manifest(
    val schemaVersion: Int = 1,
    val libraryName: String = "",
    val macName: String = "",
    val dataClasses: DataClasses = DataClasses(),
    val historyDays: Int = 0,
    val askEnabled: Boolean = false,
    val generatedAt: String? = null,
)

@Serializable
data class DataClasses(
    val meetings: Boolean = false,
    val transcripts: Boolean = false,
    val digests: Boolean = false,
    val timeline: Boolean = false,
    val windowTitles: Boolean = false,
    val people: Boolean = false,
    val projects: Boolean = false,
)

@Serializable
data class PersonRef(val id: String, val displayName: String)

@Serializable
data class ProjectRef(val id: String, val name: String)

@Serializable
enum class ActionStatus {
    @SerialName("open") Open,
    @SerialName("done") Done,
    @SerialName("deferred") Deferred;

    val wireName: String get() = name.lowercase()

    companion object {
        fun fromWire(value: String?): ActionStatus? = entries.firstOrNull { it.wireName == value }
    }
}

@Serializable
data class Citation(
    val start: Double = 0.0,
    val end: Double = 0.0,
    val speaker: String? = null,
    val excerpt: String = "",
)

@Serializable
data class MeetingAction(
    val id: String,
    val text: String,
    val owner: String? = null,
    val ownerIsUser: Boolean = false,
    val ownerUnclear: Boolean = false,
    val dueDate: String? = null,
    val dueText: String? = null,
    val status: ActionStatus = ActionStatus.Open,
    val importance: Int = 3,
    val citations: List<Citation> = emptyList(),
)

/** A decision or an open question. */
@Serializable
data class Outcome(
    val id: String,
    val text: String,
    val citations: List<Citation> = emptyList(),
)

@Serializable
data class Meeting(
    val id: String,
    val title: String,
    val startedAt: String,
    val endedAt: String? = null,
    val day: String,
    val timeZoneOffsetMinutes: Int = 0,
    val durationSeconds: Double = 0.0,
    val appName: String? = null,
    val people: List<PersonRef> = emptyList(),
    val projects: List<ProjectRef> = emptyList(),
    val summaryMarkdown: String? = null,
    val notesMarkdown: String? = null,
    val actions: List<MeetingAction> = emptyList(),
    val decisions: List<Outcome> = emptyList(),
    val openQuestions: List<Outcome> = emptyList(),
    val hasTranscript: Boolean = false,
    val mergedInto: String? = null,
)

@Serializable
data class TranscriptSegment(
    val start: Double,
    val end: Double = start,
    val speaker: String = "",
    val colorIndex: Int = -1,
    val text: String,
)

@Serializable
data class Transcript(
    val meetingId: String,
    val segments: List<TranscriptSegment> = emptyList(),
)

@Serializable
data class DigestSections(
    val highlights: List<String> = emptyList(),
    val decisions: List<String> = emptyList(),
    val tasks: List<String> = emptyList(),
    val blockers: List<String> = emptyList(),
    val followUps: List<String> = emptyList(),
) {
    val isEmpty: Boolean
        get() = highlights.isEmpty() && decisions.isEmpty() && tasks.isEmpty() && blockers.isEmpty() && followUps.isEmpty()
}

@Serializable
data class Digest(
    val markdown: String = "",
    val generatedAt: String? = null,
    val userEdited: Boolean = false,
    val sections: DigestSections = DigestSections(),
)

@Serializable
enum class SessionKind {
    @SerialName("work") Work,
    @SerialName("meeting") Meeting,
    @SerialName("agent") Agent,
}

@Serializable
data class NamedDuration(val name: String, val seconds: Double = 0.0)

@Serializable
data class WorkSession(
    val start: String,
    val end: String,
    val title: String = "",
    val kind: SessionKind = SessionKind.Work,
    val meetingId: String? = null,
    val project: String? = null,
    val apps: List<NamedDuration> = emptyList(),
    val windowTitles: List<String> = emptyList(),
)

@Serializable
data class SavedMoment(val at: String, val label: String = "")

@Serializable
data class DayTimeline(
    val trackedSeconds: Double = 0.0,
    val sessions: List<WorkSession> = emptyList(),
    val byProject: List<NamedDuration> = emptyList(),
    val byApp: List<NamedDuration> = emptyList(),
    val savedMoments: List<SavedMoment> = emptyList(),
)

@Serializable
data class DayRecord(
    val date: String,
    val digest: Digest? = null,
    val timeline: DayTimeline? = null,
    val meetingIds: List<String> = emptyList(),
)

@Serializable
data class OpenWork(
    val meetingId: String,
    val actionId: String,
    val text: String,
    val dueDate: String? = null,
    val theirs: Boolean = false,
)

/** A decision attributed to a meeting, as listed on people and projects. */
@Serializable
data class MeetingNote(val meetingId: String, val text: String)

@Serializable
data class Person(
    val id: String,
    val displayName: String,
    val lastMetAt: String? = null,
    val openWork: List<OpenWork> = emptyList(),
    val decisionsTogether: List<MeetingNote> = emptyList(),
    val meetingIds: List<String> = emptyList(),
)

@Serializable
data class ProjectAction(
    val meetingId: String,
    val actionId: String,
    val text: String,
    val dueDate: String? = null,
    val status: ActionStatus = ActionStatus.Open,
)

@Serializable
data class WaitingItem(
    val meetingId: String,
    val actionId: String,
    val text: String,
    val owner: String? = null,
    val dueDate: String? = null,
)

@Serializable
data class Project(
    val id: String,
    val name: String,
    val whereItStands: String? = null,
    val yourActions: List<ProjectAction> = emptyList(),
    val waitingOnOthers: List<WaitingItem> = emptyList(),
    val decisions: List<MeetingNote> = emptyList(),
    val timeThisWeekSeconds: Double = 0.0,
    val people: List<PersonRef> = emptyList(),
    val meetingIds: List<String> = emptyList(),
)

/** An action with its meeting, as returned by `SyncClient.actions` (ffi.md). */
@Serializable
data class ActionRow(
    val meetingId: String,
    val meetingTitle: String,
    val meetingStartedAt: String,
    val action: MeetingAction,
    val pending: Boolean = false,
)

@Serializable
data class AskTurn(val role: String, val text: String)

@Serializable
data class AskScope(val day: String? = null, val meetingId: String? = null)

@Serializable
data class AskRequest(
    val requestId: String,
    val conversationId: String,
    val question: String,
    val history: List<AskTurn> = emptyList(),
    val scope: AskScope? = null,
)

@Serializable
enum class AnswerLocation {
    @SerialName("mac") Mac,
    @SerialName("remote") Remote,
}

@Serializable
data class AskCitation(
    val index: Int,
    val meetingId: String? = null,
    val at: Double? = null,
    val label: String = "",
)

@Serializable
data class AskResult(
    val requestId: String,
    val answer: String,
    val citations: List<AskCitation> = emptyList(),
    val engineLabel: String? = null,
    val location: AnswerLocation = AnswerLocation.Mac,
    val answeredAt: String? = null,
)

@Serializable
data class AskExchange(val request: AskRequest, val result: AskResult)
