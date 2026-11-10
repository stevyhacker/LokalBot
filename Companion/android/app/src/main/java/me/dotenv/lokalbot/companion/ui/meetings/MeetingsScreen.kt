package me.dotenv.lokalbot.companion.ui.meetings

import android.view.accessibility.AccessibilityManager
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalInputModeManager
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
import me.dotenv.lokalbot.companion.ui.recording.DeleteRecordingDialog
import me.dotenv.lokalbot.companion.ui.recording.DeviceRecordingRow
import me.dotenv.lokalbot.companion.ui.recording.LocalRecordAction
import me.dotenv.lokalbot.companion.ui.recording.RecordIconButton
import me.dotenv.lokalbot.companion.ui.recording.RenameRecordingDialog
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
    val recordings by viewModel.recordings.collectAsStateWithLifecycle()
    val computer by viewModel.computerName.collectAsStateWithLifecycle()
    val formats = LocalFormats.current
    val record = LocalRecordAction.current
    var deleting by rememberSaveable { mutableStateOf<String?>(null) }
    var renaming by rememberSaveable { mutableStateOf<String?>(null) }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = pageContentPadding(horizontal = if (pane.twoPane) 12.dp else pagePadding()),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        item(key = "header") {
            Column(Modifier.padding(bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                PageHeader(
                    title = stringResource(R.string.nav_meetings),
                    // Until the list has reached its end, only how many are listed is known.
                    subtitle = if (state.hasMore) stringResource(R.string.meetings_count_more, state.total)
                    else pluralStringResource(R.plurals.meetings_count, state.total, state.total),
                    actions = {
                        record?.let { RecordIconButton(it) }
                        OverflowDestinationsButton(offerRecord = false)
                    },
                )
                SearchField(query, viewModel::setQuery, stringResource(R.string.meetings_search))
            }
        }
        if (query.isBlank() && recordings.isNotEmpty()) {
            item(key = "from-this-device") {
                SectionHeader(stringResource(R.string.meetings_from_this_device), Modifier.padding(start = 10.dp, top = 4.dp, bottom = 4.dp))
            }
            items(recordings, key = { "recording-${it.recording.id}" }) { row ->
                DeviceRecordingRow(
                    row = row,
                    computer = computer,
                    today = state.today,
                    onOpen = { record?.invoke() },
                    onRename = { renaming = row.recording.id },
                    onDelete = { deleting = row.recording.id },
                    onRetry = { viewModel.retryRecording(row.recording.id) },
                )
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
        if (state.hasMore) {
            item(key = "more") {
                // Reaching the end of what's listed loads the meetings before it.
                LaunchedEffect(state) { viewModel.showMore() }
                Box(Modifier.fillMaxWidth().padding(vertical = 16.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                }
            }
        }
    }
    deleting?.let { id ->
        DeleteRecordingDialog(
            onConfirm = {
                deleting = null
                viewModel.deleteRecording(id)
            },
            onDismiss = { deleting = null },
        )
    }
    renaming?.let { id ->
        RenameRecordingDialog(
            title = recordings.firstOrNull { it.recording.id == id }?.recording?.title.orEmpty(),
            onSave = {
                renaming = null
                viewModel.renameRecording(id, it)
            },
            onDismiss = { renaming = null },
        )
    }
}

/**
 * The quiet search field used above lists. On a touchscreen it takes focus only
 * when pressed: the pane scaffold gives its pane focus on arrival, which would
 * otherwise land here and open the keyboard, including on the way back from
 * recording. Accessibility services and keyboards don't press, so they can always.
 */
@Composable
fun SearchField(value: String, onValueChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier) {
    val palette = LokalBotTheme.palette
    val inputMode = LocalInputModeManager.current
    val accessibility = LocalContext.current.getSystemService(AccessibilityManager::class.java)
    var pressed by remember { mutableStateOf(false) }
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier
            .fillMaxWidth()
            .pointerInput(Unit) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    pressed = true
                }
            }
            .focusProperties { canFocus = pressed || inputMode.inputMode != InputMode.Touch || accessibility?.isEnabled == true }
            .onFocusChanged { if (!it.hasFocus) pressed = false },
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
