package me.dotenv.lokalbot.companion.ui.common

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.ui.adaptive.LocalWindowLayout
import me.dotenv.lokalbot.companion.ui.adaptive.WidthClass

/** Page margins: tighter on phones, the Mac's 28 pt on wide windows. */
@Composable
fun pagePadding(): Dp = when (LocalWindowLayout.current.widthClass) {
    WidthClass.Compact -> 16.dp
    WidthClass.Medium -> 20.dp
    WidthClass.Expanded -> 28.dp
}

/** Content padding for a scrolling page: margins plus the status-bar inset. */
@Composable
fun pageContentPadding(horizontal: Dp = pagePadding(), bottom: Dp = 28.dp): PaddingValues {
    val top = WindowInsets.safeDrawing.only(WindowInsetsSides.Top).asPaddingValues().calculateTopPadding()
    // A bottom bar already sits above the system navigation bar; rails and drawers don't.
    val systemBottom = if (LocalWindowLayout.current.widthClass == WidthClass.Compact) 0.dp
    else WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom).asPaddingValues().calculateBottomPadding()
    return PaddingValues(start = horizontal, end = horizontal, top = top + 12.dp, bottom = bottom + systemBottom)
}

/** Centres a page's content column at [maxWidth]. */
@Composable
fun CenteredColumn(maxWidth: Dp, content: @Composable () -> Unit) {
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        Box(Modifier.widthIn(max = maxWidth).fillMaxWidth()) { content() }
    }
}

/** Back from a detail pane shown alone on a phone. */
@Composable
fun BackButton(onBack: () -> Unit) {
    IconButton(onClick = onBack) {
        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
    }
}

/** A row of header actions. */
@Composable
fun HeaderActions(content: @Composable () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(0.dp)) { content() }
}
