package me.dotenv.lokalbot.companion.ui.adaptive

import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.layout.PaneAdaptedValue
import androidx.compose.material3.adaptive.navigation.NavigableListDetailPaneScaffold
import androidx.compose.material3.adaptive.navigation.rememberListDetailPaneScaffoldNavigator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import kotlinx.coroutines.launch
import me.dotenv.lokalbot.companion.ui.theme.LokalBotMotion
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme

/** What a list pane needs: how to open an item and which one is showing. */
data class ListPaneState(
    val selectedKey: String?,
    val twoPane: Boolean,
    val open: (String) -> Unit,
)

/**
 * The Material 3 list-detail scaffold used by Meetings, Actions, People and
 * Projects: one pane on a phone, both on wider windows and on either side of
 * a fold, with predictive back. Selection survives rotation and folding.
 */
@Composable
fun ListDetailLayout(
    openRequest: String?,
    onOpenRequestHandled: () -> Unit,
    list: @Composable (ListPaneState) -> Unit,
    detail: @Composable (key: String, back: (() -> Unit)?) -> Unit,
    placeholder: @Composable () -> Unit,
    modifier: Modifier = Modifier,
) {
    val layout = LocalWindowLayout.current
    PaneHost { originX ->
        val directive = rememberPaneDirective(layout, originX)
        val navigator = rememberListDetailPaneScaffoldNavigator<String>(scaffoldDirective = directive)
        val scope = rememberCoroutineScope()
        val twoPane = navigator.scaffoldValue[ListDetailPaneScaffoldRole.List] == PaneAdaptedValue.Expanded &&
            navigator.scaffoldValue[ListDetailPaneScaffoldRole.Detail] == PaneAdaptedValue.Expanded
        val selected = navigator.currentDestination?.contentKey

        LaunchedEffect(openRequest) {
            if (openRequest != null) {
                navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, openRequest)
                onOpenRequestHandled()
            }
        }

        val reduced = LokalBotMotion.reduced
        val separator = LokalBotTheme.palette.separator
        NavigableListDetailPaneScaffold(
            navigator = navigator,
            modifier = modifier.background(if (twoPane) separator else LokalBotTheme.palette.window),
            listPane = {
                AnimatedPane(
                    enterTransition = if (reduced) EnterTransition.None else androidx.compose.animation.fadeIn(),
                    exitTransition = if (reduced) ExitTransition.None else androidx.compose.animation.fadeOut(),
                ) {
                    Box(Modifier.fillMaxSize().background(LokalBotTheme.palette.window)) {
                        list(ListPaneState(selected, twoPane) { key -> scope.launch { navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, key) } })
                    }
                }
            },
            detailPane = {
                AnimatedPane(
                    enterTransition = if (reduced) EnterTransition.None else androidx.compose.animation.fadeIn(),
                    exitTransition = if (reduced) ExitTransition.None else androidx.compose.animation.fadeOut(),
                ) {
                    Box(Modifier.fillMaxSize().background(LokalBotTheme.palette.window)) {
                        val key = selected
                        if (key == null) {
                            placeholder()
                        } else {
                            detail(key, if (twoPane) null else ({ scope.launch { navigator.navigateBack() } }))
                        }
                    }
                }
            },
        )
    }
}
