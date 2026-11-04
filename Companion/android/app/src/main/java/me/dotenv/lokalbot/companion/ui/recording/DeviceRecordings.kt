package me.dotenv.lokalbot.companion.ui.recording

import android.content.res.Resources
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.DeviceRecording
import me.dotenv.lokalbot.companion.data.RecordingState
import me.dotenv.lokalbot.companion.data.UploadProgress
import me.dotenv.lokalbot.companion.ui.LocalFormats
import me.dotenv.lokalbot.companion.ui.components.StatusDot
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

/** Where a recording on this device has got to, as the list shows it. */
sealed interface RecordingStatus {
    data object Recording : RecordingStatus

    /** [message] says what's holding it up, when anything is known to. */
    data class Waiting(val message: String?, val computerTurnedItOff: Boolean = false) : RecordingStatus
    data class Sending(val percent: Int) : RecordingStatus

    /** The computer has it; the row stays until the meeting arrives. */
    data object Processing : RecordingStatus
    data class Failed(val message: String?) : RecordingStatus
}

data class RecordingRowState(val recording: DeviceRecording, val status: RecordingStatus)

fun recordingStatus(recording: DeviceRecording, progress: UploadProgress?, computerTurnedItOff: Boolean): RecordingStatus = when (recording.state) {
    RecordingState.Recording -> RecordingStatus.Recording
    RecordingState.Uploaded -> RecordingStatus.Processing
    RecordingState.Failed -> RecordingStatus.Failed(recording.message)
    RecordingState.Waiting ->
        if (progress?.recordingId == recording.id) {
            RecordingStatus.Sending(sentPercent(progress.sentBytes, progress.totalBytes))
        } else {
            RecordingStatus.Waiting(recording.message, computerTurnedItOff)
        }
}

fun sentPercent(sentBytes: Long, totalBytes: Long): Int =
    if (totalBytes <= 0) 0 else (sentBytes * 100 / totalBytes).toInt().coerceIn(0, 100)

data class RecordingStatusText(val headline: String, val detail: String? = null)

fun RecordingStatus.text(resources: Resources, computer: String?): RecordingStatusText = when (this) {
    RecordingStatus.Recording -> RecordingStatusText(resources.getString(R.string.recording_status_recording))
    is RecordingStatus.Waiting -> RecordingStatusText(
        computer?.let { resources.getString(R.string.recording_status_waiting, it) }
            ?: resources.getString(R.string.recording_status_waiting_unnamed),
        message ?: resources.getString(R.string.recording_turned_off).takeIf { computerTurnedItOff },
    )
    is RecordingStatus.Sending -> RecordingStatusText(resources.getString(R.string.recording_status_sending, percent))
    RecordingStatus.Processing -> RecordingStatusText(
        computer?.let { resources.getString(R.string.recording_status_processing, it) }
            ?: resources.getString(R.string.recording_status_processing_unnamed),
    )
    is RecordingStatus.Failed -> RecordingStatusText(resources.getString(R.string.recording_status_failed), message)
}

/** Title, then "Today · 10:30 · 42 min", then where it has got to. */
@Composable
fun DeviceRecordingRow(
    row: RecordingRowState,
    computer: String?,
    today: LocalDate,
    onOpen: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = LokalBotTheme.palette
    val recording = row.recording
    val status = row.status
    val text = status.text(LocalResources.current, computer)
    val headlineColor = when (status) {
        RecordingStatus.Recording -> palette.recordingText
        is RecordingStatus.Failed -> palette.attentionText
        is RecordingStatus.Sending -> palette.accentText
        else -> LokalBotTheme.supportingText
    }
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .then(if (status == RecordingStatus.Recording) Modifier.clickable(role = Role.Button, onClick = onOpen) else Modifier)
            .padding(start = 10.dp, top = 10.dp, bottom = 10.dp),
    ) {
        Column(Modifier.weight(1f).padding(end = 10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                recording.title.ifBlank { stringResource(R.string.recording_default_title) },
                style = LokalBotType.body.copy(fontWeight = FontWeight.SemiBold),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                LocalFormats.current.recordingMeta(recording.startedAt, recording.durationSeconds, today),
                style = LokalBotType.timestamp,
                color = LokalBotTheme.supportingText,
                maxLines = 1,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (status == RecordingStatus.Recording) StatusDot(palette.recording)
                Text(text.headline, style = LokalBotType.secondary, color = headlineColor)
            }
            text.detail?.let { Text(it, style = LokalBotType.caption, color = palette.attentionText) }
            if (status is RecordingStatus.Failed) {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    RowAction(stringResource(R.string.recording_retry), palette.accentText, onRetry)
                    RowAction(stringResource(R.string.recording_delete), palette.recordingText, onDelete)
                }
            }
        }
        if (status is RecordingStatus.Waiting) RowMenu(onRename, onDelete)
    }
}

@Composable
private fun RowAction(label: String, color: Color, onClick: () -> Unit) {
    TextButton(onClick = onClick) { Text(label, color = color) }
}

@Composable
private fun RowMenu(onRename: () -> Unit, onDelete: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Outlined.MoreHoriz, contentDescription = stringResource(R.string.recording_more))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.recording_rename)) },
                onClick = {
                    open = false
                    onRename()
                },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.recording_delete), color = LokalBotTheme.palette.recordingText) },
                onClick = {
                    open = false
                    onDelete()
                },
            )
        }
    }
}

/** Deleting destroys the only copy, so it asks. */
@Composable
fun DeleteRecordingDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.recording_delete_title)) },
        text = { Text(stringResource(R.string.recording_delete_message)) },
        confirmButton = {
            TextButton(onClick = onConfirm) { Text(stringResource(R.string.recording_delete), color = LokalBotTheme.palette.recordingText) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
fun RenameRecordingDialog(title: String, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var draft by rememberSaveable { mutableStateOf(title) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.recording_rename_title)) },
        text = {
            OutlinedTextField(
                value = draft,
                onValueChange = { draft = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text(stringResource(R.string.recording_rename_field)) },
                singleLine = true,
            )
        },
        confirmButton = { TextButton(onClick = { onSave(draft) }) { Text(stringResource(R.string.recording_save)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
