package me.dotenv.lokalbot.companion.data

import com.google.common.truth.Truth.assertThat
import java.time.ZoneOffset
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import me.dotenv.lokalbot.companion.TestLibrary
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.data.model.AskRequest
import me.dotenv.lokalbot.companion.data.model.DayRecord
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.model.RecordEnvelope
import me.dotenv.lokalbot.companion.data.model.RecordJson
import me.dotenv.lokalbot.companion.data.model.SessionKind
import org.junit.Test

class SampleLibraryTest {
    private val repository = TestLibrary.repository()

    @Test
    fun `every record in the fixture decodes`() {
        val envelopes = RecordJson.decodeFromString(ListSerializer(RecordEnvelope.serializer()), TestLibrary.json)
        assertThat(envelopes.groupingBy { it.kind }.eachCount()).containsExactly(
            "manifest", 1, "meeting", 6, "transcript", 2, "day", 4, "person", 4, "project", 2,
        )
        envelopes.filter { it.kind == "meeting" }.forEach { RecordJson.decodeFromJsonElement(Meeting.serializer(), it.body) }
        envelopes.filter { it.kind == "day" }.forEach { RecordJson.decodeFromJsonElement(DayRecord.serializer(), it.body) }
    }

    @Test
    fun `manifest and clock come from the library`() = runBlocking {
        val manifest = repository.manifest()!!
        assertThat(manifest.macName).isEqualTo("Sample Mac")
        assertThat(manifest.dataClasses.windowTitles).isTrue()
        assertThat(manifest.historyDays).isEqualTo(0)
        assertThat(repository.zone()).isEqualTo(ZoneOffset.ofHours(1))
        assertThat(repository.today()).isEqualTo(TestLibrary.today)
        assertThat(repository.now()).isEqualTo(TestLibrary.now)
    }

    @Test
    fun `meetings are newest first and optional fields stay empty`() = runBlocking {
        val meetings = repository.meetings()
        assertThat(meetings.map { it.title }.first()).isEqualTo("Product standup")
        assertThat(meetings.map { it.startedAt }).isInOrder(Comparator.reverseOrder<String>())
        val northwind = repository.meeting(TestLibrary.NORTHWIND)!!
        assertThat(northwind.notesMarkdown).isNull()
        assertThat(northwind.mergedInto).isNull()
        assertThat(northwind.hasTranscript).isFalse()
        val unclear = repository.meeting(TestLibrary.STANDUP)!!.actions.first { it.ownerUnclear }
        assertThat(unclear.owner).isNull()
        assertThat(unclear.dueDate).isNull()
        assertThat(unclear.citations.single().speaker).isEqualTo("Priya Nair")
    }

    @Test
    fun `day ranges select meetings by local day`() = runBlocking {
        val yesterday = TestLibrary.yesterday.toString()
        assertThat(repository.meetings(fromDay = yesterday, toDay = yesterday).map { it.title })
            .containsExactly("Call with Northwind", "1:1 with Maya", "Design review — onboarding").inOrder()
    }

    @Test
    fun `transcripts keep speaker colours`() = runBlocking {
        val transcript = repository.transcript(TestLibrary.DESIGN_REVIEW)!!
        assertThat(transcript.segments).hasSize(10)
        assertThat(transcript.segments.first { it.speaker == "You" }.colorIndex).isEqualTo(0)
        assertThat(repository.transcript(TestLibrary.NORTHWIND)).isNull()
    }

    @Test
    fun `days carry digests and timelines`() = runBlocking {
        assertThat(repository.days()).containsExactlyElementsIn(TestLibrary.days).inOrder()
        val today = repository.day(TestLibrary.today.toString())!!
        assertThat(today.digest).isNull()
        assertThat(today.timeline!!.sessions.map { it.kind }).containsExactly(SessionKind.Meeting, SessionKind.Work).inOrder()
        val yesterday = repository.day(TestLibrary.yesterday.toString())!!
        assertThat(yesterday.digest!!.sections.blockers).containsExactly("Waiting on legal review of the pricing tiers.")
        assertThat(yesterday.timeline!!.sessions.single { it.kind == SessionKind.Agent }.windowTitles).isEmpty()
        assertThat(yesterday.timeline!!.savedMoments.single().label).isEqualTo("Pricing table idea")
    }

    @Test
    fun `people and projects decode`() = runBlocking {
        val maya = repository.person("person:maya-chen")!!
        assertThat(maya.openWork.single().theirs).isFalse()
        assertThat(repository.people()).hasSize(4)
        val onboarding = repository.project(TestLibrary.ONBOARDING)!!
        assertThat(onboarding.waitingOnOthers.single().owner).isEqualTo("Ben Ortiz")
        assertThat(onboarding.yourActions.single().status).isEqualTo(ActionStatus.Open)
    }

    @Test
    fun `status changes show as pending until the Mac confirms`() = runBlocking {
        repository.setActionStatus(TestLibrary.DESIGN_REVIEW, "act-1f2e3d4c", ActionStatus.Done)
        val row = repository.actions(ActionFilter(status = null)).single { it.action.id == "act-1f2e3d4c" }
        assertThat(row.pending).isTrue()
        assertThat(row.action.status).isEqualTo(ActionStatus.Done)
        assertThat(repository.meeting(TestLibrary.DESIGN_REVIEW)!!.actions.first().status).isEqualTo(ActionStatus.Done)
        assertThat(repository.revision.value).isEqualTo(1)

        repository.setActionStatus(TestLibrary.DESIGN_REVIEW, "act-1f2e3d4c", ActionStatus.Open)
        assertThat(repository.actions(ActionFilter(status = null)).single { it.action.id == "act-1f2e3d4c" }.pending).isFalse()
    }

    @Test
    fun `search covers titles, actions, transcripts and digests`() = runBlocking {
        val hits = repository.search("pricing deck")
        assertThat(hits.map { it.kind }).contains(SearchHitKind.Action)
        assertThat(repository.search("flag").map { it.kind }).containsAtLeast(SearchHitKind.Decision, SearchHitKind.Transcript, SearchHitKind.Digest)
        assertThat(repository.search("x")).isEmpty()
    }

    @Test
    fun `sample answers cite meetings and moments`() = runBlocking {
        val request = AskRequest(requestId = "r1", conversationId = "c1", question = "What's overdue?")
        val events = repository.ask(request).toList()
        val done = events.last() as AskEvent.Done
        assertThat(done.result.answer).contains("[1]")
        assertThat(done.result.citations.single().meetingId).isEqualTo(TestLibrary.DESIGN_REVIEW)
        assertThat(done.result.citations.single().at).isEqualTo(721.4)
        assertThat(events.filterIsInstance<AskEvent.Delta>().joinToString("") { it.text }).isEqualTo(done.result.answer)
        assertThat(repository.askHistory().single().request).isEqualTo(request)
    }
}
