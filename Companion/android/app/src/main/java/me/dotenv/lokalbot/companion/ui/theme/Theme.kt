package me.dotenv.lokalbot.companion.ui.theme

import android.app.UiModeManager
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

val LocalLokalBotPalette = staticCompositionLocalOf { LokalBotTokens.Light }
val LocalIsDarkTheme = staticCompositionLocalOf { false }

/** Increase Contrast (Android 14+ contrast setting) strengthens strokes and supporting text. */
val LocalIncreasedContrast = staticCompositionLocalOf { false }

/** Access to the full LokalBot palette and roles beyond Material's color scheme. */
object LokalBotTheme {
    val palette: LokalBotPalette
        @Composable @ReadOnlyComposable get() = LocalLokalBotPalette.current

    val isDark: Boolean
        @Composable @ReadOnlyComposable get() = LocalIsDarkTheme.current

    val increasedContrast: Boolean
        @Composable @ReadOnlyComposable get() = LocalIncreasedContrast.current

    /** Metadata lines: readable grey, primary text under Increase Contrast. */
    val supportingText: Color
        @Composable @ReadOnlyComposable get() =
            if (LocalIncreasedContrast.current) LocalLokalBotPalette.current.textPrimary else LocalLokalBotPalette.current.textSupporting
}

/**
 * LokalBot's Material 3 theme: dynamic color stays off so the teal brand
 * holds, colors come from Companion/design/tokens.json, type is Inter.
 */
@Composable
fun LokalBotTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    reduceMotion: Boolean? = null,
    content: @Composable () -> Unit,
) {
    val palette = if (darkTheme) LokalBotTokens.Dark else LokalBotTokens.Light
    val context = LocalContext.current
    val increasedContrast = remember(context) {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            (context.getSystemService(UiModeManager::class.java)?.contrast ?: 0f) >= 0.5f
    }
    val motion = reduceMotion ?: rememberSystemReducedMotion()
    MaterialTheme(
        colorScheme = lokalBotColorScheme(palette, darkTheme),
        typography = LokalBotTypography,
        shapes = LokalBotShapes,
    ) {
        CompositionLocalProvider(
            LocalLokalBotPalette provides palette,
            LocalIsDarkTheme provides darkTheme,
            LocalIncreasedContrast provides increasedContrast,
            LocalReduceMotion provides motion,
            content = content,
        )
    }
}

val LokalBotShapes = Shapes(
    extraSmall = RoundedCornerShape(LokalBotTokens.Radius.tab),
    small = RoundedCornerShape(LokalBotTokens.Radius.row),
    medium = RoundedCornerShape(LokalBotTokens.Radius.panel),
    large = RoundedCornerShape(LokalBotTokens.Radius.composer),
    extraLarge = RoundedCornerShape(28.dp),
)

fun lokalBotColorScheme(palette: LokalBotPalette, dark: Boolean): ColorScheme {
    val window = palette.window
    fun Color.over(): Color = compositeOver(window)
    val outline = palette.textSupporting.copy(alpha = if (dark) 0.45f else 0.38f).over()
    val base = if (dark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = palette.accentFill,
        onPrimary = Color.White,
        primaryContainer = palette.accentFill.copy(alpha = 0.16f).over(),
        onPrimaryContainer = palette.accentText,
        inversePrimary = if (dark) LokalBotTokens.Light.accentText else LokalBotTokens.Dark.accentText,
        secondary = palette.accentText,
        onSecondary = if (dark) Color.Black else Color.White,
        secondaryContainer = palette.accentWash.over(),
        onSecondaryContainer = palette.accentText,
        tertiary = palette.attention,
        onTertiary = Color.Black,
        tertiaryContainer = palette.attentionWash.over(),
        onTertiaryContainer = palette.attentionText,
        background = window,
        onBackground = palette.textPrimary.over(),
        surface = window,
        onSurface = palette.textPrimary.over(),
        surfaceVariant = palette.sidebar,
        onSurfaceVariant = palette.textSupporting,
        surfaceTint = Color.Transparent,
        inverseSurface = if (dark) Color(0xFFE8E8EA) else Color(0xFF2A2A2C),
        inverseOnSurface = if (dark) Color(0xFF1E1E1F) else Color(0xFFF2F2F3),
        error = palette.recording,
        onError = Color.White,
        errorContainer = palette.recording.copy(alpha = 0.12f).over(),
        onErrorContainer = palette.recordingText,
        outline = outline,
        outlineVariant = palette.separator.over(),
        scrim = Color.Black,
        surfaceBright = palette.elevated,
        surfaceDim = palette.sidebar,
        surfaceContainerLowest = window,
        surfaceContainerLow = window,
        surfaceContainer = palette.sidebar,
        surfaceContainerHigh = palette.elevated,
        surfaceContainerHighest = palette.chipFill.over(),
    )
}
