package me.dotenv.lokalbot.companion.ui.timeline

import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Bookmark
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.ViewTimeline
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.PaneAdaptedValue
import androidx.compose.material3.adaptive.layout.SupportingPaneScaffoldRole
import androidx.compose.material3.adaptive.navigation.NavigableSupportingPaneScaffold
import androidx.compose.material3.adaptive.navigation.rememberSupportingPaneScaffoldNavigator
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit
import kotlinx.coroutines.launch
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.model.SessionKind
import me.dotenv.lokalbot.companion.data.model.WorkSession
import me.dotenv.lokalbot.companion.ui.LocalAppNavigator
import me.dotenv.lokalbot.companion.ui.LocalFormats
import me.dotenv.lokalbot.companion.ui.OverflowDestinationsButton
import me.dotenv.lokalbot.companion.ui.adaptive.LocalWindowLayout
import me.dotenv.lokalbot.companion.ui.adaptive.PaneHost
import me.dotenv.lokalbot.companion.ui.adaptive.rememberPaneDirective
import me.dotenv.lokalbot.companion.ui.common.BackButton
import me.dotenv.lokalbot.companion.ui.common.CenteredColumn
import me.dotenv.lokalbot.companion.ui.common.pageContentPadding
import me.dotenv.lokalbot.companion.ui.components.BarLegend
import me.dotenv.lokalbot.companion.ui.components.EmptyState
import me.dotenv.lokalbot.companion.ui.components.PageHeader
import me.dotenv.lokalbot.companion.ui.components.ProportionBar
import me.dotenv.lokalbot.companion.ui.components.StatusDot
import me.dotenv.lokalbot.companion.ui.components.WorkspaceSection
import me.dotenv.lokalbot.companion.ui.components.groupedSurface
import me.dotenv.lokalbot.companion.ui.components.rememberSegments
import me.dotenv.lokalbot.companion.ui.format.Formats
import me.dotenv.lokalbot.companion.ui.meetings.MeetingRow
import me.dotenv.lokalbot.companion.ui.theme.BrandColors
import me.dotenv.lokalbot.companion.ui.theme.LokalBotMotion
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTokens
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

private val DayMaxWidth = 820.dp

/**
 * The Timeline: a day pane (strip, overview bar, digest, meetings, saved
 * moments) beside the work-session rail. Narrow windows show the rail on
 * demand, like the Mac's drawer below 820 pt.
 */
