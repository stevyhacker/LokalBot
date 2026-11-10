package me.dotenv.lokalbot.companion.ui.text

import com.google.common.truth.Truth.assertThat
import me.dotenv.lokalbot.companion.ui.text.SearchSnippet.Part
import org.junit.Test

class SearchSnippetTest {

    @Test
    fun `the sync core's marks become matches`() {
        assertThat(SearchSnippet.parts("…we keep «three» pricing «tiers».")).containsExactly(
            Part("…we keep ", isMatch = false),
            Part("three", isMatch = true),
            Part(" pricing ", isMatch = false),
            Part("tiers", isMatch = true),
            Part(".", isMatch = false),
        ).inOrder()
        assertThat(SearchSnippet.parts("«Pricing» review")).containsExactly(
            Part("Pricing", isMatch = true),
            Part(" review", isMatch = false),
        ).inOrder()
    }

    @Test
    fun `a snippet without marks stays one plain part`() {
        assertThat(SearchSnippet.parts("Share pricing tiers with legal")).containsExactly(Part("Share pricing tiers with legal", isMatch = false))
        assertThat(SearchSnippet.parts("")).isEmpty()
    }

    @Test
    fun `a mark cut short is dropped and its words kept`() {
        assertThat(SearchSnippet.parts("open «only").joinToString("") { it.text }).isEqualTo("open only")
        assertThat(SearchSnippet.parts("open «only").none { it.isMatch }).isTrue()
    }
}
