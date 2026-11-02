package me.dotenv.lokalbot.companion.ui.adaptive

import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.BoxWithConstraintsScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.adaptive.HingeInfo
import androidx.compose.material3.adaptive.WindowAdaptiveInfo
import androidx.compose.material3.adaptive.layout.PaneScaffoldDirective
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirectiveWithTwoPanesOnMediumWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.window.core.layout.WindowSizeClass

enum class WidthClass { Compact, Medium, Expanded }

/** What the screens need to know about the window: its width class and any fold. */
data class WindowLayout(
    val adaptiveInfo: WindowAdaptiveInfo,
    val widthClass: WidthClass,
    /** A vertical fold that separates the screen, as in book posture. */
    val bookHinge: HingeInfo?,
    /** A horizontal fold with the device half open, as in tabletop posture. */
    val tabletopHinge: HingeInfo?,
    /** Under 480 dp tall, such as a phone in landscape. */
    val heightCompact: Boolean = false,
) {
    companion object {
        fun from(info: WindowAdaptiveInfo): WindowLayout {
            val size = info.windowSizeClass
            val width = when {
                size.isWidthAtLeastBreakpoint(WindowSizeClass.WIDTH_DP_EXPANDED_LOWER_BOUND) -> WidthClass.Expanded
                size.isWidthAtLeastBreakpoint(WindowSizeClass.WIDTH_DP_MEDIUM_LOWER_BOUND) -> WidthClass.Medium
                else -> WidthClass.Compact
            }
            val hinges = info.windowPosture.hingeList
            return WindowLayout(
                adaptiveInfo = info,
                widthClass = width,
                bookHinge = hinges.firstOrNull { it.isVertical && it.isSeparating },
                tabletopHinge = hinges.firstOrNull { !it.isVertical && it.isSeparating }
                    ?.takeIf { info.windowPosture.isTabletop },
                heightCompact = !size.isHeightAtLeastBreakpoint(WindowSizeClass.HEIGHT_DP_MEDIUM_LOWER_BOUND),
            )
        }
    }
}

val LocalWindowLayout = staticCompositionLocalOf<WindowLayout> { error("WindowLayout not provided") }

/**
 * A list-detail directive: two panes from medium widths, the list sized to
 * about 40% of the space, and, with a vertical fold, the panes split exactly
 * along the hinge so nothing sits under it.
 */
@Composable
fun BoxWithConstraintsScope.rememberPaneDirective(
    layout: WindowLayout,
    originX: Float,
    fixedPaneAtEnd: Boolean = false,
    preferredWidth: Dp = (maxWidth * 0.38f).coerceIn(260.dp, 380.dp),
): PaneScaffoldDirective {
    val density = LocalDensity.current
    val base = calculatePaneScaffoldDirectiveWithTwoPanesOnMediumWidth(layout.adaptiveInfo)
    if (layout.widthClass == WidthClass.Compact) {
        return base.copy(maxHorizontalPartitions = 1, horizontalPartitionSpacerSize = 0.dp)
    }
    val hinge = layout.bookHinge
    if (hinge != null) {
        val hingeStart = with(density) { (hinge.bounds.left - originX).toDp() }
        val hingeWidth = with(density) { hinge.bounds.width.toDp() }
        if (hingeStart > 200.dp && hingeStart < maxWidth - 200.dp) {
            return base.copy(
                maxHorizontalPartitions = 2,
                horizontalPartitionSpacerSize = hingeWidth,
                defaultPanePreferredWidth = if (fixedPaneAtEnd) maxWidth - hingeStart - hingeWidth else hingeStart,
                excludedBounds = listOf(hinge.bounds),
            )
        }
    }
    return base.copy(
        maxHorizontalPartitions = 2,
        horizontalPartitionSpacerSize = 1.dp,
        defaultPanePreferredWidth = preferredWidth,
        excludedBounds = emptyList(),
    )
}

/** Measures where the pane scaffold starts in the window, so a hinge can be found in its coordinates. */
@Composable
fun PaneHost(content: @Composable BoxWithConstraintsScope.(originX: Float) -> Unit) {
    var originX by remember { mutableFloatStateOf(0f) }
    BoxWithConstraints(Modifier.fillMaxSize().onGloballyPositioned { originX = it.positionInWindow().x }) {
        content(originX)
    }
}

/** A hinge's top edge relative to a composable at [originY] in the window, in dp. */
fun Rect.topIn(originY: Float, toDp: (Float) -> Dp): Dp = toDp(top - originY)
