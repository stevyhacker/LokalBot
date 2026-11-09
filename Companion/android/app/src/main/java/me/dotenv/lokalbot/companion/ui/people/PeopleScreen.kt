package me.dotenv.lokalbot.companion.ui.people

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.CallMade
import androidx.compose.material.icons.automirrored.outlined.CallReceived
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.CheckCircleOutline
import androidx.compose.material.icons.outlined.People
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import java.time.Instant
import java.time.LocalDate
import kotlinx.coroutines.flow.StateFlow
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.ActionOrdering
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.model.MeetingAction
import me.dotenv.lokalbot.companion.data.model.MeetingNote
import me.dotenv.lokalbot.companion.data.model.OpenWork
import me.dotenv.lokalbot.companion.data.model.Person
import me.dotenv.lokalbot.companion.ui.LocalAppNavigator
import me.dotenv.lokalbot.companion.ui.LocalFormats
import me.dotenv.lokalbot.companion.ui.OverflowDestinationsButton
import me.dotenv.lokalbot.companion.ui.adaptive.ListDetailLayout
import me.dotenv.lokalbot.companion.ui.adaptive.ListPaneState
import me.dotenv.lokalbot.companion.ui.common.BackButton
import me.dotenv.lokalbot.companion.ui.common.CenteredColumn
import me.dotenv.lokalbot.companion.ui.common.LibraryViewModel
import me.dotenv.lokalbot.companion.ui.common.pageContentPadding
import me.dotenv.lokalbot.companion.ui.common.pagePadding
import me.dotenv.lokalbot.companion.ui.components.EmptyState
import me.dotenv.lokalbot.companion.ui.components.InitialsAvatar
import me.dotenv.lokalbot.companion.ui.components.PageHeader
import me.dotenv.lokalbot.companion.ui.components.WorkspaceSection
import me.dotenv.lokalbot.companion.ui.components.chipChrome
import me.dotenv.lokalbot.companion.ui.components.rowSelection
import me.dotenv.lokalbot.companion.ui.meetings.MeetingRow
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTokens
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

class PeopleViewModel(repository: CompanionRepository) : LibraryViewModel(repository) {
    val people: StateFlow<List<Person>?> = library(null) { repository.people() }
    fun now(): Instant = repository.now()
}

data class PersonState(val person: Person? = null, val meetings: List<Meeting> = emptyList(), val today: LocalDate, val loaded: Boolean = false)

class PersonViewModel(repository: CompanionRepository, id: String) : LibraryViewModel(repository) {
    val state: StateFlow<PersonState> = library(PersonState(today = repository.today())) {
        val person = repository.person(id)
        val ids = person?.meetingIds.orEmpty().toSet()
        PersonState(person, repository.meetings().filter { it.id in ids }, repository.today(), loaded = true)
    }
}

@Composable
fun PeopleScreen(repository: CompanionRepository) {
    val navigator = LocalAppNavigator.current
    ListDetailLayout(
        openRequest = navigator.personLink,
        onOpenRequestHandled = { navigator.personLink = null },
        list = { pane -> PeopleList(repository, pane) },
        detail = { id, back -> PersonDetail(repository, id, back) },
        placeholder = { EmptyState(stringResource(R.string.people_choose_title), stringResource(R.string.people_choose_message), icon = Icons.Outlined.People) },
    )
}

@Composable
private fun PeopleList(repository: CompanionRepository, pane: ListPaneState) {
    val viewModel = viewModel(key = "people-${repository.id}") { PeopleViewModel(repository) }
    val people by viewModel.people.collectAsStateWithLifecycle()
    val formats = LocalFormats.current
    val list = people.orEmpty()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = pageContentPadding(horizontal = if (pane.twoPane) 12.dp else pagePadding())) {
        item(key = "header") {
            PageHeader(
                title = stringResource(R.string.nav_people),
                subtitle = pluralStringResource(R.plurals.people_count, list.size, list.size),
                actions = { OverflowDestinationsButton() },
                modifier = Modifier.padding(bottom = 12.dp),
            )
        }
        if (people != null && list.isEmpty()) {
            item(key = "empty") { EmptyState(stringResource(R.string.people_empty_title), stringResource(R.string.people_empty_message)) }
        }
        items(list, key = { it.id }) { person ->
            val waitingOnYou = person.openWork.count { !it.theirs }
            val waitingOnThem = person.openWork.count { it.theirs }
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(LokalBotTokens.Radius.row))
                    .rowSelection(pane.twoPane && pane.selectedKey == person.id)
                    .clickable(role = Role.Button) { pane.open(person.id) }
                    .padding(horizontal = 10.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                InitialsAvatar(person.displayName, size = 36.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(person.displayName, style = LokalBotType.body.copy(fontWeight = FontWeight.Medium), maxLines = 1)
                    Text(
                        pluralStringResource(R.plurals.people_meetings, person.meetingIds.size, person.meetingIds.size),
                        style = LokalBotType.secondary,
                        color = LokalBotTheme.supportingText,
                    )
                }
                Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    person.lastMetAt?.let { Instant.parse(it) }?.let {
                        Text(formats.ago(it, viewModel.now()), style = LokalBotType.caption, color = LokalBotTheme.supportingText)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        if (waitingOnYou > 0) CountBadge(Icons.AutoMirrored.Outlined.CallMade, waitingOnYou, LokalBotTheme.palette.attentionText, pluralStringResource(R.plurals.people_waiting_on_you_count, waitingOnYou, waitingOnYou))
                        if (waitingOnThem > 0) CountBadge(Icons.AutoMirrored.Outlined.CallReceived, waitingOnThem, LokalBotTheme.supportingText, pluralStringResource(R.plurals.people_waiting_on_them_count, waitingOnThem, waitingOnThem))
                    }
                }
            }
        }
    }
}

