package me.dotenv.lokalbot.companion.ui.onboarding

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import java.time.Instant
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import me.dotenv.lokalbot.companion.PairOutcome
import me.dotenv.lokalbot.companion.pairing.PairingLink
import me.dotenv.lokalbot.companion.pairing.PairingLinkResult
import me.dotenv.lokalbot.companion.pairing.PairingPayload

sealed interface PairingStep {
    /** Scanning the QR code or pasting the link. */
    data object Scan : PairingStep
    data class Confirm(val payload: PairingPayload, val link: String) : PairingStep
    /** The Mac is asking the person whether to allow this device. */
    data class Waiting(val macName: String) : PairingStep
    data class Failed(val message: String) : PairingStep
    data class Paired(val macName: String) : PairingStep
}

enum class LinkProblem { NotALink, Expired, Unsupported }

class PairingViewModel(
    private val pair: suspend (link: String, payload: PairingPayload, deviceName: String) -> PairOutcome,
    initialDeviceName: suspend () -> String,
    private val now: () -> Instant = Instant::now,
) : ViewModel() {
    private val _step = MutableStateFlow<PairingStep>(PairingStep.Scan)
    val step: StateFlow<PairingStep> = _step.asStateFlow()

    private val _problem = MutableStateFlow<LinkProblem?>(null)
    val problem: StateFlow<LinkProblem?> = _problem.asStateFlow()

    /** The name the Mac shows when it asks whether to allow this device. */
    private val _deviceName = MutableStateFlow("")
    val deviceName: StateFlow<String> = _deviceName.asStateFlow()

    private var job: Job? = null

    init {
        viewModelScope.launch { if (_deviceName.value.isEmpty()) _deviceName.value = initialDeviceName() }
    }

    fun setDeviceName(name: String) {
        _deviceName.value = name.take(MAX_NAME_LENGTH)
    }

    /** A scanned or pasted pairing link. Returns true when it was accepted. */
    fun submit(text: String): Boolean {
        if (_step.value != PairingStep.Scan) return false
        return when (val result = PairingLink.parse(text, now())) {
            is PairingLinkResult.Valid -> {
                _problem.value = null
                _step.value = PairingStep.Confirm(result.payload, result.link)
                true
            }
            PairingLinkResult.NotALink -> { _problem.value = LinkProblem.NotALink; false }
            PairingLinkResult.Expired -> { _problem.value = LinkProblem.Expired; false }
            PairingLinkResult.Unsupported -> { _problem.value = LinkProblem.Unsupported; false }
        }
    }

    fun confirm() {
        val confirm = _step.value as? PairingStep.Confirm ?: return
        if (confirm.payload.isExpired(now())) {
            _problem.value = LinkProblem.Expired
            _step.value = PairingStep.Scan
            return
        }
        _step.value = PairingStep.Waiting(confirm.payload.macName)
        job = viewModelScope.launch {
            _step.value = when (val outcome = pair(confirm.link, confirm.payload, _deviceName.value.trim())) {
                is PairOutcome.Paired -> PairingStep.Paired(outcome.macName)
                is PairOutcome.Failed -> PairingStep.Failed(outcome.message)
            }
        }
    }

    private companion object {
        const val MAX_NAME_LENGTH = 60
    }

    fun restart() {
        job?.cancel()
        _problem.value = null
        _step.value = PairingStep.Scan
    }
}
