package me.dotenv.lokalbot.companion.ui.meetings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.ui.LocalFormats
import me.dotenv.lokalbot.companion.ui.components.rowSelection
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

/** Title over "Zoom · 10:30 · 42 min", as in the Mac's meeting list. */
@Composable
fun MeetingRow(meeting: Meeting, onClick: () -> Unit, modifier: Modifier = Modifier, selected: Boolean = false) {
    val formats = LocalFormats.current
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .rowSelection(selected)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            meeting.title,
            style = LokalBotType.body.copy(fontWeight = FontWeight.SemiBold),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(formats.meetingMeta(meeting), style = LokalBotType.timestamp, color = LokalBotTheme.supportingText, maxLines = 1)
    }
}
