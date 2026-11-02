package me.dotenv.lokalbot.companion.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import me.dotenv.lokalbot.companion.ui.theme.LokalBotMotion
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.MotionKind

/**
 * Equal-width capsule tabs with a sliding teal knob (`ToolbarTabs`). The
 * selected tab is white on the accent fill; a hidden semibold copy of each
 * title reserves its width so the control never changes size.
 */
@Composable
fun <T> ToolbarTabs(
    tabs: List<T>,
    selected: T,
    onSelect: (T) -> Unit,
    title: @Composable (T) -> String,
    label: String,
    modifier: Modifier = Modifier,
) {
    val palette = LokalBotTheme.palette
    val index = tabs.indexOf(selected).coerceAtLeast(0)
    val knob by animateFloatAsState(index.toFloat(), LokalBotMotion.spec(MotionKind.Tabs), label = "toolbarTabsKnob")
    val knobColor = palette.accentFill
    Layout(
        modifier = modifier
            .background(palette.groupFill, CircleShape)
            .padding(3.dp)
            .drawBehind {
                val width = size.width / tabs.size.coerceAtLeast(1)
                val x = if (layoutDirection == LayoutDirection.Rtl) size.width - width * (knob + 1) else width * knob
                drawRoundRect(knobColor, Offset(x, 0f), Size(width, size.height), CornerRadius(size.height / 2))
            }
            .selectableGroup()
            .semantics { contentDescription = label },
        content = {
            tabs.forEach { tab ->
                val isSelected = tab == selected
                val text = title(tab)
                Box(
                    Modifier
                        .clip(CircleShape)
                        .selectable(selected = isSelected, role = Role.Tab, onClick = { onSelect(tab) })
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    val style = MaterialTheme.typography.labelLarge
                    Text(text, style = style.copy(fontWeight = FontWeight.SemiBold), maxLines = 1, modifier = Modifier.alpha(0f))
                    // Shrinks rather than clips when the pane is narrow or the font scale large.
                    BasicText(
                        text,
                        style = style.copy(
                            fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Medium,
                            color = if (isSelected) Color.White else LokalBotTheme.supportingText,
                        ),
                        maxLines = 1,
                        autoSize = TextAutoSize.StepBased(minFontSize = 10.sp, maxFontSize = style.fontSize),
                    )
                }
            }
        },
    ) { measurables, constraints ->
        val count = measurables.size.coerceAtLeast(1)
        val widest = measurables.maxOfOrNull { it.maxIntrinsicWidth(constraints.maxHeight) } ?: 0
        val total = (widest * count).coerceIn(constraints.minWidth, constraints.maxWidth)
        val each = total / count
        val placeables = measurables.map { it.measure(Constraints.fixedWidth(each)) }
        val height = placeables.maxOfOrNull { it.height } ?: 0
        layout(each * count, height) {
            placeables.forEachIndexed { i, placeable -> placeable.placeRelative(i * each, (height - placeable.height) / 2) }
        }
    }
}
