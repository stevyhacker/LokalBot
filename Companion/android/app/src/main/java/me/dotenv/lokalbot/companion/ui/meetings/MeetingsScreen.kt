package me.dotenv.lokalbot.companion.ui.meetings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.ui.LocalAppNavigator
import me.dotenv.lokalbot.companion.ui.LocalFormats
import me.dotenv.lokalbot.companion.ui.OverflowDestinationsButton
import me.dotenv.lokalbot.companion.ui.adaptive.ListDetailLayout
import me.dotenv.lokalbot.companion.ui.adaptive.ListPaneState
import me.dotenv.lokalbot.companion.ui.common.pageContentPadding
import me.dotenv.lokalbot.companion.ui.common.pagePadding
import me.dotenv.lokalbot.companion.ui.components.EmptyState
import me.dotenv.lokalbot.companion.ui.components.PageHeader
import me.dotenv.lokalbot.companion.ui.components.SectionHeader
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme

@Composable
fun MeetingsScreen(repository: CompanionRepository) {
    val navigator = LocalAppNavigator.current
    val link = navigator.meetingLink
    ListDetailLayout(
        openRequest = link?.meetingId,
        // A link with a moment stays until the transcript has scrolled to it.
        onOpenRequestHandled = { if (navigator.meetingLink?.at == null) navigator.meetingLink = null },
        list = { pane -> MeetingList(repository, pane) },
        detail = { key, back ->
            val focus = navigator.meetingLink?.takeIf { it.meetingId == key }?.at
            MeetingDetail(repository, key, focusAt = focus, onFocusHandled = { navigator.meetingLink = null }, onBack = back)
        },
        placeholder = {
            EmptyState(
                title = stringResource(R.string.meetings_choose_title),
                message = stringResource(R.string.meetings_choose_message),
                icon = Icons.Outlined.GraphicEq,
            )
        },
    )
}

@Composable
private fun MeetingList(repository: CompanionRepository, pane: ListPaneState) {
    val viewModel = viewModel(key = "meetings-${repository.id}") { MeetingsViewModel(repository) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val query by viewModel.query.collectAsStateWithLifecycle()
    val formats = LocalFormats.current
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = pageContentPadding(horizontal = if (pane.twoPane) 12.dp else pagePadding()),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        item(key = "header") {
            Column(Modifier.padding(bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                PageHeader(
                    title = stringResource(R.string.nav_meetings),
                    subtitle = pluralStringResource(R.plurals.meetings_count, state.total, state.total),
                    actions = { OverflowDestinationsButton() },
                )
                SearchField(query, viewModel::setQuery, stringResource(R.string.meetings_search))
            }
        }
        if (state.loaded && state.days.isEmpty()) {
            item(key = "empty") {
                if (query.isBlank()) {
                    EmptyState(stringResource(R.string.meetings_empty_title), stringResource(R.string.meetings_empty_message))
                } else {
                    EmptyState(stringResource(R.string.meetings_no_results_title), stringResource(R.string.meetings_no_results_message))
                }
            }
        }
        state.days.forEach { group ->
            item(key = "day-${group.day}") {
                SectionHeader(formats.dayLabel(group.day, state.today), Modifier.padding(start = 10.dp, top = 14.dp, bottom = 4.dp))
            }
            items(group.meetings, key = { it.id }) { meeting ->
                MeetingRow(meeting, onClick = { pane.open(meeting.id) }, selected = pane.twoPane && pane.selectedKey == meeting.id)
            }
        }
    }
}

/** The quiet search field used above lists. */
@Composable
fun SearchField(value: String, onValueChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier) {
    val palette = LokalBotTheme.palette
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.fillMaxWidth(),
        placeholder = { androidx.compose.material3.Text(placeholder) },
        leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
        singleLine = true,
        shape = RoundedCornerShape(10.dp),
        colors = OutlinedTextFieldDefaults.colors(
            unfocusedContainerColor = palette.groupFill,
            focusedContainerColor = palette.groupFill,
            unfocusedBorderColor = palette.groupStroke,
            focusedBorderColor = palette.accentFill,
        ),
    )
}