@Composable
fun TimelineScreen(repository: CompanionRepository) {
    val viewModel = viewModel(key = "timeline-${repository.id}") { TimelineViewModel(repository) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val appNavigator = LocalAppNavigator.current
    val layout = LocalWindowLayout.current

    LaunchedEffect(appNavigator.timelineDay) {
        appNavigator.timelineDay?.let { day ->
            runCatching { LocalDate.parse(day) }.getOrNull()?.let(viewModel::select)
            appNavigator.timelineDay = null
        }
    }

    PaneHost { originX ->
        val railWidth = (maxWidth * 0.4f).coerceIn(LokalBotTokens.Spacing.timelineDrawerBreakpoint / 3, 400.dp)
        val directive = rememberPaneDirective(layout, originX, fixedPaneAtEnd = true, preferredWidth = railWidth)
        val navigator = rememberSupportingPaneScaffoldNavigator(scaffoldDirective = directive)
        val scope = rememberCoroutineScope()
        val railHidden = navigator.scaffoldValue[SupportingPaneScaffoldRole.Supporting] == PaneAdaptedValue.Hidden
        val reduced = LokalBotMotion.reduced
        NavigableSupportingPaneScaffold(
            navigator = navigator,
            modifier = Modifier.background(if (railHidden) LokalBotTheme.palette.window else LokalBotTheme.palette.separator),
            mainPane = {
                AnimatedPane(
                    enterTransition = if (reduced) EnterTransition.None else fadeIn(),
                    exitTransition = if (reduced) ExitTransition.None else fadeOut(),
                ) {
                    Box(Modifier.fillMaxSize().background(LokalBotTheme.palette.window)) {
                        DayPane(
                            state = state,
                            onSelect = viewModel::select,
                            onStep = viewModel::step,
                            onShowSessions = if (railHidden) ({ scope.launch { navigator.navigateTo(SupportingPaneScaffoldRole.Supporting) } }) else null,
                            onOpenMeeting = { appNavigator.openMeeting(it) },
                        )
                    }
                }
            },
            supportingPane = {
                AnimatedPane(
                    enterTransition = if (reduced) EnterTransition.None else fadeIn(),
                    exitTransition = if (reduced) ExitTransition.None else fadeOut(),
                ) {
                    Box(Modifier.fillMaxSize().background(LokalBotTheme.palette.window)) {
                        SessionRail(
                            state = state,
                            onOpenMeeting = { appNavigator.openMeeting(it) },
                            onBack = if (navigator.scaffoldValue[SupportingPaneScaffoldRole.Main] == PaneAdaptedValue.Hidden) ({ scope.launch { navigator.navigateBack() } }) else null,
                        )
                    }
                }
            },
        )
    }
}

@Composable
private fun DayPane(
    state: TimelineState,
    onSelect: (LocalDate) -> Unit,
    onStep: (Long) -> Unit,
    onShowSessions: (() -> Unit)?,
    onOpenMeeting: (String) -> Unit,
) {
    val formats = LocalFormats.current
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    var pickerOpen by rememberSaveable { mutableStateOf(false) }
    val timeline = state.record?.timeline
    LazyColumn(
        Modifier
            .fillMaxSize()
            .pointerInput(state.day, rtl) {
                var travelled = 0f
                detectHorizontalDragGestures(
                    onDragStart = { travelled = 0f },
                    onDragEnd = {
                        val threshold = 80.dp.toPx()
                        val forward = if (rtl) travelled > threshold else travelled < -threshold
                        val back = if (rtl) travelled < -threshold else travelled > threshold
                        when {
                            forward && state.day < state.today -> onStep(1)
                            back -> onStep(-1)
                        }
                    },
                ) { _, dragAmount -> travelled += dragAmount }
            },
        contentPadding = pageContentPadding(),
        verticalArrangement = Arrangement.spacedBy(LokalBotTokens.Spacing.sectionSpacing),
    ) {
        item(key = "header") {
            CenteredColumn(DayMaxWidth) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    PageHeader(
                        title = stringResource(R.string.nav_timeline),
                        subtitle = formats.fullDate(state.day),
                        actions = {
                            IconButton(onClick = { pickerOpen = true }) {
                                Icon(Icons.Outlined.CalendarMonth, stringResource(R.string.timeline_pick_day), tint = LokalBotTheme.palette.accentText)
                            }
                            OverflowDestinationsButton()
                        },
                    )
                    DayStrip(state, onSelect, onStep)
                }
            }
        }
        if (state.loaded && state.record == null && state.meetings.isEmpty()) {
            item(key = "empty") {
                EmptyState(stringResource(R.string.timeline_empty_title), stringResource(R.string.timeline_empty_message), icon = Icons.Outlined.ViewTimeline)
            }
        }
        if (timeline != null) {
            item(key = "overview") {
                CenteredColumn(DayMaxWidth) {
                    Column(Modifier.fillMaxWidth().groupedSurface().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(Formats.duration(timeline.trackedSeconds), style = LokalBotType.timestamp.copy(fontSize = 26.sp, fontWeight = FontWeight.SemiBold))
                            Text(stringResource(R.string.stat_tracked), style = LokalBotType.secondary, color = LokalBotTheme.supportingText, modifier = Modifier.padding(bottom = 3.dp))
                        }
                        val sessions = timeline.sessions.count { it.kind != SessionKind.Meeting }
                        Text(
                            listOf(
                                pluralStringResource(R.plurals.timeline_work_sessions, sessions, sessions),
                                pluralStringResource(R.plurals.timeline_meetings, state.meetings.size, state.meetings.size),
                                pluralStringResource(R.plurals.timeline_projects, timeline.byProject.size, timeline.byProject.size),
                            ).joinToString(" · "),
                            style = LokalBotType.secondary,
                            color = LokalBotTheme.supportingText,
                        )
                        val segments = rememberSegments(timeline.byProject.ifEmpty { timeline.byApp })
                        ProportionBar(segments, height = 8.dp)
                        BarLegend(segments)
                        if (onShowSessions != null && timeline.sessions.isNotEmpty()) {
                            OutlinedButton(onClick = onShowSessions) {
                                Text(pluralStringResource(R.plurals.timeline_show_sessions, timeline.sessions.size, timeline.sessions.size))
                            }
                        }
                    }
                }
            }
        }
        state.record?.digest?.let { digest ->
            item(key = "digest") {
                CenteredColumn(DayMaxWidth) {
                    WorkspaceSection(stringResource(R.string.digest_title)) {
                        DigestView(digest)
                        digest.generatedAt?.let {
                            Text(stringResource(R.string.digest_updated, formats.time(it)), style = LokalBotType.caption, color = LokalBotTheme.supportingText)
                        }
                    }
                }
            }
        }
        if (state.meetings.isNotEmpty()) {
            item(key = "meetings") {
                CenteredColumn(DayMaxWidth) {
                    WorkspaceSection(stringResource(R.string.timeline_meetings_title), contentPadding = 4.dp) {
                        state.meetings.forEach { MeetingRow(it, onClick = { onOpenMeeting(it.id) }) }
                    }
                }
            }
        }
        val moments = timeline?.savedMoments.orEmpty()
        if (moments.isNotEmpty()) {
            item(key = "moments") {
                CenteredColumn(DayMaxWidth) {
                    WorkspaceSection(stringResource(R.string.timeline_saved_moments)) {
                        moments.forEach { moment ->
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Icon(Icons.Outlined.Bookmark, null, tint = LokalBotTheme.palette.attention, modifier = Modifier.size(18.dp))
                                Text(moment.label, style = LokalBotType.body, modifier = Modifier.weight(1f))
                                Text(formats.time(moment.at), style = LokalBotType.timestamp, color = LokalBotTheme.supportingText)
                            }
                        }
                    }
                }
            }
        }
    }

    if (pickerOpen) {
        DayPickerDialog(state, onDismiss = { pickerOpen = false }, onPick = { onSelect(it); pickerOpen = false })
    }
}

