package me.dotenv.lokalbot.companion.ui.recording

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.recording.MeetingRecorder
import me.dotenv.lokalbot.companion.recording.RecorderState
import me.dotenv.lokalbot.companion.recording.RecordingService
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme

/** Starts a recording, or returns to the one going. Null when this library can't record. */
val LocalRecordAction = staticCompositionLocalOf<(() -> Unit)?> { null }

enum class MicrophonePrompt { Explain, OpenSettings }

/**
 * What follows a denied microphone. Android stops offering its own prompt
 * after "don't ask again", which leaves only system settings.
 */
fun promptAfterDenial(canAskAgain: Boolean): MicrophonePrompt =
    if (canAskAgain) MicrophonePrompt.Explain else MicrophonePrompt.OpenSettings

private fun granted(context: Context, permission: String) =
    ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

/** The microphone, plus the notification on recent Android. Recording goes ahead without the notification. */
private fun permissionsToAsk(context: Context): Array<String> = buildList {
    add(Manifest.permission.RECORD_AUDIO)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !granted(context, Manifest.permission.POST_NOTIFICATIONS)) {
        add(Manifest.permission.POST_NOTIFICATIONS)
    }
}.toTypedArray()

/** Shows the recording screen over [content], the whole app, while it's wanted. */
@Composable
fun RecordingHost(recorder: MeetingRecorder?, content: @Composable () -> Unit) {
    RecordingAccess(recorder) {
        // Keeps the app's scroll and pane state while the screen covers it.
        val appState = rememberSaveableStateHolder()
        if (recorder != null && recordingScreenShown(recorder)) {
            RecordingScreen(recorder)
        } else {
            appState.SaveableStateProvider("app", content)
        }
    }
}

@Composable
private fun recordingScreenShown(recorder: MeetingRecorder): Boolean {
    val state by recorder.state.collectAsStateWithLifecycle()
    val hidden by recorder.screenHidden.collectAsStateWithLifecycle()
    return state !is RecorderState.Idle && !hidden
}

/** Provides [LocalRecordAction] to [content], and walks the person through the microphone permission. */
@Composable
private fun RecordingAccess(recorder: MeetingRecorder?, content: @Composable () -> Unit) {
    if (recorder == null) {
        content()
        return
    }
    val context = LocalContext.current
    val activity = LocalActivity.current
    val palette = LokalBotTheme.palette
    var prompt by rememberSaveable { mutableStateOf<MicrophonePrompt?>(null) }
    val canAskAgain = {
        activity != null && ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.RECORD_AUDIO)
    }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { answers ->
        if (answers[Manifest.permission.RECORD_AUDIO] == true) {
            RecordingService.start(context, recorder)
        } else {
            prompt = promptAfterDenial(canAskAgain())
        }
    }
    val record: () -> Unit = remember(recorder, context, activity, request) {
        {
            when {
                recorder.isActive -> recorder.showScreen()
                granted(context, Manifest.permission.RECORD_AUDIO) -> RecordingService.start(context, recorder)
                canAskAgain() -> prompt = MicrophonePrompt.Explain
                else -> request.launch(permissionsToAsk(context))
            }
        }
    }
    CompositionLocalProvider(LocalRecordAction provides record, content = content)

    when (prompt) {
        MicrophonePrompt.Explain -> AlertDialog(
            onDismissRequest = { prompt = null },
            title = { Text(stringResource(R.string.recording_mic_explain_title)) },
            text = { Text(stringResource(R.string.recording_mic_explain_message)) },
            confirmButton = {
                TextButton(onClick = {
                    prompt = null
                    request.launch(permissionsToAsk(context))
                }) { Text(stringResource(R.string.recording_mic_allow), color = palette.accentText) }
            },
            dismissButton = { TextButton(onClick = { prompt = null }) { Text(stringResource(R.string.cancel)) } },
        )
        MicrophonePrompt.OpenSettings -> AlertDialog(
            onDismissRequest = { prompt = null },
            title = { Text(stringResource(R.string.recording_mic_blocked_title)) },
            text = { Text(stringResource(R.string.recording_mic_blocked_message)) },
            confirmButton = {
                TextButton(onClick = {
                    prompt = null
                    context.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:${context.packageName}".toUri()),
                    )
                }) { Text(stringResource(R.string.recording_mic_open_settings), color = palette.accentText) }
            },
            dismissButton = { TextButton(onClick = { prompt = null }) { Text(stringResource(R.string.cancel)) } },
        )
        null -> Unit
    }
}

@Composable
fun RecordIconButton(onClick: () -> Unit) {
    IconButton(onClick = onClick) {
        Icon(Icons.Outlined.Mic, stringResource(R.string.record_button), tint = LokalBotTheme.palette.accentText)
    }
}
