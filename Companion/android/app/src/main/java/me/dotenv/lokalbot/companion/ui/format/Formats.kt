package me.dotenv.lokalbot.companion.ui.format

import android.text.format.DateFormat
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale
import me.dotenv.lokalbot.companion.data.formatOffset
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.parseDayOrNull

/** Words that depend on the app's language, from string resources. */
data class RelativeWords(
    val today: String = "Today",
    val yesterday: String = "Yesterday",
    val tomorrow: String = "Tomorrow",
    val justNow: String = "just now",
    val minutesAgo: (Long) -> String = { "$it min ago" },
    val hoursAgo: (Long) -> String = { "$it h ago" },
)

/** Dates, times and durations the way the Mac shows them, in the person's locale. */
class Formats(
    val locale: Locale,
    val zone: ZoneId,
    private val words: RelativeWords = RelativeWords(),
) {
    private fun pattern(skeleton: String): DateTimeFormatter =
        DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, skeleton), locale)

    private val timeFormat by lazy { pattern("jmm") }
    private val longDayFormat by lazy { pattern("EEEEdMMMM") }
    private val longDayYearFormat by lazy { pattern("EEEEdMMMMy") }
    private val shortDayFormat by lazy { pattern("EEEdMMM") }
    private val weekdayFormat by lazy { pattern("EEE") }
    private val dayNumberFormat by lazy { pattern("d") }
    private val monthYearFormat by lazy { pattern("MMMMy") }

    fun time(instant: Instant, zone: ZoneId = this.zone): String = timeFormat.format(instant.atZone(zone))

    fun time(iso: String?, zone: ZoneId = this.zone): String = iso?.let(::parseInstant)?.let { time(it, zone) }.orEmpty()

    /** "10:30–11:15". */
    fun timeRange(start: String, end: String): String = "${time(start)}–${time(end)}"

    /** Meeting times use the Mac's offset at the time of the meeting. */
    fun meetingTime(meeting: Meeting): String =
        time(meeting.startedAt, ZoneOffset.ofTotalSeconds(meeting.timeZoneOffsetMinutes * 60))

    /** "Today", "Yesterday", "Thursday, 30 October". */
    fun dayLabel(date: LocalDate, today: LocalDate): String = when (date) {
        today -> words.today
        today.minusDays(1) -> words.yesterday
        else -> (if (date.year == today.year) longDayFormat else longDayYearFormat).format(date)
    }

    fun dayLabel(day: String, today: LocalDate): String = parseDayOrNull(day)?.let { dayLabel(it, today) } ?: day

    /** "Saturday, 31 October 2026". */
    fun fullDate(date: LocalDate): String = longDayYearFormat.format(date)

    /** "Thu 30 Oct". */
    fun shortDay(date: LocalDate): String = shortDayFormat.format(date)

    fun shortDay(day: String): String = parseDayOrNull(day)?.let(::shortDay) ?: day

    fun weekday(date: LocalDate): String = weekdayFormat.format(date)

    fun dayNumber(date: LocalDate): String = dayNumberFormat.format(date)

    fun monthYear(date: LocalDate): String = monthYearFormat.format(date)

    /** "Today", "Tomorrow" or "Thu 30 Oct". */
    fun dueDay(day: String, today: LocalDate): String {
        val date = parseDayOrNull(day) ?: return day
        return when (date) {
            today -> words.today
            today.plusDays(1) -> words.tomorrow
            today.minusDays(1) -> words.yesterday
            else -> shortDay(date)
        }
    }

    /** "Zoom · 10:30 · 42 min". */
    fun meetingMeta(meeting: Meeting): String =
        listOfNotNull(meeting.appName, meetingTime(meeting), meetingDuration(meeting.durationSeconds)).joinToString(" · ")

    /** "just now", "2 min ago", "3 h ago", "Yesterday", "Thu 30 Oct". */
    fun ago(then: Instant, now: Instant): String {
        val elapsed = Duration.between(then, now)
        return when {
            elapsed.toMinutes() < 1 -> words.justNow
            elapsed.toMinutes() < 60 -> words.minutesAgo(elapsed.toMinutes())
            elapsed.toHours() < 12 -> words.hoursAgo(elapsed.toHours())
            else -> {
                val thenDay = then.atZone(zone).toLocalDate()
                val today = now.atZone(zone).toLocalDate()
                when {
                    thenDay == today -> time(then)
                    ChronoUnit.DAYS.between(thenDay, today) == 1L -> words.yesterday
                    else -> shortDay(thenDay)
                }
            }
        }
    }

    companion object {
        fun parseInstant(iso: String): Instant? = runCatching { Instant.parse(iso) }.getOrNull()

        /** The Mac's `CaptureStyle.hm`: "<1m", "42m", "1h 5m". */
        fun duration(seconds: Double): String {
            if (seconds > 0 && seconds < 60) return "<1m"
            val minutes = (seconds / 60).toLong()
            return if (minutes >= 60) "${minutes / 60}h ${minutes % 60}m" else "${minutes}m"
        }

        /** Meeting rows: "42 min", "1 hr 5 min". */
        fun meetingDuration(seconds: Double): String? {
            if (seconds <= 0) return null
            val minutes = ((seconds + 30) / 60).toLong().coerceAtLeast(1)
            return if (minutes >= 60) {
                val rest = minutes % 60
                if (rest == 0L) "${minutes / 60} hr" else "${minutes / 60} hr $rest min"
            } else "$minutes min"
        }

        /** "12:04" or "1:02:03" into a recording. */
        fun offset(seconds: Double): String = formatOffset(seconds)
    }
}
