package me.dotenv.lokalbot.companion.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.RemoveCircleOutline
import androidx.compose.material3.Icon
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme

/**
 * The round, Reminders-style action toggle (`ActionItemToggleStyle`): an
 * empty circle when open, a teal check when done, a dash when deferred.
 * Toggling marks an open action done and anything else open.
 */
@Composable
fun ActionToggle(status: ActionStatus, onToggle: (ActionStatus) -> Unit, modifier: Modifier = Modifier) {
    val palette = LokalBotTheme.palette
    val done = status == ActionStatus.Done
    val label = stringResource(if (status == ActionStatus.Open) R.string.action_mark_done else R.string.action_mark_open)
    val state = stringResource(
        when (status) {
            ActionStatus.Open -> R.string.action_status_open
            ActionStatus.Done -> R.string.action_status_done
            ActionStatus.Deferred -> R.string.action_status_deferred
        },
    )
    Box(
        modifier
            .size(40.dp)
            .clip(CircleShape)
            .toggleable(
                value = done,
                interactionSource = remember { MutableInteractionSource() },
                indication = ripple(bounded = false, radius = 20.dp),
                role = Role.Checkbox,
                onValueChange = { onToggle(if (status == ActionStatus.Open) ActionStatus.Done else ActionStatus.Open) },
            )
            .semantics {
                contentDescription = label
                stateDescription = state
            },
        contentAlignment = Alignment.Center,
    ) {
        when (status) {
            ActionStatus.Done -> Icon(Icons.Filled.CheckCircle, null, tint = palette.accentText, modifier = Modifier.size(22.dp))
            ActionStatus.Deferred -> Icon(Icons.Outlined.RemoveCircleOutline, null, tint = LokalBotTheme.supportingText, modifier = Modifier.size(22.dp))
            ActionStatus.Open -> Icon(Icons.Outlined.Circle, null, tint = palette.textSupporting.copy(alpha = 0.7f), modifier = Modifier.size(22.dp))
        }
    }
}
