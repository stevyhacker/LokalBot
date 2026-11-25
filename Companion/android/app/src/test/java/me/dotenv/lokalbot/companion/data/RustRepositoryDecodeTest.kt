package me.dotenv.lokalbot.companion.data

import com.google.common.truth.Truth.assertThat
import me.dotenv.lokalbot.companion.data.model.ActionRow
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.model.Person
import me.dotenv.lokalbot.companion.data.model.Project
import org.junit.Test

class RustRepositoryDecodeTest {

    private val validMeetingJson = """
        {"id":"m1","title":"Design review","startedAt":"2026-11-10T09:00:00Z","day":"2026-11-10","durationSeconds":1800,"actions":[],"decisions":[],"hasTranscript":false}
    """.trimIndent()

    private val secondMeetingJson = """
        {"id":"m2","title":"Weekly sync","startedAt":"2026-11-09T09:00:00Z","day":"2026-11-09","durationSeconds":900,"actions":[],"decisions":[],"hasTranscript":false}
    """.trimIndent()

    private val validActionRowJson = """
        {"meetingId":"m1","meetingTitle":"Design review","meetingStartedAt":"2026-11-10T09:00:00Z","action":{"id":"a1","text":"Ship fix"},"pending":false}
    """.trimIndent()

    @Test
    fun `decodeAll skips corrupt and truncated rows instead of failing the screen`() {
        val meetings = RustRepository.decodeAll(
            listOf(validMeetingJson, "{not-json", """{"id":"missing-fields"}""", secondMeetingJson),
            Meeting.serializer(),
        )
        assertThat(meetings.map { it.id }).containsExactly("m1", "m2").inOrder()

        val actions = RustRepository.decodeAll(
            listOf("{broken", validActionRowJson, """{"meetingId":123}"""),
            ActionRow.serializer(),
        )
        assertThat(actions.map { it.action.id }).containsExactly("a1")
    }

    @Test
    fun `newestMeetingsPage keeps valid rows and preserves hasMore when one row is malformed`() {
        val page = RustRepository.newestMeetingsPage(
            listOf(validMeetingJson, "{corrupt", secondMeetingJson),
            limit = 2,
        )
        assertThat(page.meetings.map { it.id }).containsExactly("m1")
        assertThat(page.hasMore).isTrue()

        val lastPage = RustRepository.newestMeetingsPage(
            listOf(validMeetingJson, "{corrupt"),
            limit = 2,
        )
        assertThat(lastPage.meetings.map { it.id }).containsExactly("m1")
        assertThat(lastPage.hasMore).isFalse()
    }

    @Test
    fun `decodeOrNull returns null for corrupt single records`() {
        assertThat(RustRepository.decodeOrNull("{bad", Meeting.serializer())).isNull()
        assertThat(RustRepository.decodeOrNull("{}", Person.serializer())).isNull()
        assertThat(RustRepository.decodeOrNull("[]", Project.serializer())).isNull()
        assertThat(RustRepository.decodeOrNull(validMeetingJson, Meeting.serializer())?.title).isEqualTo("Design review")
    }
}
