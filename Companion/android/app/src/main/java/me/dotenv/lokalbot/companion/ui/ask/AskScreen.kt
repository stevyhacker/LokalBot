package me.dotenv.lokalbot.companion.ui.ask

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.MacRoute
import me.dotenv.lokalbot.companion.data.SearchHit
import me.dotenv.lokalbot.companion.data.SyncFailure
import me.dotenv.lokalbot.companion.data.SyncState
import me.dotenv.lokalbot.companion.data.model.AnswerLocation
import me.dotenv.lokalbot.companion.data.model.AskCitation
import me.dotenv.lokalbot.companion.data.model.AskResult
import me.dotenv.lokalbot.companion.ui.LocalAppNavigator
import me.dotenv.lokalbot.companion.ui.LocalFormats
import me.dotenv.lokalbot.companion.ui.OverflowDestinationsButton
import me.dotenv.lokalbot.companion.ui.adaptive.LocalWindowLayout
import me.dotenv.lokalbot.companion.ui.adaptive.WidthClass
import me.dotenv.lokalbot.companion.ui.common.pagePadding
import me.dotenv.lokalbot.companion.ui.components.LoadingStateLabel
import me.dotenv.lokalbot.companion.ui.components.MarkdownText
import me.dotenv.lokalbot.companion.ui.components.SourceBadge
import me.dotenv.lokalbot.companion.ui.components.StatusDot
import me.dotenv.lokalbot.companion.ui.components.chipChrome
import me.dotenv.lokalbot.companion.ui.components.groupedSurface
import me.dotenv.lokalbot.companion.ui.format.Formats
import me.dotenv.lokalbot.companion.ui.text.Citations
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTokens
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

/**
 * Ask: the Mac's editorial reading layout (no bubbles, the question in
 * semibold, numbered teal source badges) with the composer docked below.
 * Tabletop posture puts the answer on the upright half and the composer on
 * the flat half.
 */
