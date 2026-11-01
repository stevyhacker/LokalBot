package me.dotenv.lokalbot.companion.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTokens
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

/**
 * The Mac's grouped surface (`lbGroupedSurface`): a quiet fill with a
 * hairline stroke, or a tinted status surface when [tint] is set.
 */
fun Modifier.groupedSurface(
    tint: Color? = null,
    shape: Shape = RoundedCornerShape(LokalBotTokens.Radius.panel),
): Modifier = composed {
    val palette = LokalBotTheme.palette
    val contrast = LokalBotTheme.increasedContrast
    val stroke = when {
        contrast -> palette.textPrimary.copy(alpha = 0.5f)
        tint != null -> tint.copy(alpha = 0.28f)
        else -> palette.groupStroke
    }
    this
        .background(tint?.copy(alpha = 0.10f) ?: palette.groupFill, shape)
        .border(if (contrast) 2.dp else 1.dp, stroke, shape)
}

/** Capsule chip chrome shared by metadata badges, stat pills and labels. */
fun Modifier.chipChrome(compact: Boolean = false): Modifier = composed {
    this
        .background(LokalBotTheme.palette.chipFill, CircleShape)
        .padding(horizontal = if (compact) 8.dp else 10.dp, vertical = if (compact) 3.dp else 5.dp)
}

/** The selected-row wash used in lists beside a detail pane. */
fun Modifier.rowSelection(selected: Boolean): Modifier = composed {
    if (selected) background(LokalBotTheme.palette.accentWash, RoundedCornerShape(LokalBotTokens.Radius.row)) else this
}

/** Holds prose to a comfortable reading line on wide screens. */
fun Modifier.readingWidth(): Modifier = widthIn(max = LokalBotTokens.Spacing.readingMaxWidth)

/** A titled group of rows on a grouped surface (`WorkspaceSection`). */
@Composable
fun WorkspaceSection(
    title: String,
    modifier: Modifier = Modifier,
    trailing: @Composable RowScope.() -> Unit = {},
    contentPadding: Dp = LokalBotTokens.Spacing.cardPadding,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(LokalBotTokens.Spacing.headerToContent)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = LokalBotType.section, modifier = Modifier.weight(1f).semantics { heading() })
            trailing()
        }
        Column(
            Modifier.fillMaxWidth().groupedSurface().padding(contentPadding),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            content = content,
        )
    }
}

/** Caption header for list groupings such as meeting-list days (`SectionHeader`). */
@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = LokalBotType.sectionHeader,
        color = LokalBotTheme.supportingText,
        modifier = modifier.semantics { heading() },
    )
}

/** A small capsule chip: optional icon and text in the supporting colour (`BrandChip`). */
@Composable
fun BrandChip(text: String, modifier: Modifier = Modifier, icon: ImageVector? = null, compact: Boolean = false, color: Color = LokalBotTheme.supportingText) {
    Row(modifier.chipChrome(compact), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        if (icon != null) Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(if (compact) 12.dp else 14.dp))
        Text(text, style = if (compact) LokalBotType.caption else LokalBotType.timestamp, color = color, maxLines = 1)
    }
}

/** A small state-coloured dot (`StatusDot`). */
@Composable
fun StatusDot(color: Color, modifier: Modifier = Modifier, size: Dp = 8.dp) {
    Box(modifier.size(size).background(color, CircleShape))
}

/** Icon, value and label in a chip, with tabular digits (`StatTile`). */
@Composable
fun StatTile(icon: ImageVector, value: String, label: String, modifier: Modifier = Modifier) {
    Row(modifier.chipChrome(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Icon(icon, contentDescription = null, tint = LokalBotTheme.supportingText, modifier = Modifier.size(15.dp))
        Text(value, style = LokalBotType.timestamp.copy(fontWeight = FontWeight.SemiBold))
        Text(label, style = LokalBotType.secondary, color = LokalBotTheme.supportingText)
    }
}

/** Page title with an optional subtitle and trailing actions, like the Mac's toolbar titles. */
@Composable
fun PageHeader(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = LokalBotType.pageTitle, modifier = Modifier.semantics { heading() })
            if (subtitle != null) {
                Text(subtitle, style = LokalBotType.secondary, color = LokalBotTheme.supportingText)
            }
        }
        actions()
    }
}

/** A quiet empty state with an optional call to action. */
@Composable
fun EmptyState(
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    actions: @Composable ColumnScope.() -> Unit = {},
) {
    Column(
        modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = LokalBotTheme.palette.accentText, modifier = Modifier.size(32.dp))
            Spacer(Modifier.size(4.dp))
        }
        Text(title, style = LokalBotType.columnTitle, textAlign = TextAlign.Center)
        Text(message, style = LokalBotType.secondary, color = LokalBotTheme.supportingText, textAlign = TextAlign.Center, modifier = Modifier.readingWidth())
        actions()
    }
}

/** A compact spinner beside a quiet description (`LoadingStateLabel`). */
@Composable
fun LoadingStateLabel(text: String, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.primary)
        Text(text, style = LokalBotType.secondary, color = LokalBotTheme.supportingText)
    }
}

/** A row on a grouped surface separated by hairlines. */
@Composable
fun RowDivider(modifier: Modifier = Modifier) {
    HorizontalDivider(modifier, thickness = 1.dp, color = LokalBotTheme.palette.separator)
}
