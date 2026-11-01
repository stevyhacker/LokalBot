package me.dotenv.lokalbot.companion.ui

import com.google.common.truth.Truth.assertThat
import java.time.LocalDate
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import me.dotenv.lokalbot.companion.PairOutcome
import me.dotenv.lokalbot.companion.TestLibrary
import me.dotenv.lokalbot.companion.data.ActionOrdering
import me.dotenv.lokalbot.companion.data.AskEvent
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.FixtureRepository
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.data.model.AskRequest
import me.dotenv.lokalbot.companion.ui.actions.ActionsViewModel
import me.dotenv.lokalbot.companion.ui.actions.OwnerFilter
import me.dotenv.lokalbot.companion.ui.ask.AskViewModel
import me.dotenv.lokalbot.companion.ui.ask.TurnPhase
import me.dotenv.lokalbot.companion.ui.meetings.MeetingsViewModel
import me.dotenv.lokalbot.companion.ui.onboarding.LinkProblem
import me.dotenv.lokalbot.companion.ui.onboarding.PairingStep
import me.dotenv.lokalbot.companion.ui.onboarding.PairingViewModel
import me.dotenv.lokalbot.companion.ui.timeline.TimelineViewModel
import me.dotenv.lokalbot.companion.ui.today.TodayViewModel
import org.junit.After
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ViewModelTest {
    private lateinit var repository: FixtureRepository

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        repository = TestLibrary.repository()
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `today shows yesterday's digest until today's exists`() {
        val state = TodayViewModel(repository).state.value
        assertThat(state.loaded).isTrue()
        assertThat(state.digestDay?.date).isEqualTo(TestLibrary.yesterday.toString())
        assertThat(state.digestIsYesterday).isTrue()
        assertThat(state.meetings.map { it.title }).containsExactly("Product standup")
        assertThat(state.needsAttention.first().action.id).isEqualTo("act-1f2e3d4c")
        assertThat(state.todayRecord?.timeline?.trackedSeconds).isEqualTo(5580.0)
    }

    @Test
    fun `toggling an action on Today reloads it as pending`() {
        val viewModel = TodayViewModel(repository)
        val row = viewModel.state.value.needsAttention.first()
        viewModel.setStatus(row, ActionStatus.Done)
        assertThat(viewModel.state.value.needsAttention.map { it.action.id }).doesNotContain(row.action.id)
    }

    @Test
    fun `action filters toggle back to everyone and all statuses`() {
        val viewModel = ActionsViewModel(repository)
        assertThat(viewModel.state.value.count).isEqualTo(3)
        viewModel.setOwner(OwnerFilter.Mine)
        assertThat(viewModel.state.value.filters.owner).isEqualTo(OwnerFilter.Everyone)
        assertThat(viewModel.state.value.count).isEqualTo(7)
        viewModel.setStatus(ActionStatus.Open)
        assertThat(viewModel.state.value.count).isEqualTo(10)
        assertThat(viewModel.state.value.groups.last().first).isEqualTo(ActionOrdering.Group.Closed)
        viewModel.setOwner(OwnerFilter.Unclear)
        assertThat(viewModel.state.value.groups.single().second.single().action.id).isEqualTo("act-91b0d3f5")
    }

    @Test
    fun `meeting search matches titles, people and transcripts`() {
        val viewModel = MeetingsViewModel(repository)
        assertThat(viewModel.state.value.days.map { it.day }).containsExactlyElementsIn(TestLibrary.meetingDays).inOrder()
        viewModel.setQuery("northwind")
        assertThat(viewModel.state.value.days.flatMap { it.meetings }.map { it.title }).contains("Call with Northwind")
        viewModel.setQuery("Priya")
        assertThat(viewModel.state.value.days.flatMap { it.meetings }.map { it.id }).containsExactly(
            TestLibrary.STANDUP, "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e05", "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e06",
        )
        viewModel.setQuery("behind a flag")
        assertThat(viewModel.state.value.days.flatMap { it.meetings }.map { it.id }).contains(TestLibrary.DESIGN_REVIEW)
    }

    @Test
    fun `timeline never moves past today`() {
        val viewModel = TimelineViewModel(repository)
        assertThat(viewModel.state.value.day).isEqualTo(TestLibrary.today)
        viewModel.step(1)
        assertThat(viewModel.state.value.day).isEqualTo(TestLibrary.today)
        viewModel.step(-1)
        assertThat(viewModel.state.value.record?.digest).isNotNull()
        assertThat(viewModel.state.value.meetings).hasSize(3)
        val earliest = LocalDate.parse(TestLibrary.days.last())
        val gap = generateSequence(earliest) { it.plusDays(1) }.first { it.toString() !in TestLibrary.days }
        viewModel.select(gap)
        assertThat(viewModel.state.value.record).isNull()
        assertThat(viewModel.state.value.recordedDays).contains(earliest.toString())
    }

    @Test
    fun `ask streams the answer and keeps the conversation`() {
        val viewModel = AskViewModel(repository)
        viewModel.ask("What did Maya ask me?")
        val turn = viewModel.state.value.turns.single()
        assertThat(turn.phase).isEqualTo(TurnPhase.Done)
        assertThat(turn.result!!.citations).isNotEmpty()
        assertThat(turn.answer).contains("[1]")
        assertThat(viewModel.state.value.conversations.single().title).isEqualTo("What did Maya ask me?")

        viewModel.ask("And what's overdue?")
        val history = runBlocking { repository.askHistory() }.first().request.history
        assertThat(history.map { it.role }).containsExactly("user", "assistant").inOrder()

        viewModel.newConversation()
        assertThat(viewModel.state.value.turns).isEmpty()
        viewModel.openConversation(viewModel.state.value.conversations.single().id)
        assertThat(viewModel.state.value.turns).hasSize(2)
    }

    @Test
    fun `an unreachable Mac offers local search and a queue`() {
        val offline = object : CompanionRepository by repository {
            override fun ask(request: AskRequest): Flow<AskEvent> = flowOf(AskEvent.Failed("No route to the Mac", macUnreachable = true))
        }
        val viewModel = AskViewModel(offline)
        viewModel.ask("pricing deck")
        val id = viewModel.state.value.turns.single().request.requestId
        assertThat(viewModel.state.value.turns.single().phase).isEqualTo(TurnPhase.MacUnreachable)
        viewModel.searchThisDevice(id)
        assertThat(viewModel.state.value.turns.single().localHits).isNotEmpty()
        viewModel.askWhenMacIsBack(id)
        assertThat(viewModel.state.value.turns.single().phase).isEqualTo(TurnPhase.Queued)
        assertThat(runBlocking { repository.queuedQuestions() }.single().question).isEqualTo("pricing deck")
    }

    @Test
    fun `pairing confirms the Mac, then waits for approval`() {
        val validLink = PairingLinkFixture.link(TestLibrary.now.epochSecond + 300)
        var approved: PairOutcome = PairOutcome.Failed("Your Mac said no.")
        var sentName: String? = null
        val viewModel = PairingViewModel(
            pair = { _, _, name -> sentName = name; approved },
            initialDeviceName = { "Google Pixel 9" },
            now = { TestLibrary.now },
        )
        assertThat(viewModel.deviceName.value).isEqualTo("Google Pixel 9")

        assertThat(viewModel.submit("hello")).isFalse()
        assertThat(viewModel.problem.value).isEqualTo(LinkProblem.NotALink)
        assertThat(viewModel.submit(validLink)).isTrue()
        assertThat((viewModel.step.value as PairingStep.Confirm).payload.macName).isEqualTo("Sample Mac")
        viewModel.confirm()
        assertThat(viewModel.step.value).isEqualTo(PairingStep.Failed("Your Mac said no."))

        approved = PairOutcome.Paired("Sample Mac")
        viewModel.restart()
        viewModel.submit(validLink)
        viewModel.setDeviceName("  Stevan's Pixel  ")
        viewModel.confirm()
        assertThat(viewModel.step.value).isEqualTo(PairingStep.Paired("Sample Mac"))
        assertThat(sentName).isEqualTo("Stevan's Pixel")

        viewModel.restart()
        viewModel.submit(PairingLinkFixture.link(TestLibrary.now.epochSecond - 10))
        assertThat(viewModel.problem.value).isEqualTo(LinkProblem.Expired)
    }
}

object PairingLinkFixture {
    fun link(exp: Long): String {
        val key = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32))
        val json = """{"v":1,"macName":"Sample Mac","macKey":"$key","addrs":["192.168.1.20"],"port":17890,"pid":"AAAAAAAAAAAAAAAAAAAAAA","psk":"$key","exp":$exp}"""
        return "lokalbot://pair?d=" + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(json.toByteArray())
    }
}
