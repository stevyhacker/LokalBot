package me.dotenv.lokalbot.companion.ui.meetings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.outlined.CalendarToday
import androidx.compose.material.icons.outlined.CheckCircleOutline
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Videocam
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.model.Citation
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.model.Outcome
import me.dotenv.lokalbot.companion.data.model.Transcript
import me.dotenv.lokalbot.companion.data.model.TranscriptSegment
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.ui.LocalAppNavigator
import me.dotenv.lokalbot.companion.ui.LocalFormats
import me.dotenv.lokalbot.companion.ui.actions.ActionItemRow
import me.dotenv.lokalbot.companion.ui.common.BackButton
import me.dotenv.lokalbot.companion.ui.common.CenteredColumn
import me.dotenv.lokalbot.companion.ui.common.pageContentPadding
import me.dotenv.lokalbot.companion.ui.components.BrandChip
import me.dotenv.lokalbot.companion.ui.components.EmptyState
import me.dotenv.lokalbot.companion.ui.components.EvidencePill
import me.dotenv.lokalbot.companion.ui.components.InitialsAvatar
import me.dotenv.lokalbot.companion.ui.components.MarkdownText
import me.dotenv.lokalbot.companion.ui.components.RowDivider
import me.dotenv.lokalbot.companion.ui.components.StatusDot
import me.dotenv.lokalbot.companion.ui.components.ToolbarTabs
import me.dotenv.lokalbot.companion.ui.components.WorkspaceSection
import me.dotenv.lokalbot.companion.ui.components.chipChrome
import me.dotenv.lokalbot.companion.ui.components.groupedSurface
import me.dotenv.lokalbot.companion.ui.format.Formats
import me.dotenv.lokalbot.companion.ui.text.Markdown
import me.dotenv.lokalbot.companion.ui.theme.BrandColors
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTokens
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

enum class MeetingTab(val title: Int) {
    Summary(R.string.meeting_tab_summary),
    Transcript(R.string.meeting_tab_transcript),
    Notes(R.string.meeting_tab_notes),
}

private val ReadingWidth = LokalBotTokens.Spacing.readingMaxWidth + 56.dp

