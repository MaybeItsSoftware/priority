package uk.co.maybeitsadam.takt.ui.inspector

import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import java.time.ZoneId
import uk.co.maybeitsadam.takt.core.TaskCalendarDate
import uk.co.maybeitsadam.takt.data.workspace.TaskEditorDraft
import uk.co.maybeitsadam.takt.data.workspace.TaskEditorField
import uk.co.maybeitsadam.takt.data.workspace.TaskEditorValues
import uk.co.maybeitsadam.takt.ui.components.EmptyState
import uk.co.maybeitsadam.takt.ui.components.Format
import uk.co.maybeitsadam.takt.ui.components.Hairline
import uk.co.maybeitsadam.takt.ui.components.IconAction
import uk.co.maybeitsadam.takt.ui.components.PButton
import uk.co.maybeitsadam.takt.ui.components.TaktTopBar
import uk.co.maybeitsadam.takt.ui.navigation.LocalShell
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme
import uk.co.maybeitsadam.takt.ui.theme.Metrics

/**
 * Every field of a task. The phone's bottom sheet ([asSheet]) or the wide
 * screen's side pane, both hosted by the shell.
 *
 * Edits collect in a draft and are written by Save as one "Edit Task" step,
 * as on the Mac. Closing with unsaved changes asks first; the sheet swiped
 * away, or another task picked, saves what can be saved (the Mac's flush).
 */
@Composable
fun TaskInspector(taskId: String, asSheet: Boolean, onClose: () -> Unit) {
    val container = LocalShell.current.container
    val vm: TaskInspectorViewModel = viewModel(key = "task_inspector") { TaskInspectorViewModel(container) }
    LaunchedEffect(vm, taskId) { vm.bind(taskId) }
    val activity = LocalActivity.current
    DisposableEffect(vm) {
        onDispose { if (activity?.isChangingConfigurations != true) vm.release() }
    }

    val draftState by vm.draft.collectAsStateWithLifecycle()
    val around by vm.surroundings.collectAsStateWithLifecycle()
    val save by vm.saveState.collectAsStateWithLifecycle()
    val draft = draftState?.takeIf { it.baseline.taskId == taskId }
    val dirty = draft?.isDirty == true
    var closePrompt by rememberSaveable(taskId) { mutableStateOf(false) }
    val requestClose = { if (dirty) closePrompt = true else onClose() }
    BackHandler(enabled = dirty && !closePrompt) { closePrompt = true }
    LaunchedEffect(dirty) { if (!dirty) closePrompt = false }

    Column(
        Modifier
            .fillMaxSize()
            .background(TaktTheme.colors.paper)
            .then(if (asSheet) Modifier.imePadding() else Modifier)
            .testTag("inspector"),
    ) {
        TaktTopBar(
            title = if (around.task?.isList == true) "List" else "Task",
            subtitle = around.listName.ifEmpty { null },
            showHistory = false,
            insetStatusBar = !asSheet,
        ) {
            IconAction(Icons.Filled.Close, "Close inspector", tint = TaktTheme.colors.mutedText, onClick = requestClose)
        }
        val task = around.task?.takeIf { it.id == taskId }
        if (draft == null || task == null) {
            if (draftState == null && around.task == null) EmptyState("Loading…") else EmptyState("Task unavailable", detail = "It may have been deleted.")
            return@Column
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            InspectorBody(
                vm = vm,
                draft = draft,
                around = around,
                task = task,
                onClose = onClose,
                modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
            )
        }
        if (dirty || save.error != null || closePrompt) {
            UnsavedBar(
                draft = draft,
                save = save,
                closing = closePrompt,
                onSave = { vm.saveAsync { saved -> if (saved && closePrompt) onClose() } },
                onDiscard = {
                    vm.discard()
                    if (closePrompt) onClose()
                },
                onKeepEditing = { closePrompt = false },
            )
        }
    }
}

