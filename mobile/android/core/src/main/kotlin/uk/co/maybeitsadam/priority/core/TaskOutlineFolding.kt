package uk.co.maybeitsadam.priority.core

/**
 * Folding a depth-first outline: a folded task stays and everything beneath it
 * goes. Port of `TaskOutlineFolding.swift`.
 */
object TaskOutlineFolding {
    /** The rows still drawn once every folded task's descendants are removed. */
    fun visible(items: List<TaskOutlineItem>, folded: Set<String>): List<TaskOutlineItem> {
        if (folded.isEmpty()) return items
        var hiddenBelow: Int? = null
        return items.filter { item ->
            val depth = hiddenBelow
            if (depth != null) {
                if (item.depth > depth) return@filter false
                hiddenBelow = null
            }
            if (item.id in folded) hiddenBelow = item.depth
            true
        }
    }

    /** Every row with something beneath it, read from the unfolded outline. */
    fun parentIDs(items: List<TaskOutlineItem>): Set<String> {
        val result = mutableSetOf<String>()
        for (i in 0 until items.size - 1) if (items[i + 1].depth > items[i].depth) result += items[i].id
        return result
    }

    /** The nearest earlier row one level up; null at the top or when absent. */
    fun parentID(id: String, items: List<TaskOutlineItem>): String? {
        val index = items.indexOfFirst { it.id == id }
        if (index < 0) return null
        val depth = items[index].depth
        return items.subList(0, index).lastOrNull { it.depth < depth }?.id
    }

    /** The first row beneath a row, if it has one. */
    fun firstChildID(id: String, items: List<TaskOutlineItem>): String? {
        val index = items.indexOfFirst { it.id == id }
        if (index < 0 || index + 1 >= items.size || items[index + 1].depth <= items[index].depth) return null
        return items[index + 1].id
    }

    /** Every row beneath a row, at any depth. */
    fun descendantIDs(id: String, items: List<TaskOutlineItem>): List<String> {
        val index = items.indexOfFirst { it.id == id }
        if (index < 0) return emptyList()
        val depth = items[index].depth
        return items.drop(index + 1).takeWhile { it.depth > depth }.map { it.id }
    }
}
