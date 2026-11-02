package me.dotenv.lokalbot.companion.data

import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import me.dotenv.lokalbot.companion.data.model.AnswerLocation
import me.dotenv.lokalbot.companion.data.model.AskCitation
import me.dotenv.lokalbot.companion.data.model.AskRequest
import me.dotenv.lokalbot.companion.data.model.AskResult
import me.dotenv.lokalbot.companion.data.model.Citation
import me.dotenv.lokalbot.companion.data.model.Meeting

/**
 * Answers questions about the sample library from its own records, so the
 * Ask screen can be tried without a Mac. Real answers come from the Mac's
 * Ask agent.
 */
internal class SampleAnswerer(private val repository: CompanionRepository) {

    private data class Source(val text: String, val meeting: Meeting, val citation: Citation?)

    suspend fun answer(request: AskRequest, today: LocalDate): AskResult {
        val question = LocalSearch.fold(request.question)
        val meetings = repository.meetings()
        val (lead, sources) = when {
            "overdue" in question -> overdue(meetings, today)
            "yesterday" in question || "today" in question -> daySummary(question, today, meetings)
            else -> related(request.question, meetings)
        }
        val citations = sources.mapIndexed { index, source ->
            AskCitation(
                index = index + 1,
                meetingId = source.meeting.id,
                at = source.citation?.start,
                label = listOfNotNull(source.meeting.title, source.citation?.start?.let(::formatOffset)).joinToString(" · "),
            )
        }
        val body = sources.mapIndexed { index, source -> "${source.text.trimEnd('.')} [${index + 1}]." }.joinToString(" ")
        return AskResult(
            requestId = request.requestId,
            answer = listOf(lead, body).filter { it.isNotBlank() }.joinToString(" "),
            citations = citations,
            engineLabel = "the sample library",
            location = AnswerLocation.Mac,
            answeredAt = repository.now().toString(),
        )
    }

    private fun overdue(meetings: List<Meeting>, today: LocalDate): Pair<String, List<Source>> {
        val sources = meetings.flatMap { meeting ->
            meeting.actions.filter { ActionOrdering.isOverdue(it, today) }
                .map { Source("${it.owner ?: "Someone"}: ${it.text}, due ${it.dueDate?.let(::sampleDay) ?: it.dueText}", meeting, it.citations.firstOrNull()) }
        }
        val lead = when (sources.size) {
            0 -> "Nothing is overdue in the sample library."
            1 -> "One action is past its due date."
            else -> "${sources.size} actions are past their due dates."
        }
        return lead to sources
    }

    private suspend fun daySummary(question: String, today: LocalDate, meetings: List<Meeting>): Pair<String, List<Source>> {
        val date = if ("yesterday" in question) today.minusDays(1) else today
        val day = repository.day(date.toString())
        val dayMeetings = meetings.filter { it.day == date.toString() }
        val highlights = day?.digest?.sections?.highlights.orEmpty()
        val sources = dayMeetings.flatMap { meeting ->
            meeting.decisions.map { Source(it.text, meeting, it.citations.firstOrNull()) }
        }.take(3)
        val lead = buildString {
            append(if (date == today) "Today " else "Yesterday ")
            append(
                when (dayMeetings.size) {
                    0 -> "had no meetings."
                    1 -> "had one meeting, ${dayMeetings.first().title}."
                    else -> "had ${dayMeetings.size} meetings: ${dayMeetings.joinToString(", ") { it.title }}."
                },
            )
            if (highlights.isNotEmpty()) append(" ").append(highlights.joinToString(" "))
            if (sources.isNotEmpty()) append(" Decisions:")
        }
        return lead to sources
    }

    private fun related(question: String, meetings: List<Meeting>): Pair<String, List<Source>> {
        val terms = LocalSearch.terms(question).filter { it.length >= 4 && it !in STOP_WORDS }
        val candidates = meetings.flatMap { meeting ->
            meeting.decisions.map { Source(it.text, meeting, it.citations.firstOrNull()) } +
                meeting.actions.map { action ->
                    val owner = when {
                        action.ownerIsUser -> "You"
                        action.ownerUnclear -> "Nobody yet"
                        else -> action.owner ?: "Someone"
                    }
                    Source("$owner: ${action.text}", meeting, action.citations.firstOrNull())
                }
        }
        fun score(source: Source): Int {
            val haystack = LocalSearch.fold(listOf(source.text, source.meeting.title, source.citation?.speaker.orEmpty(), source.citation?.excerpt.orEmpty()).joinToString(" "))
            return terms.count { haystack.contains(it) }
        }
        val ranked = candidates.map { it to score(it) }.filter { it.second > 0 }
            .sortedWith(compareByDescending<Pair<Source, Int>> { it.second }.thenByDescending { it.first.meeting.startedAt })
            .map { it.first }.take(3)
        return if (ranked.isNotEmpty()) "Here is what the sample library says." to ranked
        else "The sample library has nothing on that. Its most recent decisions:" to
            candidates.filter { !it.text.contains(':') }.sortedByDescending { it.meeting.startedAt }.take(2)
    }

    private companion object {
        val STOP_WORDS = setOf("what", "when", "where", "which", "about", "with", "this", "that", "week", "does", "have", "from", "they", "there", "decide", "decided", "tell")
    }
}

/** "Thu 29 Oct": the sample library is in English. */
private fun sampleDay(day: String): String =
    parseDayOrNull(day)?.let { DateTimeFormatter.ofPattern("EEE d MMM", Locale.ENGLISH).format(it) } ?: day

/** Seconds into a recording as "m:ss" or "h:mm:ss". */
fun formatOffset(seconds: Double): String {
    val total = seconds.toInt().coerceAtLeast(0)
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) String.format(Locale.ROOT, "%d:%02d:%02d", h, m, s) else String.format(Locale.ROOT, "%d:%02d", m, s)
}
