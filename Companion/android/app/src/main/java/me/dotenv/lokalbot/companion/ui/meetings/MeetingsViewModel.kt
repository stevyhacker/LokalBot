package me.dotenv.lokalbot.companion.ui.meetings

import androidx.lifecycle.viewModelScope
import java.time.LocalDate
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import me.dotenv.lokalbot.companion.data.ActionFilter
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.LocalSearch
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.model.Transcript
import me.dotenv.lokalbot.companion.ui.common.LibraryViewModel

data class MeetingDay(val day: String, val meetings: List<Meeting>)

data class MeetingsState(
    val today: LocalDate,
    val days: List<MeetingDay> = emptyList(),
    val total: Int = 0,
    val loaded: Boolean = false,
)

@OptIn(ExperimentalCoroutinesApi::class)
class MeetingsViewModel(repository: CompanionRepository) : LibraryViewModel(repository) {
    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()

    val state: StateFlow<MeetingsState> = combine(repository.revision, _query) { _, query -> query }
        .mapLatest(::load)
        .stateIn(viewModelScope, SharingStarted.Eagerly, MeetingsState(repository.today()))

    fun setQuery(value: String) {
        _query.value = value
    }

    private suspend fun load(query: String): MeetingsState {
        val all = repository.meetings()
        val shown = if (query.isBlank()) all else {
            val terms = LocalSearch.terms(query)
            val hitIds = repository.search(query, limit = 200).mapNotNull { it.meetingId }.toSet()
            all.filter { meeting ->
                val haystack = LocalSearch.fold(
                    listOfNotNull(meeting.title, meeting.appName).plus(meeting.people.map { it.displayName })
                        .plus(meeting.projects.map { it.name }).joinToString(" "),
                )
                meeting.id in hitIds || terms.all { haystack.contains(it) }
            }
        }
        return MeetingsState(
            today = repository.today(),
            days = shown.groupBy { it.day }.map { (day, meetings) -> MeetingDay(day, meetings) },
            total = all.size,
            loaded = true,
        )
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
            pendingActionIds = repository.actions(ActionFilter(status = null))
                .filter { it.meetingId == meetingId && it.pending }.map { it.action.id }.toSet(),
            loaded = true,
        )
    }

    fun setStatus(actionId: String, status: ActionStatus) {
        viewModelScope.launch { repository.setActionStatus(meetingId, actionId, status) }
    }
}
