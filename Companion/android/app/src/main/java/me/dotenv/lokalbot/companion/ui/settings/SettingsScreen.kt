package me.dotenv.lokalbot.companion.ui.settings

import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.MacRoute
import me.dotenv.lokalbot.companion.data.SyncState
import me.dotenv.lokalbot.companion.data.model.Manifest
import me.dotenv.lokalbot.companion.ui.LocalFormats
import me.dotenv.lokalbot.companion.ui.OverflowDestinationsButton
import me.dotenv.lokalbot.companion.ui.common.CenteredColumn
import me.dotenv.lokalbot.companion.ui.common.LibraryViewModel
import me.dotenv.lokalbot.companion.ui.common.pageContentPadding
import me.dotenv.lokalbot.companion.ui.components.PageHeader
import me.dotenv.lokalbot.companion.ui.components.RowDivider
import me.dotenv.lokalbot.companion.ui.components.WorkspaceSection
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTokens
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

/** What Settings needs from outside the library. */
data class SettingsActions(
    val appLockEnabled: Boolean = false,
    val appLockAvailable: Boolean = true,
    val onAppLockChange: (Boolean) -> Unit = {},
    val onPair: () -> Unit = {},
    val onRemoveLibrary: () -> Unit = {},
    val storageBytes: Long = 0,
    val versionName: String = "",
)

class SettingsViewModel(repository: CompanionRepository) : LibraryViewModel(repository) {
    val manifest: StateFlow<Manifest?> = library(null) { repository.manifest() }
    val syncState: StateFlow<SyncState> = repository.syncState
    private val _syncing = MutableStateFlow(false)
    val syncing: StateFlow<Boolean> = _syncing.asStateFlow()
    val isSample: Boolean get() = repository.isSample
    fun now() = repository.now()

    fun syncNow() {
        viewModelScope.launch {
            _syncing.value = true
            repository.sync()
            _syncing.value = false
        }
    }
}

