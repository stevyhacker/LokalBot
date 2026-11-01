package me.dotenv.lokalbot.companion.screenshots

import androidx.activity.ComponentActivity
import androidx.compose.material3.adaptive.HingeInfo
import androidx.compose.material3.adaptive.Posture
import androidx.compose.material3.adaptive.WindowAdaptiveInfo
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.window.core.layout.WindowSizeClass
import androidx.window.core.layout.computeWindowSizeClass
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.runBlocking
import me.dotenv.lokalbot.companion.TestLibrary
import me.dotenv.lokalbot.companion.data.FixtureRepository
import me.dotenv.lokalbot.companion.data.model.ActionStatus
import me.dotenv.lokalbot.companion.ui.LokalBotApp
import me.dotenv.lokalbot.companion.ui.navigation.AppNavigator
import me.dotenv.lokalbot.companion.ui.navigation.Destination
import me.dotenv.lokalbot.companion.ui.onboarding.WelcomeScreen
import me.dotenv.lokalbot.companion.ui.settings.SettingsActions
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The app at phone, unfolded-foldable and tablet widths, in light and dark,
 * plus a foldable in book and tabletop postures. Record with
 * `./gradlew :app:recordRoborazziDebug`; CI runs `verifyRoborazziDebug`.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "en-rGB-w411dp-h891dp-hdpi")
class ScreenshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val repository: FixtureRepository = TestLibrary.repository()

    private fun windowInfo(widthDp: Int, heightDp: Int, posture: Posture = Posture()) =
        WindowAdaptiveInfo(WindowSizeClass.BREAKPOINTS_V1.computeWindowSizeClass(widthDp.toFloat(), heightDp.toFloat()), posture)

    private fun show(
        name: String,
        navigator: AppNavigator,
        widthDp: Int = 411,
        heightDp: Int = 891,
        dark: Boolean = false,
        posture: Posture = Posture(),
        rtl: Boolean = false,
        before: () -> Unit = {},
    ) {
        compose.setContent {
            val direction = if (rtl) LayoutDirection.Rtl else LayoutDirection.Ltr
            CompositionLocalProvider(LocalLayoutDirection provides direction) {
                Themed(dark) {
                    LokalBotApp(repository, SettingsActions(versionName = "0.1.0"), adaptiveInfo = windowInfo(widthDp, heightDp, posture), navigator = navigator)
                }
            }
        }
        compose.waitForIdle()
        before()
        compose.waitForIdle()
        compose.onRoot().captureRoboImage("src/test/screenshots/$name.png")
    }

    @Composable
    private fun Themed(dark: Boolean, content: @Composable () -> Unit) = LokalBotTheme(darkTheme = dark, reduceMotion = true, content = content)

    // Phone (compact)

    @Test
    fun phoneToday() = show("phone_today_light", AppNavigator(Destination.Today))

    @Test
    fun phoneTodayDark() = show("phone_today_dark", AppNavigator(Destination.Today), dark = true)

    @Test
    fun phoneMeetings() = show("phone_meetings_list", AppNavigator(Destination.Meetings))

    @Test
    fun phoneMeetingSummary() = show("phone_meeting_summary", AppNavigator(Destination.Meetings).apply { openMeeting(TestLibrary.DESIGN_REVIEW) })

    @Test
    fun phoneMeetingTranscriptDark() = show(
        "phone_meeting_transcript_dark",
        AppNavigator(Destination.Meetings).apply { openMeeting(TestLibrary.DESIGN_REVIEW, at = 721.4) },
        dark = true,
    )

    @Test
    fun phoneActions() = show("phone_actions_light", AppNavigator(Destination.Actions))

    @Test
    fun phoneActionsDark() = show("phone_actions_dark", AppNavigator(Destination.Actions), dark = true)

    @Test
    fun phoneActionPending() {
        runBlocking { repository.setActionStatus(TestLibrary.DESIGN_REVIEW, "act-1f2e3d4c", ActionStatus.Done) }
        show("phone_action_detail_pending", AppNavigator(Destination.Actions).apply { openAction(TestLibrary.DESIGN_REVIEW, "act-1f2e3d4c") })
    }

    @Test
    fun phoneTimeline() = show("phone_timeline", AppNavigator(Destination.Timeline).apply { openDay(TestLibrary.yesterday.toString()) })

    @Test
    fun phoneAsk() = show("phone_ask_answer", AppNavigator(Destination.Ask)) {
        compose.onNodeWithText("What did Maya ask me?").performClick()
    }

    @Test
    fun phoneAskEmptyDark() = show("phone_ask_empty_dark", AppNavigator(Destination.Ask), dark = true)

    @Test
    fun phoneSettings() = show("phone_settings_sample", AppNavigator(Destination.Settings))

    @Test
    fun phonePerson() = show("phone_person", AppNavigator(Destination.People).apply { openPerson("person:maya-chen") })

    @Test
    fun phoneWelcome() {
        compose.setContent { Themed(dark = false) { WelcomeScreen(onPair = {}, onTrySample = {}) } }
        compose.onRoot().captureRoboImage("src/test/screenshots/phone_welcome.png")
    }

    @Test
    @Config(qualifiers = "en-rGB-w891dp-h411dp-hdpi")
    fun phoneLandscapeMeetings() = show(
        "phone_landscape_meetings",
        AppNavigator(Destination.Meetings).apply { openMeeting(TestLibrary.DESIGN_REVIEW) },
        891,
        411,
    )

    @Test
    @Config(qualifiers = "en-rGB-w411dp-h891dp-hdpi", fontScale = 1.6f)
    fun phoneLargeText() = show("phone_today_large_text", AppNavigator(Destination.Today))

    @Test
    fun phoneRightToLeft() = show("phone_actions_rtl", AppNavigator(Destination.Actions).apply { openAction(TestLibrary.DESIGN_REVIEW, "act-1f2e3d4c") }, rtl = true)

    // Unfolded foldable or small tablet (medium)

    @Test
    @Config(qualifiers = "en-rGB-w673dp-h841dp-hdpi")
    fun mediumMeetings() = show("medium_meetings_light", AppNavigator(Destination.Meetings).apply { openMeeting(TestLibrary.DESIGN_REVIEW) }, 673, 841)

    @Test
    @Config(qualifiers = "en-rGB-w673dp-h841dp-hdpi")
    fun mediumMeetingsDark() = show("medium_meetings_dark", AppNavigator(Destination.Meetings).apply { openMeeting(TestLibrary.DESIGN_REVIEW) }, 673, 841, dark = true)

    @Test
    @Config(qualifiers = "en-rGB-w673dp-h841dp-hdpi")
    fun mediumTimeline() = show("medium_timeline", AppNavigator(Destination.Timeline).apply { openDay(TestLibrary.yesterday.toString()) }, 673, 841)

    // Tablet (expanded)

    @Test
    @Config(qualifiers = "en-rGB-w1280dp-h800dp-mdpi")
    fun tabletToday() = show("tablet_today_light", AppNavigator(Destination.Today), 1280, 800)

    @Test
    @Config(qualifiers = "en-rGB-w1280dp-h800dp-mdpi")
    fun tabletTodayDark() = show("tablet_today_dark", AppNavigator(Destination.Today), 1280, 800, dark = true)

    @Test
    @Config(qualifiers = "en-rGB-w1280dp-h800dp-mdpi")
    fun tabletMeetings() = show("tablet_meetings", AppNavigator(Destination.Meetings).apply { openMeeting(TestLibrary.STANDUP) }, 1280, 800)

    @Test
    @Config(qualifiers = "en-rGB-w1280dp-h800dp-mdpi")
    fun tabletTimeline() = show("tablet_timeline", AppNavigator(Destination.Timeline).apply { openDay(TestLibrary.yesterday.toString()) }, 1280, 800)

    @Test
    @Config(qualifiers = "en-rGB-w1280dp-h800dp-mdpi")
    fun tabletProject() = show("tablet_project", AppNavigator(Destination.Projects).apply { openProject(TestLibrary.ONBOARDING) }, 1280, 800)

    @Test
    @Config(qualifiers = "en-rGB-w1280dp-h800dp-mdpi")
    fun tabletAskDark() = show("tablet_ask_dark", AppNavigator(Destination.Ask), 1280, 800, dark = true) {
        compose.onNodeWithText("What's overdue?").performClick()
    }

    // Foldable postures (Pixel Fold inner display, 841 × 701 dp)

    @Test
    @Config(qualifiers = "en-rGB-w841dp-h701dp-hdpi")
    fun foldableBookActions() {
        val density = RuntimeEnvironment.getApplication().resources.displayMetrics.density
        val hingeX = 841 / 2f * density
        val hinge = HingeInfo(
            bounds = Rect(hingeX, 0f, hingeX, 701 * density),
            isFlat = false,
            isVertical = true,
            isSeparating = true,
            isOccluding = false,
        )
        show(
            "foldable_book_actions",
            AppNavigator(Destination.Actions).apply { openAction(TestLibrary.DESIGN_REVIEW, "act-1f2e3d4c") },
            841,
            701,
            posture = Posture(isTabletop = false, hingeList = listOf(hinge)),
        )
    }

    @Test
    @Config(qualifiers = "en-rGB-w701dp-h841dp-hdpi")
    fun foldableTabletopAsk() {
        val density = RuntimeEnvironment.getApplication().resources.displayMetrics.density
        val hingeY = 841 / 2f * density
        val hinge = HingeInfo(
            bounds = Rect(0f, hingeY, 701 * density, hingeY),
            isFlat = false,
            isVertical = false,
            isSeparating = true,
            isOccluding = false,
        )
        show("foldable_tabletop_ask", AppNavigator(Destination.Ask), 701, 841, posture = Posture(isTabletop = true, hingeList = listOf(hinge))) {
            compose.onNodeWithText("What's overdue?").performClick()
        }
    }
}
