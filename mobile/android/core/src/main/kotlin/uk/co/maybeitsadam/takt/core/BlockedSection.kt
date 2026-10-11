package uk.co.maybeitsadam.takt.core

/**
 * Where the "Blocked" label goes in a list of tasks. Port of
 * `BlockedSection.swift`.
 *
 * Blocked tasks sink below their open siblings (the core's ordering), so each
 * group of siblings — an outline parent's children, a board column's cards —
 * ends with its blocked ones. A quiet label above the first of them says what
 * they are, once per group, rather than leaving the fading to say it alone.
 */
object BlockedSection {
    /**
     * The ids to draw the label above: in each group, the first of the run of
     * blocked tasks the group ends with. A blocked task with an unblocked one
     * after it in its group — a stale read, say — is faded but not labelled,
     * since a label there would head a section that is not all blocked.
     *
     * [items] are the rows in drawing order, each with the group it belongs
     * to. A group's rows need not be contiguous: an outline draws a sibling's
     * subtasks between it and the next sibling.
     */
    fun <G> labelledIds(items: List<Pair<String, G>>, blocked: Set<String>): Set<String> {
        if (blocked.isEmpty()) return emptySet()
        // Walked from the end: a group's run is open until a row of it that is
        // not blocked closes it.
        val runStart = HashMap<G, String>()
        val closed = HashSet<G>()
        for (index in items.indices.reversed()) {
            val (id, group) = items[index]
            if (group in closed) continue
            if (id in blocked) runStart[group] = id else closed += group
        }
        return runStart.values.toSet()
    }
}
