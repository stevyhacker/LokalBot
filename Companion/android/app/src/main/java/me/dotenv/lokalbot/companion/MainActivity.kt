package me.dotenv.lokalbot.companion

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import me.dotenv.lokalbot.companion.recording.RecordingService
import me.dotenv.lokalbot.companion.ui.CompanionRoot
import me.dotenv.lokalbot.companion.ui.LockScreen
import me.dotenv.lokalbot.companion.ui.RootActions
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme

/** A FragmentActivity because BiometricPrompt needs one. */
class MainActivity : FragmentActivity() {
    private val container get() = (application as CompanionApp).container

    private var appLockEnabled by mutableStateOf(false)
    private var lockKnown by mutableStateOf(false)
    private var locked by mutableStateOf(false)
    private var pairingLink by mutableStateOf<String?>(null)
    private var stoppedAt: Long? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        // Restored state says "unlocked" for as long as Android keeps it, which can be days after
        // it ended the process. Only a restart soon after the app was left may skip the lock.
        locked = savedInstanceState == null || savedInstanceState.getBoolean(KEY_LOCKED) ||
            awayTooLong(savedInstanceState.getLong(KEY_STOPPED_AT, NEVER))
        pairingLink = savedInstanceState?.getString(KEY_LINK) ?: pairingLinkFrom(intent)
        if (savedInstanceState == null) showRecorderIfAsked(intent)

        lifecycleScope.launch {
            appLockIs(container.preferences.appLockEnabled.first())
            if (!appLockEnabled) locked = false
            lockKnown = true
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                container.preferences.appLockEnabled.collect { appLockIs(it) }
            }
        }

        setContent {
            LokalBotTheme {
                if (!lockKnown) {
                    Box(Modifier.fillMaxSize().background(LokalBotTheme.palette.window))
                } else if (appLockEnabled && locked) {
                    LockScreen(onUnlock = { authenticate { locked = false } })
                } else {
                    CompanionRoot(
                        container,
                        RootActions(
                            appLockEnabled = appLockEnabled,
                            appLockAvailable = canAuthenticate(),
                            onAppLockChange = { enable ->
                                // Turning the lock on asks once, so nobody locks themselves out.
                                if (enable) authenticate { setAppLock(true) } else setAppLock(false)
                            },
                            pairingLink = pairingLink,
                            onPairingLinkConsumed = { pairingLink = null },
                            versionName = packageManager.getPackageInfo(packageName, 0).versionName.orEmpty(),
                        ),
                    )
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        pairingLinkFrom(intent)?.let { pairingLink = it }
        showRecorderIfAsked(intent)
    }

    override fun onStart() {
        super.onStart()
        val since = stoppedAt
        if (appLockEnabled && since != null && awayTooLong(since)) locked = true
        stoppedAt = null
    }

    override fun onStop() {
        super.onStop()
        stoppedAt = SystemClock.elapsedRealtime()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_LOCKED, locked)
        outState.putLong(KEY_STOPPED_AT, stoppedAt ?: SystemClock.elapsedRealtime())
        pairingLink?.let { outState.putString(KEY_LINK, it) }
    }

    /** [since] is on the clock that restarts with the device, so a time ahead of it is from before a restart. */
    private fun awayTooLong(since: Long): Boolean {
        val away = SystemClock.elapsedRealtime() - since
        return since == NEVER || away > RELOCK_AFTER_MS || away < 0
    }

    private fun setAppLock(enabled: Boolean) {
        lifecycleScope.launch { container.preferences.setAppLockEnabled(enabled) }
        appLockIs(enabled)
        locked = false
    }

    private fun appLockIs(enabled: Boolean) {
        appLockEnabled = enabled
        keepOutOfRecents(enabled)
    }

    private fun canAuthenticate(): Boolean =
        BiometricManager.from(this).canAuthenticate(AUTHENTICATORS) == BiometricManager.BIOMETRIC_SUCCESS

    private fun authenticate(onSuccess: () -> Unit) {
        val prompt = BiometricPrompt(
            this,
            ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = onSuccess()
            },
        )
        prompt.authenticate(
            BiometricPrompt.PromptInfo.Builder()
                .setTitle(getString(R.string.lock_prompt_title))
                .setSubtitle(getString(R.string.lock_prompt_subtitle))
                .setAllowedAuthenticators(AUTHENTICATORS)
                .build(),
        )
    }

    /** The recording notification opens the recording screen. */
    private fun showRecorderIfAsked(intent: Intent?) {
        if (intent?.getBooleanExtra(RecordingService.EXTRA_SHOW_RECORDER, false) == true) container.recorder.showScreen()
    }

    private fun pairingLinkFrom(intent: Intent?): String? =
        intent?.data?.takeIf { it.scheme == "lokalbot" && it.host == "pair" }?.toString()

    private companion object {
        const val KEY_LOCKED = "locked"
        const val KEY_LINK = "pairingLink"
        const val KEY_STOPPED_AT = "stoppedAt"
        const val NEVER = -1L
        const val RELOCK_AFTER_MS = 30_000L
        const val AUTHENTICATORS = BIOMETRIC_WEAK or DEVICE_CREDENTIAL
    }
}

/**
 * With the app lock on, the recents screen shows no picture of the library: the
 * lock only comes down after a while in the background, and the system takes
 * that picture on the way out. Android 13 can leave just that picture out, so
 * the person's own screenshots still work, as on iOS. Earlier versions can only
 * mark the whole window secure, which stops screenshots too.
 */
internal fun Activity.keepOutOfRecents(hide: Boolean) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        setRecentsScreenshotEnabled(!hide)
    } else if (hide) {
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    } else {
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
}