@Composable
fun AskScreen(repository: CompanionRepository) {
    val viewModel = viewModel(key = "ask-${repository.id}") { AskViewModel(repository) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val sync by viewModel.syncState.collectAsStateWithLifecycle()
    val layout = LocalWindowLayout.current
    val navigator = LocalAppNavigator.current
    var draft by rememberSaveable { mutableStateOf("") }
    var historyOpen by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(navigator.askDraft) {
        navigator.askDraft?.let {
            draft = it
            navigator.askDraft = null
        }
    }
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    val send = {
        viewModel.ask(draft)
        draft = ""
    }
    val actions = TurnActions(
        onCitation = { citation -> citation.meetingId?.let { navigator.openMeeting(it, citation.at) } },
        onSearch = viewModel::searchThisDevice,
        onQueue = { id ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            viewModel.askWhenMacIsBack(id)
        },
        onHit = { hit -> hit.meetingId?.let { navigator.openMeeting(it, hit.at) } ?: hit.date?.let(navigator::openDay) },
        onRetry = { question -> viewModel.ask(question) },
        isSample = viewModel.isSample,
    )
    val sideList = layout.widthClass == WidthClass.Expanded && layout.tabletopHinge == null

    Row(Modifier.fillMaxSize()) {
        if (sideList) {
            ConversationList(state, onOpen = viewModel::openConversation, onNew = viewModel::newConversation, modifier = Modifier.width(300.dp).fillMaxHeight())
            VerticalDivider(color = LokalBotTheme.palette.separator)
        }
        var originY by remember { mutableFloatStateOf(0f) }
        Box(Modifier.weight(1f).fillMaxHeight().onGloballyPositioned { originY = it.positionInWindow().y }) {
            val hinge = layout.tabletopHinge
            val header: @Composable () -> Unit = {
                AskHeader(
                    sync = sync,
                    isSample = viewModel.isSample,
                    showConversationButtons = !sideList,
                    onHistory = { historyOpen = true },
                    onNew = viewModel::newConversation,
                )
            }
            val composer: @Composable () -> Unit = {
                Composer(
                    draft = draft,
                    onDraft = { draft = it },
                    busy = state.busy,
                    onSend = send,
                    onStop = viewModel::stop,
                    suggestions = if (state.turns.isEmpty()) suggestions() else emptyList(),
                    onSuggestion = { viewModel.ask(it) },
                )
            }
            if (hinge != null) {
                val density = LocalDensity.current
                val topHeight = with(density) { (hinge.bounds.top - originY).toDp() }.coerceAtLeast(160.dp)
                val hingeHeight = with(density) { hinge.bounds.height.toDp() }
                Column(Modifier.fillMaxSize()) {
                    Column(Modifier.fillMaxWidth().height(topHeight)) {
                        header()
                        Transcript(state, actions, Modifier.weight(1f))
                    }
                    Spacer(Modifier.height(hingeHeight))
                    Column(Modifier.fillMaxWidth().weight(1f).background(LokalBotTheme.palette.sidebar), verticalArrangement = Arrangement.Center) {
                        composer()
                    }
                }
            } else {
                Column(Modifier.fillMaxSize().imePadding()) {
                    header()
                    Transcript(state, actions, Modifier.weight(1f))
                    composer()
                }
            }
        }
    }

    if (historyOpen) {
        ModalBottomSheet(onDismissRequest = { historyOpen = false }) {
            ConversationList(
                state,
                onOpen = { viewModel.openConversation(it); historyOpen = false },
                onNew = { viewModel.newConversation(); historyOpen = false },
                modifier = Modifier.fillMaxWidth().padding(bottom = 24.dp),
            )
        }
    }
}

private data class TurnActions(
    val onCitation: (AskCitation) -> Unit,
    val onSearch: (String) -> Unit,
    val onQueue: (String) -> Unit,
    val onHit: (SearchHit) -> Unit,
    val onRetry: (String) -> Unit,
    val isSample: Boolean,
)

@Composable
private fun suggestions(): List<String> = listOf(
    stringResource(R.string.ask_suggestion_overdue),
    stringResource(R.string.ask_suggestion_yesterday),
    stringResource(R.string.ask_suggestion_maya),
)

@Composable
private fun AskHeader(sync: SyncState, isSample: Boolean, showConversationButtons: Boolean, onHistory: () -> Unit, onNew: () -> Unit) {
    val palette = LokalBotTheme.palette
    val top = WindowInsets.safeDrawing.only(WindowInsetsSides.Top).asPaddingValues().calculateTopPadding()
    val route = when (sync.status.route) {
        MacRoute.Wifi -> stringResource(R.string.route_wifi)
        MacRoute.Tailscale -> stringResource(R.string.route_tailscale)
        null -> null
    }
    val (dot, status) = when {
        isSample -> palette.textSupporting to stringResource(R.string.ask_status_sample)
        sync is SyncState.Failed && sync.reason == SyncFailure.Unreachable -> palette.attention to stringResource(R.string.ask_status_unreachable)
        else -> palette.accentText to listOfNotNull(stringResource(R.string.ask_status_mac), route).joinToString(" · ")
    }
    Row(
        Modifier.fillMaxWidth().padding(start = pagePadding(), end = 8.dp, top = top + 12.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(stringResource(R.string.nav_ask), style = LokalBotType.pageTitle, modifier = Modifier.semantics { heading() })
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                StatusDot(dot, size = 7.dp)
                Text(status, style = LokalBotType.caption, color = LokalBotTheme.supportingText)
            }
        }
        if (showConversationButtons) {
            IconButton(onClick = onHistory) { Icon(Icons.Outlined.History, stringResource(R.string.ask_conversations), tint = palette.accentText) }
            IconButton(onClick = onNew) { Icon(Icons.Outlined.EditNote, stringResource(R.string.ask_new_conversation), tint = palette.accentText) }
        }
        OverflowDestinationsButton()
    }
}

