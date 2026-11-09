package me.dotenv.lokalbot.companion.ui.timeline

import androidx.lifecycle.viewModelScope
import java.time.LocalDate
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.model.DayRecord
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.ui.common.LibraryViewModel

data class TimelineState(
    val today: LocalDate,
    val day: LocalDate,
    val record: DayRecord? = null,
    val meetings: List<Meeting> = emptyList(),
    /** Days the Mac shared a record for, newest first. */
    val recordedDays: Set<String> = emptySet(),
    val earliest: LocalDate = today.minusDays(30),
    val loaded: Boolean = false,
)

@OptIn(ExperimentalCoroutinesApi::class)
class TimelineViewModel(repository: CompanionRepository) : LibraryViewModel(repository) {
    private val day = MutableStateFlow(repository.today())

    val state: StateFlow<TimelineState> = combine(repository.revision, day) { _, day -> day }
        .mapLatest { day ->
            val today = repository.today()
            val key = day.toString()
            val days = repository.days()
            val earliestRecorded = days.lastOrNull()?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
            TimelineState(
                today = today,
                day = day,
                record = repository.day(key),
                meetings = repository.meetings(fromDay = key, toDay = key).sortedBy { it.startedAt },
                recordedDays = days.toSet(),
                earliest = listOfNotNull(earliestRecorded, today.minusDays(30)).min(),
                loaded = true,
            )
        }
        .stateIn(viewModelScope, SharingStarted.Eagerly, TimelineState(repository.today(), repository.today()))

    fun select(date: LocalDate) {
        day.value = minOf(date, repository.today())
    }

    fun step(days: Long) = select(day.value.plusDays(days))
}
