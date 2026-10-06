package uk.co.maybeitsadam.takt.ui.settings

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import uk.co.maybeitsadam.takt.core.WorkspaceExportFormat
import uk.co.maybeitsadam.takt.ui.components.PButton
import uk.co.maybeitsadam.takt.ui.theme.Metrics
import uk.co.maybeitsadam.takt.ui.theme.TaktTheme

/**
 * "Your data": the whole workspace written out through the system's save
 * dialog, in the Mac's Markdown or JSON (Takt/WorkspaceViewModel+Export.swift),
 * so a file from either opens the same way.
 */
@Composable
internal fun DataSection(model: SettingsViewModel) {
    val status by model.exportStatus.collectAsStateWithLifecycle()
    // One launcher per format, so the provider is told the file's real type
    // and keeps the extension rather than appending its own.
    val launchers = WorkspaceExportFormat.entries.associateWith { format ->
        rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(format.mimeType)) { uri ->
            uri?.let { model.export(format, it) }
        }
    }
    Section("Your data", footer = "Markdown reads anywhere; JSON keeps every field, for a backup or a script.") {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = Metrics.md, vertical = Metrics.sm),
            verticalArrangement = Arrangement.spacedBy(Metrics.sm),
        ) {
            Column {
                Text("Export workspace", style = TaktTheme.type.body, color = TaktTheme.colors.ink)
                Text(
                    "Every list, archived ones included, with its whole task tree and notes.",
                    style = TaktTheme.type.small, color = TaktTheme.colors.mutedText,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.sm)) {
                for (format in WorkspaceExportFormat.entries) {
                    PButton("${format.title}…", modifier = Modifier.testTag("settings_export_${format.fileExtension}")) {
                        launchers.getValue(format).launch(format.suggestedFileName)
                    }
                }
            }
            status?.let {
                Text(
                    it.message,
                    style = TaktTheme.type.small,
                    color = if (it.isError) TaktTheme.colors.danger else TaktTheme.colors.success,
                )
            }
        }
    }
}
