package me.dotenv.lokalbot.companion.ui.people

import androidx.activity.ComponentActivity
import androidx.compose.material3.adaptive.Posture
import androidx.compose.material3.adaptive.WindowAdaptiveInfo
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.window.core.layout.WindowSizeClass
import androidx.window.core.layout.computeWindowSizeClass
import me.dotenv.lokalbot.companion.TestLibrary
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.model.Person
import me.dotenv.lokalbot.companion.ui.LokalBotApp
import me.dotenv.lokalbot.companion.ui.navigation.AppNavigator
import me.dotenv.lokalbot.companion.ui.navigation.Destination
import me.dotenv.lokalbot.companion.ui.settings.SettingsActions
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/** The People list, on Robolectric. */
@RunWith(AndroidJUnit4::class)
@Config(qualifiers = "en-rGB-w411dp-h891dp-hdpi")
class PeopleScreenTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun `a last-met date that isn't an instant leaves the list readable`() {
        val sample = TestLibrary.repository()
        // A bare day, which Instant.parse refuses.
        val library = object : CompanionRepository by sample {
            override suspend fun people(): List<Person> = sample.people().map { it.copy(lastMetAt = "2026-10-30") }
        }
        compose.setContent {
            LokalBotTheme(darkTheme = false, reduceMotion = true) {
                LokalBotApp(
                    library,
                    SettingsActions(versionName = "0.1.0"),
                    adaptiveInfo = WindowAdaptiveInfo(WindowSizeClass.BREAKPOINTS_V1.computeWindowSizeClass(411f, 891f), Posture()),
                    navigator = AppNavigator(Destination.People),
                )
            }
        }
        compose.waitForIdle()
        compose.onNodeWithText("Maya Chen").assertIsDisplayed()
    }
}
