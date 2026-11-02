package me.dotenv.lokalbot.companion.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color
import java.text.Normalizer

/**
 * Colors derived from names, identical on every platform.
 */
object BrandColors {

    /**
     * The Mac's `CaptureStyle.color` hue in degrees: djb2 over the UTF-8
     * bytes with 64-bit unsigned wrapping arithmetic (tokens.json "nameColor").
     */
    fun nameHue(name: String): Int {
        var hash: ULong = 5381u
        for (byte in name.encodeToByteArray()) hash = hash * 33u + byte.toUByte().toULong()
        return (hash % 360u).toInt()
    }

    /** App and project colours on the Timeline. "Other" is quiet grey. */
    fun nameColor(name: String, palette: LokalBotPalette): Color =
        if (name == OTHER) palette.textSupporting.copy(alpha = 0.55f)
        else Color.hsv(nameHue(name).toFloat(), LokalBotTokens.NAME_COLOR_SATURATION, LokalBotTokens.NAME_COLOR_BRIGHTNESS)

    /** Speaker colour for a transcript `colorIndex`; -1 (grouped or unknown) is supporting grey. */
    fun speakerColor(index: Int, palette: LokalBotPalette): Color =
        if (index < 0) palette.textSupporting else palette.speakers[index % palette.speakers.size]

    /** The Mac's `InitialsAvatar.color(for:)`: a speaker colour picked from the folded name. */
    fun avatarIndex(name: String): Int {
        var hash = 0
        for (codePoint in normalizedName(name).codePoints()) hash = (hash * 31 + codePoint) and 0xFFFF
        return hash % LokalBotTokens.Light.speakers.size
    }

    fun avatarColor(name: String, palette: LokalBotPalette): Color = palette.speakers[avatarIndex(name)]

    /** `PeopleDirectory.normalized`: case and diacritics folded, words joined by single spaces. */
    fun normalizedName(value: String): String =
        Normalizer.normalize(value, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase()
            .split(Regex("[^\\p{L}\\p{Nd}]+")).filter { it.isNotEmpty() }.joinToString(" ")

    fun initials(name: String): String {
        val words = name.split(' ').filter { word -> word.firstOrNull()?.isLetter() == true }
        val picked = if (words.size >= 2) listOf(words.first(), words.last()) else words.take(1)
        return picked.joinToString("") { it.first().uppercase() }
    }

    const val OTHER = "Other"
}

@Composable
@ReadOnlyComposable
fun nameColor(name: String): Color = BrandColors.nameColor(name, LokalBotTheme.palette)
