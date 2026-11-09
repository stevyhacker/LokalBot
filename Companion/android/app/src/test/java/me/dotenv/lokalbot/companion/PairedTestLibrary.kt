package me.dotenv.lokalbot.companion

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.DeviceRecording
import me.dotenv.lokalbot.companion.data.FixtureRepository
import me.dotenv.lokalbot.companion.data.RecordingState
import me.dotenv.lokalbot.companion.data.SyncState
import me.dotenv.lokalbot.companion.data.SyncStatusInfo
import me.dotenv.lokalbot.companion.data.UploadOutcome
import me.dotenv.lokalbot.companion.data.UploadProgress
import me.dotenv.lokalbot.companion.recording.AudioCapture

/** The sample library as if paired with a computer: it can record, and keeps recordings in memory. */
class PairedTestLibrary(
    private val library: FixtureRepository = TestLibrary.repository(),
    rows: List<DeviceRecording> = emptyList(),
    computer: String? = "Studio Computer",
    private val bytesWritten: () -> Long = { 1024 },
) : CompanionRepository by library {
    override val id: String = "paired-test"
    override val isSample: Boolean = false
    override val canRecord: Boolean = true
    override val syncState: StateFlow<SyncState> = MutableStateFlow(
        SyncState.Idle(SyncStatusInfo(paired = true, macName = computer, lastSyncAt = null, lastAddress = null, pendingOps = 0)),
    )

    override val recordings = MutableStateFlow(rows)
    override val uploadProgress = MutableStateFlow<UploadProgress?>(null)

    var recovered = 0
        private set
    var uploads = 0
        private set
    val finishedSeconds = mutableMapOf<String, Double>()
    private var nextId = 0

    override suspend fun beginRecording(title: String?): DeviceRecording {
        val recording = DeviceRecording(
            id = "recording-${++nextId}",
            title = title.orEmpty(),
            state = RecordingState.Recording,
            startedAt = TestLibrary.now.toString(),
            filePath = "/test/recording-$nextId.aac",
        )
        recordings.update { listOf(recording) + it }
        return recording
    }

    override suspend fun finishRecording(id: String, durationSeconds: Double): Boolean {
        val bytes = bytesWritten()
        if (bytes == 0L) {
            discardRecording(id)
            return false
        }
        finishedSeconds[id] = durationSeconds
        edit(id) { it.copy(state = RecordingState.Waiting, durationSeconds = durationSeconds, byteCount = bytes) }
        return true
    }

    override suspend fun recoverRecordings(): Int {
        val active = recordings.value.count { it.state == RecordingState.Recording }
        recovered += active
        recordings.update { rows -> rows.map { if (it.state == RecordingState.Recording) it.copy(state = RecordingState.Waiting) else it } }
        return active
    }

    override suspend fun discardRecording(id: String) {
        recordings.update { rows -> rows.filterNot { it.id == id } }
    }

    override suspend fun setRecordingTitle(id: String, title: String) = edit(id) { it.copy(title = title) }

    override suspend fun retryRecording(id: String) = edit(id) { it.copy(state = RecordingState.Waiting, message = null) }

    override suspend fun uploadRecordings(): UploadOutcome {
        uploads++
        val rows = recordings.value
        return UploadOutcome.Finished(0, rows.count { it.state == RecordingState.Waiting }, rows.count { it.state == RecordingState.Failed })
    }

    private fun edit(id: String, change: (DeviceRecording) -> DeviceRecording) {
        recordings.update { rows -> rows.map { if (it.id == id) change(it) else it } }
    }
}

/** A microphone that hears what it's told and writes nothing. */
class FakeCapture(private val failToStart: Boolean = false) : AudioCapture {
    var startedAt: String? = null
        private set
    var stopped = false
        private set
    var amplitude = 0
    var errorCallback: (() -> Unit)? = null
        private set

    override fun start(path: String, onError: () -> Unit) {
        if (failToStart) error("The microphone is busy.")
        startedAt = path
        errorCallback = onError
    }

    override fun maxAmplitude(): Int = amplitude

    override fun stop() {
        stopped = true
    }
}
