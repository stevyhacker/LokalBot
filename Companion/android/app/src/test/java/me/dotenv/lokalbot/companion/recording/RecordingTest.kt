package me.dotenv.lokalbot.companion.recording

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import me.dotenv.lokalbot.companion.FakeCapture
import me.dotenv.lokalbot.companion.PairedTestLibrary
import me.dotenv.lokalbot.companion.TestLibrary
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.DeviceRecording
import me.dotenv.lokalbot.companion.data.RecordingState
import me.dotenv.lokalbot.companion.data.SyncFailure
import me.dotenv.lokalbot.companion.data.UploadOutcome
import me.dotenv.lokalbot.companion.data.UploadProgress
import me.dotenv.lokalbot.companion.sync.UploadWorker
import me.dotenv.lokalbot.companion.ui.LibraryScopes
import me.dotenv.lokalbot.companion.ui.meetings.MeetingsViewModel
import me.dotenv.lokalbot.companion.ui.recording.MicrophonePrompt
import me.dotenv.lokalbot.companion.ui.recording.RecordingStatus
import me.dotenv.lokalbot.companion.ui.recording.promptAfterDenial
import me.dotenv.lokalbot.companion.ui.recording.recordingStatus
import me.dotenv.lokalbot.companion.ui.recording.sentPercent
import me.dotenv.lokalbot.companion.ui.settings.SettingsViewModel
import org.junit.After
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RecordingTest {
    private val dispatcher = UnconfinedTestDispatcher()
    private var clock = 1_000L
    private var capture = FakeCapture()
    private var library = PairedTestLibrary()

    private fun recorder(repository: () -> PairedTestLibrary? = { library }) = MeetingRecorder(
        scope = CoroutineScope(dispatcher),
        library = repository,
        newCapture = { capture },
        elapsedMillis = { clock },
        titleSaveDelayMillis = 0,
    )

    private fun recording(state: RecordingState, id: String = "a", message: String? = null) =
        DeviceRecording(id = id, title = "", state = state, startedAt = TestLibrary.now.toString(), message = message)

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `stopping hands the recording to the core with its duration`() {
        val recorder = recorder()
        assertThat(recorder.requestStart()).isTrue()
        assertThat(recorder.state.value).isEqualTo(RecorderState.Starting)
        recorder.begin()
        val active = recorder.state.value as RecorderState.Recording
        assertThat(capture.startedAt).isEqualTo("/test/${active.id}.aac")
        assertThat(library.recordings.value.single().state).isEqualTo(RecordingState.Recording)

        clock += 61_500
        recorder.stop()
        assertThat(capture.stopped).isTrue()
        assertThat(recorder.state.value).isEqualTo(RecorderState.Idle)
        assertThat(library.finishedSeconds[active.id]).isEqualTo(61.5)
        assertThat(library.recordings.value.single().state).isEqualTo(RecordingState.Waiting)
    }

    @Test
    fun `a second start returns to the recording going`() {
        val recorder = recorder()
        recorder.requestStart()
        recorder.begin()
        val active = recorder.state.value
        recorder.hideScreen()

        assertThat(recorder.requestStart()).isFalse()
        assertThat(recorder.screenHidden.value).isFalse()
        recorder.begin()
        assertThat(recorder.state.value).isEqualTo(active)
        assertThat(library.recordings.value).hasSize(1)
    }

    @Test
    fun `discard deletes the recording and tells the core nothing else`() {
        val recorder = recorder()
        recorder.requestStart()
        recorder.begin()
        recorder.discard()
        assertThat(capture.stopped).isTrue()
        assertThat(recorder.state.value).isEqualTo(RecorderState.Idle)
        assertThat(library.recordings.value).isEmpty()
        assertThat(library.finishedSeconds).isEmpty()
    }

    @Test
    fun `an empty file leaves no recording and says so`() {
        library = PairedTestLibrary(bytesWritten = { 0 })
        val recorder = recorder()
        recorder.requestStart()
        recorder.begin()
        recorder.stop()
        assertThat(recorder.state.value).isEqualTo(RecorderState.Failed(RecorderProblem.NothingRecorded))
        assertThat(library.recordings.value).isEmpty()
        recorder.dismissProblem()
        assertThat(recorder.state.value).isEqualTo(RecorderState.Idle)
    }

    @Test
    fun `a microphone that won't start leaves no recording`() {
        capture = FakeCapture(failToStart = true)
        val recorder = recorder()
        recorder.requestStart()
        recorder.begin()
        assertThat(recorder.state.value).isEqualTo(RecorderState.Failed(RecorderProblem.CouldNotStart))
        assertThat(library.recordings.value).isEmpty()
    }

    @Test
    fun `without a library it can't start`() {
        val recorder = recorder(repository = { null })
        recorder.requestStart()
        recorder.begin()
        assertThat(recorder.state.value).isEqualTo(RecorderState.Failed(RecorderProblem.CouldNotStart))
    }

    @Test
    fun `a recorder error finishes with what's there and says why`() {
        val recorder = recorder()
        recorder.requestStart()
        recorder.begin()
        recorder.hideScreen()
        clock += 5_000
        capture.errorCallback!!()
        assertThat(capture.stopped).isTrue()
        assertThat(recorder.state.value).isEqualTo(RecorderState.Failed(RecorderProblem.Interrupted))
        assertThat(library.recordings.value.single().state).isEqualTo(RecordingState.Waiting)
        assertThat(recorder.screenHidden.value).isFalse()
    }

    @Test
    fun `a title reaches the core while recording and when stopping`() {
        val recorder = recorder()
        recorder.requestStart()
        recorder.begin()
        recorder.setTitle("Site visit")
        assertThat((recorder.state.value as RecorderState.Recording).title).isEqualTo("Site visit")
        recorder.stop()
        assertThat(library.recordings.value.single().title).isEqualTo("Site visit")
    }

    @Test
    fun `aborting lets go of the microphone and leaves the rest to the core`() = runBlocking {
        val recorder = recorder()
        recorder.requestStart()
        recorder.begin()
        recorder.abort()
        assertThat(capture.stopped).isTrue()
        assertThat(recorder.state.value).isEqualTo(RecorderState.Idle)
        assertThat(recorder.isActive).isFalse()
        assertThat(library.finishedSeconds).isEmpty()
        assertThat(library.recordings.value.single().state).isEqualTo(RecordingState.Recording)
    }

    @Test
    fun `recovery runs only when nothing is recording`() = runBlocking {
        library = PairedTestLibrary(rows = listOf(recording(RecordingState.Recording)))
        val recorder = recorder()

        recorder.requestStart()
        assertThat(recorder.recoverIfIdle(library)).isEqualTo(0)
        assertThat(library.recovered).isEqualTo(0)
        recorder.begin()
        assertThat(recorder.recoverIfIdle(library)).isEqualTo(0)
        assertThat(library.recovered).isEqualTo(0)
        recorder.discard()

        assertThat(recorder.recoverIfIdle(library)).isEqualTo(1)
        assertThat(library.recordings.value.single { it.id == "a" }.state).isEqualTo(RecordingState.Waiting)
    }

    @Test
    fun `the meter follows loudness on a decibel scale`() {
        assertThat(meterLevel(0)).isEqualTo(0f)
        assertThat(meterLevel(32767)).isEqualTo(1f)
        assertThat(meterLevel(40000)).isEqualTo(1f)
        assertThat(meterLevel(1036)).isWithin(0.01f).of(0.5f)
        // Below the floor it reads as silence.
        assertThat(meterLevel(1)).isEqualTo(0f)
        val recorder = recorder()
        assertThat(recorder.level()).isEqualTo(0f)
        recorder.requestStart()
        recorder.begin()
        capture.amplitude = 32767
        assertThat(recorder.level()).isEqualTo(1f)
    }

    @Test
    fun `row state follows the recording and the upload`() {
        val progress = UploadProgress("a", 42, 100)
        assertThat(recordingStatus(recording(RecordingState.Recording), null, false)).isEqualTo(RecordingStatus.Recording)
        assertThat(recordingStatus(recording(RecordingState.Waiting, message = "Update it"), null, false))
            .isEqualTo(RecordingStatus.Waiting("Update it"))
        assertThat(recordingStatus(recording(RecordingState.Waiting), progress, false)).isEqualTo(RecordingStatus.Sending(42))
        // Only the one being sent shows it.
        assertThat(recordingStatus(recording(RecordingState.Waiting, id = "b"), progress, false)).isEqualTo(RecordingStatus.Waiting(null))
        assertThat(recordingStatus(recording(RecordingState.Uploaded), progress, false)).isEqualTo(RecordingStatus.Processing)
        assertThat(recordingStatus(recording(RecordingState.Failed, message = "No audio"), null, false))
            .isEqualTo(RecordingStatus.Failed("No audio"))
    }

    @Test
    fun `percentages stay in range`() {
        assertThat(sentPercent(0, 0)).isEqualTo(0)
        assertThat(sentPercent(1, 3)).isEqualTo(33)
        assertThat(sentPercent(2, 3)).isEqualTo(66)
        assertThat(sentPercent(3, 3)).isEqualTo(100)
        assertThat(sentPercent(4, 3)).isEqualTo(100)
        // A long recording's bytes don't overflow.
        assertThat(sentPercent(5_000_000_000, 10_000_000_000)).isEqualTo(50)
    }

    @Test
    fun `the meetings list shows recordings and acts on them`() {
        library = PairedTestLibrary(rows = listOf(recording(RecordingState.Waiting, id = "a"), recording(RecordingState.Failed, id = "b", message = "No audio")))
        val viewModel = MeetingsViewModel(library)
        assertThat(viewModel.computerName.value).isEqualTo("Studio Computer")
        assertThat(viewModel.recordings.value.map { it.status }).containsExactly(RecordingStatus.Waiting(null), RecordingStatus.Failed("No audio")).inOrder()

        library.uploadProgress.value = UploadProgress("a", 1, 4)
        assertThat(viewModel.recordings.value.first().status).isEqualTo(RecordingStatus.Sending(25))
        library.uploadProgress.value = null

        viewModel.renameRecording("a", "Site visit")
        assertThat(viewModel.recordings.value.first().recording.title).isEqualTo("Site visit")
        viewModel.retryRecording("b")
        assertThat(viewModel.recordings.value.last().status).isEqualTo(RecordingStatus.Waiting(null))
        viewModel.deleteRecording("a")
        assertThat(viewModel.recordings.value.map { it.recording.id }).containsExactly("b")
    }

    @Test
    fun `a computer with recordings off explains waiting rows but blocks nothing`() {
        val turnedOff = object : CompanionRepository by library {
            override suspend fun manifest() = library.manifest()?.copy(recordingsEnabled = false)
        }
        library.recordings.value = listOf(recording(RecordingState.Waiting))
        val viewModel = MeetingsViewModel(turnedOff)
        assertThat(viewModel.recordings.value.single().status).isEqualTo(RecordingStatus.Waiting(null, computerTurnedItOff = true))
        assertThat(turnedOff.canRecord).isTrue()
    }

    @Test
    fun `the removal confirmation counts what hasn't reached the computer`() {
        library = PairedTestLibrary(
            rows = listOf(
                recording(RecordingState.Waiting, id = "a"),
                recording(RecordingState.Failed, id = "b"),
                recording(RecordingState.Uploaded, id = "c"),
            ),
        )
        assertThat(SettingsViewModel(library).unsentRecordings.value).isEqualTo(2)
        assertThat(SettingsViewModel(TestLibrary.repository()).unsentRecordings.value).isEqualTo(0)
    }

    @Test
    fun `the sample library can't record`() = runBlocking {
        val sample = TestLibrary.repository()
        assertThat(sample.canRecord).isFalse()
        assertThat(sample.recordings.value).isEmpty()
        assertThat(sample.beginRecording()).isNull()
        assertThat(sample.uploadRecordings()).isEqualTo(UploadOutcome.Finished(0, 0, 0))
        assertThat(MeetingsViewModel(sample).recordings.value).isEmpty()
    }

    @Test
    fun `the worker retries until nothing waits`() {
        assertThat(UploadWorker.shouldRetry(UploadOutcome.Finished(uploaded = 0, waiting = 0, failed = 0))).isFalse()
        assertThat(UploadWorker.shouldRetry(UploadOutcome.Finished(uploaded = 2, waiting = 0, failed = 1))).isFalse()
        // A computer that deferred it, or a pass that left one behind.
        assertThat(UploadWorker.shouldRetry(UploadOutcome.Finished(uploaded = 1, waiting = 1, failed = 0))).isTrue()
        assertThat(UploadWorker.shouldRetry(UploadOutcome.Failed(SyncFailure.Unreachable, "gone"))).isTrue()
        // An older computer: the rows say to update it, and the next try may find it updated.
        assertThat(UploadWorker.shouldRetry(UploadOutcome.Failed(SyncFailure.Other, "update"))).isTrue()
        assertThat(UploadWorker.shouldRetry(UploadOutcome.Failed(SyncFailure.Revoked, "removed"))).isFalse()
        assertThat(UploadWorker.shouldRetry(UploadOutcome.Failed(SyncFailure.NotPaired, "no"))).isFalse()
    }

    @Test
    fun `pairing again with the same computer gets fresh view models`() {
        val scopes = LibraryScopes()
        val first = PairedTestLibrary()
        val store = scopes.storeFor(first)
        assertThat(scopes.storeFor(first)).isSameInstanceAs(store)
        val again = PairedTestLibrary()
        assertThat(again.id).isEqualTo(first.id)
        assertThat(scopes.storeFor(again)).isNotSameInstanceAs(store)
    }

    @Test
    fun `a denied microphone offers another try, then settings`() {
        assertThat(promptAfterDenial(canAskAgain = true)).isEqualTo(MicrophonePrompt.Explain)
        assertThat(promptAfterDenial(canAskAgain = false)).isEqualTo(MicrophonePrompt.OpenSettings)
    }
}
