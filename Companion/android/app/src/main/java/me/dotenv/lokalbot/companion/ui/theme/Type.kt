package me.dotenv.lokalbot.companion.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import me.dotenv.lokalbot.companion.R

/** Inter, the interface font the Linux/Windows app also bundles (OFL-1.1). */
val Inter = FontFamily(
    Font(R.font.inter_regular, FontWeight.Normal),
    Font(R.font.inter_medium, FontWeight.Medium),
    Font(R.font.inter_semibold, FontWeight.SemiBold),
    Font(R.font.inter_bold, FontWeight.Bold),
)

private val default = Typography()

private fun TextStyle.inter(weight: FontWeight? = null) =
    copy(fontFamily = Inter, fontWeight = weight ?: fontWeight, letterSpacing = 0.sp)

/** Material 3's scalable sizes in Inter, with the Mac's heavier title weights. */
val LokalBotTypography = Typography(
    displayLarge = default.displayLarge.inter(),
    displayMedium = default.displayMedium.inter(),
    displaySmall = default.displaySmall.inter(),
    headlineLarge = default.headlineLarge.inter(FontWeight.Bold),
    headlineMedium = default.headlineMedium.inter(FontWeight.Bold),
    headlineSmall = default.headlineSmall.inter(FontWeight.SemiBold),
    titleLarge = default.titleLarge.inter(FontWeight.SemiBold),
    titleMedium = default.titleMedium.inter(FontWeight.SemiBold),
    titleSmall = default.titleSmall.inter(FontWeight.SemiBold),
    bodyLarge = default.bodyLarge.inter().copy(lineHeight = 24.sp),
    bodyMedium = default.bodyMedium.inter(),
    bodySmall = default.bodySmall.inter(),
    labelLarge = default.labelLarge.inter(FontWeight.Medium),
    labelMedium = default.labelMedium.inter(FontWeight.Medium),
    labelSmall = default.labelSmall.inter(FontWeight.Medium),
)

/** The Mac's text roles (tokens.json "type") on Material 3 styles. */
object LokalBotType {
    val pageTitle: TextStyle
        @Composable @ReadOnlyComposable get() = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.Bold)
    val question: TextStyle
        @Composable @ReadOnlyComposable get() = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.SemiBold)
    val columnTitle: TextStyle
        @Composable @ReadOnlyComposable get() = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
    val section: TextStyle
        @Composable @ReadOnlyComposable get() = MaterialTheme.typography.titleSmall
    val body: TextStyle
        @Composable @ReadOnlyComposable get() = MaterialTheme.typography.bodyLarge
    val reading: TextStyle
        @Composable @ReadOnlyComposable get() = MaterialTheme.typography.bodyLarge.copy(lineHeight = 25.sp)
    val secondary: TextStyle
        @Composable @ReadOnlyComposable get() = MaterialTheme.typography.bodyMedium
    val caption: TextStyle
        @Composable @ReadOnlyComposable get() = MaterialTheme.typography.bodySmall
    val sectionHeader: TextStyle
        @Composable @ReadOnlyComposable get() = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.SemiBold)

    /** Times and durations: tabular figures so columns line up. */
    val timestamp: TextStyle
        @Composable @ReadOnlyComposable get() = MaterialTheme.typography.bodyMedium.copy(fontFeatureSettings = "tnum")
}
