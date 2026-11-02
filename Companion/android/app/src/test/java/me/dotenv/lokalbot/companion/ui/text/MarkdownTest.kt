package me.dotenv.lokalbot.companion.ui.text

import com.google.common.truth.Truth.assertThat
import me.dotenv.lokalbot.companion.data.model.AskCitation
import me.dotenv.lokalbot.companion.ui.text.Markdown.Block
import me.dotenv.lokalbot.companion.ui.text.Markdown.Inline
import org.junit.Test

class MarkdownTest {

    @Test
    fun `blocks cover headings, lists and paragraphs`() {
        val blocks = Markdown.blocks("## Recap\nThe team cut\nonboarding.\n\n- **You:** Send the deck\n  - nested\n1. First\n")
        assertThat(blocks).containsExactly(
            Block.Heading(2, "Recap"),
            Block.Paragraph("The team cut onboarding."),
            Block.Bullet("**You:** Send the deck"),
            Block.Bullet("nested", depth = 1),
            Block.Bullet("First", number = 1),
        ).inOrder()
    }

    @Test
    fun `section returns the text under a heading`() {
        val summary = "## Recap\nOn track.\n\n## Action items\n- Review\n\n## Decisions\n- Ship"
        assertThat(Markdown.section(summary, "Recap")).isEqualTo("On track.")
        assertThat(Markdown.section(summary, "action items")).isEqualTo("- Review")
        assertThat(Markdown.section(summary, "Open questions")).isNull()
    }

    @Test
    fun `inline runs keep bold, italic and code`() {
        assertThat(Markdown.inline("**You:** send *now* via `mail`")).containsExactly(
            Inline.Run("You:", bold = true),
            Inline.Run(" send "),
            Inline.Run("now", italic = true),
            Inline.Run(" via "),
            Inline.Run("mail", code = true),
        ).inOrder()
        assertThat(Markdown.inline("snake_case_name stays")).containsExactly(Inline.Run("snake_case_name stays"))
    }

    @Test
    fun `citation markers become badges only when the citation exists`() {
        assertThat(Markdown.inline("Three steps [1] and five customers [2]. See [3].", citations = setOf(1, 2))).containsExactly(
            Inline.Run("Three steps "),
            Inline.Cite(1),
            Inline.Run(" and five customers "),
            Inline.Cite(2),
            Inline.Run(". See [3]."),
        ).inOrder()
    }

    @Test
    fun `grouped and meeting citations are normalised`() {
        val existing = listOf(AskCitation(index = 1, meetingId = "m1", at = 724.0, label = "Design review · 12:04"))
        val parsed = Citations.parse("Cut to three steps [1, 2]. Flag first [meeting:3f6c2a10-8a4e@00:31:10].", existing)
        assertThat(parsed.answer).isEqualTo("Cut to three steps [1][2]. Flag first [2].")
        assertThat(parsed.citations.map { it.index }).containsExactly(1, 2).inOrder()
        assertThat(parsed.citations[1].meetingId).isEqualTo("3f6c2a10-8a4e")
        assertThat(parsed.citations[1].at).isEqualTo(1870.0)

        val minutes = Citations.parse("[meeting:abc@12:04]", emptyList())
        assertThat(minutes.answer).isEqualTo("[1]")
        assertThat(minutes.citations.single().at).isEqualTo(724.0)
    }

    @Test
    fun `plain text drops markers`() {
        assertThat(Markdown.plainText("## Highlights\n- **Agreed** a flow")).isEqualTo("Highlights Agreed a flow")
    }
}
