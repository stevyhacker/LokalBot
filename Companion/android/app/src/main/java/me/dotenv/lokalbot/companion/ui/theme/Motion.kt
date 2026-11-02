package me.dotenv.lokalbot.companion.ui.theme

import android.provider.Settings
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext

/** True under "Remove animations"; every LokalBot animation is then off. */
val LocalReduceMotion = staticCompositionLocalOf { false }

enum class MotionKind(val millis: Int, val easing: Easing) {
    Selection(LokalBotTokens.Motion.selection, EaseOut),
    Disclosure(LokalBotTokens.Motion.disclosure, EaseInOut),
    Drawer(LokalBotTokens.Motion.drawer, EaseOut),
    Tabs(LokalBotTokens.Motion.tabs, Snappy),
    Milestone(LokalBotTokens.Motion.milestone, Snappy),
}

private val EaseOut: Easing get() = CubicBezierEasing(0f, 0f, 0.58f, 1f)
private val EaseInOut: Easing get() = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)
private val Snappy: Easing get() = CubicBezierEasing(0.2f, 0.9f, 0.3f, 1f)

object LokalBotMotion {
    val reduced: Boolean
        @Composable @ReadOnlyComposable get() = LocalReduceMotion.current

    @Composable
    @ReadOnlyComposable
    fun <T> spec(kind: MotionKind): AnimationSpec<T> =
        if (LocalReduceMotion.current) snap() else tween(kind.millis, easing = kind.easing)
}

@Composable
fun rememberSystemReducedMotion(): Boolean {
    val context = LocalContext.current
    return remember(context) {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
}
