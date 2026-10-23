package uk.co.maybeitsadam.takt.ui.quickadd

import androidx.compose.runtime.Immutable
import java.time.Instant
import java.time.ZoneId
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import uk.co.maybeitsadam.takt.core.TaskCapture

/** What kind of token a chip shows, which decides its colour. */
enum class CaptureChipKind { ESTIMATE, START, DUE, TAG, PRIORITY, WAITING }

@Immutable
data class CaptureChip(val label: String, val kind: CaptureChipKind, val priority: Int? = null)

/**
 * What the add field will file, read the way the store reads it
 * (`TaskCapture.parse`): the title left after the trailing tokens, a chip per
 * token in `detailLabels` order (estimate, start, due, tags, priority), and
 * why it would be refused — a start on or after the due day — if it would.
 */
@Immutable
data class CapturePreview(
    val title: String,
    val chips: ImmutableList<CaptureChip>,
    val problem: String? = null,
) {
    /** Not with a problem: the text stays, with the reason, until a day changes. */
    val canAdd: Boolean get() = title.isNotBlank() && problem == null

    /** Read aloud for the chip row: "Will set 30m, due Fri 2 Oct, #work". */
    val spoken: String get() = if (chips.isEmpty()) "" else
        listOfNotNull("Will set ${chips.joinToString(", ") { it.label }}", problem).joinToString(". ")

    companion object {
        val Empty = CapturePreview("", persistentListOf())

        fun of(text: String, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): CapturePreview {
            if (text.isBlank()) return Empty
            val capture = TaskCapture.parse(text, now, zone)
            val labels = capture.detailLabels(now, zone)
            val chips = ArrayList<CaptureChip>(labels.size)
            var next = 0
            if (capture.estimateSeconds != null) chips += CaptureChip(labels[next++], CaptureChipKind.ESTIMATE)
            if (capture.startAt != null) chips += CaptureChip(labels[next++], CaptureChipKind.START)
            if (capture.dueAt != null) chips += CaptureChip(labels[next++], CaptureChipKind.DUE)
            repeat(capture.tags.size) { chips += CaptureChip(labels[next++], CaptureChipKind.TAG) }
            if (capture.priority != null) chips += CaptureChip(labels[next++], CaptureChipKind.PRIORITY, capture.priority)
            if (capture.waitingOn != null) chips += CaptureChip(labels[next], CaptureChipKind.WAITING)
            return CapturePreview(capture.title, chips.toImmutableList(), capture.problem)
        }

        /** The syntax, in one line under the field. */
        const val HINT = "End with 30m, @fri, ^mon, #tag or !1 to set an estimate, due day, start day, tag or priority."
    }
}