/** Sticky under the form while the draft differs from what is saved. */
@Composable
private fun UnsavedBar(
    draft: TaskEditorDraft,
    save: SaveState,
    closing: Boolean,
    onSave: () -> Unit,
    onDiscard: () -> Unit,
    onKeepEditing: () -> Unit,
) {
    val colors = TaktTheme.colors
    val blocked = draft.conflicts.isNotEmpty() || draft.isUnavailable
    Column(Modifier.fillMaxWidth().background(colors.paper).testTag("inspector_unsaved")) {
        Hairline()
        Column(
            Modifier.fillMaxWidth().padding(horizontal = Metrics.lg, vertical = Metrics.sm),
            verticalArrangement = Arrangement.spacedBy(Metrics.xs),
        ) {
            val message = when {
                save.error != null -> save.error
                closing -> "Save your changes before closing?"
                draft.conflicts.isNotEmpty() -> "Resolve the changed fields above before saving."
                else -> "Unsaved changes"
            }
            Text(
                message,
                style = TaktTheme.type.small,
                color = if (save.error != null) colors.danger else colors.mutedText,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.sm), verticalAlignment = Alignment.CenterVertically) {
                if (closing) {
                    PButton("Keep editing", onClick = onKeepEditing)
                    Spacer(Modifier.weight(1f))
                } else {
                    Spacer(Modifier.weight(1f))
                }
                PButton("Discard", destructive = closing, onClick = onDiscard)
                PButton(
                    if (save.saving) "Saving…" else if (closing) "Save and close" else "Save",
                    primary = true,
                    enabled = !blocked && !save.saving && draft.isDirty,
                    onClick = onSave,
                    modifier = Modifier.testTag("inspector_save"),
                )
            }
        }
    }
}

/** One banner per field changed both here and in the saved task. */
@Composable
internal fun ConflictBanners(vm: TaskInspectorViewModel, draft: TaskEditorDraft, around: InspectorSurroundings) {
    val colors = TaktTheme.colors
    val zone = remember { ZoneId.systemDefault() }
    val fields by remember(draft) { derivedStateOf { TaskEditorField.entries.filter { it in draft.conflicts } } }
    for (field in fields) {
        Column(
            Modifier
                .padding(horizontal = Metrics.lg, vertical = Metrics.xs)
                .fillMaxWidth()
                .background(colors.warning.copy(alpha = 0.08f), Metrics.control)
                .border(BorderStroke(Metrics.hairline, colors.warning.copy(alpha = 0.4f)), Metrics.control)
                .padding(Metrics.md)
                .testTag("inspector_conflict_${field.name}"),
            verticalArrangement = Arrangement.spacedBy(Metrics.xs),
        ) {
            Text("${field.label} changed in the saved task", style = TaktTheme.type.bodyStrong, color = colors.ink)
            Text("Saved: ${display(field, draft.baseline.values, around, zone)}", style = TaktTheme.type.small, color = colors.mutedText, maxLines = 3)
            Text("Yours: ${display(field, draft.values, around, zone)}", style = TaktTheme.type.small, color = colors.mutedText, maxLines = 3)
            Spacer(Modifier.height(Metrics.xxs))
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.sm)) {
                PButton("Keep mine", onClick = { vm.resolve(field, useSaved = false) })
                PButton("Use saved", onClick = { vm.resolve(field, useSaved = true) })
            }
        }
    }
}

/** A field's value written out for a conflict banner. */
private fun display(field: TaskEditorField, values: TaskEditorValues, around: InspectorSurroundings, zone: ZoneId): String =
    when (field) {
        TaskEditorField.TITLE -> values.title
        TaskEditorField.NOTES -> values.notes.ifEmpty { "Empty" }
        TaskEditorField.DUE_AT -> values.dueAt?.let { Format.due(it, zone) } ?: "None"
        TaskEditorField.ESTIMATE_MINUTES -> if (values.estimateMinutes.isBlank()) "None" else "${values.estimateMinutes} minutes"
        TaskEditorField.PRIORITY -> PriorityLabels.label(values.priority)
        TaskEditorField.TAGS -> values.tags.ifEmpty { "None" }
        TaskEditorField.RECURRENCE_RULE -> values.recurrenceRule.ifEmpty { "None" }
        TaskEditorField.LINKS -> values.links.ifEmpty { "None" }
        TaskEditorField.DAILY_PROGRESS -> if (values.dailyProgress) "On" else "Off"
        TaskEditorField.START_AT -> values.startAt?.let { Format.due(it, zone) } ?: "None"
        TaskEditorField.DUE_DATE -> values.dueDate?.let { raw -> TaskCalendarDate.date(raw, zone)?.let { Format.day(it, zone) } ?: raw } ?: "None"
        TaskEditorField.REQUIREMENTS -> values.requirementGroups.orEmpty()
            .joinToString(" and ") { group -> group.joinToString(" or ") { around.conditionName(it) } }
            .ifEmpty { "None" }
        TaskEditorField.MINIMUM_BLOCK -> values.minimumBlockMinutes?.let { "$it minutes" } ?: "None"
        TaskEditorField.SINGLE_SITTING -> if (values.requiresSingleSitting == true) "Required" else "Not required"
    }
