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

/** What the microphone is doing. The recording screen and [RecordingService] both follow it. */
sealed interface RecorderState {
    data object Idle : RecorderState

    /** Asked to record; the service hasn't got the microphone going yet. */
    data object Starting : RecorderState

    data class Recording(val id: String, val title: String, val startedAtElapsedMillis: Long) : RecorderState

    /** Shown until the person closes it. */
    data class Failed(val problem: RecorderProblem) : RecorderState
}

enum class RecorderProblem {
    /** The microphone wouldn't start, and there's no recording. */
    CouldNotStart,

    /** It stopped with an empty file, which leaves no recording. */
    NothingRecorded,

    /** It failed partway. What was written is kept and goes to the computer. */
    Interrupted,
}

/** The thing that writes audio to a file. [MediaRecorderCapture] on a device. */
interface AudioCapture {
    /** Starts writing to [path]. Throws when the microphone can't start. */
    fun start(path: String, onError: () -> Unit)

    /** The loudest sample since the last call, 0 to 32767. */
    fun maxAmplitude(): Int

    /** Stops and lets go of the microphone. Never throws; what was written stays. */
    fun stop()
}

/**
 * The one recording in progress, for the whole process: it outlives any
 * Activity, because [RecordingService] keeps the process alive, so screens read
 * their state from here. The core owns the row and the file's location.
 */
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

    /** True while the person has gone back to the app and left it recording. */
    private val _screenHidden = MutableStateFlow(false)
    val screenHidden: StateFlow<Boolean> = _screenHidden.asStateFlow()

    val isActive: Boolean get() = state.value.let { it is RecorderState.Starting || it is RecorderState.Recording }

    fun showScreen() {
        _screenHidden.value = false
    }

    fun hideScreen() {
        _screenHidden.value = true
    }

    /** The screen opens at once. False when a recording is already going, which it shows instead. */
    fun requestStart(): Boolean {
        showScreen()
        if (isActive) return false
        _state.value = RecorderState.Starting
        return true
    }

    /** The service couldn't get into the foreground, so the microphone can't start. */
    fun failToStart() {
        fail(RecorderProblem.CouldNotStart)
    }

    /** Called by the service once it's in the foreground. */
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

    /** Ends the recording with what's there and hands it to the core; [problem] says why, if it wasn't asked for. */
    fun stop(problem: RecorderProblem? = null): Job = scope.launch {
        lock.withLock {
            val recording = _state.value as? RecorderState.Recording ?: return@withLock
            val current = session ?: return@withLock
            val seconds = (elapsedMillis() - recording.startedAtElapsedMillis) / 1000.0
            current.capture.stop()
            session = null
            titleSave?.cancel()
            runCatching { current.repository.setRecordingTitle(recording.id, recording.title) }
            // Any other failure leaves the row as it is, for the next launch to recover.
            val kept = runCatching { current.repository.finishRecording(recording.id, seconds) }.getOrDefault(true)
            when {
                !kept -> fail(RecorderProblem.NothingRecorded)
                problem != null -> fail(problem)
                else -> _state.value = RecorderState.Idle
            }
        }
    }

    /** Stops and deletes the recording: nothing reaches the computer. */
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

    /**
     * The library is going, or has gone: lets go of the microphone and leaves
     * the row and the file to the core. Removing the device from here erases
     * them; if the Mac removed it, they stay for when it pairs again.
     */
    suspend fun abort() {
        lock.withLock {
            session?.capture?.stop()
            session = null
            titleSave?.cancel()
            _state.value = RecorderState.Idle
        }
    }

    /** At startup: a recording cut short by a dead process goes on as a normal waiting one. */
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

    /** How loud it is right now, for the meter: 0 to 1. */
    fun level(): Float = meterLevel(session?.capture?.maxAmplitude() ?: 0)

    private fun fail(problem: RecorderProblem) {
        _screenHidden.value = false
        _state.value = RecorderState.Failed(problem)
    }
}

private const val METER_FLOOR_DB = 60.0

/** A sample's loudness on a decibel scale: quiet speech across a room still moves the meter. */
fun meterLevel(amplitude: Int): Float {
    if (amplitude <= 0) return 0f
    val decibels = 20 * log10(amplitude.coerceAtMost(32767) / 32767.0)
    return ((decibels + METER_FLOOR_DB) / METER_FLOOR_DB).toFloat().coerceIn(0f, 1f)
}
