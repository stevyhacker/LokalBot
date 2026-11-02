package me.dotenv.lokalbot.companion.ui.projects

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import java.time.LocalDate
import kotlinx.coroutines.flow.StateFlow
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.model.MeetingAction
import me.dotenv.lokalbot.companion.data.model.OpenWork
import me.dotenv.lokalbot.companion.data.model.Project
import me.dotenv.lokalbot.companion.ui.LocalAppNavigator
import me.dotenv.lokalbot.companion.ui.OverflowDestinationsButton
import me.dotenv.lokalbot.companion.ui.actions.ActionItemRow
import me.dotenv.lokalbot.companion.ui.adaptive.ListDetailLayout
import me.dotenv.lokalbot.companion.ui.adaptive.ListPaneState
import me.dotenv.lokalbot.companion.ui.common.BackButton
import me.dotenv.lokalbot.companion.ui.common.CenteredColumn
import me.dotenv.lokalbot.companion.ui.common.LibraryViewModel
import me.dotenv.lokalbot.companion.ui.common.pageContentPadding
import me.dotenv.lokalbot.companion.ui.common.pagePadding
import me.dotenv.lokalbot.companion.ui.components.EmptyState
import me.dotenv.lokalbot.companion.ui.components.InitialsAvatar
import me.dotenv.lokalbot.companion.ui.components.MarkdownText
import me.dotenv.lokalbot.companion.ui.components.PageHeader
import me.dotenv.lokalbot.companion.ui.components.ProjectMonogram
import me.dotenv.lokalbot.companion.ui.components.StatTile
import me.dotenv.lokalbot.companion.ui.components.WorkspaceSection
import me.dotenv.lokalbot.companion.ui.components.chipChrome
import me.dotenv.lokalbot.companion.ui.components.rowSelection
import me.dotenv.lokalbot.companion.ui.format.Formats
import me.dotenv.lokalbot.companion.ui.meetings.MeetingRow
import me.dotenv.lokalbot.companion.ui.people.DecisionRow
import me.dotenv.lokalbot.companion.ui.people.OpenWorkRow
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTokens
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch

class ProjectsViewModel(repository: CompanionRepository) : LibraryViewModel(repository) {
    val projects: StateFlow<List<Project>?> = library(null) { repository.projects() }
}

data class ProjectState(val project: Project? = null, val meetings: List<Meeting> = emptyList(), val today: LocalDate, val loaded: Boolean = false)

class ProjectViewModel(repository: CompanionRepository, id: String) : LibraryViewModel(repository) {
    val state: StateFlow<ProjectState> = library(ProjectState(today = repository.today())) {
        val project = repository.project(id)
        val ids = project?.meetingIds.orEmpty().toSet()
        ProjectState(project, repository.meetings().filter { it.id in ids }, repository.today(), loaded = true)
    }

    fun setStatus(meetingId: String, actionId: String, status: ActionStatus) {
        viewModelScope.launch { repository.setActionStatus(meetingId, actionId, status) }
    }
}

@Composable
fun ProjectsScreen(repository: CompanionRepository) {
    val navigator = LocalAppNavigator.current
    ListDetailLayout(
        openRequest = navigator.projectLink,
        onOpenRequestHandled = { navigator.projectLink = null },
        list = { pane -> ProjectList(repository, pane) },
        detail = { id, back -> ProjectDetail(repository, id, back) },
        placeholder = { EmptyState(stringResource(R.string.projects_choose_title), stringResource(R.string.projects_choose_message), icon = Icons.Outlined.Folder) },
    )
}

@Composable
private fun projectSummary(project: Project): String = listOf(
    pluralStringResource(R.plurals.people_meetings, project.meetingIds.size, project.meetingIds.size),
    pluralStringResource(R.plurals.projects_yours, project.yourActions.size, project.yourActions.size),
    stringResource(R.string.projects_this_week, Formats.duration(project.timeThisWeekSeconds)),
).joinToString(" · ")

@Composable
private fun ProjectList(repository: CompanionRepository, pane: ListPaneState) {
    val viewModel = viewModel(key = "projects-${repository.id}") { ProjectsViewModel(repository) }
    val projects by viewModel.projects.collectAsStateWithLifecycle()
    val list = projects.orEmpty()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = pageContentPadding(horizontal = if (pane.twoPane) 12.dp else pagePadding())) {
        item(key = "header") {
            PageHeader(
                title = stringResource(R.string.nav_projects),
                subtitle = pluralStringResource(R.plurals.projects_count, list.size, list.size),
                actions = { OverflowDestinationsButton() },
                modifier = Modifier.padding(bottom = 12.dp),
            )
        }
        if (projects != null && list.isEmpty()) {
            item(key = "empty") { EmptyState(stringResource(R.string.projects_empty_title), stringResource(R.string.projects_empty_message)) }
        }
        items(list, key = { it.id }) { project ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(LokalBotTokens.Radius.row))
                    .rowSelection(pane.twoPane && pane.selectedKey == project.id)
                    .clickable(role = Role.Button) { pane.open(project.id) }
                    .padding(horizontal = 10.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                ProjectMonogram(project.name, size = 36.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(project.name, style = LokalBotType.body.copy(fontWeight = FontWeight.Medium))
                    Text(projectSummary(project), style = LokalBotType.secondary, color = LokalBotTheme.supportingText)
                }
            }
        }
    }
}

