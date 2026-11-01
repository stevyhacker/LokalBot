package me.dotenv.lokalbot.companion.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.launch
import me.dotenv.lokalbot.companion.AppContainer
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.ui.onboarding.AppMark
import me.dotenv.lokalbot.companion.ui.onboarding.PairingScreen
import me.dotenv.lokalbot.companion.ui.onboarding.PairingViewModel
import me.dotenv.lokalbot.companion.ui.onboarding.WelcomeScreen
import me.dotenv.lokalbot.companion.ui.settings.SettingsActions
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

/** Device-level state the activity owns: app lock and an incoming pairing link. */
data class RootActions(
    val appLockEnabled: Boolean,
    val appLockAvailable: Boolean,
    val onAppLockChange: (Boolean) -> Unit,
    val pairingLink: String?,
    val onPairingLinkConsumed: () -> Unit,
    val versionName: String,
)

/** Chooses between first run, pairing and the library. */
@Composable
fun CompanionRoot(container: AppContainer, actions: RootActions) {
    val ready by container.ready.collectAsStateWithLifecycle()
    val repository by container.repository.collectAsStateWithLifecycle()
    val removedByMac by container.removedByMac.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var pairing by rememberSaveable { mutableStateOf(false) }
    val palette = LokalBotTheme.palette

    when {
        !ready -> Box(Modifier.fillMaxSize().background(palette.window))
        pairing || actions.pairingLink != null -> {
            val pairingViewModel = viewModel { PairingViewModel(pair = container::pair, initialDeviceName = container::deviceName) }
            PairingScreen(
                viewModel = pairingViewModel,
                initialLink = actions.pairingLink,
                onDone = {
                    pairing = false
                    actions.onPairingLinkConsumed()
                },
                onClose = {
                    pairingViewModel.restart()
                    pairing = false
                    actions.onPairingLinkConsumed()
                },
            )
        }
        repository == null -> WelcomeScreen(
            onPair = { pairing = true },
            onTrySample = { scope.launch { container.openSample() } },
            removedByMac = removedByMac,
            onDismissRemoved = container::dismissRemovedNotice,
        )
        else -> {
            val library = repository!!
            LibraryScope(library.id) {
                LokalBotApp(
                    repository = library,
                    settingsActions = SettingsActions(
                        appLockEnabled = actions.appLockEnabled,
                        appLockAvailable = actions.appLockAvailable,
                        onAppLockChange = actions.onAppLockChange,
                        onPair = { pairing = true },
                        onRemoveLibrary = { scope.launch { container.removeLibrary() } },
                        storageBytes = container.storageBytes(),
                        versionName = actions.versionName,
                    ),
                )
            }
        }
    }
}

/** Keeps one library's view models together, and drops them when the library changes. */
class LibraryScopes : ViewModel() {
    private var current: Pair<String, ViewModelStore>? = null

    fun storeFor(id: String): ViewModelStore {
        current?.takeIf { it.first == id }?.let { return it.second }
        current?.second?.clear()
        return ViewModelStore().also { current = id to it }
    }

    override fun onCleared() {
        current?.second?.clear()
    }
}

@Composable
fun LibraryScope(id: String, content: @Composable () -> Unit) {
    val scopes: LibraryScopes = viewModel()
    val store = scopes.storeFor(id)
    val owner = remember(store) { object : ViewModelStoreOwner { override val viewModelStore = store } }
    CompositionLocalProvider(LocalViewModelStoreOwner provides owner, content = content)
}

/** Shown while the app lock is on and the app hasn't been unlocked. */
@Composable
fun LockScreen(onUnlock: () -> Unit) {
    val palette = LokalBotTheme.palette
    Box(Modifier.fillMaxSize().background(palette.window), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.padding(32.dp)) {
            AppMark()
            Text(stringResource(R.string.lock_title), style = LokalBotType.columnTitle, textAlign = TextAlign.Center)
            Button(onClick = onUnlock, colors = ButtonDefaults.buttonColors(containerColor = palette.accentFill)) {
                Text(stringResource(R.string.lock_unlock))
            }
        }
    }
}
