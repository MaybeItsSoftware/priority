package uk.co.maybeitsadam.priority.ui.lists

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import uk.co.maybeitsadam.priority.ui.components.EmptyState
import uk.co.maybeitsadam.priority.ui.components.PriorityTopBar
import uk.co.maybeitsadam.priority.ui.navigation.ListRoute

/** Stub: the Lists slice replaces this. */
@Composable
fun ListScreen(route: ListRoute) {
    Column {
        PriorityTopBar(if (route.listId == null) "Everything" else "List")
        EmptyState("List")
    }
}