@Composable
fun SettingsScreen(repository: CompanionRepository, actions: SettingsActions) {
    val viewModel = viewModel(key = "settings-${repository.id}") { SettingsViewModel(repository) }
    val manifest by viewModel.manifest.collectAsStateWithLifecycle()
    val sync by viewModel.syncState.collectAsStateWithLifecycle()
    val syncing by viewModel.syncing.collectAsStateWithLifecycle()
    val formats = LocalFormats.current
    val palette = LokalBotTheme.palette
    val context = LocalContext.current
    var confirmRemove by rememberSaveable { mutableStateOf(false) }
    var licenseOpen by rememberSaveable { mutableStateOf(false) }
    val status = sync.status

    LazyColumn(Modifier.fillMaxSize(), contentPadding = pageContentPadding()) {
        item(key = "settings") {
            CenteredColumn(LokalBotTokens.Spacing.readingMaxWidth) {
                Column(verticalArrangement = Arrangement.spacedBy(LokalBotTokens.Spacing.sectionSpacing)) {
                    PageHeader(stringResource(R.string.nav_settings), actions = { OverflowDestinationsButton() })

                    if (viewModel.isSample) {
                        WorkspaceSection(stringResource(R.string.settings_sample_title)) {
                            Text(stringResource(R.string.settings_sample_message), style = LokalBotType.secondary, color = LokalBotTheme.supportingText)
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Button(onClick = actions.onPair, colors = ButtonDefaults.buttonColors(containerColor = palette.accentFill)) {
                                    Text(stringResource(R.string.welcome_pair))
                                }
                                OutlinedButton(onClick = actions.onRemoveLibrary) { Text(stringResource(R.string.settings_leave_sample)) }
                            }
                        }
                    } else {
                        WorkspaceSection(stringResource(R.string.settings_your_mac)) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Icon(Icons.Outlined.Laptop, null, tint = palette.accentText)
                                Text(status.macName ?: manifest?.macName.orEmpty(), style = LokalBotType.body.copy(fontWeight = FontWeight.SemiBold))
                            }
                            val route = when (status.route) {
                                MacRoute.Wifi -> stringResource(R.string.settings_route_wifi)
                                MacRoute.Tailscale -> stringResource(R.string.settings_route_tailscale)
                                null -> stringResource(R.string.settings_route_unknown)
                            }
                            SettingLine(stringResource(R.string.settings_reached), listOfNotNull(route, status.lastAddress).joinToString(" · "))
                            SettingLine(
                                stringResource(R.string.settings_last_sync),
                                status.lastSyncAt?.let { formats.ago(it, viewModel.now()) } ?: stringResource(R.string.settings_never),
                            )
                            if (status.pendingOps > 0) {
                                SettingLine(stringResource(R.string.settings_pending), status.pendingOps.toString())
                            }
                            Button(
                                onClick = viewModel::syncNow,
                                enabled = !syncing,
                                colors = ButtonDefaults.buttonColors(containerColor = palette.accentFill),
                            ) { Text(stringResource(if (syncing) R.string.settings_syncing else R.string.settings_sync_now)) }
                            Text(stringResource(R.string.settings_tailscale_hint), style = LokalBotType.caption, color = LokalBotTheme.supportingText)
                        }
                    }

                    manifest?.let { manifest ->
                        WorkspaceSection(stringResource(R.string.settings_receives)) {
                            val classes = manifest.dataClasses
                            DataClassLine(stringResource(R.string.data_meetings), classes.meetings)
                            DataClassLine(stringResource(R.string.data_transcripts), classes.transcripts)
                            DataClassLine(stringResource(R.string.data_digests), classes.digests)
                            DataClassLine(stringResource(R.string.data_timeline), classes.timeline)
                            DataClassLine(stringResource(R.string.data_window_titles), classes.windowTitles)
                            DataClassLine(stringResource(R.string.data_people), classes.people)
                            DataClassLine(stringResource(R.string.data_projects), classes.projects)
                            Text(
                                if (manifest.historyDays == 0) stringResource(R.string.settings_history_all)
                                else pluralStringResource(R.plurals.settings_history_days, manifest.historyDays, manifest.historyDays),
                                style = LokalBotType.caption,
                                color = LokalBotTheme.supportingText,
                            )
                        }
                    }

                    WorkspaceSection(stringResource(R.string.settings_this_device)) {
                        SettingLine(stringResource(R.string.settings_storage), Formatter.formatShortFileSize(context, actions.storageBytes))
                        RowDivider()
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .heightIn(min = 48.dp)
                                .toggleable(
                                    value = actions.appLockEnabled,
                                    enabled = actions.appLockAvailable,
                                    role = Role.Switch,
                                    onValueChange = actions.onAppLockChange,
                                ),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(stringResource(R.string.settings_app_lock), style = LokalBotType.body)
                                Text(
                                    stringResource(if (actions.appLockAvailable) R.string.settings_app_lock_hint else R.string.settings_app_lock_unavailable),
                                    style = LokalBotType.caption,
                                    color = LokalBotTheme.supportingText,
                                )
                            }
                            Switch(
                                checked = actions.appLockEnabled,
                                onCheckedChange = null,
                                enabled = actions.appLockAvailable,
                                colors = SwitchDefaults.colors(checkedTrackColor = palette.accentFill),
                            )
                        }
                    }

                    if (!viewModel.isSample) {
                        WorkspaceSection(stringResource(R.string.settings_remove_title)) {
                            Text(stringResource(R.string.settings_remove_message), style = LokalBotType.secondary, color = LokalBotTheme.supportingText)
                            OutlinedButton(onClick = { confirmRemove = true }, colors = ButtonDefaults.outlinedButtonColors(contentColor = palette.recordingText)) {
                                Text(stringResource(R.string.settings_remove_button))
                            }
                        }
                    }

                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(stringResource(R.string.settings_version, actions.versionName), style = LokalBotType.caption, color = LokalBotTheme.supportingText)
                        TextButton(onClick = { licenseOpen = true }) { Text(stringResource(R.string.settings_licenses)) }
                    }
                }
            }
        }
    }

    if (confirmRemove) {
        AlertDialog(
            onDismissRequest = { confirmRemove = false },
            title = { Text(stringResource(R.string.settings_remove_confirm_title)) },
            text = { Text(stringResource(R.string.settings_remove_confirm_message)) },
            confirmButton = {
                TextButton(onClick = { confirmRemove = false; actions.onRemoveLibrary() }) {
                    Text(stringResource(R.string.settings_remove_button), color = palette.recordingText)
                }
            },
            dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
    if (licenseOpen) {
        val text = androidx.compose.runtime.remember {
            runCatching { context.assets.open("licenses/Inter-LICENSE.txt").bufferedReader().use { it.readText() } }.getOrDefault("")
        }
        AlertDialog(
            onDismissRequest = { licenseOpen = false },
            title = { Text(stringResource(R.string.settings_licenses)) },
            text = {
                Text(text, style = LokalBotType.caption, modifier = Modifier.verticalScroll(rememberScrollState()))
            },
            confirmButton = { TextButton(onClick = { licenseOpen = false }) { Text(stringResource(R.string.done)) } },
        )
    }
}

@Composable
private fun SettingLine(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, style = LokalBotType.secondary, color = LokalBotTheme.supportingText, modifier = Modifier.weight(1f))
        Text(value, style = LokalBotType.secondary)
    }
}

@Composable
private fun DataClassLine(label: String, enabled: Boolean) {
    Row(
        Modifier.fillMaxWidth().semantics(mergeDescendants = true) {
            toggleableState = if (enabled) ToggleableState.On else ToggleableState.Off
        },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            if (enabled) Icons.Outlined.Check else Icons.Outlined.Close,
            contentDescription = null,
            tint = if (enabled) LokalBotTheme.palette.accentText else LokalBotTheme.supportingText,
            modifier = Modifier.size(18.dp),
        )
        Text(label, style = LokalBotType.secondary, color = if (enabled) Color.Unspecified else LokalBotTheme.supportingText)
    }
}
