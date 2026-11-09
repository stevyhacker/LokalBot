package me.dotenv.lokalbot.companion.ui.actions

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.FormatQuote
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.TaskAlt
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.ActionOrdering
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.ui.LocalAppNavigator
import me.dotenv.lokalbot.companion.ui.LocalFormats
import me.dotenv.lokalbot.companion.ui.OverflowDestinationsButton
import me.dotenv.lokalbot.companion.ui.adaptive.ListDetailLayout
import me.dotenv.lokalbot.companion.ui.adaptive.ListPaneState
import me.dotenv.lokalbot.companion.ui.common.BackButton
import me.dotenv.lokalbot.companion.ui.common.CenteredColumn
import me.dotenv.lokalbot.companion.ui.common.pageContentPadding
import me.dotenv.lokalbot.companion.ui.common.pagePadding
import me.dotenv.lokalbot.companion.ui.components.EmptyState
import me.dotenv.lokalbot.companion.ui.components.PageHeader
import me.dotenv.lokalbot.companion.ui.components.SectionHeader
import me.dotenv.lokalbot.companion.ui.components.groupedSurface
import me.dotenv.lokalbot.companion.ui.format.Formats
import me.dotenv.lokalbot.companion.ui.navigation.ActionLink
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTokens
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

@Composable
fun ActionsScreen(repository: CompanionRepository) {
    val navigator = LocalAppNavigator.current
    ListDetailLayout(
        openRequest = navigator.actionLink?.key,
        onOpenRequestHandled = { navigator.actionLink = null },
        list = { pane -> ActionList(repository, pane) },
        detail = { key, back -> ActionDetail(repository, ActionLink.fromKey(key), back) },
        placeholder = {
            EmptyState(stringResource(R.string.actions_choose_title), stringResource(R.string.actions_choose_message), icon = Icons.Outlined.TaskAlt)
        },
    )
}

@Composable
private fun ActionList(repository: CompanionRepository, pane: ListPaneState) {
    val viewModel = viewModel(key = "actions-${repository.id}") { ActionsViewModel(repository) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = pageContentPadding(horizontal = if (pane.twoPane) 12.dp else pagePadding()),
    ) {
        item(key = "header") {
            Column(Modifier.padding(bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                PageHeader(
                    title = stringResource(R.string.nav_actions),
                    subtitle = pluralStringResource(R.plurals.actions_count, state.count, state.count),
                    actions = { OverflowDestinationsButton() },
                )
                FilterBar(state.filters, onOwner = viewModel::setOwner, onStatus = viewModel::setStatus)
            }
        }
        if (state.loaded && state.groups.isEmpty()) {
            item(key = "empty") {
                EmptyState(stringResource(R.string.actions_empty_title), stringResource(R.string.actions_empty_message))
            }
        }
        state.groups.forEach { (group, rows) ->
            item(key = "group-$group") {
                SectionHeader(groupTitle(group), Modifier.padding(start = 6.dp, top = 16.dp, bottom = 4.dp))
            }
            items(rows, key = { "${it.meetingId}/${it.action.id}" }) { row ->
                ActionItemRow(
                    action = row.action,
                    today = state.today,
                    meetingTitle = row.meetingTitle,
                    pending = row.pending,
                    selected = pane.twoPane && pane.selectedKey == ActionLink(row.meetingId, row.action.id).key,
                    onToggle = { viewModel.setActionStatus(row, it) },
                    onClick = { pane.open(ActionLink(row.meetingId, row.action.id).key) },
                )
            }
        }
    }
}

@Composable
private fun groupTitle(group: ActionOrdering.Group): String = stringResource(
    when (group) {
        ActionOrdering.Group.Overdue -> R.string.actions_group_overdue
        ActionOrdering.Group.ThisWeek -> R.string.actions_group_this_week
        ActionOrdering.Group.Later -> R.string.actions_group_later
        ActionOrdering.Group.NoDate -> R.string.actions_group_no_date
        ActionOrdering.Group.Closed -> R.string.actions_group_closed
    },
)

@Composable
private fun FilterBar(filters: ActionFilters, onOwner: (OwnerFilter) -> Unit, onStatus: (ActionStatus) -> Unit) {
    val palette = LokalBotTheme.palette
    val colors = FilterChipDefaults.filterChipColors(
        selectedContainerColor = palette.accentFill,
        selectedLabelColor = androidx.compose.ui.graphics.Color.White,
        selectedLeadingIconColor = androidx.compose.ui.graphics.Color.White,
        containerColor = palette.chipFill,
        labelColor = LokalBotTheme.supportingText,
    )
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        listOf(
            OwnerFilter.Mine to R.string.actions_filter_mine,
            OwnerFilter.Others to R.string.actions_filter_others,
            OwnerFilter.Unclear to R.string.actions_filter_unclear,
        ).forEach { (owner, label) ->
            FilterChip(
                selected = filters.owner == owner,
                onClick = { onOwner(owner) },
                label = { Text(stringResource(label)) },
                colors = colors,
                border = null,
                shape = CircleShape,
            )
        }
        VerticalDivider(Modifier.height(24.dp), color = palette.separator)
        listOf(
            ActionStatus.Open to R.string.action_status_open,
            ActionStatus.Done to R.string.action_status_done,
            ActionStatus.Deferred to R.string.action_status_deferred,
        ).forEach { (status, label) ->
            FilterChip(
                selected = filters.status == status,
                onClick = { onStatus(status) },
                label = { Text(stringResource(label)) },
                colors = colors,
                border = null,
                shape = CircleShape,
            )
        }
    }
}

