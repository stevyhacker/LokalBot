package me.dotenv.lokalbot.companion.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FormatQuote
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.ui.format.Formats
import me.dotenv.lokalbot.companion.ui.theme.BrandColors
import me.dotenv.lokalbot.companion.ui.theme.Inter
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

/** A transcript timestamp that jumps to the cited moment (`EvidencePill`). */
@Composable
fun EvidencePill(start: Double, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val stamp = Formats.offset(start)
    val description = stringResource(R.string.evidence_jump, stamp)
    val accent = LokalBotTheme.palette.accentText
    Row(
        modifier
            .clip(RoundedCornerShape(6.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .heightIn(min = 32.dp)
            .padding(horizontal = 6.dp, vertical = 4.dp)
            .semantics(mergeDescendants = true) { contentDescription = description },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(Icons.Outlined.FormatQuote, contentDescription = null, tint = accent, modifier = Modifier.size(16.dp))
        Text(stamp, style = LokalBotType.timestamp, color = accent)
    }
}

/** A numbered teal source badge: white on the accent fill, as on the Mac's Evidence list. */
@Composable
fun SourceBadge(number: Int, modifier: Modifier = Modifier, size: Dp = 20.dp) {
    val fontSize = with(LocalDensity.current) { (size * 0.55f).toSp() }
    Box(
        modifier
            .size(size)
            .background(LokalBotTheme.palette.accentFill, RoundedCornerShape(size * 0.2f)),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            number.toString(),
            style = TextStyle(fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = fontSize, fontFeatureSettings = "tnum"),
            color = androidx.compose.ui.graphics.Color.White,
        )
    }
}

/** A person's initials on a tint chosen from their name (`InitialsAvatar`). */
@Composable
fun InitialsAvatar(name: String, modifier: Modifier = Modifier, size: Dp = 30.dp) {
    val color = BrandColors.avatarColor(name, LokalBotTheme.palette)
    val fontSize = with(LocalDensity.current) { (size * 0.4f).toSp() }
    Box(
        modifier
            .size(size)
            .background(color.copy(alpha = 0.16f), CircleShape)
            .border(0.5.dp, color.copy(alpha = 0.28f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Text(BrandColors.initials(name), style = TextStyle(fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = fontSize), color = color)
    }
}

/** A project's first letter on a tint chosen from its name (`ProjectMonogram`). */
@Composable
fun ProjectMonogram(name: String, modifier: Modifier = Modifier, size: Dp = 30.dp) {
    val color = BrandColors.avatarColor(name, LokalBotTheme.palette)
    val shape = RoundedCornerShape(size * 0.26f)
    val fontSize = with(LocalDensity.current) { (size * 0.46f).toSp() }
    Box(
        modifier
            .size(size)
            .background(color.copy(alpha = 0.16f), shape)
            .border(0.5.dp, color.copy(alpha = 0.28f), shape),
        contentAlignment = Alignment.Center,
    ) {
        Text(name.firstOrNull()?.uppercase().orEmpty(), style = TextStyle(fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = fontSize), color = color)
    }
}
