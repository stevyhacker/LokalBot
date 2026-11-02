package me.dotenv.lokalbot.companion.data

import java.time.LocalDate
import me.dotenv.lokalbot.companion.data.model.ActionRow
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.data.model.MeetingAction

/** Action ordering and filters shared by every screen (ffi.md, `ActionRow`). */
object ActionOrdering {

    fun isOverdue(action: MeetingAction, today: LocalDate): Boolean {
        if (action.status != ActionStatus.Open) return false
        val due = action.dueDate?.let(::parseDayOrNull) ?: return false
        return due.isBefore(today)
    }

    /** Overdue first, then by due date (none last), then the newest meeting first. */
    fun sorted(rows: List<ActionRow>, today: LocalDate): List<ActionRow> = rows.sortedWith(
        compareBy<ActionRow> { if (isOverdue(it.action, today)) 0 else 1 }
            .thenBy { it.action.dueDate == null }
            .thenBy { it.action.dueDate ?: "" }
            .thenByDescending { it.meetingStartedAt },
    )

    fun matches(row: ActionRow, filter: ActionFilter): Boolean {
        val action = row.action
        if (filter.status != null && action.status != filter.status) return false
        if (filter.mineOnly && !action.ownerIsUser) return false
        if (filter.othersOnly && (action.ownerIsUser || action.ownerUnclear)) return false
        if (filter.ownerUnclearOnly && !action.ownerUnclear) return false
        if (filter.dueBefore != null) {
            val due = action.dueDate ?: return false
            if (due >= filter.dueBefore) return false
        }
        return true
    }

    enum class Group { Overdue, ThisWeek, Later, NoDate, Closed }

    /** Sections for the Actions list: overdue, due within a week, later, undated, then closed. */
    fun grouped(rows: List<ActionRow>, today: LocalDate): List<Pair<Group, List<ActionRow>>> {
        val weekEnd = today.plusDays(7)
        return sorted(rows, today).groupBy { row ->
            val action = row.action
            val due = action.dueDate?.let(::parseDayOrNull)
            when {
                action.status != ActionStatus.Open -> Group.Closed
                isOverdue(action, today) -> Group.Overdue
                due == null -> Group.NoDate
                !due.isAfter(weekEnd) -> Group.ThisWeek
                else -> Group.Later
            }
        }.toList().sortedBy { it.first.ordinal }
    }

    /** Today's "Needs attention": your open actions, as on the Mac. */
    fun needsAttention(rows: List<ActionRow>, today: LocalDate, limit: Int = 3): List<ActionRow> =
        sorted(rows.filter { it.action.status == ActionStatus.Open && it.action.ownerIsUser }, today)
            .take(limit)
}

fun parseDayOrNull(value: String): LocalDate? = runCatching { LocalDate.parse(value) }.getOrNull()