@Composable
private fun ProjectDetail(repository: CompanionRepository, id: String, onBack: (() -> Unit)?) {
    val viewModel = viewModel(key = "project-${repository.id}-$id") { ProjectViewModel(repository, id) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val navigator = LocalAppNavigator.current
    val project = state.project
    if (project == null) {
        if (state.loaded) EmptyState(stringResource(R.string.project_missing_title), stringResource(R.string.project_missing_message))
        return
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = pageContentPadding()) {
        item(key = "project") {
            CenteredColumn(LokalBotTokens.Spacing.readingMaxWidth) {
                Column(verticalArrangement = Arrangement.spacedBy(LokalBotTokens.Spacing.sectionSpacing)) {
                    if (onBack != null) BackButton(onBack)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        ProjectMonogram(project.name, size = 56.dp)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(project.name, style = LokalBotType.pageTitle)
                            Text(projectSummary(project), style = LokalBotType.secondary, color = LokalBotTheme.supportingText)
                        }
                    }
                    val question = stringResource(R.string.project_ask_question, project.name)
                    OutlinedButton(onClick = { navigator.ask(question) }) {
                        Icon(Icons.Outlined.AutoAwesome, null, Modifier.size(18.dp))
                        Text(stringResource(R.string.project_ask_about, project.name), Modifier.padding(start = 6.dp))
                    }
                    WorkspaceSection(stringResource(R.string.project_where_it_stands)) {
                        val stands = project.whereItStands
                        if (stands.isNullOrBlank()) {
                            Text(stringResource(R.string.project_no_note), style = LokalBotType.secondary, color = LokalBotTheme.supportingText)
                        } else {
                            MarkdownText(stands)
                        }
                    }
                    if (project.yourActions.isNotEmpty()) {
                        WorkspaceSection(stringResource(R.string.project_your_actions), contentPadding = 6.dp) {
                            project.yourActions.forEach { item ->
                                ActionItemRow(
                                    action = MeetingAction(id = item.actionId, text = item.text, ownerIsUser = true, dueDate = item.dueDate, status = item.status),
                                    today = state.today,
                                    onToggle = { viewModel.setStatus(item.meetingId, item.actionId, it) },
                                    onClick = { navigator.openAction(item.meetingId, item.actionId) },
                                )
                            }
                        }
                    }
                    if (project.waitingOnOthers.isNotEmpty()) {
                        WorkspaceSection(stringResource(R.string.project_waiting_on_others)) {
                            project.waitingOnOthers.forEach { item ->
                                Column {
                                    OpenWorkRow(OpenWork(item.meetingId, item.actionId, item.text, item.dueDate, theirs = true), state.today) {
                                        navigator.openAction(item.meetingId, item.actionId)
                                    }
                                    item.owner?.let { Text(it, style = LokalBotType.caption, color = LokalBotTheme.supportingText) }
                                }
                            }
                        }
                    }
                    if (project.decisions.isNotEmpty()) {
                        WorkspaceSection(stringResource(R.string.project_decisions)) {
                            project.decisions.forEach { DecisionRow(it) { navigator.openMeeting(it.meetingId) } }
                        }
                    }
                    WorkspaceSection(stringResource(R.string.project_time_this_week)) {
                        StatTile(Icons.Outlined.Schedule, Formats.duration(project.timeThisWeekSeconds), stringResource(R.string.stat_tracked))
                    }
                    if (project.people.isNotEmpty()) {
                        WorkspaceSection(stringResource(R.string.project_people)) {
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                project.people.forEach { person ->
                                    Row(
                                        Modifier.clip(CircleShape).clickable(role = Role.Button) { navigator.openPerson(person.id) }.chipChrome(),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                                    ) {
                                        InitialsAvatar(person.displayName, size = 20.dp)
                                        Text(person.displayName, style = LokalBotType.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if (state.meetings.isNotEmpty()) {
                        WorkspaceSection(stringResource(R.string.project_meetings), contentPadding = 4.dp) {
                            state.meetings.forEach { MeetingRow(it, onClick = { navigator.openMeeting(it.id) }) }
                        }
                    }
                }
            }
        }
    }
}
