package me.dotenv.lokalbot.companion

import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
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
        locked = savedInstanceState?.getBoolean(KEY_LOCKED) ?: true
        pairingLink = savedInstanceState?.getString(KEY_LINK) ?: pairingLinkFrom(intent)

        lifecycleScope.launch {
            appLockEnabled = container.preferences.appLockEnabled.first()
            if (!appLockEnabled) locked = false
            lockKnown = true
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                container.preferences.appLockEnabled.collect { appLockEnabled = it }
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
    }

    override fun onStart() {
        super.onStart()
        val since = stoppedAt
        if (appLockEnabled && since != null && SystemClock.elapsedRealtime() - since > RELOCK_AFTER_MS) locked = true
        stoppedAt = null
    }

    override fun onStop() {
        super.onStop()
        stoppedAt = SystemClock.elapsedRealtime()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_LOCKED, locked)
        pairingLink?.let { outState.putString(KEY_LINK, it) }
    }

    private fun setAppLock(enabled: Boolean) {
        lifecycleScope.launch { container.preferences.setAppLockEnabled(enabled) }
        appLockEnabled = enabled
        locked = false
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

    private fun pairingLinkFrom(intent: Intent?): String? =
        intent?.data?.takeIf { it.scheme == "lokalbot" && it.host == "pair" }?.toString()

    private companion object {
        const val KEY_LOCKED = "locked"
        const val KEY_LINK = "pairingLink"
        const val RELOCK_AFTER_MS = 30_000L
        const val AUTHENTICATORS = BIOMETRIC_WEAK or DEVICE_CREDENTIAL
    }
}
