package me.dotenv.lokalbot.companion.ui.theme

import com.google.common.truth.Truth.assertThat
import java.math.BigInteger
import org.junit.Test

class BrandColorsTest {

    /**
     * The Mac's `CaptureStyle.color` (LokalBot/Views/CaptureView.swift):
     * `var hash: UInt64 = 5381; hash = hash &* 33 &+ UInt64(byte)`, hue = hash % 360.
     */
    private fun macHue(name: String): Int {
        val modulus = BigInteger.ONE.shiftLeft(64)
        var hash = BigInteger.valueOf(5381)
        for (byte in name.toByteArray(Charsets.UTF_8)) {
            hash = (hash * BigInteger.valueOf(33) + BigInteger.valueOf((byte.toInt() and 0xFF).toLong())).mod(modulus)
        }
        return hash.mod(BigInteger.valueOf(360)).toInt()
    }

    @Test
    fun `name hue matches the Mac`() {
        // Hues the Mac computes for these names.
        val mac = mapOf(
            "Onboarding" to 304, "Pricing" to 25, "Xcode" to 224, "Zoom" to 82, "Other" to 207,
            "Safari" to 339, "Google Meet" to 21, "Claude Code" to 270, "" to 341, "Café Zürich" to 186,
        )
        mac.forEach { (name, hue) ->
            assertThat(BrandColors.nameHue(name)).isEqualTo(hue)
            assertThat(macHue(name)).isEqualTo(hue)
        }
        listOf("日本語のプロジェクト", "a".repeat(200), "Pull Request #212 — Export rework").forEach {
            assertThat(BrandColors.nameHue(it)).isEqualTo(macHue(it))
        }
    }

    @Test
    fun `name colour uses the token saturation and brightness`() {
        val color = BrandColors.nameColor("Pricing", LokalBotTokens.Light)
        val hsv = FloatArray(3)
        java.awt.Color.RGBtoHSB((color.red * 255).toInt(), (color.green * 255).toInt(), (color.blue * 255).toInt(), hsv)
        assertThat(hsv[0] * 360).isWithin(1.5f).of(25f)
        assertThat(hsv[1]).isWithin(0.01f).of(LokalBotTokens.NAME_COLOR_SATURATION)
        assertThat(hsv[2]).isWithin(0.01f).of(LokalBotTokens.NAME_COLOR_BRIGHTNESS)
        assertThat(BrandColors.nameColor("Other", LokalBotTokens.Light).alpha).isWithin(0.01f).of(0.55f)
    }

    @Test
    fun `speaker colours follow the palette and grey out unknown voices`() {
        val palette = LokalBotTokens.Dark
        assertThat(BrandColors.speakerColor(0, palette)).isEqualTo(palette.accentText)
        assertThat(BrandColors.speakerColor(9, palette)).isEqualTo(palette.speakers[1])
        assertThat(BrandColors.speakerColor(-1, palette)).isEqualTo(palette.textSupporting)
    }

    @Test
    fun `avatar colours match the Mac's InitialsAvatar`() {
        // The Mac folds case and diacritics, then hashes Unicode scalars with h * 31 + v, masked to 16 bits.
        fun macIndex(normalized: String): Int {
            var hash = 0
            normalized.codePoints().forEach { hash = (hash * 31 + it) and 0xFFFF }
            return hash % 8
        }
        assertThat(BrandColors.normalizedName("  Zoë  O'Brien ")).isEqualTo("zoe o brien")
        assertThat(BrandColors.avatarIndex("Maya Chen")).isEqualTo(macIndex("maya chen"))
        assertThat(BrandColors.avatarIndex("MAYA chen")).isEqualTo(BrandColors.avatarIndex("Maya Chen"))
        assertThat(BrandColors.initials("Maya Chen")).isEqualTo("MC")
        assertThat(BrandColors.initials("Ben van der Ortiz")).isEqualTo("BO")
        assertThat(BrandColors.initials("Priya")).isEqualTo("P")
    }
}