/** One action: who and when, the passage it came from, and what you can do from here. */
@Composable
private fun ActionDetail(repository: CompanionRepository, link: ActionLink, onBack: (() -> Unit)?) {
    val viewModel = viewModel(key = "action-${repository.id}-${link.key}") { ActionDetailViewModel(repository, link.meetingId, link.actionId) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val navigator = LocalAppNavigator.current
    val formats = LocalFormats.current
    val palette = LokalBotTheme.palette
    val action = state.action
    val meeting = state.meeting
    if (action == null || meeting == null) {
        if (state.loaded) EmptyState(stringResource(R.string.action_missing_title), stringResource(R.string.action_missing_message))
        return
    }
    val overdue = ActionOrdering.isOverdue(action, state.today)
    LazyColumn(Modifier.fillMaxSize(), contentPadding = pageContentPadding()) {
        item(key = "detail") {
            CenteredColumn(LokalBotTokens.Spacing.readingMaxWidth) {
                Column(verticalArrangement = Arrangement.spacedBy(LokalBotTokens.Spacing.sectionSpacing)) {
                    if (onBack != null) BackButton(onBack)
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(action.text, style = LokalBotType.question)
                        val owner = when {
                            action.ownerIsUser -> stringResource(R.string.action_owner_you)
                            action.ownerUnclear -> stringResource(R.string.action_owner_unclear)
                            else -> action.owner.orEmpty()
                        }
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            DetailFact(stringResource(R.string.action_detail_owner), owner, if (action.ownerUnclear) palette.attentionText else null)
                            action.dueDate?.let { due ->
                                val value = buildString {
                                    append(formats.shortDay(due))
                                    if (overdue) append(" · ").append(stringResource(R.string.action_overdue_word))
                                    action.dueText?.let { append(" · ").append(stringResource(R.string.action_said, it)) }
                                }
                                DetailFact(stringResource(R.string.action_detail_due), value, if (overdue) palette.recordingText else null)
                            }
                            DetailFact(stringResource(R.string.action_detail_importance), action.importance.toString(), null)
                            DetailFact(stringResource(R.string.action_detail_status), stringResource(statusLabel(action.status)), null)
                        }
                    }
                    action.citations.firstOrNull()?.let { citation ->
                        Column(verticalArrangement = Arrangement.spacedBy(LokalBotTokens.Spacing.headerToContent)) {
                            Text(stringResource(R.string.action_from_meeting), style = LokalBotType.section)
                            Column(
                                Modifier.fillMaxWidth()
                                    .clip(RoundedCornerShape(LokalBotTokens.Radius.panel))
                                    .clickable(role = Role.Button) { navigator.openMeeting(meeting.id, citation.start.takeIf { state.hasTranscript }) }
                                    .groupedSurface()
                                    .padding(14.dp),
                                verticalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Icon(Icons.Outlined.FormatQuote, null, tint = palette.accentText, modifier = Modifier.size(16.dp))
                                    Text(
                                        listOfNotNull(citation.speaker, meeting.title, Formats.offset(citation.start)).joinToString(" · "),
                                        style = LokalBotType.secondary.copy(fontWeight = FontWeight.Medium),
                                        color = palette.accentText,
                                    )
                                }
                                Text("“${citation.excerpt}”", style = LokalBotType.reading.copy(fontStyle = FontStyle.Italic))
                            }
                        }
                    }
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (action.status == ActionStatus.Open) {
                            Button(onClick = { viewModel.setStatus(ActionStatus.Done) }, colors = ButtonDefaults.buttonColors(containerColor = palette.accentFill)) {
                                Icon(Icons.Outlined.CheckCircle, null, Modifier.size(18.dp))
                                Text(stringResource(R.string.action_mark_done_button), Modifier.padding(start = 6.dp))
                            }
                            OutlinedButton(onClick = { viewModel.setStatus(ActionStatus.Deferred) }) { Text(stringResource(R.string.action_defer)) }
                        } else {
                            Button(onClick = { viewModel.setStatus(ActionStatus.Open) }, colors = ButtonDefaults.buttonColors(containerColor = palette.accentFill)) {
                                Text(stringResource(R.string.action_reopen))
                            }
                        }
                        TextButton(onClick = { navigator.openMeeting(meeting.id) }) { Text(stringResource(R.string.action_open_meeting)) }
                    }
                    if (state.pending) {
                        Row(
                            Modifier.fillMaxWidth().groupedSurface(tint = palette.attention).padding(12.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(Icons.Outlined.Schedule, null, tint = palette.attentionText, modifier = Modifier.size(18.dp))
                            Text(
                                stringResource(R.string.action_pending_message, stringResource(statusLabel(action.status)).lowercase()),
                                style = LokalBotType.secondary,
                                color = palette.attentionText,
                            )
                        }
                    }
                }
            }
        }
    }
}

private fun statusLabel(status: ActionStatus) = when (status) {
    ActionStatus.Open -> R.string.action_status_open
    ActionStatus.Done -> R.string.action_status_done
    ActionStatus.Deferred -> R.string.action_status_deferred
}

@Composable
private fun DetailFact(label: String, value: String, valueColor: androidx.compose.ui.graphics.Color?) {
    Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Text(label, style = LokalBotType.secondary, color = LokalBotTheme.supportingText)
        Text(value, style = LokalBotType.secondary.copy(fontWeight = FontWeight.Medium), color = valueColor ?: androidx.compose.ui.graphics.Color.Unspecified)
    }
}

