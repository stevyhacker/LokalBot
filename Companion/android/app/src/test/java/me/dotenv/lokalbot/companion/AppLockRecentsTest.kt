package me.dotenv.lokalbot.companion

import android.app.Activity
import android.view.WindowManager.LayoutParams.FLAG_SECURE
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.annotation.Config

/** What the recents screen may show of the library while the app lock is on. */
@RunWith(AndroidJUnit4::class)
class AppLockRecentsTest {
    class Probe : Activity() {
        var recentsPicture: Boolean? = null

        override fun setRecentsScreenshotEnabled(enabled: Boolean) {
            recentsPicture = enabled
        }
    }

    private fun Activity.isSecure() = window.attributes.flags and FLAG_SECURE != 0

    @Test
    fun `the lock keeps the recents picture out and leaves screenshots alone`() {
        val activity = Robolectric.buildActivity(Probe::class.java).setup().get()
        activity.keepOutOfRecents(true)
        assertThat(activity.recentsPicture).isFalse()
        assertThat(activity.isSecure()).isFalse()
        activity.keepOutOfRecents(false)
        assertThat(activity.recentsPicture).isTrue()
    }

    @Test
    @Config(sdk = [32])
    fun `before Android 13 the lock marks the window secure`() {
        val activity = Robolectric.buildActivity(Probe::class.java).setup().get()
        activity.keepOutOfRecents(true)
        assertThat(activity.isSecure()).isTrue()
        assertThat(activity.recentsPicture).isNull()
        activity.keepOutOfRecents(false)
        assertThat(activity.isSecure()).isFalse()
    }
}
