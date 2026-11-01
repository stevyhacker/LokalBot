package me.dotenv.lokalbot.companion.data

import java.text.Normalizer
import me.dotenv.lokalbot.companion.data.model.DayRecord
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.model.Transcript

/**
 * Substring search over records held in memory, for the sample library. The
 * synced library uses the Rust store's FTS5 index instead.
 */
object LocalSearch {

    fun search(
        query: String,
        meetings: List<Meeting>,
        transcripts: Map<String, Transcript>,
        days: List<DayRecord>,
        limit: Int,
    ): List<SearchHit> {
        val terms = terms(query)
        if (terms.isEmpty()) return emptyList()
        val hits = mutableListOf<Pair<Int, SearchHit>>()
        fun consider(text: String, hit: () -> SearchHit) {
            val score = score(text, terms)
            if (score > 0) hits += score to hit()
        }
        for (meeting in meetings) {
            consider(meeting.title) {
                SearchHit(SearchHitKind.Meeting, meeting.id, meeting.id, meeting.title, meeting.appName ?: "", date = meeting.day)
            }
            meeting.summaryMarkdown?.let { summary ->
                consider(summary) {
                    SearchHit(SearchHitKind.Meeting, meeting.id, meeting.id, meeting.title, snippet(summary, terms), date = meeting.day)
                }
            }
            meeting.notesMarkdown?.let { notes ->
                consider(notes) {
                    SearchHit(SearchHitKind.Meeting, meeting.id, meeting.id, meeting.title, snippet(notes, terms), date = meeting.day)
                }
            }
            for (action in meeting.actions) {
                consider(action.text + " " + (action.owner ?: "")) {
                    SearchHit(SearchHitKind.Action, action.id, meeting.id, action.text, meeting.title,
                        at = action.citations.firstOrNull()?.start, date = meeting.day)
                }
            }
            for (decision in meeting.decisions) {
                consider(decision.text) {
                    SearchHit(SearchHitKind.Decision, decision.id, meeting.id, decision.text, meeting.title,
                        at = decision.citations.firstOrNull()?.start, date = meeting.day)
                }
            }
            transcripts[meeting.id]?.segments?.forEach { segment ->
                consider(segment.text) {
                    SearchHit(SearchHitKind.Transcript, meeting.id, meeting.id, meeting.title,
                        "${segment.speaker}: ${segment.text}", at = segment.start, date = meeting.day)
                }
            }
        }
        for (day in days) {
            val digest = day.digest ?: continue
            consider(digest.markdown) {
                SearchHit(SearchHitKind.Digest, day.date, null, day.date, snippet(digest.markdown, terms), date = day.date)
            }
        }
        return hits
            .distinctBy { (_, hit) -> Triple(hit.kind, hit.key, hit.at) }
            .sortedWith(compareByDescending<Pair<Int, SearchHit>> { it.first }.thenByDescending { it.second.date ?: "" })
            .take(limit)
            .map { it.second }
    }

    fun terms(query: String): List<String> =
        fold(query).split(Regex("[^\\p{L}\\p{Nd}]+")).filter { it.length >= 2 }.distinct()

    private fun score(text: String, terms: List<String>): Int {
        val folded = fold(text)
        return terms.count { folded.contains(it) }.let { matched -> if (matched == terms.size) matched * 2 else if (matched * 2 >= terms.size && terms.size > 2) matched else 0 }
    }

    private fun snippet(text: String, terms: List<String>): String {
        val lines = text.lines().map { it.trim().removePrefix("- ").removePrefix("## ") }.filter { it.isNotBlank() }
        return lines.firstOrNull { line -> terms.any { fold(line).contains(it) } } ?: lines.firstOrNull().orEmpty()
    }

    fun fold(text: String): String =
        Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase()
}
