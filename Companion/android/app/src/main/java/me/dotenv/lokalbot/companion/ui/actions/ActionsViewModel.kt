package me.dotenv.lokalbot.companion.ui.actions

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
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import me.dotenv.lokalbot.companion.data.ActionFilter
import me.dotenv.lokalbot.companion.data.ActionOrdering
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.model.ActionRow
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.data.model.MeetingAction
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.ui.common.LibraryViewModel

/** Whose actions to show. */
enum class OwnerFilter { Everyone, Mine, Others, Unclear }

data class ActionFilters(val owner: OwnerFilter = OwnerFilter.Mine, val status: ActionStatus? = ActionStatus.Open) {
    fun toRepositoryFilter() = ActionFilter(
        mineOnly = owner == OwnerFilter.Mine,
        othersOnly = owner == OwnerFilter.Others,
        ownerUnclearOnly = owner == OwnerFilter.Unclear,
        status = status,
    )
}

data class ActionsState(
    val today: LocalDate,
    val filters: ActionFilters = ActionFilters(),
    val groups: List<Pair<ActionOrdering.Group, List<ActionRow>>> = emptyList(),
    val count: Int = 0,
    val loaded: Boolean = false,
)

@OptIn(ExperimentalCoroutinesApi::class)
class ActionsViewModel(repository: CompanionRepository) : LibraryViewModel(repository) {
    private val filters = MutableStateFlow(ActionFilters())

    val state: StateFlow<ActionsState> = combine(repository.revision, filters) { _, filters -> filters }
        .mapLatest { filters ->
            val today = repository.today()
            val rows = repository.actions(filters.toRepositoryFilter()).filter { ActionOrdering.matches(it, filters.toRepositoryFilter()) }
            ActionsState(today, filters, ActionOrdering.grouped(rows, today), rows.size, loaded = true)
        }
        .stateIn(viewModelScope, SharingStarted.Eagerly, ActionsState(repository.today()))

    fun setOwner(owner: OwnerFilter) = filters.update { it.copy(owner = if (it.owner == owner) OwnerFilter.Everyone else owner) }

    fun setStatus(status: ActionStatus) = filters.update { it.copy(status = if (it.status == status) null else status) }

    fun setActionStatus(row: ActionRow, status: ActionStatus) {
        viewModelScope.launch { repository.setActionStatus(row.meetingId, row.action.id, status) }
    }
}

data class ActionDetailState(
    val today: LocalDate,
    val meeting: Meeting? = null,
    val action: MeetingAction? = null,
    val pending: Boolean = false,
    val hasTranscript: Boolean = false,
    val loaded: Boolean = false,
)

class ActionDetailViewModel(
    repository: CompanionRepository,
    private val meetingId: String,
    private val actionId: String,
) : LibraryViewModel(repository) {

    val state: StateFlow<ActionDetailState> = library(ActionDetailState(repository.today())) {
        val meeting = repository.meeting(meetingId)
        val row = repository.actions(ActionFilter(status = null)).firstOrNull { it.meetingId == meetingId && it.action.id == actionId }
        ActionDetailState(
            today = repository.today(),
            meeting = meeting,
            action = row?.action ?: meeting?.actions?.firstOrNull { it.id == actionId },
            pending = row?.pending == true,
            hasTranscript = meeting?.hasTranscript == true,
            loaded = true,
        )
    }

    fun setStatus(status: ActionStatus) {
        viewModelScope.launch { repository.setActionStatus(meetingId, actionId, status) }
    }
}
