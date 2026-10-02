package uk.co.maybeitsadam.priority.ui.today

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import uk.co.maybeitsadam.priority.ui.components.EmptyState
import uk.co.maybeitsadam.priority.ui.components.PriorityTopBar
import uk.co.maybeitsadam.priority.ui.components.SettingsAction

/** Stub: the Today slice replaces this. */
@Composable
fun TodayScreen() {
    Column {
        PriorityTopBar("Today", actions = { SettingsAction() })
        EmptyState("Today")
    }
}
