package me.dotenv.lokalbot.companion.ui.meetings

import com.google.common.truth.Truth.assertThat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.jsonObject
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.FixtureRepository
import me.dotenv.lokalbot.companion.data.MeetingsPage
import me.dotenv.lokalbot.companion.data.model.DayRecord
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.model.Person
import me.dotenv.lokalbot.companion.data.model.PersonRef
import me.dotenv.lokalbot.companion.data.model.Project
import me.dotenv.lokalbot.companion.data.model.ProjectRef
import me.dotenv.lokalbot.companion.data.model.RecordEnvelope
import me.dotenv.lokalbot.companion.data.model.RecordJson
import me.dotenv.lokalbot.companion.data.model.RecordKind
import me.dotenv.lokalbot.companion.ui.people.PersonViewModel
import me.dotenv.lokalbot.companion.ui.projects.ProjectViewModel
import me.dotenv.lokalbot.companion.ui.timeline.TimelineViewModel
import org.junit.After
import org.junit.Before
import org.junit.Test

/** A library with more meetings than the Meetings list loads at once. */
@OptIn(ExperimentalCoroutinesApi::class)
class LongHistoryTest {
    private lateinit var repository: FixtureRepository

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        repository = FixtureRepository(envelopes(), fixedNow = FIRST.plusSeconds(COUNT * SPACING))
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    private fun MeetingsViewModel.shown() = state.value.days.flatMap { it.meetings }.map { it.id }

    @Test
    fun `the list goes on past the meetings it loads first`() {
        val viewModel = MeetingsViewModel(repository)
        assertThat(viewModel.shown()).hasSize(MeetingsViewModel.PAGE)
        assertThat(viewModel.shown()).doesNotContain(OLDEST)
        // The header says "More than 1000 meetings" until the end is reached.
        assertThat(viewModel.state.value.hasMore).isTrue()
        assertThat(viewModel.state.value.total).isEqualTo(MeetingsViewModel.PAGE)

        viewModel.showMore()
        assertThat(viewModel.shown()).hasSize(COUNT)
        assertThat(viewModel.shown().last()).isEqualTo(OLDEST)
        assertThat(viewModel.state.value.hasMore).isFalse()
        assertThat(viewModel.state.value.total).isEqualTo(COUNT)
        // Nothing is left to ask for.
        viewModel.showMore()
        assertThat(viewModel.shown()).hasSize(COUNT)
    }

    @Test
    fun `a meeting the page couldn't use doesn't end the list`() {
        // Whether older meetings exist is the store's to say, from the rows it read, not from how many it could use.
        val short = object : CompanionRepository by repository {
            override suspend fun newestMeetings(limit: Int): MeetingsPage =
                repository.newestMeetings(limit).let { it.copy(meetings = it.meetings.drop(1)) }
        }
        val viewModel = MeetingsViewModel(short)
        assertThat(viewModel.shown()).hasSize(MeetingsViewModel.PAGE - 1)
        assertThat(viewModel.state.value.hasMore).isTrue()

        viewModel.showMore()
        assertThat(viewModel.shown()).hasSize(COUNT - 1)
        assertThat(viewModel.shown().last()).isEqualTo(OLDEST)
    }

    @Test
    fun `search finds a meeting older than the ones the list loads first`() {
        val viewModel = MeetingsViewModel(repository)
        viewModel.setQuery("kickoff")
        assertThat(viewModel.shown()).containsExactly(OLDEST)
        viewModel.setQuery("Ines")
        assertThat(viewModel.shown()).containsExactly(NEWEST, OLDEST).inOrder()
        // In the summary only, so it comes from the search index.
        viewModel.setQuery("lighthouse")
        assertThat(viewModel.shown()).containsExactly(OLDEST)
        assertThat(viewModel.state.value.total).isEqualTo(COUNT)
        assertThat(viewModel.state.value.hasMore).isFalse()
        // The rows a search keeps in memory carry what a row shows, not the long texts.
        assertThat(viewModel.state.value.days.single().meetings.single().summaryMarkdown).isNull()

        viewModel.setQuery("")
        assertThat(viewModel.shown()).hasSize(MeetingsViewModel.PAGE)
    }

    @Test
    fun `a person and a project list meetings older than the newest thousand`() {
        assertThat(PersonViewModel(repository, PERSON).state.value.meetings.map { it.id }).containsExactly(NEWEST, OLDEST).inOrder()
        assertThat(ProjectViewModel(repository, PROJECT).state.value.meetings.map { it.id }).containsExactly(NEWEST, OLDEST).inOrder()
    }

    @Test
    fun `the timeline goes back to the first recorded day`() {
        val first = LocalDate.parse("2023-01-01")
        val days = (0 until 1005L).map { first.plusDays(it).toString() }
        val library = FixtureRepository(
            days.map { envelope(RecordKind.DAY, it, DayRecord.serializer(), DayRecord(it)) },
            fixedNow = Instant.parse("${days.last()}T12:00:00Z"),
        )
        val state = TimelineViewModel(library).state.value
        assertThat(state.recordedDays).hasSize(days.size)
        assertThat(state.earliest).isEqualTo(first)
    }

    private companion object {
        const val COUNT = 1205
        const val SPACING = 6 * 3600L
        const val PERSON = "person-ines"
        const val PROJECT = "project-harbour"
        val FIRST: Instant = Instant.parse("2026-01-05T09:00:00Z")
        val OLDEST = id(0)
        val NEWEST = id(COUNT - 1)

        fun id(index: Int) = "meeting-%04d".format(index)

        fun <T> envelope(kind: String, key: String, serializer: KSerializer<T>, body: T) =
            RecordEnvelope(kind, key, version = 1, body = RecordJson.encodeToJsonElement(serializer, body).jsonObject)

        fun envelopes(): List<RecordEnvelope> {
            val ines = PersonRef(PERSON, "Ines Okafor")
            val harbour = ProjectRef(PROJECT, "Harbour")
            val meetings = (0 until COUNT).map { index ->
                val start = FIRST.plusSeconds(index * SPACING)
                val known = index == 0 || index == COUNT - 1
                Meeting(
                    id = id(index),
                    title = if (index == 0) "Project kickoff" else "Weekly sync $index",
                    startedAt = start.toString(),
                    day = start.atZone(ZoneOffset.UTC).toLocalDate().toString(),
                    people = if (known) listOf(ines) else emptyList(),
                    projects = if (known) listOf(harbour) else emptyList(),
                    summaryMarkdown = if (index == 0) "We agreed on the lighthouse plan." else null,
                )
            }
            val both = listOf(OLDEST, NEWEST)
            return meetings.map { envelope(RecordKind.MEETING, it.id, Meeting.serializer(), it) } +
                envelope(RecordKind.PERSON, PERSON, Person.serializer(), Person(PERSON, "Ines Okafor", meetingIds = both)) +
                envelope(RecordKind.PROJECT, PROJECT, Project.serializer(), Project(PROJECT, "Harbour", meetingIds = both))
        }
    }
}
