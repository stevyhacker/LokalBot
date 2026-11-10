package me.dotenv.lokalbot.companion.ui

import com.google.common.truth.Truth.assertThat
import java.time.LocalDate
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import me.dotenv.lokalbot.companion.PairOutcome
import me.dotenv.lokalbot.companion.TestLibrary
import me.dotenv.lokalbot.companion.data.ActionFilter
import me.dotenv.lokalbot.companion.data.ActionOrdering
import me.dotenv.lokalbot.companion.data.AskEvent
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.FixtureRepository
import me.dotenv.lokalbot.companion.data.model.ActionRow
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.data.model.AskRequest
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.model.SyncNote
import me.dotenv.lokalbot.companion.ui.actions.ActionDetailViewModel
import me.dotenv.lokalbot.companion.ui.actions.ActionsViewModel
import me.dotenv.lokalbot.companion.ui.actions.OwnerFilter
import me.dotenv.lokalbot.companion.ui.ask.AskViewModel
import me.dotenv.lokalbot.companion.ui.ask.TurnPhase
import me.dotenv.lokalbot.companion.ui.meetings.MeetingDetailViewModel
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
    fun `a meeting and an action show a waiting change without reading every action`() {
        // Reading the whole library's actions for this got slower with every meeting.
        val library = object : CompanionRepository by repository {
            override suspend fun actions(filter: ActionFilter): List<ActionRow> = error("The meeting already says which actions wait.")
        }
        val meeting = MeetingDetailViewModel(library, TestLibrary.DESIGN_REVIEW)
        val action = ActionDetailViewModel(library, TestLibrary.DESIGN_REVIEW, "act-1f2e3d4c")
        assertThat(meeting.state.value.loaded).isTrue()
        assertThat(meeting.state.value.pendingActionIds).isEmpty()
        assertThat(action.state.value.pending).isFalse()

        meeting.setStatus("act-1f2e3d4c", ActionStatus.Done)
        assertThat(meeting.state.value.pendingActionIds).containsExactly("act-1f2e3d4c")
        assertThat(action.state.value.pending).isTrue()
        assertThat(action.state.value.action?.status).isEqualTo(ActionStatus.Done)
    }

    @Test
    fun `an action shows that the computer didn't make a change`() {
        val note = SyncNote("This action changed on your computer. Open the meeting to update it.")
        val refused = object : CompanionRepository by repository {
            override suspend fun meeting(id: String): Meeting? = repository.meeting(id)?.let { meeting ->
                meeting.copy(actions = meeting.actions.map { if (it.id == "act-1f2e3d4c") it.copy(syncNote = note) else it })
            }
        }
        val state = ActionDetailViewModel(refused, TestLibrary.DESIGN_REVIEW, "act-1f2e3d4c").state.value
        assertThat(state.pending).isFalse()
        assertThat(state.syncNote).isEqualTo(note)
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
    fun `an answer cut off by the lock screen is picked up on return`() {
        var attempts = 0
        val flaky = object : CompanionRepository by repository {
            override fun ask(request: AskRequest): Flow<AskEvent> = when (++attempts) {
                1 -> flowOf(AskEvent.Delta("Maya asked "), AskEvent.Interrupted)
                2 -> flowOf(AskEvent.Failed("No route to the Mac", macUnreachable = true))
                // Picking up: the first delta is the whole text so far.
                3 -> flowOf(AskEvent.Delta("Maya asked about pricing"), AskEvent.Interrupted)
                else -> repository.ask(request)
            }
        }
        val viewModel = AskViewModel(flaky)
        viewModel.ask("What did Maya ask me?")
        fun turn() = viewModel.state.value.turns.single()
        assertThat(turn().phase).isEqualTo(TurnPhase.Waiting)
        assertThat(turn().answer).isEqualTo("Maya asked ")

        // Still out of reach: the question stays queued, so it keeps waiting.
        viewModel.resumeWaiting()
        assertThat(turn().phase).isEqualTo(TurnPhase.Waiting)
        assertThat(turn().answer).isEqualTo("Maya asked ")

        viewModel.resumeWaiting()
        assertThat(turn().answer).isEqualTo("Maya asked about pricing")

        viewModel.resumeWaiting()
        assertThat(turn().phase).isEqualTo(TurnPhase.Done)
        assertThat(turn().answer).isEqualTo(turn().result!!.answer)
        assertThat(attempts).isEqualTo(4)
        // Nothing left to pick up.
        viewModel.resumeWaiting()
        assertThat(attempts).isEqualTo(4)
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
    fun `a queued question shows its answer once the Mac has answered`() {
        val changes = MutableStateFlow(0L)
        val offline = object : CompanionRepository by repository {
            override val revision: StateFlow<Long> = changes
            override fun ask(request: AskRequest): Flow<AskEvent> = flowOf(AskEvent.Failed("No route to the Mac", macUnreachable = true))
        }
        val viewModel = AskViewModel(offline)
        viewModel.ask("What did Maya ask me?")
        val request = viewModel.state.value.turns.single().request
        viewModel.askWhenMacIsBack(request.requestId)
        assertThat(viewModel.state.value.turns.single().phase).isEqualTo(TurnPhase.Queued)

        // A later sync asks the Mac, which saves the answer; the library then says it changed.
        runBlocking { repository.ask(request).collect {} }
        changes.value += 1
        val turn = viewModel.state.value.turns.single()
        assertThat(turn.phase).isEqualTo(TurnPhase.Done)
        assertThat(turn.answer).isEqualTo(turn.result!!.answer)
        assertThat(turn.result!!.citations).isNotEmpty()
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
        // Well past the two minutes the sync core allows for a clock that runs fast.
        viewModel.submit(PairingLinkFixture.link(TestLibrary.now.epochSecond - 600))
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
