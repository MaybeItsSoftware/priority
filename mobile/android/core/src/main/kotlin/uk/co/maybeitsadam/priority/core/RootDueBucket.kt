package uk.co.maybeitsadam.priority.core

/** Port of `RootDueBucket.swift`; `raw` is the Swift `Int` raw value. */
enum class RootDueBucket(val raw: Int, val title: String) {
    OVERDUE(0, "Overdue"),
    ASAP(1, "ASAP"),
    TODAY(2, "Today"),
    TOMORROW(3, "Tomorrow"),
    NEXT_SEVEN_DAYS(4, "Next 7 days"),
    FUTURE(5, "Further in the future"),
    NO_DUE_DATE(6, "No due date");

    companion object {
        fun of(raw: Int): RootDueBucket? = entries.firstOrNull { it.raw == raw }
    }
}