@Composable
private fun Transcript(state: AskState, actions: TurnActions, modifier: Modifier = Modifier) {
    val listState = rememberLazyListState()
    val last = state.turns.lastOrNull()
    LaunchedEffect(state.turns.size, last?.phase, last?.answer?.length?.div(200)) {
        if (state.turns.isNotEmpty()) listState.animateScrollToItem(state.turns.lastIndex)
    }
    if (state.turns.isEmpty()) {
        EmptyAsk(modifier)
        return
    }
    LazyColumn(
        modifier.fillMaxWidth(),
        state = listState,
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = pagePadding(), vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        items(state.turns, key = { it.request.requestId }) { turn ->
            Box(Modifier.widthIn(max = LokalBotTokens.Spacing.readingMaxWidth).fillMaxWidth()) { TurnView(turn, actions) }
        }
    }
}



@Composable
private fun EmptyAsk(modifier: Modifier) {
    Column(
        modifier.fillMaxWidth().padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Outlined.AutoAwesome, null, tint = LokalBotTheme.palette.accentText, modifier = Modifier.size(32.dp))
        Spacer(Modifier.height(12.dp))
        Text(stringResource(R.string.ask_empty_title), style = LokalBotType.pageTitle, textAlign = TextAlign.Center)
        Spacer(Modifier.height(6.dp))
        Text(stringResource(R.string.ask_empty_message), style = LokalBotType.secondary, color = LokalBotTheme.supportingText, textAlign = TextAlign.Center)
    }
}

@Composable
private fun TurnView(turn: AskTurnState, actions: TurnActions) {
    val palette = LokalBotTheme.palette
    val formats = LocalFormats.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Icon(Icons.Outlined.AccountCircle, null, tint = LokalBotTheme.supportingText, modifier = Modifier.size(16.dp))
            Text(stringResource(R.string.ask_you_at, formats.time(turn.askedAt)), style = LokalBotType.caption, color = LokalBotTheme.supportingText)
        }
        Text(turn.request.question, style = LokalBotType.question)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.padding(top = 6.dp)) {
            Icon(Icons.Outlined.AutoAwesome, null, tint = palette.accentText, modifier = Modifier.size(16.dp))
            Text(
                stringResource(if (turn.phase == TurnPhase.Streaming) R.string.ask_answering else R.string.app_name),
                style = LokalBotType.caption,
                color = LokalBotTheme.supportingText,
            )
        }
        val parsed = remember(turn.answer, turn.result) { Citations.parse(turn.answer, turn.result?.citations.orEmpty()) }
        if (parsed.answer.isNotBlank()) {
            MarkdownText(
                parsed.answer,
                citations = parsed.citations.map { it.index }.toSet(),
                onCitation = { index -> parsed.citations.firstOrNull { it.index == index }?.let(actions.onCitation) },
            )
        } else if (turn.phase == TurnPhase.Streaming) {
            LoadingStateLabel(stringResource(R.string.ask_asking_mac))
        }
        when (turn.phase) {
            TurnPhase.Done -> turn.result?.let { result ->
                AnswerLocationLine(result, actions.isSample)
                if (parsed.citations.isNotEmpty()) Sources(parsed.citations, actions.onCitation)
            }
            TurnPhase.MacUnreachable -> Unreachable(turn, actions)
            TurnPhase.Queued -> Notice(stringResource(R.string.ask_queued), palette.accentFill, palette.accentText)
            TurnPhase.Failed -> {
                Notice(turn.error?.let { stringResource(R.string.ask_failed_with, it) } ?: stringResource(R.string.ask_stopped), palette.attention, palette.attentionText)
                OutlinedButton(onClick = { actions.onRetry(turn.request.question) }) { Text(stringResource(R.string.ask_retry)) }
            }
            TurnPhase.Streaming -> Unit
        }
    }
}