@Composable
private fun DayStrip(state: TimelineState, onSelect: (LocalDate) -> Unit, onStep: (Long) -> Unit) {
    val formats = LocalFormats.current
    val palette = LokalBotTheme.palette
    val days = remember(state.today, state.earliest) {
        val count = ChronoUnit.DAYS.between(state.earliest, state.today).toInt().coerceAtLeast(0) + 1
        (0 until count).map { state.today.minusDays(it.toLong()) }
    }
    val listState = rememberLazyListState()
    LaunchedEffect(state.day) {
        val index = days.indexOf(state.day)
        if (index >= 0) listState.animateScrollToItem((index - 2).coerceAtLeast(0))
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { onStep(-1) }, enabled = state.day > state.earliest) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, stringResource(R.string.timeline_previous_day))
        }
        LazyRow(
            Modifier.weight(1f),
            state = listState,
            reverseLayout = true,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            items(days, key = { it.toString() }) { date ->
                val selected = date == state.day
                val recorded = date.toString() in state.recordedDays
                val label = formats.dayLabel(date, state.today)
                Column(
                    Modifier
                        .width(44.dp)
                        .clip(RoundedCornerShape(LokalBotTokens.Radius.control))
                        .background(if (selected) palette.accentFill else Color.Transparent)
                        .clickable(role = Role.Tab) { onSelect(date) }
                        .padding(vertical = 6.dp)
                        .semantics(mergeDescendants = true) {
                            this.selected = selected
                            contentDescription = label
                        },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    val textColor = if (selected) Color.White else LokalBotTheme.supportingText
                    Text(formats.weekday(date), style = LokalBotType.caption, color = textColor, maxLines = 1)
                    Text(formats.dayNumber(date), style = LokalBotType.timestamp.copy(fontWeight = FontWeight.SemiBold), color = if (selected) Color.White else Color.Unspecified)
                    StatusDot(if (recorded) (if (selected) Color.White else palette.accentText) else Color.Transparent, size = 5.dp)
                }
            }
        }
        IconButton(onClick = { onStep(1) }, enabled = state.day < state.today) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, stringResource(R.string.timeline_next_day))
        }
    }
    if (state.day != state.today) {
        TextButton(onClick = { onSelect(state.today) }) { Text(stringResource(R.string.timeline_go_today)) }
    }
}

@Composable
private fun DayPickerDialog(state: TimelineState, onDismiss: () -> Unit, onPick: (LocalDate) -> Unit) {
    val todayMillis = state.today.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
    val pickerState = rememberDatePickerState(
        initialSelectedDateMillis = state.day.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
        selectableDates = object : SelectableDates {
            override fun isSelectableDate(utcTimeMillis: Long): Boolean = utcTimeMillis <= todayMillis
            override fun isSelectableYear(year: Int): Boolean = year <= state.today.year
        },
    )
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = {
                pickerState.selectedDateMillis?.let { onPick(Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate()) } ?: onDismiss()
            }) { Text(stringResource(R.string.timeline_show_day)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    ) {
        DatePicker(pickerState)
    }
}

