package me.dotenv.lokalbot.companion.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalResources
import java.time.ZoneId
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.ui.format.Formats
import me.dotenv.lokalbot.companion.ui.format.RelativeWords

val LocalFormats = staticCompositionLocalOf<Formats> { error("Formats not provided") }

@Composable
fun rememberFormats(zone: ZoneId): Formats {
    val locale = LocalConfiguration.current.locales[0]
    val resources = LocalResources.current
    return remember(locale, zone, resources) {
        Formats(
            locale = locale,
            zone = zone,
            words = RelativeWords(
                today = resources.getString(R.string.day_today),
                yesterday = resources.getString(R.string.day_yesterday),
                tomorrow = resources.getString(R.string.day_tomorrow),
                justNow = resources.getString(R.string.time_just_now),
                minutesAgo = { resources.getString(R.string.time_minutes_ago, it) },
                hoursAgo = { resources.getString(R.string.time_hours_ago, it) },
            ),
        )
    }
}