/** One meeting: header, then Summary, Transcript and Notes behind the capsule tabs. */
@Composable
fun MeetingDetail(
    repository: CompanionRepository,
    meetingId: String,
    focusAt: Double?,
    onFocusHandled: () -> Unit,
    onBack: (() -> Unit)?,
) {
    val viewModel = viewModel(key = "meeting-${repository.id}-$meetingId") { MeetingDetailViewModel(repository, meetingId) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val meeting = state.meeting
    if (meeting == null) {
        if (state.loaded) EmptyState(stringResource(R.string.meeting_missing_title), stringResource(R.string.meeting_missing_message))
        return
    }
    val navigator = LocalAppNavigator.current
    var tab by rememberSaveable(meetingId) { mutableStateOf(MeetingTab.Summary) }
    var highlightAt by rememberSaveable(meetingId) { mutableStateOf<Double?>(null) }
    var evidence by remember { mutableStateOf<Citation?>(null) }
    val listState = rememberLazyListState()
    val transcript = state.transcript

    fun showEvidence(citation: Citation) {
        if (transcript != null) {
            highlightAt = citation.start
            tab = MeetingTab.Transcript
        } else {
            evidence = citation
        }
    }

    LaunchedEffect(focusAt, transcript) {
        if (focusAt != null && transcript != null) {
            highlightAt = focusAt
            tab = MeetingTab.Transcript
            onFocusHandled()
        }
    }
    LaunchedEffect(tab, highlightAt, transcript) {
        val at = highlightAt ?: return@LaunchedEffect
        if (tab != MeetingTab.Transcript || transcript == null) return@LaunchedEffect
        val index = segmentIndexAt(transcript, at)
        if (index >= 0) listState.animateScrollToItem(HEADER_ITEMS + index, scrollOffset = -120)
    }

    val tabs = buildList {
        add(MeetingTab.Summary)
        if (meeting.hasTranscript) add(MeetingTab.Transcript)
        if (!meeting.notesMarkdown.isNullOrBlank()) add(MeetingTab.Notes)
    }
    LazyColumn(Modifier.fillMaxSize(), state = listState, contentPadding = pageContentPadding()) {
        item(key = "header") {
            CenteredColumn(ReadingWidth) {
                MeetingHeader(
                    meeting,
                    onBack = onBack,
                    onPerson = navigator::openPerson,
                    onProject = navigator::openProject,
                )
            }
        }
        item(key = "tabs") {
            CenteredColumn(ReadingWidth) {
                if (tabs.size > 1) {
                    ToolbarTabs(
                        tabs = tabs,
                        selected = tab.takeIf { it in tabs } ?: MeetingTab.Summary,
                        onSelect = { tab = it },
                        title = { stringResource(it.title) },
                        label = stringResource(R.string.meeting_tabs_label),
                        modifier = Modifier.padding(vertical = 16.dp),
                    )
                } else {
                    Spacer(Modifier.size(16.dp))
                }
            }
        }
        when (tab.takeIf { it in tabs } ?: MeetingTab.Summary) {
            MeetingTab.Summary -> item(key = "summary") {
                CenteredColumn(ReadingWidth) {
                    SummaryTab(state, onToggle = viewModel::setStatus, onEvidence = ::showEvidence)
                }
            }
            MeetingTab.Transcript -> {
                val segments = transcript?.segments.orEmpty()
                if (segments.isEmpty()) {
                    item(key = "no-transcript") {
                        EmptyState(stringResource(R.string.transcript_missing_title), stringResource(R.string.transcript_missing_message))
                    }
                }
                val highlighted = highlightAt?.let { at -> transcript?.let { segmentIndexAt(it, at) } } ?: -1
                itemsIndexed(segments, key = { index, _ -> "segment-$index" }) { index, segment ->
                    CenteredColumn(ReadingWidth) {
                        TranscriptLine(
                            segment,
                            showSpeaker = index == 0 || segments[index - 1].speaker != segment.speaker,
                            highlighted = index == highlighted,
                        )
                    }
                }
            }
            MeetingTab.Notes -> item(key = "notes") {
                CenteredColumn(ReadingWidth) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(stringResource(R.string.meeting_notes_title), style = LokalBotType.section)
                        MarkdownText(meeting.notesMarkdown.orEmpty(), Modifier.fillMaxWidth().groupedSurface().padding(14.dp))
                        Text(stringResource(R.string.meeting_notes_caption), style = LokalBotType.caption, color = LokalBotTheme.supportingText)
                    }
                }
            }
        }
    }

    evidence?.let { citation ->
        AlertDialog(
            onDismissRequest = { evidence = null },
            confirmButton = { TextButton(onClick = { evidence = null }) { Text(stringResource(R.string.done)) } },
            title = { Text(listOfNotNull(citation.speaker, Formats.offset(citation.start)).joinToString(" · ")) },
            text = { Text("“${citation.excerpt}”", style = LokalBotType.reading.copy(fontStyle = FontStyle.Italic)) },
        )
    }
}

private const val HEADER_ITEMS = 2

/** The segment containing [at], or the last one starting before it. */
fun segmentIndexAt(transcript: Transcript, at: Double): Int {
    val segments = transcript.segments
    val containing = segments.indexOfFirst { at >= it.start - 0.5 && at < it.end + 0.5 }
    if (containing >= 0) return containing
    return segments.indexOfLast { it.start <= at }.takeIf { it >= 0 } ?: if (segments.isEmpty()) -1 else 0
}