/** Where the answer was produced: teal for the Mac's own engine, amber for an approved remote one. */
@Composable
private fun AnswerLocationLine(result: AskResult, isSample: Boolean) {
    val palette = LokalBotTheme.palette
    val engine = result.engineLabel ?: stringResource(R.string.ask_engine_unknown)
    val (dot, text) = when {
        isSample -> palette.accentText to stringResource(R.string.ask_answered_sample)
        result.location == AnswerLocation.Mac -> palette.accentText to stringResource(R.string.ask_answered_on_mac, engine)
        else -> palette.attention to stringResource(R.string.ask_answered_remote, engine)
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        StatusDot(dot, size = 7.dp)
        Text(text, style = LokalBotType.caption, color = LokalBotTheme.supportingText)
    }
}

@Composable
private fun Sources(citations: List<AskCitation>, onCitation: (AskCitation) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(stringResource(R.string.ask_sources), style = LokalBotType.sectionHeader, color = LokalBotTheme.supportingText)
        citations.forEach { citation ->
            val clickable = citation.meetingId != null
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(LokalBotTokens.Radius.row))
                    .then(if (clickable) Modifier.clickable(role = Role.Button) { onCitation(citation) } else Modifier)
                    .groupedSurface(shape = RoundedCornerShape(LokalBotTokens.Radius.row))
                    .padding(horizontal = 10.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                SourceBadge(citation.index)
                Text(
                    citation.label.ifBlank { citation.at?.let { Formats.offset(it) } ?: citation.meetingId.orEmpty() },
                    style = LokalBotType.secondary.copy(fontWeight = FontWeight.Medium),
                    modifier = Modifier.weight(1f),
                )
                if (clickable) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = LokalBotTheme.supportingText)
            }
        }
    }
}

@Composable
private fun Unreachable(turn: AskTurnState, actions: TurnActions) {
    val palette = LokalBotTheme.palette
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Notice(stringResource(R.string.ask_unreachable), palette.attention, palette.attentionText)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { actions.onSearch(turn.request.requestId) }) { Text(stringResource(R.string.ask_search_device)) }
            OutlinedButton(onClick = { actions.onQueue(turn.request.requestId) }) { Text(stringResource(R.string.ask_when_back)) }
        }
        turn.localHits?.let { hits ->
            if (hits.isEmpty()) {
                Text(stringResource(R.string.ask_no_local_hits), style = LokalBotType.secondary, color = LokalBotTheme.supportingText)
            } else {
                Column(Modifier.fillMaxWidth().groupedSurface().padding(6.dp)) {
                    hits.forEachIndexed { index, hit ->
                        if (index > 0) HorizontalDivider(color = palette.separator)
                        Column(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).clickable(role = Role.Button) { actions.onHit(hit) }.padding(8.dp),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(hit.title, style = LokalBotType.body.copy(fontWeight = FontWeight.Medium), maxLines = 1)
                            Text(hit.snippet, style = LokalBotType.secondary, color = LokalBotTheme.supportingText, maxLines = 2)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Notice(text: String, tint: Color, textColor: Color) {
    Text(
        text,
        style = LokalBotType.secondary,
        color = textColor,
        modifier = Modifier.fillMaxWidth().groupedSurface(tint = tint).padding(12.dp),
    )
}

@Composable
private fun Composer(
    draft: String,
    onDraft: (String) -> Unit,
    busy: Boolean,
    onSend: () -> Unit,
    onStop: () -> Unit,
    suggestions: List<String>,
    onSuggestion: (String) -> Unit,
) {
    val palette = LokalBotTheme.palette
    val shape = RoundedCornerShape(LokalBotTokens.Radius.composer)
    val compact = LocalWindowLayout.current.widthClass == WidthClass.Compact
    val bottomInset = if (compact) 0.dp else WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom).asPaddingValues().calculateBottomPadding()
    Column(
        Modifier.fillMaxWidth().padding(start = pagePadding(), end = pagePadding(), top = 8.dp, bottom = 12.dp + bottomInset),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            Modifier
                .widthIn(max = LokalBotTokens.Spacing.readingMaxWidth)
                .fillMaxWidth()
                .background(palette.elevated, shape)
                .border(1.dp, if (LokalBotTheme.increasedContrast) palette.textPrimary else palette.separator, shape)
                .padding(start = 4.dp, end = 8.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextField(
                value = draft,
                onValueChange = onDraft,
                // A hardware Enter sends; Shift+Enter starts a new line.
                modifier = Modifier.weight(1f).onPreviewKeyEvent { event ->
                    val enter = event.key == Key.Enter || event.key == Key.NumPadEnter
                    if (!enter || event.isShiftPressed) return@onPreviewKeyEvent false
                    if (event.type == KeyEventType.KeyDown && draft.isNotBlank() && !busy) onSend()
                    true
                },
                placeholder = { Text(stringResource(R.string.ask_placeholder)) },
                maxLines = 4,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { if (draft.isNotBlank() && !busy) onSend() }),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
            )
            if (busy) {
                FilledIconButton(onClick = onStop, colors = IconButtonDefaults.filledIconButtonColors(containerColor = palette.accentFill)) {
                    Icon(Icons.Outlined.Stop, stringResource(R.string.ask_stop), tint = Color.White)
                }
            } else {
                FilledIconButton(
                    onClick = onSend,
                    enabled = draft.isNotBlank(),
                    colors = IconButtonDefaults.filledIconButtonColors(containerColor = palette.accentFill, contentColor = Color.White),
                ) {
                    Icon(Icons.Outlined.ArrowUpward, stringResource(R.string.ask_send))
                }
            }
        }
        if (suggestions.isNotEmpty()) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                suggestions.forEach { suggestion ->
                    Text(
                        suggestion,
                        style = LokalBotType.secondary,
                        color = palette.accentText,
                        modifier = Modifier.clip(CircleShape).clickable(role = Role.Button) { onSuggestion(suggestion) }.chipChrome(),
                    )
                }
            }
        }
    }
}

