package me.dotenv.lokalbot.companion.ui.navigation

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.TaskAlt
import androidx.compose.material.icons.outlined.ViewTimeline
import androidx.compose.material.icons.outlined.WbSunny
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.vector.ImageVector
import me.dotenv.lokalbot.companion.R

/** Top-level destinations, in the Mac sidebar's order, with Actions promoted for phones. */
enum class Destination(@param:StringRes val label: Int, val icon: ImageVector, val primary: Boolean) {
    Today(R.string.nav_today, Icons.Outlined.WbSunny, primary = true),
    Meetings(R.string.nav_meetings, Icons.Outlined.GraphicEq, primary = true),
    Actions(R.string.nav_actions, Icons.Outlined.TaskAlt, primary = true),
    Timeline(R.string.nav_timeline, Icons.Outlined.ViewTimeline, primary = true),
    People(R.string.nav_people, Icons.Outlined.People, primary = false),
    Projects(R.string.nav_projects, Icons.Outlined.Folder, primary = false),
    Ask(R.string.nav_ask, Icons.Outlined.AutoAwesome, primary = true),
    Settings(R.string.nav_settings, Icons.Outlined.Settings, primary = false),
}

/** A meeting to open, optionally at a moment in its transcript. */
data class MeetingLink(val meetingId: String, val at: Double? = null)

/** An action to open, by meeting and action id. */
data class ActionLink(val meetingId: String, val actionId: String) {
    val key: String get() = "$meetingId/$actionId"

    companion object {
        fun fromKey(key: String): ActionLink = ActionLink(key.substringBefore('/'), key.substringAfter('/'))
    }
}

/**
 * The selected destination plus one-shot links between screens (a citation
 * opening a meeting, a person opening Ask). The destination survives
 * rotation and folding; pane selections are saved by each scaffold.
 */
@Stable
class AppNavigator(initial: Destination) {
    var destination by mutableStateOf(initial)
        private set
    var meetingLink by mutableStateOf<MeetingLink?>(null)
    var actionLink by mutableStateOf<ActionLink?>(null)
    var personLink by mutableStateOf<String?>(null)
    var projectLink by mutableStateOf<String?>(null)
    var timelineDay by mutableStateOf<String?>(null)
    var askDraft by mutableStateOf<String?>(null)

    fun go(destination: Destination) {
        this.destination = destination
    }

    fun openMeeting(meetingId: String, at: Double? = null) {
        meetingLink = MeetingLink(meetingId, at)
        destination = Destination.Meetings
    }

    fun openAction(meetingId: String, actionId: String) {
        actionLink = ActionLink(meetingId, actionId)
        destination = Destination.Actions
    }

    fun openPerson(id: String) {
        personLink = id
        destination = Destination.People
    }

    fun openProject(id: String) {
        projectLink = id
        destination = Destination.Projects
    }

    fun openDay(day: String) {
        timelineDay = day
        destination = Destination.Timeline
    }

    fun ask(question: String) {
        askDraft = question
        destination = Destination.Ask
    }

    companion object {
        val Saver: Saver<AppNavigator, String> = Saver(
            save = { it.destination.name },
            restore = { AppNavigator(Destination.valueOf(it)) },
        )
    }
}

@Composable
fun rememberAppNavigator(initial: Destination = Destination.Today): AppNavigator =
    rememberSaveable(saver = AppNavigator.Saver) { AppNavigator(initial) }
