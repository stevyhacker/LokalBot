package me.dotenv.lokalbot.companion.recording

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.material3.adaptive.Posture
import androidx.compose.material3.adaptive.WindowAdaptiveInfo
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.input.InputModeManager
import androidx.compose.ui.platform.LocalInputModeManager
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertIsNotFocused
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.window.core.layout.WindowSizeClass
import androidx.window.core.layout.computeWindowSizeClass
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import me.dotenv.lokalbot.companion.FakeCapture
import me.dotenv.lokalbot.companion.PairOutcome
import me.dotenv.lokalbot.companion.PairedTestLibrary
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.TestLibrary
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.DeviceRecording
import me.dotenv.lokalbot.companion.data.RecordingState
import me.dotenv.lokalbot.companion.ui.LokalBotApp
import me.dotenv.lokalbot.companion.ui.PairingLinkFixture
import me.dotenv.lokalbot.companion.ui.navigation.AppNavigator
import me.dotenv.lokalbot.companion.ui.onboarding.PairingScreen
import me.dotenv.lokalbot.companion.ui.onboarding.PairingStep
import me.dotenv.lokalbot.companion.ui.onboarding.PairingViewModel
import me.dotenv.lokalbot.companion.ui.onboarding.WelcomeScreen
import me.dotenv.lokalbot.companion.ui.navigation.Destination
import me.dotenv.lokalbot.companion.ui.recording.RecordingStatus
import me.dotenv.lokalbot.companion.ui.recording.text
import me.dotenv.lokalbot.companion.ui.settings.SettingsActions
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/** The record button, row wording and confirmations, on Robolectric. */
@RunWith(AndroidJUnit4::class)
@Config(qualifiers = "en-rGB-w411dp-h891dp-hdpi")
class RecordingUiTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val resources get() = ApplicationProvider.getApplicationContext<Application>().resources

    private fun recorder(library: CompanionRepository) = MeetingRecorder(
        scope = CoroutineScope(Dispatchers.Unconfined),
        library = { library },
        newCapture = { FakeCapture() },
        elapsedMillis = { 0 },
    )

    @Test
    fun `the welcome screen holds recordings the computer never got`() {
        var deleted = 0
        compose.setContent {
            LokalBotTheme(darkTheme = false, reduceMotion = true) {
                WelcomeScreen(onPair = {}, onTrySample = {}, heldRecordings = 2, onDeleteHeldRecordings = { deleted++ })
            }
        }
        compose.onNodeWithText(resources.getQuantityString(R.plurals.welcome_held_recordings_title, 2, 2)).assertIsDisplayed()
        compose.onNodeWithText(resources.getString(R.string.welcome_held_recordings_delete)).performClick()
        assertThat(deleted).isEqualTo(0)
        compose.onNode(hasText(resources.getString(R.string.welcome_held_recordings_delete)) and hasAnyAncestor(isDialog())).performClick()
        compose.waitForIdle()
        assertThat(deleted).isEqualTo(1)
    }

    /** Pairing again is how recordings held after a removal get sent. */
    @Test
    fun `the pairing screen works again after pairing once`() {
        fun link() = PairingLinkFixture.link(System.currentTimeMillis() / 1000 + 300)
        val viewModel = PairingViewModel(pair = { _, _, _ -> PairOutcome.Paired("Dev Computer") }, initialDeviceName = { "Phone" })
        var done = 0
        compose.setContent {
            LokalBotTheme(darkTheme = false, reduceMotion = true) {
                PairingScreen(viewModel, initialLink = null, onDone = { done++ }, onClose = {})
            }
        }
        assertThat(viewModel.submit(link())).isTrue()
        viewModel.confirm()
        compose.waitForIdle()
        assertThat(done).isEqualTo(1)
        assertThat(viewModel.step.value).isEqualTo(PairingStep.Scan)
        assertThat(viewModel.submit(link())).isTrue()
    }

    private fun show(library: CompanionRepository, destination: Destination = Destination.Meetings, recorder: MeetingRecorder = recorder(library)) {
        compose.setContent {
            // Robolectric's window isn't in touch mode, as a phone's is.
            CompositionLocalProvider(LocalInputModeManager provides Touchscreen) {
                LokalBotTheme(darkTheme = false, reduceMotion = true) {
                    LokalBotApp(
                        library,
                        SettingsActions(versionName = "0.1.0"),
                        adaptiveInfo = WindowAdaptiveInfo(WindowSizeClass.BREAKPOINTS_V1.computeWindowSizeClass(411f, 891f), Posture()),
                        navigator = AppNavigator(destination),
                        recorder = recorder,
                    )
                }
            }
        }
        compose.waitForIdle()
    }

    private object Touchscreen : InputModeManager {
        override val inputMode = InputMode.Touch

        @ExperimentalComposeUiApi
        override fun requestInputMode(inputMode: InputMode) = inputMode == InputMode.Touch
    }

    private fun row(state: RecordingState, id: String = "a", message: String? = null) =
        DeviceRecording(id = id, title = "", state = state, startedAt = TestLibrary.now.toString(), durationSeconds = 120.0, message = message)

    @Test
    fun `the sample library has no record button`() {
        show(TestLibrary.repository())
        compose.onNodeWithContentDescription("Record a meeting").assertDoesNotExist()
        compose.onNodeWithText("From this device").assertDoesNotExist()
    }

    @Test
    fun `the sample library's menu has no record entry`() {
        show(TestLibrary.repository(), Destination.Today)
        compose.onNodeWithContentDescription("More").performClick()
        compose.onNodeWithText("Record").assertDoesNotExist()
    }

    @Test
    fun `a paired library records from Meetings`() {
        val library = PairedTestLibrary()
        show(library)
        compose.onNodeWithContentDescription("Record a meeting").assertIsDisplayed()
        // Nothing to show yet, so no section.
        compose.onNodeWithText("From this device").assertDoesNotExist()
    }

    @Test
    fun `Today offers recording in its menu`() {
        show(PairedTestLibrary(), Destination.Today)
        compose.onNodeWithContentDescription("More").performClick()
        compose.onNodeWithText("Record").assertIsDisplayed()
    }

    @Test
    fun `the search field doesn't take focus on arrival`() {
        val library = PairedTestLibrary()
        val recorder = recorder(library)
        show(library, Destination.Today, recorder)
        compose.onNodeWithText("Meetings").performClick()
        compose.onNode(hasSetTextAction()).assertIsNotFocused()
        // Nor on the way back from recording, where it would open the keyboard.
        compose.runOnUiThread {
            recorder.requestStart()
            recorder.begin()
        }
        compose.onNodeWithText("Stop").performClick()
        compose.waitUntil { recorder.state.value == RecorderState.Idle }
        compose.onNode(hasSetTextAction()).assertIsNotFocused()
        // A tap still does.
        compose.onNode(hasSetTextAction()).performClick()
        compose.onNode(hasSetTextAction()).assertIsFocused()
    }

    @Test
    fun `row wording names the computer`() {
        assertThat(RecordingStatus.Waiting(null).text(resources, "Dev Computer").headline).isEqualTo("Waiting for Dev Computer")
        assertThat(RecordingStatus.Waiting(null).text(resources, null).headline).isEqualTo("Waiting for your computer")
        assertThat(RecordingStatus.Sending(42).text(resources, "Dev Computer").headline).isEqualTo("Sending… 42%")
        assertThat(RecordingStatus.Processing.text(resources, "Dev Computer").headline).isEqualTo("Processing on Dev Computer")
        assertThat(RecordingStatus.Recording.text(resources, "Dev Computer").headline).isEqualTo("Recording")
        assertThat(RecordingStatus.Failed("No audio").text(resources, "Dev Computer").detail).isEqualTo("No audio")
    }

    @Test
    fun `waiting rows say why when anything is known`() {
        assertThat(RecordingStatus.Waiting("Update LokalBot.").text(resources, null).detail).isEqualTo("Update LokalBot.")
        assertThat(RecordingStatus.Waiting(null, computerTurnedItOff = true).text(resources, null).detail)
            .isEqualTo(resources.getString(R.string.recording_turned_off))
        // What the computer said last wins over a manifest that can be stale.
        assertThat(RecordingStatus.Waiting("Disk full.", computerTurnedItOff = true).text(resources, null).detail).isEqualTo("Disk full.")
        assertThat(RecordingStatus.Waiting(null).text(resources, null).detail).isNull()
    }

    @Test
    fun `deleting a waiting recording asks first`() {
        val library = PairedTestLibrary(rows = listOf(row(RecordingState.Waiting)))
        show(library)
        compose.onNodeWithText("Phone recording").assertIsDisplayed()
        compose.onNodeWithContentDescription("More for this recording").performClick()
        compose.onNodeWithText("Delete").performClick()
        compose.onNodeWithText("Delete this recording?").assertIsDisplayed()
        assertThat(library.recordings.value).hasSize(1)
        compose.onNodeWithText("Delete").performClick()
        compose.waitUntil { library.recordings.value.isEmpty() }
        compose.onNodeWithText("From this device").assertDoesNotExist()
    }

    @Test
    fun `a failed recording offers retry and delete`() {
        val library = PairedTestLibrary(rows = listOf(row(RecordingState.Failed, message = "No audio")))
        show(library)
        compose.onNodeWithText("No audio").assertIsDisplayed()
        compose.onNodeWithText("Delete").assertIsDisplayed()
        compose.onNodeWithText("Retry").performClick()
        compose.waitUntil { library.recordings.value.single().state == RecordingState.Waiting }
    }

    @Test
    fun `a recording being sent or processed offers nothing to delete`() {
        val library = PairedTestLibrary(rows = listOf(row(RecordingState.Uploaded)))
        show(library)
        compose.onNodeWithText("Processing on Studio Computer").assertIsDisplayed()
        compose.onNodeWithContentDescription("More for this recording").assertDoesNotExist()
        compose.onNodeWithText("Delete").assertDoesNotExist()
    }

    @Test
    fun `removing this device says how many recordings go with it`() {
        val library = PairedTestLibrary(rows = listOf(row(RecordingState.Waiting, id = "a"), row(RecordingState.Failed, id = "b"), row(RecordingState.Uploaded, id = "c")))
        show(library, Destination.Settings)
        compose.onNodeWithText("Remove and erase").performScrollTo().performClick()
        compose.onNodeWithText("2 recordings haven't reached your computer and will be deleted.").assertIsDisplayed()
    }

    @Test
    fun `nothing is said about recordings when none are unsent`() {
        show(PairedTestLibrary(), Destination.Settings)
        compose.onNodeWithText("Remove and erase").performScrollTo().performClick()
        compose.onNodeWithText("Remove this device?").assertIsDisplayed()
        compose.onNodeWithText("hasn't reached", substring = true).assertDoesNotExist()
    }

    @Test
    fun `the recording screen follows the recorder, not the composable`() {
        val library = PairedTestLibrary()
        val recorder = recorder(library)
        show(library, recorder = recorder)
        compose.runOnUiThread {
            recorder.requestStart()
            recorder.begin()
        }
        compose.onNodeWithText("Stop").assertIsDisplayed()
        compose.onNodeWithText("Let everyone know you're recording.").assertIsDisplayed()

        // Back leaves it recording, and the list says so.
        compose.onNodeWithContentDescription("Back to LokalBot. It keeps recording.").performClick()
        compose.onNodeWithText("Search meetings").assertIsDisplayed()
        compose.onNodeWithText("From this device").assertIsDisplayed()
        assertThat(recorder.isActive).isTrue()

        // The row returns to it.
        compose.onNodeWithText("Phone recording").performClick()
        compose.onNodeWithText("Stop").performClick()
        compose.waitUntil { recorder.state.value == RecorderState.Idle }
        compose.onNodeWithText("Search meetings").assertIsDisplayed()
    }

    @Test
    fun `discarding asks first`() {
        val library = PairedTestLibrary()
        val recorder = recorder(library)
        show(library, recorder = recorder)
        compose.runOnUiThread {
            recorder.requestStart()
            recorder.begin()
        }
        compose.onNodeWithText("Discard").performClick()
        compose.onNodeWithText("Discard this recording?").assertIsDisplayed()
        assertThat(library.recordings.value).hasSize(1)
        compose.onNode(hasText("Discard") and hasAnyAncestor(isDialog())).performClick()
        compose.waitUntil { library.recordings.value.isEmpty() }
        compose.onNodeWithText("Search meetings").assertIsDisplayed()
    }
}
