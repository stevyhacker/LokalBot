package me.dotenv.lokalbot.companion.recording

import android.os.SystemClock
import kotlin.math.log10
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import me.dotenv.lokalbot.companion.data.CompanionRepository

sealed interface RecorderState {
    data object Idle : RecorderState

    data object Starting : RecorderState

    data class Recording(val id: String, val title: String, val startedAtElapsedMillis: Long) : RecorderState

    data class Failed(val problem: RecorderProblem) : RecorderState
}

enum class RecorderProblem {
    CouldNotStart,

    NothingRecorded,

    Interrupted,
}

interface AudioCapture {
    fun start(path: String, onError: () -> Unit)

    fun maxAmplitude(): Int

    fun stop()
}

class MeetingRecorder(
    private val scope: CoroutineScope,
    private val library: () -> CompanionRepository?,
    private val newCapture: () -> AudioCapture,
    private val elapsedMillis: () -> Long = SystemClock::elapsedRealtime,
    private val titleSaveDelayMillis: Long = 500,
) {
    private class Session(val repository: CompanionRepository, val capture: AudioCapture)

    private val lock = Mutex()

    @Volatile
    private var session: Session? = null
    private var titleSave: Job? = null

    private val _state = MutableStateFlow<RecorderState>(RecorderState.Idle)
    val state: StateFlow<RecorderState> = _state.asStateFlow()

    private val _screenHidden = MutableStateFlow(false)
    val screenHidden: StateFlow<Boolean> = _screenHidden.asStateFlow()

    val isActive: Boolean get() = state.value.let { it is RecorderState.Starting || it is RecorderState.Recording }

    fun showScreen() {
        _screenHidden.value = false
    }

    fun hideScreen() {
        _screenHidden.value = true
    }

    fun requestStart(): Boolean {
        showScreen()
        if (isActive) return false
        _state.value = RecorderState.Starting
        return true
    }

    fun failToStart() {
        fail(RecorderProblem.CouldNotStart)
    }

    fun begin(): Job = scope.launch {
        lock.withLock {
            if (_state.value is RecorderState.Recording) return@withLock
            val repository = library()
            val recording = runCatching { repository?.beginRecording() }.getOrNull()
            if (repository == null || recording == null) {
                fail(RecorderProblem.CouldNotStart)
                return@withLock
            }
            val capture = newCapture()
            val started = runCatching {
                capture.start(recording.filePath, onError = { stop(RecorderProblem.Interrupted) })
            }
            if (started.isFailure) {
                capture.stop()
                runCatching { repository.discardRecording(recording.id) }
                fail(RecorderProblem.CouldNotStart)
                return@withLock
            }
            session = Session(repository, capture)
            _state.value = RecorderState.Recording(recording.id, title = "", startedAtElapsedMillis = elapsedMillis())
        }
    }

    fun stop(problem: RecorderProblem? = null): Job = scope.launch {
        lock.withLock {
            val recording = _state.value as? RecorderState.Recording ?: return@withLock
            val current = session ?: return@withLock
            val seconds = (elapsedMillis() - recording.startedAtElapsedMillis) / 1000.0
            current.capture.stop()
            session = null
            titleSave?.cancel()
            runCatching { current.repository.setRecordingTitle(recording.id, recording.title) }
            val kept = runCatching { current.repository.finishRecording(recording.id, seconds) }.getOrDefault(true)
            when {
                !kept -> fail(RecorderProblem.NothingRecorded)
                problem != null -> fail(problem)
                else -> _state.value = RecorderState.Idle
            }
        }
    }

    fun discard(): Job = scope.launch {
        lock.withLock {
            val recording = _state.value as? RecorderState.Recording ?: return@withLock
            val current = session ?: return@withLock
            current.capture.stop()
            session = null
            titleSave?.cancel()
            runCatching { current.repository.discardRecording(recording.id) }
            _state.value = RecorderState.Idle
        }
    }

    suspend fun abort() {
        lock.withLock {
            session?.capture?.stop()
            session = null
            titleSave?.cancel()
            _state.value = RecorderState.Idle
        }
    }

    suspend fun recoverIfIdle(repository: CompanionRepository): Int = lock.withLock {
        if (isActive) 0 else runCatching { repository.recoverRecordings() }.getOrDefault(0)
    }

    fun setTitle(title: String) {
        val recording = _state.value as? RecorderState.Recording ?: return
        _state.update { (it as? RecorderState.Recording)?.copy(title = title) ?: it }
        val repository = session?.repository ?: return
        titleSave?.cancel()
        titleSave = scope.launch {
            delay(titleSaveDelayMillis)
            runCatching { repository.setRecordingTitle(recording.id, title) }
        }
    }

    fun dismissProblem() {
        if (_state.value is RecorderState.Failed) _state.value = RecorderState.Idle
    }

    fun level(): Float = meterLevel(session?.capture?.maxAmplitude() ?: 0)

    private fun fail(problem: RecorderProblem) {
        _screenHidden.value = false
        _state.value = RecorderState.Failed(problem)
    }
}

private const val METER_FLOOR_DB = 60.0

fun meterLevel(amplitude: Int): Float {
    if (amplitude <= 0) return 0f
    val decibels = 20 * log10(amplitude.coerceAtMost(32767) / 32767.0)
    return ((decibels + METER_FLOOR_DB) / METER_FLOOR_DB).toFloat().coerceIn(0f, 1f)
}