@Composable
private fun CountBadge(icon: androidx.compose.ui.graphics.vector.ImageVector, count: Int, color: Color, description: String) {
    Row(Modifier.chipChrome(compact = true), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        Icon(icon, description, tint = color, modifier = Modifier.size(12.dp))
        Text(count.toString(), style = LokalBotType.caption.copy(fontFeatureSettings = "tnum"), color = color)
    }
}

@Composable
private fun PersonDetail(repository: CompanionRepository, id: String, onBack: (() -> Unit)?) {
    val viewModel = viewModel(key = "person-${repository.id}-$id") { PersonViewModel(repository, id) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val navigator = LocalAppNavigator.current
    val person = state.person
    if (person == null) {
        if (state.loaded) EmptyState(stringResource(R.string.person_missing_title), stringResource(R.string.person_missing_message))
        return
    }
    val first = person.displayName.substringBefore(' ')
    val yours = person.openWork.filter { !it.theirs }
    val theirs = person.openWork.filter { it.theirs }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = pageContentPadding()) {
        item(key = "person") {
            CenteredColumn(LokalBotTokens.Spacing.readingMaxWidth) {
                Column(verticalArrangement = Arrangement.spacedBy(LokalBotTokens.Spacing.sectionSpacing)) {
                    if (onBack != null) BackButton(onBack)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        InitialsAvatar(person.displayName, size = 56.dp)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(person.displayName, style = LokalBotType.pageTitle)
                            Text(
                                listOf(
                                    pluralStringResource(R.plurals.people_meetings, person.meetingIds.size, person.meetingIds.size),
                                    pluralStringResource(R.plurals.people_open, person.openWork.size, person.openWork.size),
                                ).joinToString(" · "),
                                style = LokalBotType.secondary,
                                color = LokalBotTheme.supportingText,
                            )
                        }
                    }
                    val question = stringResource(R.string.person_ask_question, first)
                    OutlinedButton(onClick = { navigator.ask(question) }) {
                        Icon(Icons.Outlined.AutoAwesome, null, Modifier.size(18.dp))
                        Text(stringResource(R.string.person_ask_about, first), Modifier.padding(start = 6.dp))
                    }
                    if (yours.isEmpty() && theirs.isEmpty()) {
                        WorkspaceSection(stringResource(R.string.person_open_work)) {
                            Text(stringResource(R.string.person_nothing_open, first), style = LokalBotType.secondary, color = LokalBotTheme.supportingText)
                        }
                    }
                    if (yours.isNotEmpty()) {
                        WorkspaceSection(stringResource(R.string.person_waiting_on_you)) {
                            yours.forEach { OpenWorkRow(it, state.today) { navigator.openAction(it.meetingId, it.actionId) } }
                        }
                    }
                    if (theirs.isNotEmpty()) {
                        WorkspaceSection(stringResource(R.string.person_waiting_on, first)) {
                            theirs.forEach { OpenWorkRow(it, state.today) { navigator.openAction(it.meetingId, it.actionId) } }
                        }
                    }
                    if (person.decisionsTogether.isNotEmpty()) {
                        WorkspaceSection(stringResource(R.string.person_decisions_together)) {
                            person.decisionsTogether.forEach { DecisionRow(it) { navigator.openMeeting(it.meetingId) } }
                        }
                    }
                    if (state.meetings.isNotEmpty()) {
                        WorkspaceSection(stringResource(R.string.person_meetings_together), contentPadding = 4.dp) {
                            state.meetings.forEach { MeetingRow(it, onClick = { navigator.openMeeting(it.id) }) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun OpenWorkRow(work: OpenWork, today: LocalDate, onClick: () -> Unit) {
    val formats = LocalFormats.current
    val overdue = work.dueDate?.let { ActionOrdering.isOverdue(MeetingAction(id = work.actionId, text = work.text, dueDate = it), today) } == true
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).clickable(role = Role.Button, onClick = onClick).padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(work.text, style = LokalBotType.body, modifier = Modifier.weight(1f))
        work.dueDate?.let {
            Text(
                formats.dueDay(it, today),
                style = LokalBotType.timestamp,
                color = if (overdue) LokalBotTheme.palette.recordingText else LokalBotTheme.supportingText,
            )
        }
    }
}

@Composable
fun DecisionRow(note: MeetingNote, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).clickable(role = Role.Button, onClick = onClick).padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Outlined.CheckCircleOutline, null, tint = LokalBotTheme.palette.successText, modifier = Modifier.padding(top = 2.dp).size(20.dp))
        Text(note.text, style = LokalBotType.body, modifier = Modifier.weight(1f))
    }
}