@Composable
private fun MeetingHeader(meeting: Meeting, onBack: (() -> Unit)?, onPerson: (String) -> Unit, onProject: (String) -> Unit) {
    val formats = LocalFormats.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (onBack != null) Box(Modifier.padding(start = 0.dp)) { BackButton(onBack) }
        Text(meeting.title, style = LokalBotType.pageTitle)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            BrandChip("${formats.shortDay(meeting.day)} · ${formats.meetingTime(meeting)}", icon = Icons.Outlined.CalendarToday)
            Formats.meetingDuration(meeting.durationSeconds)?.let { BrandChip(it, icon = Icons.Outlined.Schedule) }
            meeting.appName?.let { BrandChip(it, icon = Icons.Outlined.Videocam) }
            meeting.projects.forEach { project ->
                BrandChip(project.name, icon = Icons.Outlined.Folder, modifier = Modifier.clip(CircleShape).clickable(role = Role.Button) { onProject(project.id) })
            }
        }
        if (meeting.people.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                meeting.people.forEach { person ->
                    Row(
                        Modifier.clip(CircleShape).clickable(role = Role.Button) { onPerson(person.id) }.chipChrome().heightIn(min = 22.dp),
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
}

@Composable
private fun SummaryTab(
    state: MeetingDetailState,
    onToggle: (String, me.dotenv.lokalbot.companion.data.model.ActionStatus) -> Unit,
    onEvidence: (Citation) -> Unit,
) {
    val meeting = state.meeting ?: return
    val palette = LokalBotTheme.palette
    Column(verticalArrangement = Arrangement.spacedBy(LokalBotTokens.Spacing.sectionSpacing)) {
        meeting.summaryMarkdown?.let { summary ->
            val recap = Markdown.section(summary, "Recap") ?: summary
            WorkspaceSection(stringResource(R.string.meeting_recap)) { MarkdownText(recap) }
        }
        WorkspaceSection(stringResource(R.string.meeting_action_items), contentPadding = 6.dp) {
            if (meeting.actions.isEmpty()) {
                EmptyRow(stringResource(R.string.meeting_no_actions))
            }
            meeting.actions.forEachIndexed { index, action ->
                if (index > 0) RowDivider(Modifier.padding(start = 40.dp))
                ActionItemRow(
                    action = action,
                    today = state.today,
                    pending = action.id in state.pendingActionIds,
                    onToggle = { onToggle(action.id, it) },
                    trailing = { action.citations.firstOrNull()?.let { EvidencePill(it.start, onClick = { onEvidence(it) }, Modifier.padding(top = 4.dp)) } },
                )
            }
        }
        WorkspaceSection(stringResource(R.string.meeting_decisions)) {
            if (meeting.decisions.isEmpty()) EmptyRow(stringResource(R.string.meeting_no_decisions))
            meeting.decisions.forEach { decision ->
                OutcomeRow(decision, Icons.Outlined.CheckCircleOutline, palette.successText, onEvidence)
            }
        }
        if (meeting.openQuestions.isNotEmpty()) {
            WorkspaceSection(stringResource(R.string.meeting_open_questions)) {
                meeting.openQuestions.forEach { question ->
                    OutcomeRow(question, Icons.AutoMirrored.Outlined.HelpOutline, palette.attention, onEvidence)
                }
            }
        }
    }
}

@Composable
private fun OutcomeRow(outcome: Outcome, icon: androidx.compose.ui.graphics.vector.ImageVector, tint: androidx.compose.ui.graphics.Color, onEvidence: (Citation) -> Unit) {
    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.padding(top = 2.dp).size(20.dp))
        Text(outcome.text, style = LokalBotType.body, modifier = Modifier.weight(1f))
        outcome.citations.firstOrNull()?.let { EvidencePill(it.start, onClick = { onEvidence(it) }) }
    }
}

@Composable
private fun EmptyRow(text: String) {
    Text(text, style = LokalBotType.secondary, color = LokalBotTheme.supportingText, modifier = Modifier.padding(vertical = 8.dp, horizontal = 4.dp))
}

/** A transcript line: time, the speaker's colour and name on a new turn, then the words. */
@Composable
fun TranscriptLine(segment: TranscriptSegment, showSpeaker: Boolean, highlighted: Boolean) {
    val palette = LokalBotTheme.palette
    val speakerColor = BrandColors.speakerColor(segment.colorIndex, palette)
    Row(
        Modifier
            .fillMaxWidth()
            .padding(top = if (showSpeaker) 12.dp else 2.dp)
            .clip(RoundedCornerShape(6.dp))
            .then(if (highlighted) Modifier.groupedSurface(tint = palette.accentFill, shape = RoundedCornerShape(6.dp)) else Modifier)
            .padding(horizontal = 6.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            Formats.offset(segment.start),
            style = LokalBotType.timestamp,
            color = palette.accentText,
            modifier = Modifier.width(52.dp).padding(top = 2.dp),
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (showSpeaker) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    StatusDot(speakerColor, size = 6.dp)
                    Text(segment.speaker.ifBlank { stringResource(R.string.transcript_unknown_speaker) }, style = LokalBotType.secondary.copy(fontWeight = FontWeight.SemiBold))
                }
            }
            Text(segment.text, style = LokalBotType.reading)
        }
    }
}
