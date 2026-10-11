package uk.co.maybeitsadam.takt.ui.inspector

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import uk.co.maybeitsadam.takt.core.TaskStatus
import uk.co.maybeitsadam.takt.core.WorkspaceTask
import uk.co.maybeitsadam.takt.data.workspace.TaskSearchResult
import uk.co.maybeitsadam.takt.ui.theme.Metrics
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme

/**
 * What the task waits on: each blocker with a button to stop waiting on it,
 * what waits on this task, and a search to add a blocker. Written straight
 * away, each as its own undo step, like placement.
 */
@Composable
internal fun BlockedBySection(vm: TaskInspectorViewModel, task: WorkspaceTask, around: InspectorSurroundings) {
    val dependencies = around.dependencies
    var query by rememberSaveable(task.id) { mutableStateOf("") }
    var candidates by remember(task.id) { mutableStateOf(emptyList<TaskSearchResult>()) }
    LaunchedEffect(task.id, query, dependencies) {
        delay(150)
        candidates = vm.blockerCandidates(query)
    }
    InspectorSection("Blocked by", detail = if (dependencies.isBlocked) "Waiting" else null) {
        Column(Modifier.testTag("inspector_blockers")) {
            for (blocker in dependencies.blockers) {
                DependencyRow(blocker) {
                    RemoveButton("Stop waiting on ${blocker.title}") { vm.removeBlocker(blocker.id) }
                }
            }
        }
        ChalkField(
            query,
            onValueChange = { query = it },
            placeholder = "Wait on another task",
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            leading = { Icon(Icons.Filled.Add, contentDescription = null, tint = TaktTheme.colors.mutedText, modifier = Modifier.size(18.dp)) },
            modifier = Modifier.testTag("inspector_blocker_search"),
            contentDescription = "Find a task to wait on",
        )
        if (query.isNotBlank()) {
            Column {
                for (result in candidates) {
                    DependencyRow(
                        result.task,
                        detail = result.list.name,
                        modifier = Modifier.clickable(role = Role.Button, onClickLabel = "Wait on this") {
                            vm.addBlocker(result.task.id)
                            query = ""
                        },
                    )
                }
                if (candidates.isEmpty()) Hint("No open task matches.")
            }
        }
        if (dependencies.blocking.isNotEmpty()) {
            FieldLabel("Waiting on this")
            for (waiting in dependencies.blocking) DependencyRow(waiting)
        }
        Hint("A blocked task sinks below its siblings and stays out of Next up until everything it waits on is done.")
    }
}

/** One task in the section: its title (muted and struck once it is closed) and an optional trailing control. */
@Composable
private fun DependencyRow(
    task: WorkspaceTask,
    modifier: Modifier = Modifier,
    detail: String? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    val colors = TaktTheme.colors
    val closed = task.status != TaskStatus.OPEN
    Row(
        modifier.fillMaxWidth().heightIn(min = Metrics.touchTarget),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.sm),
    ) {
        Text(
            task.title,
            style = TaktTheme.type.body,
            color = if (closed) colors.mutedText else colors.ink,
            textDecoration = if (closed) TextDecoration.LineThrough else null,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        detail?.let { Text(it, style = TaktTheme.type.small, color = colors.mutedText, maxLines = 1) }
        trailing?.invoke()
    }
}

@Composable
private fun RemoveButton(description: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(Metrics.touchTarget)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description }
            .padding(Metrics.xs),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Filled.Close, contentDescription = null, tint = TaktTheme.colors.mutedText, modifier = Modifier.size(18.dp))
    }
}
