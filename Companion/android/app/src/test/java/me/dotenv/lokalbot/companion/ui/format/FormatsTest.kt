package me.dotenv.lokalbot.companion.ui.format

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Locale
import kotlinx.coroutines.runBlocking
import me.dotenv.lokalbot.companion.TestLibrary
import org.junit.Test
import org.junit.runner.RunWith

/** Runs on Robolectric for Android's locale-aware date patterns. */
@RunWith(AndroidJUnit4::class)
class FormatsTest {
    private val zone = ZoneOffset.ofHours(1)
    private val uk = Formats(Locale.UK, zone)
    private val us = Formats(Locale.US, zone)
    private val today = LocalDate.of(2026, 10, 31)

    @Test
    fun `durations read like the Mac`() {
        assertThat(Formats.duration(0.0)).isEqualTo("0m")
        assertThat(Formats.duration(20.0)).isEqualTo("<1m")
        assertThat(Formats.duration(2520.0)).isEqualTo("42m")
        assertThat(Formats.duration(3900.0)).isEqualTo("1h 5m")
        assertThat(Formats.meetingDuration(2520.0)).isEqualTo("42 min")
        assertThat(Formats.meetingDuration(3900.0)).isEqualTo("1 hr 5 min")
        assertThat(Formats.meetingDuration(7200.0)).isEqualTo("2 hr")
        assertThat(Formats.meetingDuration(0.0)).isNull()
    }

    @Test
    fun `transcript offsets drop the hour when there is none`() {
        assertThat(Formats.offset(724.0)).isEqualTo("12:04")
        assertThat(Formats.offset(3723.9)).isEqualTo("1:02:03")
        assertThat(Formats.offset(-3.0)).isEqualTo("0:00")
    }

    @Test
    fun `day labels are relative, then weekday and date`() {
        assertThat(uk.dayLabel(today, today)).isEqualTo("Today")
        assertThat(uk.dayLabel(today.minusDays(1), today)).isEqualTo("Yesterday")
        assertThat(uk.dayLabel(LocalDate.of(2026, 10, 29), today)).isEqualTo("Thursday 29 October")
        assertThat(us.dayLabel(LocalDate.of(2026, 10, 29), today)).isEqualTo("Thursday, October 29")
        assertThat(uk.dayLabel(LocalDate.of(2025, 12, 24), today)).contains("2025")
        assertThat(uk.dueDay("2026-11-01", today)).isEqualTo("Tomorrow")
        assertThat(uk.shortDay("2026-10-30")).isEqualTo("Fri 30 Oct")
    }

    @Test
    fun `meeting times use the Mac's offset at the meeting`() = runBlocking {
        val meeting = TestLibrary.repository().meeting(TestLibrary.DESIGN_REVIEW)!!
        assertThat(uk.meetingMeta(meeting)).isEqualTo("Zoom · 10:30 · 42 min")
        assertThat(us.meetingTime(meeting)).isEqualTo("10:30 AM")
    }

    @Test
    fun `last sync reads as minutes, hours, then days`() {
        val now = Instant.parse("2026-10-31T10:12:00Z")
        assertThat(uk.ago(now.minusSeconds(20), now)).isEqualTo("just now")
        assertThat(uk.ago(now.minusSeconds(120), now)).isEqualTo("2 min ago")
        assertThat(uk.ago(now.minusSeconds(3 * 3600), now)).isEqualTo("3 h ago")
        assertThat(uk.ago(Instant.parse("2026-10-30T09:00:00Z"), now)).isEqualTo("Yesterday")
        assertThat(uk.ago(Instant.parse("2026-10-27T09:00:00Z"), now)).isEqualTo("Tue 27 Oct")
    }
}
