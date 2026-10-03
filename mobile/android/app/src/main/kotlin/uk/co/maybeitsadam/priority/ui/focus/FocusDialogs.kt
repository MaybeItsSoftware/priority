package uk.co.maybeitsadam.priority.ui.focus

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import java.time.LocalTime
import uk.co.maybeitsadam.priority.ui.components.Tag
import uk.co.maybeitsadam.priority.ui.theme.PriorityTheme
import uk.co.maybeitsadam.priority.ui.theme.Metrics

/** A flat Chalk alert: paper, 8dp, no tonal tint. */
@Composable
fun ChalkDialog(
    title: String,
    onDismiss: () -> Unit,
    confirm: String,
    onConfirm: () -> Unit,
    confirmEnabled: Boolean = true,
    dismiss: String = "Cancel",
    content: @Composable () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, style = PriorityTheme.type.heading, color = PriorityTheme.colors.ink) },
        text = content,
        confirmButton = {
            TextButton(onClick = onConfirm, enabled = confirmEnabled) { Text(confirm, style = PriorityTheme.type.bodyStrong, color = if (confirmEnabled) PriorityTheme.colors.primary else PriorityTheme.colors.dimText) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(dismiss, style = PriorityTheme.type.body, color = PriorityTheme.colors.mutedText) } },
        containerColor = PriorityTheme.colors.paper,
        tonalElevation = 0.dp,
        shape = Metrics.card,
    )
}

/** Picks a time of day (24-hour), for "until" and "pick a time". */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TimeOfDayDialog(title: String, initial: LocalTime, onPick: (LocalTime) -> Unit, onDismiss: () -> Unit) {
    val state = rememberTimePickerState(initial.hour, initial.minute, is24Hour = true)
    ChalkDialog(title, onDismiss, "Set", onConfirm = { onPick(LocalTime.of(state.hour, state.minute)) }) {
        TimePicker(state)
    }
}

/** A number of minutes, typed. */
@Composable
fun MinutesDialog(title: String, initial: Int, onPick: (Int) -> Unit, onDismiss: () -> Unit) {
    var text by rememberSaveable { mutableStateOf(initial.toString()) }
    val minutes = text.trim().toIntOrNull()?.takeIf { it in 1..720 }
    ChalkDialog(title, onDismiss, "Set", onConfirm = { minutes?.let(onPick) }, confirmEnabled = minutes != null) {
        ChalkField(text, { text = it.filter(Char::isDigit).take(3) }, "Minutes", KeyboardType.Number)
    }
}

/** A new condition: a place, a tool or a state some tasks need. */
@Composable
fun NewConditionDialog(onCreate: (name: String, isLocation: Boolean) -> Unit, onDismiss: () -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    var isPlace by rememberSaveable { mutableStateOf(false) }
    ChalkDialog("New condition", onDismiss, "Add", onConfirm = { onCreate(name, isPlace) }, confirmEnabled = name.isNotBlank()) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.sm)) {
            Text("A place, a tool or a state you need to be in for some tasks.", style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText)
            ChalkField(name, { name = it }, "Name", KeyboardType.Text)
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.sm)) {
                Tag("Condition", selected = !isPlace, color = if (!isPlace) PriorityTheme.colors.primary else PriorityTheme.colors.mutedText) { isPlace = false }
                Tag("Place", selected = isPlace, color = if (isPlace) PriorityTheme.colors.primary else PriorityTheme.colors.mutedText) { isPlace = true }
            }
        }
    }
}

@Composable
private fun ChalkField(value: String, onChange: (String) -> Unit, label: String, keyboard: KeyboardType) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label, style = PriorityTheme.type.small) },
        singleLine = true,
        // 16sp: anything smaller makes some keyboards zoom.
        textStyle = PriorityTheme.type.field.copy(color = PriorityTheme.colors.ink),
        keyboardOptions = KeyboardOptions(keyboardType = keyboard),
        shape = Metrics.control,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = PriorityTheme.colors.primary,
            unfocusedBorderColor = PriorityTheme.colors.inputBorder,
            focusedLabelColor = PriorityTheme.colors.primary,
            unfocusedLabelColor = PriorityTheme.colors.mutedText,
            cursorColor = PriorityTheme.colors.primary,
            focusedContainerColor = PriorityTheme.colors.raised,
            unfocusedContainerColor = PriorityTheme.colors.raised,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}
