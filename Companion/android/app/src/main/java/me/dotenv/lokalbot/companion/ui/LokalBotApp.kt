package me.dotenv.lokalbot.companion.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.WindowAdaptiveInfo
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfoV2
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.res.stringResource
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.ui.actions.ActionsScreen
import me.dotenv.lokalbot.companion.ui.adaptive.LocalWindowLayout
import me.dotenv.lokalbot.companion.ui.adaptive.WidthClass
import me.dotenv.lokalbot.companion.ui.adaptive.WindowLayout
import me.dotenv.lokalbot.companion.ui.ask.AskScreen
import me.dotenv.lokalbot.companion.ui.meetings.MeetingsScreen
import me.dotenv.lokalbot.companion.ui.navigation.AppNavigator
import me.dotenv.lokalbot.companion.ui.navigation.Destination
import me.dotenv.lokalbot.companion.ui.navigation.rememberAppNavigator
import me.dotenv.lokalbot.companion.ui.people.PeopleScreen
import me.dotenv.lokalbot.companion.ui.projects.ProjectsScreen
import me.dotenv.lokalbot.companion.ui.settings.SettingsActions
import me.dotenv.lokalbot.companion.ui.settings.SettingsScreen
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.timeline.TimelineScreen
import me.dotenv.lokalbot.companion.ui.today.TodayScreen

/** Destinations the navigation bar leaves out, shown from a "More" menu in page headers. */
val LocalOverflowDestinations = staticCompositionLocalOf<List<Destination>> { emptyList() }
val LocalAppNavigator = staticCompositionLocalOf<AppNavigator> { error("AppNavigator not provided") }

/**
 * The app shell: a bottom bar on compact widths, a rail on medium widths and
 * beside a fold, the Mac-like drawer on expanded widths.
 */
@Composable
fun LokalBotApp(
    repository: CompanionRepository,
    settingsActions: SettingsActions,
    modifier: Modifier = Modifier,
    adaptiveInfo: WindowAdaptiveInfo = currentWindowAdaptiveInfoV2(),
    navigator: AppNavigator = rememberAppNavigator(),
) {
    val layout = remember(adaptiveInfo) { WindowLayout.from(adaptiveInfo) }
    val heightDp = with(LocalDensity.current) { LocalWindowInfo.current.containerSize.height.toDp() }
    val suiteType = when {
        layout.widthClass == WidthClass.Compact -> NavigationSuiteType.NavigationBar
        // Beside a fold, and on short windows such as a phone in landscape, the drawer would
        // crowd the content or run off the screen.
        layout.widthClass == WidthClass.Medium || layout.bookHinge != null || layout.heightCompact -> NavigationSuiteType.NavigationRail
        else -> NavigationSuiteType.NavigationDrawer
    }
    val showsAll = suiteType == NavigationSuiteType.NavigationDrawer ||
        (suiteType == NavigationSuiteType.NavigationRail && heightDp >= 640.dp)
    val shown = Destination.entries.filter { showsAll || it.primary }
    val overflow = Destination.entries - shown.toSet()
    val palette = LokalBotTheme.palette

    val itemColors = NavigationSuiteDefaults.itemColors(
        navigationBarItemColors = NavigationBarItemDefaults.colors(
            selectedIconColor = palette.accentText,
            selectedTextColor = palette.textPrimary,
            indicatorColor = palette.accentWash,
            unselectedIconColor = LokalBotTheme.supportingText,
            unselectedTextColor = LokalBotTheme.supportingText,
        ),
        navigationRailItemColors = NavigationRailItemDefaults.colors(
            selectedIconColor = palette.accentText,
            selectedTextColor = palette.textPrimary,
            indicatorColor = palette.accentWash,
            unselectedIconColor = LokalBotTheme.supportingText,
            unselectedTextColor = LokalBotTheme.supportingText,
        ),
        navigationDrawerItemColors = NavigationDrawerItemDefaults.colors(
            selectedContainerColor = palette.accentWash,
            unselectedContainerColor = palette.sidebar,
            selectedIconColor = palette.accentText,
            unselectedIconColor = palette.accentText,
            selectedTextColor = palette.textPrimary,
            unselectedTextColor = palette.textPrimary,
        ),
    )

    CompositionLocalProvider(
        LocalWindowLayout provides layout,
        LocalFormats provides rememberFormats(repository.zone()),
        LocalOverflowDestinations provides overflow,
        LocalAppNavigator provides navigator,
    ) {
        NavigationSuiteScaffold(
            modifier = modifier,
            layoutType = suiteType,
            containerColor = palette.window,
            navigationSuiteColors = NavigationSuiteDefaults.colors(
                navigationBarContainerColor = palette.sidebar,
                navigationRailContainerColor = palette.sidebar,
                navigationDrawerContainerColor = palette.sidebar,
            ),
            navigationSuiteItems = {
                shown.forEach { destination ->
                    item(
                        selected = navigator.destination == destination,
                        onClick = { navigator.go(destination) },
                        icon = { Icon(destination.icon, contentDescription = null) },
                        label = { NavLabel(stringResource(destination.label)) },
                        colors = itemColors,
                    )
                }
            },
        ) {
            // Each destination keeps its scroll and pane state while you move between them.
            val saveableState = rememberSaveableStateHolder()
            Box(Modifier.fillMaxSize()) {
                saveableState.SaveableStateProvider(navigator.destination.name) {
                    when (navigator.destination) {
                        Destination.Today -> TodayScreen(repository)
                        Destination.Meetings -> MeetingsScreen(repository)
                        Destination.Actions -> ActionsScreen(repository)
                        Destination.Timeline -> TimelineScreen(repository)
                        Destination.People -> PeopleScreen(repository)
                        Destination.Projects -> ProjectsScreen(repository)
                        Destination.Ask -> AskScreen(repository)
                        Destination.Settings -> SettingsScreen(repository, settingsActions)
                    }
                }
            }
        }
    }
}

/** A navigation label that shrinks to one line at large font scales instead of breaking mid-word. */
@Composable
private fun NavLabel(text: String) {
    val style = LocalTextStyle.current
    BasicText(
        text,
        style = style.copy(color = LocalContentColor.current),
        maxLines = 1,
        autoSize = TextAutoSize.StepBased(minFontSize = 9.sp, maxFontSize = style.fontSize),
    )
}

/** The "More" button for destinations the bottom bar leaves out. */
@Composable
fun OverflowDestinationsButton() {
    val overflow = LocalOverflowDestinations.current
    if (overflow.isEmpty()) return
    val navigator = LocalAppNavigator.current
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Outlined.MoreHoriz, contentDescription = stringResource(R.string.nav_more))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            overflow.forEach { destination ->
                DropdownMenuItem(
                    text = { Text(stringResource(destination.label)) },
                    leadingIcon = { Icon(destination.icon, contentDescription = null, tint = LokalBotTheme.palette.accentText) },
                    onClick = {
                        open = false
                        navigator.go(destination)
                    },
                )
            }
        }
    }
}
