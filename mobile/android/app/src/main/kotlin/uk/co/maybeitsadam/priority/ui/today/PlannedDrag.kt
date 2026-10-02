package uk.co.maybeitsadam.priority.ui.today

import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput

/**
 * Dragging a planned card by its handle. The order is held here while the
 * finger is down (so the list re-lays out as cards pass each other) and
 * handed to the ViewModel on release as one write.
 */
@Stable
class PlannedDrag(private val listState: LazyListState) {
    var draggingId by mutableStateOf<String?>(null)
        private set
    var offset by mutableFloatStateOf(0f)
        private set
    var order by mutableStateOf<List<String>?>(null)
        private set

    fun start(id: String, planned: List<String>) {
        if (id !in planned) return
        draggingId = id
        order = planned
        offset = 0f
    }

    fun drag(dy: Float) {
        val id = draggingId ?: return
        val current = order ?: return
        offset += dy
        val visible = listState.layoutInfo.visibleItemsInfo
        val index = current.indexOf(id)
        if (offset > 0 && index < current.lastIndex) {
            val next = visible.firstOrNull { it.key == current[index + 1] } ?: return
            if (offset > next.size / 2f) {
                order = current.swapped(index, index + 1)
                offset -= next.size
            }
        } else if (offset < 0 && index > 0) {
            val previous = visible.firstOrNull { it.key == current[index - 1] } ?: return
            if (-offset > previous.size / 2f) {
                order = current.swapped(index, index - 1)
                offset += previous.size
            }
        }
    }

    /** Ends the drag, returning the order to write (null when nothing was dragged). */
    fun end(): List<String>? {
        val result = order
        draggingId = null
        order = null
        offset = 0f
        return result
    }

    private fun List<String>.swapped(a: Int, b: Int): List<String> = toMutableList().also {
        val t = it[a]
        it[a] = it[b]
        it[b] = t
    }
}

@Composable
fun rememberPlannedDrag(listState: LazyListState): PlannedDrag = remember(listState) { PlannedDrag(listState) }

/** The handle's gesture: press and drag to move the card through the planned cards. */
@Composable
fun Modifier.plannedDragHandle(drag: PlannedDrag, id: String, plannedIds: List<String>, onDrop: (List<String>) -> Unit): Modifier {
    val planned by rememberUpdatedState(plannedIds)
    val drop by rememberUpdatedState(onDrop)
    return pointerInput(drag, id) {
        detectDragGestures(
            onDragStart = { drag.start(id, planned) },
            onDragEnd = { drag.end()?.let(drop) },
            onDragCancel = { drag.end() },
        ) { change, amount ->
            change.consume()
            drag.drag(amount.y)
        }
    }
}