@Composable
private fun ConversationList(state: AskState, onOpen: (String) -> Unit, onNew: () -> Unit, modifier: Modifier = Modifier) {
    val formats = LocalFormats.current
    val top = WindowInsets.safeDrawing.only(WindowInsetsSides.Top).asPaddingValues().calculateTopPadding()
    LazyColumn(modifier, contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 12.dp, end = 12.dp, top = top + 12.dp, bottom = 16.dp)) {
        item(key = "conversations-header") {
            Row(Modifier.fillMaxWidth().padding(start = 6.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.ask_conversations), style = LokalBotType.columnTitle, modifier = Modifier.weight(1f))
                IconButton(onClick = onNew) { Icon(Icons.Outlined.EditNote, stringResource(R.string.ask_new_conversation)) }
            }
        }
        if (state.conversations.isEmpty()) {
            item(key = "conversations-empty") {
                Text(stringResource(R.string.ask_no_conversations), style = LokalBotType.secondary, color = LokalBotTheme.supportingText, modifier = Modifier.padding(6.dp))
            }
        }
        items(state.conversations, key = { it.id }) { conversation ->
            val selected = conversation.id == state.conversationId
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(LokalBotTokens.Radius.row))
                    .background(if (selected) LokalBotTheme.palette.accentWash else Color.Transparent)
                    .clickable(role = Role.Button) { onOpen(conversation.id) }
                    .padding(horizontal = 10.dp, vertical = 9.dp),
            ) {
                Text(conversation.title, style = LokalBotType.body.copy(fontWeight = FontWeight.SemiBold), maxLines = 1)
                conversation.lastAt?.let { Formats.parseInstant(it) }?.let {
                    Text(formats.time(it), style = LokalBotType.caption, color = LokalBotTheme.supportingText)
                }
            }
        }
    }
}
