package me.dotenv.lokalbot.companion.ui.today

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.ViewTimeline
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import java.time.Instant
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.SyncState
import me.dotenv.lokalbot.companion.data.model.ActionRow
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.ui.LocalAppNavigator
import me.dotenv.lokalbot.companion.ui.LocalFormats
import me.dotenv.lokalbot.companion.ui.OverflowDestinationsButton
import me.dotenv.lokalbot.companion.ui.actions.ActionItemRow
import me.dotenv.lokalbot.companion.ui.common.CenteredColumn
import me.dotenv.lokalbot.companion.ui.common.pageContentPadding
import me.dotenv.lokalbot.companion.ui.components.BrandChip
import me.dotenv.lokalbot.companion.ui.components.PageHeader
import me.dotenv.lokalbot.companion.ui.components.RowDivider
import me.dotenv.lokalbot.companion.ui.components.SyncPill
import me.dotenv.lokalbot.companion.ui.components.WorkspaceSection
import me.dotenv.lokalbot.companion.ui.components.groupedSurface
import me.dotenv.lokalbot.companion.ui.meetings.MeetingRow
import me.dotenv.lokalbot.companion.ui.navigation.Destination
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTokens
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType
import me.dotenv.lokalbot.companion.ui.timeline.DayOverview
import me.dotenv.lokalbot.companion.ui.timeline.DigestView

private val TodayMaxWidth = 956.dp

@Composable
fun TodayScreen(repository: CompanionRepository) {
    val viewModel = viewModel(key = "today-${repository.id}") { TodayViewModel(repository) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val sync by viewModel.syncState.collectAsStateWithLifecycle()
    val refreshing by viewModel.refreshing.collectAsStateWithLifecycle()
    val navigator = LocalAppNavigator.current
    TodayContent(
        state = state,
        sync = sync,
        isSample = viewModel.isSample,
        now = viewModel.now(),
        refreshing = refreshing,
        onRefresh = viewModel::refresh,
        onToggle = viewModel::setStatus,
        onOpenAction = { navigator.openAction(it.meetingId, it.action.id) },
        onOpenMeeting = { navigator.openMeeting(it) },
        onReviewActions = { navigator.go(Destination.Actions) },
        onOpenTimeline = { navigator.openDay(state.today.toString()) },
        onAskAboutToday = { navigator.go(Destination.Ask) },
    )
}

@Composable
fun TodayContent(
    state: TodayState,
    sync: SyncState,
    isSample: Boolean,
    now: Instant,
    refreshing: Boolean,
    onRefresh: () -> Unit,
    onToggle: (ActionRow, ActionStatus) -> Unit,
    onOpenAction: (ActionRow) -> Unit,
    onOpenMeeting: (String) -> Unit,
    onReviewActions: () -> Unit,
    onOpenTimeline: () -> Unit,
    onAskAboutToday: () -> Unit,
) {
    val formats = LocalFormats.current
    PullToRefreshBox(isRefreshing = refreshing, onRefresh = onRefresh, modifier = Modifier.fillMaxSize()) {
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = pageContentPadding(),
            verticalArrangement = Arrangement.spacedBy(LokalBotTokens.Spacing.sectionSpacing),
        ) {
            item(key = "header") {
                CenteredColumn(TodayMaxWidth) {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        PageHeader(
                            title = stringResource(R.string.nav_today),
                            subtitle = formats.fullDate(state.today),
                            actions = {
                                IconButton(onClick = onAskAboutToday) {
                                    Icon(Icons.Outlined.AutoAwesome, stringResource(R.string.today_ask_about_today), tint = LokalBotTheme.palette.accentText)
                                }
                                IconButton(onClick = onOpenTimeline) {
                                    Icon(Icons.Outlined.ViewTimeline, stringResource(R.string.today_open_timeline), tint = LokalBotTheme.palette.accentText)
                                }
                                OverflowDestinationsButton()
                            },
                        )
                        SyncPill(sync, isSample, now)
                    }
                }
            }
            if (state.needsAttention.isNotEmpty()) {
                item(key = "attention") {
                    CenteredColumn(TodayMaxWidth) {
                        WorkspaceSection(
                            title = stringResource(R.string.today_needs_attention),
                            trailing = { TextButton(onClick = onReviewActions) { Text(stringResource(R.string.today_review_actions)) } },
                            contentPadding = 6.dp,
                        ) {
                            state.needsAttention.forEachIndexed { index, row ->
                                if (index > 0) RowDivider(Modifier.padding(start = 40.dp))
                                ActionItemRow(
                                    action = row.action,
                                    today = state.today,
                                    meetingTitle = row.meetingTitle,
                                    pending = row.pending,
                                    onToggle = { onToggle(row, it) },
                                    onClick = { onOpenAction(row) },
                                )
                            }
                        }
                    }
                }
            }
            item(key = "digest") {
                CenteredColumn(TodayMaxWidth) { DigestSection(state, formats.time(state.digestDay?.digest?.generatedAt)) }
            }
            if (state.meetings.isNotEmpty()) {
                item(key = "meetings") {
                    CenteredColumn(TodayMaxWidth) {
                        WorkspaceSection(stringResource(R.string.today_meetings), contentPadding = 4.dp) {
                            state.meetings.forEach { meeting -> MeetingRow(meeting, onClick = { onOpenMeeting(meeting.id) }) }
                        }
                    }
                }
            }
            state.todayRecord?.timeline?.let { timeline ->
                item(key = "time") {
                    CenteredColumn(TodayMaxWidth) {
                        WorkspaceSection(
                            stringResource(R.string.today_day_so_far),
                            trailing = { TextButton(onClick = onOpenTimeline) { Text(stringResource(R.string.today_open_timeline)) } },
                        ) {
                            DayOverview(timeline, meetingCount = state.meetings.size)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DigestSection(state: TodayState, writtenAt: String) {
    val palette = LokalBotTheme.palette
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(LokalBotTokens.Spacing.headerToContent)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Outlined.AutoAwesome, contentDescription = null, tint = palette.accentText, modifier = Modifier.size(18.dp))
            Text(stringResource(R.string.digest_title), style = LokalBotType.section, modifier = Modifier.semantics { heading() })
            if (state.digestIsYesterday) BrandChip(stringResource(R.string.day_yesterday), compact = true)
        }
        val digest = state.digestDay?.digest
        Column(
            Modifier.fillMaxWidth().groupedSurface().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (digest == null) {
                Text(stringResource(R.string.digest_empty), style = LokalBotType.secondary, color = LokalBotTheme.supportingText)
            } else {
                DigestView(digest)
                if (writtenAt.isNotEmpty()) {
                    Text(stringResource(R.string.digest_updated, writtenAt), style = LokalBotType.caption, color = LokalBotTheme.supportingText)
                }
            }
        }
    }
}
