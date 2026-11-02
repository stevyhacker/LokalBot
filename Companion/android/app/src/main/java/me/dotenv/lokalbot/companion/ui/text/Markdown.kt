package me.dotenv.lokalbot.companion.ui.text

import me.dotenv.lokalbot.companion.data.model.AskCitation

/**
 * The small Markdown subset the Mac writes into summaries, digests, notes and
 * answers: headings, bullet and numbered lists, paragraphs, **bold**,
 * *italic*, `code` and `[n]` citation markers.
 */
object Markdown {

    sealed interface Block {
        data class Heading(val level: Int, val text: String) : Block
        data class Bullet(val text: String, val number: Int? = null, val depth: Int = 0) : Block
        data class Paragraph(val text: String) : Block
    }

    sealed interface Inline {
        data class Run(val text: String, val bold: Boolean = false, val italic: Boolean = false, val code: Boolean = false) : Inline
        data class Cite(val index: Int) : Inline
    }

    private val headingPattern = Regex("^(#{1,6})\\s+(.*)$")
    private val bulletPattern = Regex("^(\\s*)[-*+•]\\s+(.*)$")
    private val numberedPattern = Regex("^(\\s*)(\\d+)[.)]\\s+(.*)$")
    private val inlinePattern = Regex("\\*\\*(.+?)\\*\\*|`([^`]+)`|(?<![\\w*])[*_]([^*_\\s][^*_]*?)[*_](?![\\w*])|\\[(\\d+)]")

    fun blocks(markdown: String): List<Block> {
        val blocks = mutableListOf<Block>()
        val paragraph = StringBuilder()
        fun flush() {
            if (paragraph.isNotBlank()) blocks += Block.Paragraph(paragraph.toString().trim())
            paragraph.clear()
        }
        for (raw in markdown.lines()) {
            val line = raw.trimEnd()
            val heading = headingPattern.matchEntire(line.trim())
            val bullet = bulletPattern.matchEntire(line)
            val numbered = numberedPattern.matchEntire(line)
            when {
                line.isBlank() -> flush()
                heading != null -> { flush(); blocks += Block.Heading(heading.groupValues[1].length, heading.groupValues[2].trim()) }
                bullet != null -> { flush(); blocks += Block.Bullet(bullet.groupValues[2].trim(), depth = bullet.groupValues[1].length / 2) }
                numbered != null -> { flush(); blocks += Block.Bullet(numbered.groupValues[3].trim(), numbered.groupValues[2].toInt(), numbered.groupValues[1].length / 2) }
                else -> paragraph.append(if (paragraph.isEmpty()) line.trim() else " " + line.trim())
            }
        }
        flush()
        return blocks
    }

    /** The Markdown under the heading [title] (any level), up to the next heading at that level or above. */
    fun section(markdown: String, title: String): String? {
        val lines = markdown.lines()
        val start = lines.indexOfFirst { headingPattern.matchEntire(it.trim())?.groupValues?.get(2)?.trim().equals(title, ignoreCase = true) }
        if (start < 0) return null
        val level = headingPattern.matchEntire(lines[start].trim())!!.groupValues[1].length
        val end = (start + 1 until lines.size).firstOrNull { i ->
            headingPattern.matchEntire(lines[i].trim())?.let { it.groupValues[1].length <= level } == true
        } ?: lines.size
        return lines.subList(start + 1, end).joinToString("\n").trim().takeIf { it.isNotEmpty() }
    }

    /** Inline runs; `[n]` becomes a citation only when [citations] contains n. */
    fun inline(text: String, citations: Set<Int> = emptySet(), bold: Boolean = false, italic: Boolean = false): List<Inline> {
        val out = mutableListOf<Inline>()
        var last = 0
        fun plain(until: Int) {
            if (until > last) out += Inline.Run(text.substring(last, until), bold = bold, italic = italic)
        }
        for (match in inlinePattern.findAll(text)) {
            val (strong, code, emphasis, cite) = match.destructured
            when {
                strong.isNotEmpty() -> { plain(match.range.first); out += inline(strong, citations, bold = true, italic = italic) }
                code.isNotEmpty() -> { plain(match.range.first); out += Inline.Run(code, bold = bold, italic = italic, code = true) }
                emphasis.isNotEmpty() -> { plain(match.range.first); out += inline(emphasis, citations, bold = bold, italic = true) }
                cite.isNotEmpty() && cite.toInt() in citations -> { plain(match.range.first); out += Inline.Cite(cite.toInt()) }
                else -> continue
            }
            last = match.range.last + 1
        }
        plain(text.length)
        return out.mergeRuns()
    }

    private fun List<Inline>.mergeRuns(): List<Inline> = fold(mutableListOf()) { acc, item ->
        val previous = acc.lastOrNull()
        if (item is Inline.Run && previous is Inline.Run && previous.copy(text = "") == item.copy(text = "")) {
            acc[acc.lastIndex] = previous.copy(text = previous.text + item.text)
        } else {
            acc += item
        }
        acc
    }

    /** Plain text for previews and accessibility: no markers. */
    fun plainText(markdown: String): String = blocks(markdown).joinToString(" ") { block ->
        val text = when (block) {
            is Block.Heading -> block.text
            is Block.Bullet -> block.text
            is Block.Paragraph -> block.text
        }
        inline(text).joinToString("") { (it as? Inline.Run)?.text.orEmpty() }
    }
}

/**
 * Normalises an answer's citation markers: `[1, 2]` becomes `[1][2]`, and
 * the Mac's `[meeting:ID@HH:MM:SS]` markers become numbered citations that
 * open the meeting at that moment.
 */
object Citations {
    data class Parsed(val answer: String, val citations: List<AskCitation>)

    private val groupPattern = Regex("\\[(\\d+(?:\\s*,\\s*\\d+)+)]")
    private val meetingPattern = Regex("\\[meeting:([0-9A-Za-z-]+)@(\\d{1,2}):(\\d{2})(?::(\\d{2}))?]")

    fun parse(answer: String, citations: List<AskCitation>): Parsed {
        val all = citations.toMutableList()
        var text = groupPattern.replace(answer) { match ->
            match.groupValues[1].split(',').joinToString("") { "[${it.trim()}]" }
        }
        text = meetingPattern.replace(text) { match ->
            val (meetingId, a, b, c) = match.destructured
            val seconds = if (c.isEmpty()) a.toInt() * 60 + b.toInt() else a.toInt() * 3600 + b.toInt() * 60 + c.toInt()
            val existing = all.firstOrNull { it.meetingId == meetingId && it.at == seconds.toDouble() }
            val index = existing?.index ?: ((all.maxOfOrNull { it.index } ?: 0) + 1).also { next ->
                all += AskCitation(index = next, meetingId = meetingId, at = seconds.toDouble())
            }
            "[$index]"
        }
        return Parsed(text, all.sortedBy { it.index })
    }
}
