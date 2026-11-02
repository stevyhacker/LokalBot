package me.dotenv.lokalbot.companion.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import java.time.Duration
import java.time.Instant
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.MacRoute
import me.dotenv.lokalbot.companion.data.SyncFailure
import me.dotenv.lokalbot.companion.data.SyncState
import me.dotenv.lokalbot.companion.ui.LocalFormats
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

/** "Synced with your Mac · 2 min ago · Wi-Fi": when this copy was last current, and how. */
@Composable
fun SyncPill(
    state: SyncState,
    isSample: Boolean,
    now: Instant,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
) {
    val palette = LokalBotTheme.palette
    val formats = LocalFormats.current
    val status = state.status
    val route = when (status.route) {
        MacRoute.Wifi -> stringResource(R.string.route_wifi)
        MacRoute.Tailscale -> stringResource(R.string.route_tailscale)
        null -> null
    }
    val ago = status.lastSyncAt?.let { formats.ago(it, now) }
    val stale = status.lastSyncAt?.let { Duration.between(it, now).toHours() >= 24 } ?: true
    val (dot, text) = when {
        isSample -> palette.textSupporting to stringResource(R.string.sync_pill_sample)
        state is SyncState.Syncing -> palette.accentText to stringResource(R.string.sync_pill_syncing)
        state is SyncState.Failed && state.reason == SyncFailure.Revoked -> palette.recording to stringResource(R.string.sync_pill_revoked)
        state is SyncState.Failed && ago != null -> palette.attention to stringResource(R.string.sync_pill_unreachable_since, ago)
        state is SyncState.Failed -> palette.attention to stringResource(R.string.sync_pill_unreachable)
        ago == null -> palette.textSupporting to stringResource(R.string.sync_pill_never)
        else -> (if (stale) palette.attention else palette.success) to listOfNotNull(stringResource(R.string.sync_pill_synced), ago, route).joinToString(" · ")
    }
    Row(
        modifier
            .clip(CircleShape)
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .heightIn(min = 32.dp)
            .chipChrome(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        StatusDot(dot, size = 7.dp)
        Text(text, style = LokalBotType.caption, color = LokalBotTheme.supportingText, maxLines = 2)
    }
}
