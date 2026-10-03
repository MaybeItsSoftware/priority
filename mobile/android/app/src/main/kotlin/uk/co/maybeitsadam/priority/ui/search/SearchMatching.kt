package uk.co.maybeitsadam.priority.ui.search

/**
 * Where a search's words appear in [text], for highlighting a result. The
 * store matches each word as a prefix of a token (FTS5 prefix queries), so a
 * range starts at a word boundary and covers the typed prefix. Case-insensitive;
 * overlapping ranges are merged; sorted by start.
 */
object SearchMatching {
    fun tokens(query: String): List<String> =
        query.split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }.map { it.lowercase() }.distinct()

    fun ranges(text: String, query: String): List<IntRange> {
        val words = tokens(query)
        if (words.isEmpty() || text.isEmpty()) return emptyList()
        val lower = text.lowercase()
        val found = mutableListOf<IntRange>()
        for (word in words) {
            var from = 0
            while (from <= lower.length - word.length) {
                val index = lower.indexOf(word, from)
                if (index < 0) break
                val atBoundary = index == 0 || !lower[index - 1].isLetterOrDigit()
                if (atBoundary) found += index until index + word.length
                from = index + 1
            }
        }
        val sorted = found.sortedBy { it.first }
        val merged = mutableListOf<IntRange>()
        for (range in sorted) {
            val last = merged.lastOrNull()
            if (last != null && range.first <= last.last + 1) {
                merged[merged.size - 1] = last.first..maxOf(last.last, range.last)
            } else {
                merged += range
            }
        }
        return merged
    }

    /** The next selection for an arrow key: clamps, and starts at the first row from nothing. */
    fun move(selected: Int?, by: Int, count: Int): Int? {
        if (count <= 0) return null
        if (selected == null) return if (by > 0) 0 else count - 1
        return (selected + by).coerceIn(0, count - 1)
    }
}