/** The work-session rail: time, a dot in the project's colour, title, apps and window titles. */
@Composable
private fun SessionRail(state: TimelineState, onOpenMeeting: (String) -> Unit, onBack: (() -> Unit)?) {
    val sessions = state.record?.timeline?.sessions.orEmpty()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = pageContentPadding(horizontal = 14.dp)) {
        item(key = "rail-header") {
            Column(Modifier.padding(bottom = 10.dp)) {
                if (onBack != null) BackButton(onBack)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.timeline_sessions), style = LokalBotType.columnTitle)
                    Text(sessions.size.toString(), style = LokalBotType.timestamp, color = LokalBotTheme.supportingText)
                }
            }
        }
        if (sessions.isEmpty()) {
            item(key = "rail-empty") {
                Text(stringResource(R.string.timeline_no_sessions), style = LokalBotType.secondary, color = LokalBotTheme.supportingText)
            }
        }
        items(sessions, key = { it.start + it.title }) { session ->
            SessionRow(session, onOpenMeeting)
        }
    }
}

@Composable
private fun SessionRow(session: WorkSession, onOpenMeeting: (String) -> Unit) {
    val formats = LocalFormats.current
    val palette = LokalBotTheme.palette
    val isMeeting = session.kind == SessionKind.Meeting
    val color = when {
        isMeeting -> palette.accentFill
        else -> BrandColors.nameColor(session.project ?: session.apps.firstOrNull()?.name ?: BrandColors.OTHER, palette)
    }
    val seconds = runCatching {
        java.time.Duration.between(Instant.parse(session.start), Instant.parse(session.end)).seconds.toDouble()
    }.getOrDefault(0.0)
    val meetingId = session.meetingId
    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 3.dp)
            .clip(RoundedCornerShape(LokalBotTokens.Radius.row))
            .then(if (isMeeting) Modifier.groupedSurface(tint = palette.accentFill, shape = RoundedCornerShape(LokalBotTokens.Radius.row)) else Modifier)
            .then(if (meetingId != null) Modifier.clickable(role = Role.Button) { onOpenMeeting(meetingId) } else Modifier)
            .heightIn(min = 48.dp)
            .padding(horizontal = 8.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            formats.time(session.start),
            style = LokalBotType.caption.copy(fontFeatureSettings = "tnum"),
            color = if (isMeeting) palette.accentText else LokalBotTheme.supportingText,
            modifier = Modifier.width(44.dp).padding(top = 2.dp),
        )
        StatusDot(color, Modifier.padding(top = 6.dp), size = 9.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                when (session.kind) {
                    SessionKind.Meeting -> Icon(Icons.Outlined.GraphicEq, null, tint = palette.accentText, modifier = Modifier.size(15.dp))
                    SessionKind.Agent -> Icon(Icons.Outlined.Terminal, null, tint = LokalBotTheme.supportingText, modifier = Modifier.size(15.dp))
                    SessionKind.Work -> Unit
                }
                Text(session.title, style = LokalBotType.secondary.copy(fontWeight = FontWeight.Medium), maxLines = 2)
            }
            val kindLabel = when (session.kind) {
                SessionKind.Meeting -> stringResource(R.string.timeline_kind_meeting)
                SessionKind.Agent -> stringResource(R.string.timeline_kind_agent)
                SessionKind.Work -> null
            }
            val detail = listOfNotNull(kindLabel, session.project).plus(session.apps.map { it.name }).distinct().joinToString(" · ")
            if (detail.isNotEmpty()) Text(detail, style = LokalBotType.caption, color = LokalBotTheme.supportingText, maxLines = 2)
            session.windowTitles.take(3).forEach { title ->
                Text(title, style = LokalBotType.caption, color = LokalBotTheme.supportingText, maxLines = 1)
            }
        }
        Text(
            Formats.duration(seconds),
            style = LokalBotType.caption.copy(fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum"),
            color = if (isMeeting) palette.accentText else Color.Unspecified,
            modifier = Modifier.padding(top = 2.dp),
        )
    }
}

