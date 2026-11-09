package me.dotenv.lokalbot.companion.ui.recording

import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.MicOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.recording.MeetingRecorder
import me.dotenv.lokalbot.companion.recording.RecorderProblem
import me.dotenv.lokalbot.companion.recording.RecorderState
import me.dotenv.lokalbot.companion.ui.components.StatusDot
import me.dotenv.lokalbot.companion.ui.format.Formats
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

private const val ELAPSED_TICK_MILLIS = 250L
private const val METER_TICK_MILLIS = 100L
private const val METER_FALL = 0.8f
private const val METER_SEGMENTS = 32
private val SIDEWAYS_MAX_HEIGHT = 480.dp
private val SIDEWAYS_MIN_WIDTH = 600.dp

/** The recording in progress. All of its state lives in [recorder], so it survives a recreated Activity. */
@Composable
fun RecordingScreen(recorder: MeetingRecorder) {
    val state by recorder.state.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val startedAt = (state as? RecorderState.Recording)?.startedAtElapsedMillis
    val elapsedSeconds by produceState(0L, startedAt, lifecycle) {
        val start = startedAt ?: return@produceState
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                value = (SystemClock.elapsedRealtime() - start) / 1000
                delay(ELAPSED_TICK_MILLIS)
            }
        }
    }
    val level by produceState(0f, recorder, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                // Falls slowly, so it reads as a level instead of a flicker.
                value = maxOf(withContext(Dispatchers.Default) { recorder.level() }, value * METER_FALL)
                delay(METER_TICK_MILLIS)
            }
        }
    }
    RecordingContent(
        state = state,
        elapsedSeconds = elapsedSeconds,
        level = level,
        onTitleChange = recorder::setTitle,
        onStop = { recorder.stop() },
        onDiscard = { recorder.discard() },
        onHide = recorder::hideScreen,
        onDismissProblem = recorder::dismissProblem,
    )
}

@Composable
fun RecordingContent(
    state: RecorderState,
    elapsedSeconds: Long,
    level: Float,
    onTitleChange: (String) -> Unit,
    onStop: () -> Unit,
    onDiscard: () -> Unit,
    onHide: () -> Unit,
    onDismissProblem: () -> Unit,
) {
    val palette = LokalBotTheme.palette
    val failed = state as? RecorderState.Failed
    BackHandler { if (failed != null) onDismissProblem() else onHide() }
    Box(Modifier.fillMaxSize().background(palette.window).safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
        if (failed != null) {
            ProblemContent(failed.problem, onDismissProblem)
        } else {
            RecordingControls(state, elapsedSeconds, level, onTitleChange, onStop, onDiscard, onHide)
        }
    }
}

