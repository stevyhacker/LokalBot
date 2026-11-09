package me.dotenv.lokalbot.companion.data

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.runBlocking
import me.dotenv.lokalbot.companion.TestLibrary
import me.dotenv.lokalbot.companion.data.model.ActionRow
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.data.model.MeetingAction
import org.junit.Test

class ActionOrderingTest {
    private val today = TestLibrary.today
    private val repository = TestLibrary.repository()

    private fun day(offset: Long) = today.plusDays(offset).toString()

    private fun started(offset: Long) = today.plusDays(offset).atTime(9, 0).toInstant(TestLibrary.zone).toString()

    private fun row(id: String, due: String?, started: String, status: ActionStatus = ActionStatus.Open, mine: Boolean = true) = ActionRow(
        meetingId = "m-$id",
        meetingTitle = "Meeting $id",
        meetingStartedAt = started,
        action = MeetingAction(id = id, text = id, ownerIsUser = mine, dueDate = due, status = status),
    )

    @Test
    fun `overdue first, then by due date, undated last, ties newest meeting first`() {
        val rows = listOf(
            row("undated-old", null, started(-30)),
            row("later", day(20), started(0)),
            row("soon-old", day(3), started(-10)),
            row("soon-new", day(3), started(-1)),
            row("overdue", day(-1), started(-28)),
            row("undated-new", null, started(-2)),
        )
        assertThat(ActionOrdering.sorted(rows, today).map { it.action.id })
            .containsExactly("overdue", "soon-new", "soon-old", "later", "undated-new", "undated-old").inOrder()
    }

    @Test
    fun `done actions are never overdue`() {
        val done = MeetingAction(id = "a", text = "a", dueDate = day(-30), status = ActionStatus.Done)
        assertThat(ActionOrdering.isOverdue(done, today)).isFalse()
        assertThat(ActionOrdering.isOverdue(done.copy(status = ActionStatus.Open), today)).isTrue()
        assertThat(ActionOrdering.isOverdue(done.copy(status = ActionStatus.Open, dueDate = day(0)), today)).isFalse()
    }

    @Test
    fun `filters by owner and status on the sample library`(): Unit = runBlocking {
        fun ids(filter: ActionFilter) = runBlocking { repository.actions(filter).map { it.action.id } }
        assertThat(ids(ActionFilter(mineOnly = true))).containsExactly("act-1f2e3d4c", "act-7c1e40a2", "act-4d2c9e07").inOrder()
        assertThat(ids(ActionFilter(othersOnly = true))).containsExactly("act-a3f61b28", "act-c40f8d62", "act-e2a7c915").inOrder()
        assertThat(ids(ActionFilter(ownerUnclearOnly = true))).containsExactly("act-91b0d3f5")
        assertThat(ids(ActionFilter(status = ActionStatus.Done))).containsExactly("act-0e5d77c3", "act-58ab2e19", "act-6b3d0f44").inOrder()
        assertThat(ids(ActionFilter(status = ActionStatus.Deferred))).isEmpty()
        // Due before the Northwind follow-up: the overdue deck, the export PR, the pricing tiers.
        assertThat(ids(ActionFilter(status = null, dueBefore = TestLibrary.dueDate("act-4d2c9e07"))))
            .containsExactly("act-1f2e3d4c", "act-7c1e40a2", "act-a3f61b28").inOrder()
    }

    @Test
    fun `groups overdue, this week, later, undated and closed`(): Unit = runBlocking {
        val rows = repository.actions(ActionFilter(status = null))
        val groups = ActionOrdering.grouped(rows, today).associate { (group, items) -> group to items.map { it.action.id } }
        assertThat(groups.keys).containsExactly(
            ActionOrdering.Group.Overdue, ActionOrdering.Group.ThisWeek, ActionOrdering.Group.NoDate, ActionOrdering.Group.Closed,
        ).inOrder()
        assertThat(groups[ActionOrdering.Group.Overdue]).containsExactly("act-1f2e3d4c")
        assertThat(groups[ActionOrdering.Group.ThisWeek]).hasSize(5)
        assertThat(groups[ActionOrdering.Group.NoDate]).containsExactly("act-91b0d3f5")
    }

    @Test
    fun `needs attention lists your open actions, overdue first`(): Unit = runBlocking {
        val open = repository.actions(ActionFilter(status = ActionStatus.Open))
        assertThat(ActionOrdering.needsAttention(open, today, limit = 2).map { it.action.id })
            .containsExactly("act-1f2e3d4c", "act-7c1e40a2").inOrder()
    }
}
