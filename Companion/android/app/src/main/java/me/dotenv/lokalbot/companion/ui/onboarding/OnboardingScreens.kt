package me.dotenv.lokalbot.companion.ui.onboarding

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.ui.components.groupedSurface
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

/** The LokalBot robot on its slate plate, as on the launcher. */
@Composable
fun AppMark(modifier: Modifier = Modifier) {
    Box(modifier.size(88.dp).clip(RoundedCornerShape(22.dp))) {
        Image(painterResource(R.drawable.ic_launcher_background), contentDescription = null, modifier = Modifier.fillMaxSize())
        Image(painterResource(R.drawable.ic_launcher_foreground), contentDescription = null, modifier = Modifier.fillMaxSize())
    }
}

/** First run: pair with a Mac, or look around the built-in sample library. */
@Composable
fun WelcomeScreen(onPair: () -> Unit, onTrySample: () -> Unit, removedByMac: Boolean = false, onDismissRemoved: () -> Unit = {}) {
    val palette = LokalBotTheme.palette
    Box(Modifier.fillMaxSize().background(palette.window).safeDrawingPadding(), contentAlignment = Alignment.Center) {
        Column(
            Modifier.widthIn(max = 520.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp, vertical = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (removedByMac) {
                Row(
                    Modifier.fillMaxWidth().groupedSurface(tint = palette.attention).padding(start = 12.dp, top = 4.dp, bottom = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(stringResource(R.string.welcome_removed), style = LokalBotType.secondary, color = palette.attentionText, modifier = Modifier.weight(1f))
                    IconButton(onClick = onDismissRemoved) {
                        Icon(Icons.Outlined.Close, stringResource(R.string.dismiss), tint = palette.attentionText)
                    }
                }
            }
            AppMark()
            Text(stringResource(R.string.welcome_title), style = LokalBotType.pageTitle, textAlign = TextAlign.Center, modifier = Modifier.semantics { heading() })
            Text(stringResource(R.string.welcome_message), style = LokalBotType.body, color = LokalBotTheme.supportingText, textAlign = TextAlign.Center)
            Spacer(Modifier.height(4.dp))
            Column(Modifier.fillMaxWidth().groupedSurface().padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Promise(Icons.Outlined.Wifi, stringResource(R.string.welcome_point_network))
                Promise(Icons.Outlined.Lock, stringResource(R.string.welcome_point_encrypted))
            }
            Spacer(Modifier.height(4.dp))
            Button(onClick = onPair, modifier = Modifier.fillMaxWidth(), colors = ButtonDefaults.buttonColors(containerColor = palette.accentFill)) {
                Text(stringResource(R.string.welcome_pair))
            }
            OutlinedButton(onClick = onTrySample, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.welcome_try_sample))
            }
            Text(stringResource(R.string.welcome_requirement), style = LokalBotType.caption, color = LokalBotTheme.supportingText, textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun Promise(icon: ImageVector, text: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(icon, null, tint = LokalBotTheme.palette.accentText, modifier = Modifier.size(20.dp))
        Text(text, style = LokalBotType.secondary, modifier = Modifier.weight(1f))
    }
}

/**
 * Pairing: scan the QR code the Mac shows (or paste its link), confirm, then
 * wait while the person approves this device on the Mac.
 */
@Composable
fun PairingScreen(viewModel: PairingViewModel, initialLink: String?, onDone: () -> Unit, onClose: () -> Unit) {
    val step by viewModel.step.collectAsStateWithLifecycle()
    val deviceName by viewModel.deviceName.collectAsStateWithLifecycle()
    val problem by viewModel.problem.collectAsStateWithLifecycle()
    val palette = LokalBotTheme.palette
    LaunchedEffect(initialLink) { initialLink?.let(viewModel::submit) }
    BackHandler(onBack = onClose)
    Box(Modifier.fillMaxSize().background(palette.window).safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
        Column(
            Modifier.widthIn(max = 560.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.pair_title), style = LokalBotType.pageTitle, modifier = Modifier.weight(1f).semantics { heading() })
                TextButton(onClick = onClose) { Text(stringResource(R.string.cancel)) }
            }
            when (val current = step) {
                PairingStep.Scan -> ScanStep(problem, onSubmit = { viewModel.submit(it) })
                is PairingStep.Confirm -> {
                    Text(stringResource(R.string.pair_confirm_title, current.payload.macName), style = LokalBotType.question)
                    Text(stringResource(R.string.pair_confirm_message), style = LokalBotType.body, color = LokalBotTheme.supportingText)
                    if (current.payload.addrs.isNotEmpty()) {
                        Text(current.payload.addrs.joinToString(" · "), style = LokalBotType.timestamp, color = LokalBotTheme.supportingText)
                    }
                    OutlinedTextField(
                        value = deviceName,
                        onValueChange = viewModel::setDeviceName,
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text(stringResource(R.string.pair_device_name)) },
                        supportingText = { Text(stringResource(R.string.pair_device_name_hint)) },
                        singleLine = true,
                    )
                    Button(
                        onClick = viewModel::confirm,
                        enabled = deviceName.isNotBlank(),
                        colors = ButtonDefaults.buttonColors(containerColor = palette.accentFill),
                    ) {
                        Text(stringResource(R.string.pair_button))
                    }
                    TextButton(onClick = viewModel::restart) { Text(stringResource(R.string.pair_scan_again)) }
                }
                is PairingStep.Waiting -> {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp, color = palette.accentFill)
                        Text(stringResource(R.string.pair_waiting_title, current.macName), style = LokalBotType.question, modifier = Modifier.weight(1f))
                    }
                    Text(stringResource(R.string.pair_waiting_message), style = LokalBotType.body, color = LokalBotTheme.supportingText)
                    OutlinedButton(onClick = viewModel::restart) { Text(stringResource(R.string.cancel)) }
                }
                is PairingStep.Failed -> {
                    Text(
                        current.message,
                        style = LokalBotType.body,
                        color = palette.attentionText,
                        modifier = Modifier.fillMaxWidth().groupedSurface(tint = palette.attention).padding(12.dp),
                    )
                    Button(onClick = viewModel::restart, colors = ButtonDefaults.buttonColors(containerColor = palette.accentFill)) {
                        Text(stringResource(R.string.pair_try_again))
                    }
                }
                is PairingStep.Paired -> {
                    LaunchedEffect(Unit) { onDone() }
                    Text(stringResource(R.string.pair_done, current.macName), style = LokalBotType.question)
                }
            }
        }
    }
}

