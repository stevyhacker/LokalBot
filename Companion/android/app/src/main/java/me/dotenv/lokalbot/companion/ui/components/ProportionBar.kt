package me.dotenv.lokalbot.companion.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import me.dotenv.lokalbot.companion.data.model.NamedDuration
import me.dotenv.lokalbot.companion.ui.format.Formats
import me.dotenv.lokalbot.companion.ui.theme.BrandColors
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

/** One coloured share of the day. */
data class BarSegment(val name: String, val seconds: Double, val color: Color)

@Composable
fun rememberSegments(durations: List<NamedDuration>, maxSegments: Int = 6): List<BarSegment> {
    val palette = LokalBotTheme.palette
    val sorted = durations.filter { it.seconds > 0 }.sortedByDescending { it.seconds }
    val shown = sorted.filter { it.name != BrandColors.OTHER }.take(maxSegments)
    val rest = sorted.filterNot { it in shown }.sumOf { it.seconds }
    return shown.map { BarSegment(it.name, it.seconds, BrandColors.nameColor(it.name, palette)) } +
        if (rest > 0) listOf(BarSegment(BrandColors.OTHER, rest, BrandColors.nameColor(BrandColors.OTHER, palette))) else emptyList()
}

/** The activity overview bar: a capsule split by share of tracked time (`ProportionBar`). */
@Composable
fun ProportionBar(segments: List<BarSegment>, modifier: Modifier = Modifier, height: Dp = 10.dp) {
    val track = LokalBotTheme.palette.chipFill
    val description = segments.joinToString(", ") { "${it.name} ${Formats.duration(it.seconds)}" }
    Canvas(modifier.fillMaxWidth().height(height).semantics { contentDescription = description }) {
        val radius = CornerRadius(size.height / 2)
        val clip = Path().apply { addRoundRect(RoundRect(0f, 0f, size.width, size.height, radius)) }
        clipPath(clip) {
            drawRect(track)
            val total = segments.sumOf { it.seconds }.takeIf { it > 0 } ?: return@clipPath
            var x = 0f
            for (segment in segments) {
                val width = (segment.seconds / total * size.width).toFloat()
                val left = if (layoutDirection == LayoutDirection.Rtl) size.width - x - width else x
                drawRect(segment.color, Offset(left, 0f), Size(width, size.height))
                x += width
            }
        }
    }
}

/** Dot, name and time for each segment, wrapping on narrow screens. */
@Composable
fun BarLegend(segments: List<BarSegment>, modifier: Modifier = Modifier) {
    FlowRow(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        segments.forEach { segment ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                StatusDot(segment.color, size = 7.dp)
                Text(segment.name, style = LokalBotType.secondary, maxLines = 1)
                Text(Formats.duration(segment.seconds), style = LokalBotType.timestamp, color = LokalBotTheme.supportingText)
            }
        }
    }
}