@Composable
private fun RecordingControls(
    state: RecorderState,
    elapsedSeconds: Long,
    level: Float,
    onTitleChange: (String) -> Unit,
    onStop: () -> Unit,
    onDiscard: () -> Unit,
    onHide: () -> Unit,
) {
    val palette = LokalBotTheme.palette
    val recording = state as? RecorderState.Recording
    var confirmDiscard by rememberSaveable { mutableStateOf(false) }
    var title by rememberSaveable(recording?.id) { mutableStateOf(recording?.title.orEmpty()) }
    val hide = @Composable {
        IconButton(onClick = onHide) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.recording_hide))
        }
    }
    val progress = @Composable {
        RecordingProgress(recording, elapsedSeconds, level, title) {
            title = it
            onTitleChange(it)
        }
    }
    val actions = @Composable { RecordingActions(enabled = recording != null, onStop, onAskToDiscard = { confirmDiscard = true }) }
    BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        val height = maxHeight
        if (height < SIDEWAYS_MAX_HEIGHT && maxWidth >= SIDEWAYS_MIN_WIDTH) {
            // A phone on its side: side by side, so Stop and the caption stay on screen.
            Row(Modifier.widthIn(max = 840.dp).fillMaxSize().padding(horizontal = 24.dp), horizontalArrangement = Arrangement.spacedBy(32.dp)) {
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
                    hide()
                    progress()
                }
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()).heightIn(min = height).padding(vertical = 8.dp),
                    verticalArrangement = Arrangement.Center,
                ) {
                    actions()
                }
            }
        } else {
            Column(
                Modifier
                    .widthIn(max = 520.dp)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .heightIn(min = height)
                    .padding(horizontal = 24.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                hide()
                progress()
                actions()
            }
        }
    }
    if (confirmDiscard && recording != null) {
        AlertDialog(
            onDismissRequest = { confirmDiscard = false },
            title = { Text(stringResource(R.string.recording_discard_title)) },
            text = { Text(stringResource(R.string.recording_discard_message)) },
            confirmButton = {
                TextButton(onClick = { confirmDiscard = false; onDiscard() }) {
                    Text(stringResource(R.string.recording_discard), color = palette.recordingText)
                }
            },
            dismissButton = { TextButton(onClick = { confirmDiscard = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun RecordingProgress(
    recording: RecorderState.Recording?,
    elapsedSeconds: Long,
    level: Float,
    title: String,
    onTitleChange: (String) -> Unit,
) {
    val palette = LokalBotTheme.palette
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StatusDot(palette.recording, size = 10.dp)
            Text(
                stringResource(if (recording != null) R.string.recording_now else R.string.recording_starting),
                style = LokalBotType.body.copy(fontWeight = FontWeight.SemiBold),
                color = palette.recordingText,
            )
        }
        BasicText(
            Formats.offset(elapsedSeconds.toDouble()),
            modifier = Modifier.fillMaxWidth(),
            style = MaterialTheme.typography.displayLarge.copy(
                color = palette.textPrimary,
                fontWeight = FontWeight.Medium,
                fontFeatureSettings = "tnum",
                textAlign = TextAlign.Center,
            ),
            maxLines = 1,
            autoSize = TextAutoSize.StepBased(minFontSize = 40.sp, maxFontSize = 80.sp),
        )
        LevelMeter(level)
        OutlinedTextField(
            value = title,
            onValueChange = onTitleChange,
            modifier = Modifier.fillMaxWidth(),
            label = { Text(stringResource(R.string.recording_title_field)) },
            singleLine = true,
            enabled = recording != null,
        )
    }
}

@Composable
private fun RecordingActions(enabled: Boolean, onStop: () -> Unit, onAskToDiscard: () -> Unit) {
    val palette = LokalBotTheme.palette
    Column(
        Modifier.fillMaxWidth().padding(top = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Button(
            onClick = onStop,
            enabled = enabled,
            modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
            colors = ButtonDefaults.buttonColors(containerColor = palette.accentFill),
        ) {
            Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.padding(end = 8.dp))
            Text(stringResource(R.string.recording_stop))
        }
        TextButton(onClick = onAskToDiscard, enabled = enabled) {
            Text(stringResource(R.string.recording_discard), color = palette.recordingText)
        }
        Text(
            stringResource(R.string.recording_caption),
            style = LokalBotType.caption,
            color = LokalBotTheme.supportingText,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun ProblemContent(problem: RecorderProblem, onDismiss: () -> Unit) {
    val palette = LokalBotTheme.palette
    Column(
        Modifier.widthIn(max = 520.dp).fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        Icon(Icons.Outlined.MicOff, contentDescription = null, tint = palette.attentionText, modifier = Modifier.size(32.dp))
        Text(
            stringResource(
                when (problem) {
                    RecorderProblem.CouldNotStart -> R.string.recording_problem_start
                    RecorderProblem.NothingRecorded -> R.string.recording_problem_empty
                    RecorderProblem.Interrupted -> R.string.recording_problem_interrupted
                },
            ),
            style = LokalBotType.body,
            textAlign = TextAlign.Center,
        )
        Button(onClick = onDismiss, colors = ButtonDefaults.buttonColors(containerColor = palette.accentFill)) {
            Text(stringResource(R.string.done))
        }
    }
}

/** Lit segments from the start edge: a glance tells whether it's hearing you. */
@Composable
private fun LevelMeter(level: Float) {
    val palette = LokalBotTheme.palette
    val description = stringResource(R.string.recording_level)
    Canvas(Modifier.fillMaxWidth().height(24.dp).semantics { contentDescription = description }) {
        val gap = 3.dp.toPx()
        val width = (size.width - gap * (METER_SEGMENTS - 1)) / METER_SEGMENTS
        val lit = (level.coerceIn(0f, 1f) * METER_SEGMENTS).roundToInt()
        for (index in 0 until METER_SEGMENTS) {
            val start = index * (width + gap)
            drawRoundRect(
                color = if (index < lit) palette.accentFill else palette.chipFill,
                topLeft = Offset(if (layoutDirection == LayoutDirection.Rtl) size.width - start - width else start, 0f),
                size = Size(width, size.height),
                cornerRadius = CornerRadius(2.dp.toPx()),
            )
        }
    }
}