@Composable
private fun ScanStep(problem: LinkProblem?, onSubmit: (String) -> Unit) {
    val context = LocalContext.current
    val palette = LokalBotTheme.palette
    val hasCamera = remember { context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) }
    var granted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    var link by rememberSaveable { mutableStateOf("") }

    Text(stringResource(R.string.pair_instructions), style = LokalBotType.body)
    if (hasCamera) {
        Box(
            Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(16.dp)).groupedSurface(shape = RoundedCornerShape(16.dp)),
            contentAlignment = Alignment.Center,
        ) {
            if (granted) {
                QrScanner(onCode = { onSubmit(it) }, modifier = Modifier.fillMaxSize())
            } else {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(24.dp)) {
                    Icon(Icons.Outlined.CameraAlt, null, tint = palette.accentText, modifier = Modifier.size(32.dp))
                    Text(stringResource(R.string.pair_camera_explain), style = LokalBotType.secondary, textAlign = TextAlign.Center, color = LokalBotTheme.supportingText)
                    Button(onClick = { launcher.launch(Manifest.permission.CAMERA) }, colors = ButtonDefaults.buttonColors(containerColor = palette.accentFill)) {
                        Text(stringResource(R.string.pair_allow_camera))
                    }
                }
            }
        }
    }
    problem?.let {
        Text(
            stringResource(
                when (it) {
                    LinkProblem.NotALink -> R.string.pair_problem_not_link
                    LinkProblem.Expired -> R.string.pair_problem_expired
                    LinkProblem.Unsupported -> R.string.pair_problem_unsupported
                },
            ),
            style = LokalBotType.secondary,
            color = palette.attentionText,
        )
    }
    Text(stringResource(R.string.pair_paste_title), style = LokalBotType.section)
    OutlinedTextField(
        value = link,
        onValueChange = { link = it },
        modifier = Modifier.fillMaxWidth(),
        placeholder = { Text("lokalbot://pair?d=…") },
        singleLine = true,
    )
    OutlinedButton(onClick = { onSubmit(link) }, enabled = link.isNotBlank()) { Text(stringResource(R.string.pair_continue)) }
}
