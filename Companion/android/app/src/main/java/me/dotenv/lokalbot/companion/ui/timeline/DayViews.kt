package me.dotenv.lokalbot.companion.ui.timeline

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Redo
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.model.DayTimeline
import me.dotenv.lokalbot.companion.data.model.Digest
import me.dotenv.lokalbot.companion.ui.components.BarLegend
import me.dotenv.lokalbot.companion.ui.components.MarkdownText
import me.dotenv.lokalbot.companion.ui.components.ProportionBar
import me.dotenv.lokalbot.companion.ui.components.RichText
import me.dotenv.lokalbot.companion.ui.components.StatTile
import me.dotenv.lokalbot.companion.ui.components.groupedSurface
import me.dotenv.lokalbot.companion.ui.components.rememberSegments
import me.dotenv.lokalbot.companion.ui.format.Formats
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

/**
 * A Day Digest in the Mac's order: Blockers on an amber surface, then
 * Highlights, Decisions, Tasks and Follow-ups.
 */
@Composable
fun DigestView(digest: Digest, modifier: Modifier = Modifier) {
    val palette = LokalBotTheme.palette
    val sections = digest.sections
    if (sections.isEmpty) {
        MarkdownText(digest.markdown, modifier)
        return
    }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (sections.blockers.isNotEmpty()) {
            Column(
                Modifier.fillMaxWidth().groupedSurface(tint = palette.attention).padding(horizontal = 12.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                DigestLabel(Icons.Outlined.Warning, pluralStringResource(R.plurals.digest_blockers, sections.blockers.size), palette.attentionText, palette.attentionText)
                sections.blockers.forEach { DigestBullet(it) }
            }
        }
        DigestSection(Icons.Outlined.AutoAwesome, stringResource(R.string.digest_highlights), sections.highlights)
        DigestSection(Icons.Outlined.Verified, stringResource(R.string.digest_decisions), sections.decisions)
        DigestSection(Icons.Outlined.Checklist, stringResource(R.string.digest_tasks), sections.tasks)
        DigestSection(Icons.AutoMirrored.Outlined.Redo, stringResource(R.string.digest_follow_ups), sections.followUps)
    }
}

@Composable
private fun DigestSection(icon: ImageVector, title: String, items: List<String>) {
    if (items.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        DigestLabel(icon, title, LokalBotTheme.palette.accentText, Color.Unspecified)
        items.forEach { DigestBullet(it) }
    }
}

@Composable
private fun DigestLabel(icon: ImageVector, title: String, iconTint: Color, textColor: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(16.dp))
        Text(title, style = LokalBotType.sectionHeader, color = textColor, modifier = Modifier.semantics { heading() })
    }
}

@Composable
private fun DigestBullet(text: String) {
    Row {
        Text("•", style = LokalBotType.reading, color = LokalBotTheme.supportingText, modifier = Modifier.width(16.dp))
        RichText(text, LokalBotType.reading, modifier = Modifier.weight(1f))
    }
}

/**
 * "Day so far": tracked time, the overview bar by project and its legend
 * (`DayActivityOverview`).
 */
@Composable
fun DayOverview(timeline: DayTimeline, meetingCount: Int, modifier: Modifier = Modifier, showLegend: Boolean = true) {
    val segments = rememberSegments(timeline.byProject.ifEmpty { timeline.byApp })
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            StatTile(Icons.Outlined.Schedule, Formats.duration(timeline.trackedSeconds), stringResource(R.string.stat_tracked))
            StatTile(Icons.Outlined.GraphicEq, meetingCount.toString(), pluralStringResource(R.plurals.stat_meetings, meetingCount))
            StatTile(Icons.Outlined.Apps, timeline.byApp.size.toString(), pluralStringResource(R.plurals.stat_apps, timeline.byApp.size))
        }
        if (segments.isNotEmpty()) {
            ProportionBar(segments)
            if (showLegend) BarLegend(segments)
        }
    }
}
