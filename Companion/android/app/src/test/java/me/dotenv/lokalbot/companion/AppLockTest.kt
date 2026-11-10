package me.dotenv.lokalbot.companion

import android.app.Application
import android.os.Bundle
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.time.Duration
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.shadows.ShadowSystemClock

/**
 * The app lock when the activity comes back from its saved state: at once, as
 * on rotation, and long after, as when Android ended the process meanwhile.
 */
@RunWith(AndroidJUnit4::class)
class AppLockTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private val app get() = ApplicationProvider.getApplicationContext<Application>() as CompanionApp
    private val lockTitle get() = app.getString(R.string.lock_title)
    private val welcome get() = app.getString(R.string.welcome_try_sample)

    private fun shows(text: String) = compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()

    private fun waitFor(text: String) = compose.waitUntil(10_000) { shows(text) }

    /** Opens the app, turns the lock on while it's unlocked, leaves, and comes back from the saved state [after] that long. */
    private fun leaveAndComeBack(after: Duration) {
        val first = Robolectric.buildActivity(MainActivity::class.java).setup()
        waitFor(welcome)
        runBlocking { app.container.preferences.setAppLockEnabled(true) }
        val state = Bundle()
        first.pause().stop().saveInstanceState(state).destroy()
        ShadowSystemClock.advanceBy(after)
        Robolectric.buildActivity(MainActivity::class.java).setup(state)
    }

    @After
    fun turnTheLockOff() = runBlocking { app.container.preferences.setAppLockEnabled(false) }

    @Test
    fun `coming back from saved state long after leaving asks to unlock`() {
        leaveAndComeBack(after = Duration.ofMinutes(10))
        waitFor(lockTitle)
        check(!shows(welcome))
    }

    @Test
    fun `coming back from saved state at once stays unlocked`() {
        leaveAndComeBack(after = Duration.ofSeconds(2))
        waitFor(welcome)
        check(!shows(lockTitle))
    }
}
