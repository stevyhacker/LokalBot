package me.dotenv.lokalbot.companion.ui.meetings

import androidx.lifecycle.viewModelScope
import java.time.LocalDate
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.LocalSearch
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.model.Transcript
import me.dotenv.lokalbot.companion.ui.common.LibraryViewModel
import me.dotenv.lokalbot.companion.ui.recording.RecordingRowState
import me.dotenv.lokalbot.companion.ui.recording.recordingStatus

data class MeetingDay(val day: String, val meetings: List<Meeting>)

data class MeetingsState(
    val today: LocalDate,
    val days: List<MeetingDay> = emptyList(),
    val total: Int = 0,
    val hasMore: Boolean = false,
    val listed: Int = MeetingsViewModel.PAGE,
    val loaded: Boolean = false,
)

@OptIn(ExperimentalCoroutinesApi::class)
class MeetingsViewModel(repository: CompanionRepository) : LibraryViewModel(repository) {
    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()

    private val listed = MutableStateFlow(PAGE)

    private var searched: Pair<Long, List<Meeting>>? = null

    val state: StateFlow<MeetingsState> = combine(repository.revision, _query, listed, ::Request)
        .mapLatest(::load)
        .stateIn(viewModelScope, SharingStarted.Eagerly, MeetingsState(repository.today()))

    val recordings: StateFlow<List<RecordingRowState>> = combine(
        repository.recordings,
        repository.uploadProgress,
        repository.revision.mapLatest { repository.manifest()?.recordingsEnabled == false },
    ) { recordings, progress, turnedOff ->
        recordings.map { RecordingRowState(it, recordingStatus(it, progress, turnedOff)) }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    val computerName: StateFlow<String?> = repository.syncState.map { it.status.macName }.distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.Eagerly, repository.syncState.value.status.macName)

    fun setQuery(value: String) {
        _query.value = value
    }

    fun showMore() {
        val current = state.value
        if (current.hasMore) listed.value = current.listed + PAGE
    }

    fun retryRecording(id: String) {
        viewModelScope.launch { repository.retryRecording(id) }
    }

    fun deleteRecording(id: String) {
        viewModelScope.launch { repository.discardRecording(id) }
    }

    fun renameRecording(id: String, title: String) {
        viewModelScope.launch { repository.setRecordingTitle(id, title) }
    }

    private suspend fun load(request: Request): MeetingsState {
        val query = request.query
        if (query.isBlank()) {
            searched = null
            val page = repository.newestMeetings(request.listed)
            return showing(page.meetings, total = page.meetings.size, request).copy(hasMore = page.hasMore)
        }
        val all = searched?.takeIf { it.first == request.revision }?.second
            ?: repository.meetings(limit = Int.MAX_VALUE).map(::forListing).also { searched = request.revision to it }
        val terms = LocalSearch.terms(query)
        val hitIds = repository.search(query, limit = 200).mapNotNull { it.meetingId }.toSet()
        val found = all.filter { meeting ->
            val haystack = LocalSearch.fold(
                listOfNotNull(meeting.title, meeting.appName).plus(meeting.people.map { it.displayName })
                    .plus(meeting.projects.map { it.name }).joinToString(" "),
            )
            meeting.id in hitIds || terms.all { haystack.contains(it) }
        }
        return showing(found, total = all.size, request)
    }

    private fun showing(shown: List<Meeting>, total: Int, request: Request) = MeetingsState(
        today = repository.today(),
        days = shown.groupBy { it.day }.map { (day, meetings) -> MeetingDay(day, meetings) },
        total = total,
        listed = request.listed,
        loaded = true,
    )

    private fun forListing(meeting: Meeting) = meeting.copy(
        summaryMarkdown = null,
        notesMarkdown = null,
        actions = emptyList(),
        decisions = emptyList(),
        openQuestions = emptyList(),
    )

    private data class Request(val revision: Long, val query: String, val listed: Int)

    companion object {
        const val PAGE = 1000
    }
}

data class MeetingDetailState(
    val today: LocalDate,
    val meeting: Meeting? = null,
    val transcript: Transcript? = null,
    val pendingActionIds: Set<String> = emptySet(),
    val loaded: Boolean = false,
)

class MeetingDetailViewModel(repository: CompanionRepository, private val meetingId: String) : LibraryViewModel(repository) {

    val state: StateFlow<MeetingDetailState> = library(MeetingDetailState(repository.today())) {
        val meeting = repository.meeting(meetingId)
        MeetingDetailState(
            today = repository.today(),
            meeting = meeting,
            transcript = if (meeting?.hasTranscript == true) repository.transcript(meetingId) else null,
            pendingActionIds = meeting?.actions.orEmpty().filter { it.pending }.map { it.id }.toSet(),
            loaded = true,
        )
    }

    fun setStatus(actionId: String, status: ActionStatus) {
        viewModelScope.launch { repository.setActionStatus(meetingId, actionId, status) }
    }
}
