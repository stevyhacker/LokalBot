package me.dotenv.lokalbot.companion.ui.common

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
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

@Composable
fun pagePadding(): Dp = when (LocalWindowLayout.current.widthClass) {
    WidthClass.Compact -> 16.dp
    WidthClass.Medium -> 20.dp
    WidthClass.Expanded -> 28.dp
}

@Composable
fun pageContentPadding(horizontal: Dp = pagePadding(), bottom: Dp = 28.dp): PaddingValues {
    val top = WindowInsets.safeDrawing.only(WindowInsetsSides.Top).asPaddingValues().calculateTopPadding()
    val systemBottom = if (LocalWindowLayout.current.widthClass == WidthClass.Compact) 0.dp
    else WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom).asPaddingValues().calculateBottomPadding()
    return PaddingValues(start = horizontal, end = horizontal, top = top + 12.dp, bottom = bottom + systemBottom)
}

@Composable
fun CenteredColumn(maxWidth: Dp, content: @Composable () -> Unit) {
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        Box(Modifier.widthIn(max = maxWidth).fillMaxWidth()) { content() }
    }
}

@Composable
fun BackButton(onBack: () -> Unit) {
    IconButton(onClick = onBack) {
        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
    }
}
