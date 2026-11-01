package me.dotenv.lokalbot.companion.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.ui.text.Markdown
import me.dotenv.lokalbot.companion.ui.theme.Inter
import me.dotenv.lokalbot.companion.ui.theme.LokalBotTheme
import me.dotenv.lokalbot.companion.ui.theme.LokalBotType

/** Renders the Mac's Markdown with LokalBot type: no bubbles, an editorial reading column. */
@Composable
fun MarkdownText(
    markdown: String,
    modifier: Modifier = Modifier,
    style: TextStyle = LokalBotType.reading,
    citations: Set<Int> = emptySet(),
    onCitation: (Int) -> Unit = {},
    headingStyle: TextStyle = LokalBotType.section,
) {
    val blocks = remember(markdown) { Markdown.blocks(markdown) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        blocks.forEach { block ->
            when (block) {
                is Markdown.Block.Heading -> Text(
                    block.text,
                    style = headingStyle,
                    modifier = Modifier.padding(top = 6.dp).semantics { heading() },
                )
                is Markdown.Block.Paragraph -> RichText(block.text, style, citations = citations, onCitation = onCitation)
                is Markdown.Block.Bullet -> Row(Modifier.padding(start = (block.depth * 16).dp)) {
                    Text(
                        block.number?.let { "$it." } ?: "•",
                        style = style,
                        color = LokalBotTheme.supportingText,
                        modifier = Modifier.width(if (block.number != null) 24.dp else 16.dp),
                    )
                    RichText(block.text, style, Modifier.weight(1f), citations, onCitation)
                }
            }
        }
    }
}

/** One paragraph with inline formatting and numbered teal citation badges. */
@Composable
fun RichText(
    text: String,
    style: TextStyle,
    modifier: Modifier = Modifier,
    citations: Set<Int> = emptySet(),
    onCitation: (Int) -> Unit = {},
    color: Color = Color.Unspecified,
) {
    val codeBackground = LokalBotTheme.palette.chipFill
    val parts = remember(text, citations) { Markdown.inline(text, citations) }
    val annotated = remember(parts, codeBackground) { annotate(parts, codeBackground) }
    val cited = parts.filterIsInstance<Markdown.Inline.Cite>().map { it.index }.distinct()
    val inlineContent = cited.associate { index ->
        "cite:$index" to InlineTextContent(Placeholder(1.45.em, 1.2.em, PlaceholderVerticalAlign.TextCenter)) {
            InlineSourceBadge(index, onClick = { onCitation(index) })
        }
    }
    Text(annotated, style = style, color = color, inlineContent = inlineContent, modifier = modifier)
}

@Composable
private fun InlineSourceBadge(index: Int, onClick: () -> Unit) {
    val description = stringResource(R.string.ask_source_number, index)
    Box(
        Modifier
            .fillMaxSize()
            .padding(horizontal = 2.dp, vertical = 1.dp)
            .background(LokalBotTheme.palette.accentFill, RoundedCornerShape(4.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            index.toString(),
            style = TextStyle(fontFamily = Inter, fontWeight = FontWeight.SemiBold, fontSize = 11.sp, fontFeatureSettings = "tnum"),
            color = Color.White,
        )
    }
}

private fun annotate(parts: List<Markdown.Inline>, codeBackground: Color): AnnotatedString = buildAnnotatedString {
    for (part in parts) {
        when (part) {
            is Markdown.Inline.Run -> withStyle(
                SpanStyle(
                    fontWeight = if (part.bold) FontWeight.SemiBold else null,
                    fontStyle = if (part.italic) FontStyle.Italic else null,
                    fontFamily = if (part.code) FontFamily.Monospace else null,
                    background = if (part.code) codeBackground else Color.Unspecified,
                ),
            ) { append(part.text) }
            is Markdown.Inline.Cite -> appendInlineContent("cite:${part.index}", "[${part.index}]")
        }
    }
}
