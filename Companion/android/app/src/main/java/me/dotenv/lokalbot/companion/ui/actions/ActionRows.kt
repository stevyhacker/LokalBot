package me.dotenv.lokalbot.companion.ui.actions

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.ActionOrdering
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.data.model.MeetingAction
import me.dotenv.lokalbot.companion.ui.LocalFormats
import me.dotenv.lokalbot.companion.ui.components.ActionToggle
import me.dotenv.lokalbot.companion.ui.components.rowSelection
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

/**
 * One action item: the round toggle, the text, and a quiet line with the
 * owner, the due date (red when overdue), the meeting and any change that
 * is still waiting for the Mac.
 */
@Composable
fun ActionItemRow(
    action: MeetingAction,
    today: LocalDate,
    onToggle: (ActionStatus) -> Unit,
    modifier: Modifier = Modifier,
    meetingTitle: String? = null,
    pending: Boolean = false,
    selected: Boolean = false,
    onClick: (() -> Unit)? = null,
    trailing: @Composable () -> Unit = {},
) {
    val done = action.status != ActionStatus.Open
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .rowSelection(selected)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        verticalAlignment = Alignment.Top,
    ) {
        ActionToggle(action.status, onToggle)
        Column(Modifier.weight(1f).padding(top = 9.dp, bottom = 6.dp, end = 4.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                action.text,
                style = LokalBotType.body,
                color = if (done) LokalBotTheme.supportingText else Color.Unspecified,
                textDecoration = if (action.status == ActionStatus.Done) TextDecoration.LineThrough else null,
            )
            ActionMetaLine(action, today, meetingTitle, pending)
        }
        trailing()
    }
}

@Composable
fun ActionMetaLine(action: MeetingAction, today: LocalDate, meetingTitle: String?, pending: Boolean) {
    val formats = LocalFormats.current
    val palette = LokalBotTheme.palette
    val supporting = LokalBotTheme.supportingText
    val overdue = ActionOrdering.isOverdue(action, today)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        val owner = when {
            action.ownerIsUser -> null
            action.ownerUnclear -> stringResource(R.string.action_owner_unclear)
            else -> action.owner
        }
        if (owner != null) {
            Text(owner, style = LokalBotType.secondary, color = if (action.ownerUnclear) palette.attentionText else supporting)
        }
        action.dueDate?.let { due ->
            val label = if (overdue) stringResource(R.string.action_overdue, formats.dueDay(due, today))
            else stringResource(R.string.action_due, formats.dueDay(due, today))
            Text(label, style = LokalBotType.secondary, color = if (overdue) palette.recordingText else supporting)
        }
        if (meetingTitle != null) {
            Text(meetingTitle, style = LokalBotType.secondary, color = palette.accentText, maxLines = 1)
        }
        if (pending) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                Icon(Icons.Outlined.Schedule, null, tint = palette.attentionText, modifier = Modifier.size(14.dp))
                Text(stringResource(R.string.action_waiting_for_mac), style = LokalBotType.secondary, color = palette.attentionText)
            }
        }
    }
}
