package uk.co.maybeitsadam.priority.ui.inspector

import androidx.compose.runtime.Composable
import uk.co.maybeitsadam.priority.ui.components.EmptyState

/**
 * Stub: the inspector slice replaces this. [asSheet] is true inside the phone's
 * bottom sheet and false in the wide-screen side pane.
 */
@Composable
fun TaskInspector(taskId: String, asSheet: Boolean, onClose: () -> Unit) {
    EmptyState("Task $taskId")
}
