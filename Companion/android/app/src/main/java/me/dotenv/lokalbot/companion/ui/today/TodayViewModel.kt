package me.dotenv.lokalbot.companion.ui.today

import androidx.lifecycle.viewModelScope
import java.time.LocalDate
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import me.dotenv.lokalbot.companion.data.ActionFilter
import me.dotenv.lokalbot.companion.data.ActionOrdering
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.SyncState
import me.dotenv.lokalbot.companion.data.model.ActionRow
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.data.model.DayRecord
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.ui.common.LibraryViewModel

data class TodayState(
    val today: LocalDate,
    val needsAttention: List<ActionRow> = emptyList(),
    val openActionCount: Int = 0,
    /** Today's digest, or yesterday's until today's is written. */
    val digestDay: DayRecord? = null,
    val todayRecord: DayRecord? = null,
    val meetings: List<Meeting> = emptyList(),
    val loaded: Boolean = false,
) {
    val digestIsYesterday: Boolean get() = digestDay != null && digestDay.date != today.toString()
}

class TodayViewModel(repository: CompanionRepository) : LibraryViewModel(repository) {

    val state: StateFlow<TodayState> = library(TodayState(repository.today())) { load() }
    val syncState: StateFlow<SyncState> = repository.syncState

    private val _refreshing = MutableStateFlow(false)
    val refreshing: StateFlow<Boolean> = _refreshing.asStateFlow()

    val isSample: Boolean get() = repository.isSample

    fun now() = repository.now()

    private suspend fun load(): TodayState {
        val today = repository.today()
        val key = today.toString()
        val open = repository.actions(ActionFilter(status = ActionStatus.Open))
        val todayRecord = repository.day(key)
        val yesterday = repository.day(today.minusDays(1).toString())
        return TodayState(
            today = today,
            needsAttention = ActionOrdering.needsAttention(open, today, limit = 3),
            openActionCount = open.count { it.action.ownerIsUser },
            digestDay = todayRecord?.takeIf { it.digest != null } ?: yesterday?.takeIf { it.digest != null },
            todayRecord = todayRecord,
            meetings = repository.meetings(fromDay = key, toDay = key).sortedBy { it.startedAt },
            loaded = true,
        )
    }

    fun setStatus(row: ActionRow, status: ActionStatus) {
        viewModelScope.launch { repository.setActionStatus(row.meetingId, row.action.id, status) }
    }

    fun refresh() {
        viewModelScope.launch {
            _refreshing.value = true
            repository.sync()
            _refreshing.value = false
        }
    }
}
