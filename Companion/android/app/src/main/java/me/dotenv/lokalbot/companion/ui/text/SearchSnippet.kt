package me.dotenv.lokalbot.companion.ui.text

/**
 * A search snippet split into plain text and matched words. The sync core's
 * full-text search marks each match with `«` and `»`; the sample library's
 * search marks nothing, so its snippets come back as one plain part.
 */
object SearchSnippet {
    data class Part(val text: String, val isMatch: Boolean)

    fun parts(snippet: String): List<Part> {
        val parts = mutableListOf<Part>()
        var rest = 0
        while (true) {
            val open = snippet.indexOf(OPEN, rest)
            if (open < 0) break
            if (open > rest) parts += Part(snippet.substring(rest, open), isMatch = false)
            val close = snippet.indexOf(CLOSE, open + 1)
            if (close < 0) {
                // A mark the excerpt cut short: drop it and keep the words.
                rest = open + 1
                break
            }
            parts += Part(snippet.substring(open + 1, close), isMatch = true)
            rest = close + 1
        }
        if (rest < snippet.length) parts += Part(snippet.substring(rest), isMatch = false)
        return parts
    }

    private const val OPEN = '«'
    private const val CLOSE = '»'
}
