package uk.co.maybeitsadam.priority.ui.settings

import android.content.ClipData
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import java.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.priority.app.CelebrationStyle
import uk.co.maybeitsadam.priority.settings.SyncController
import uk.co.maybeitsadam.priority.settings.SyncPairingLink
import uk.co.maybeitsadam.priority.settings.SyncUiState
import uk.co.maybeitsadam.priority.ui.components.Card
import uk.co.maybeitsadam.priority.ui.components.Format
import uk.co.maybeitsadam.priority.ui.components.Hairline
import uk.co.maybeitsadam.priority.ui.components.IconAction
import uk.co.maybeitsadam.priority.ui.components.MonoText
import uk.co.maybeitsadam.priority.ui.components.PButton
import uk.co.maybeitsadam.priority.ui.components.PriorityTopBar
import uk.co.maybeitsadam.priority.ui.navigation.LocalShell
import uk.co.maybeitsadam.priority.ui.review.Segmented
import uk.co.maybeitsadam.priority.ui.theme.Chalk
import uk.co.maybeitsadam.priority.ui.theme.Metrics
import uk.co.maybeitsadam.priority.ui.theme.PIcons
import uk.co.maybeitsadam.priority.ui.theme.ThemeMode

/** Theme, celebrations, sync and about. */
@Composable
fun SettingsScreen() {
    val shell = LocalShell.current
    val model = viewModel { SettingsViewModel(shell.container) }
    Column(Modifier.fillMaxSize().background(Chalk.colors.paper)) {
        PriorityTopBar(
            "Settings",
            showHistory = false,
            navigation = { IconAction(Icons.AutoMirrored.Filled.ArrowBack, "Back") { shell.navigator.back() } },
        )
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(Metrics.lg).testTag("settings"),
            verticalArrangement = Arrangement.spacedBy(Metrics.xl),
        ) {
            ThemeSection(model)
            CelebrationSection(model)
            SyncSection(shell.container.sync)
            AboutSection(model)
        }
    }
}

@Composable
private fun Section(title: String, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.sm)) {
        Text(title, style = Chalk.type.label, color = Chalk.colors.mutedText)
        Card(Modifier.fillMaxWidth()) { Column(content = content) }
        if (footer != null) Text(footer, style = Chalk.type.small, color = Chalk.colors.mutedText)
    }
}

/** A radio row: a ring that fills azure when chosen. */
@Composable
private fun ChoiceRow(title: String, selected: Boolean, detail: String? = null, tag: String = "", onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = Metrics.touchTarget)
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { this.selected = selected }
            .then(if (tag.isNotEmpty()) Modifier.testTag(tag) else Modifier)
            .padding(horizontal = Metrics.md, vertical = Metrics.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = Chalk.type.body, color = Chalk.colors.ink)
            if (detail != null) Text(detail, style = Chalk.type.small, color = Chalk.colors.mutedText)
        }
        Box(
            Modifier.size(20.dp).border(BorderStroke(1.5.dp, if (selected) Chalk.colors.primary else Chalk.colors.inputBorder), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (selected) Box(Modifier.size(10.dp).background(Chalk.colors.primary, CircleShape))
        }
    }
}

@Composable
private fun ThemeSection(model: SettingsViewModel) {
    val theme by model.theme.collectAsStateWithLifecycle()
    val error by model.themeError.collectAsStateWithLifecycle()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let(model::import) }
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.sm)) {
        Text("Appearance", style = Chalk.type.label, color = Chalk.colors.mutedText)
        Segmented(
            options = ThemeMode.entries,
            selected = theme.mode,
            label = { it.title },
            tag = { "settings_mode_${it.raw}" },
            onSelect = model::setMode,
        )
    }
    Section("Theme", footer = "A theme file is JSON: a name and colours for light and dark. See docs/themes.md.") {
        ChoiceRow("Chalk", theme.choice == ThemeChoice.Chalk, tag = "settings_theme_chalk") { model.choose(ThemeChoice.Chalk) }
        Hairline(color = Chalk.colors.borderMuted)
        ChoiceRow("Chalk Dark", theme.choice == ThemeChoice.ChalkDark, detail = "Always dark", tag = "settings_theme_chalk_dark") {
            model.choose(ThemeChoice.ChalkDark)
        }
        theme.importedName?.let { name ->
            Hairline(color = Chalk.colors.borderMuted)
            ChoiceRow(name, theme.choice is ThemeChoice.Imported, detail = "Imported", tag = "settings_theme_imported") {
                model.choose(ThemeChoice.Imported(name))
            }
        }
        Hairline(color = Chalk.colors.borderMuted)
        Row(Modifier.padding(Metrics.md), horizontalArrangement = Arrangement.spacedBy(Metrics.sm)) {
            PButton("Import theme…", modifier = Modifier.testTag("settings_import_theme")) {
                picker.launch(arrayOf("application/json", "text/*"))
            }
            if (theme.importedName != null) PButton("Remove imported theme", destructive = true) { model.removeImported() }
        }
        error?.let {
            Text(it, style = Chalk.type.small, color = Chalk.colors.danger, modifier = Modifier.padding(start = Metrics.md, end = Metrics.md, bottom = Metrics.md))
        }
    }
}

@Composable
private fun CelebrationSection(model: SettingsViewModel) {
    val style by model.celebration.collectAsStateWithLifecycle()
    Section("Completing a task") {
        CelebrationStyle.entries.forEachIndexed { index, option ->
            if (index > 0) Hairline(color = Chalk.colors.borderMuted)
            ChoiceRow(option.title, option == style, detail = option.detail, tag = "settings_celebration_${option.raw}") {
                model.setCelebration(option)
            }
        }
    }
}

@Composable
private fun AboutSection(model: SettingsViewModel) {
    val licences by produceState(emptyList<Pair<String, String>>()) { value = model.licences() }
    var open by rememberSaveable { mutableStateOf<String?>(null) }
    Section("About") {
        Row(Modifier.fillMaxWidth().heightIn(min = Metrics.touchTarget).padding(horizontal = Metrics.md), verticalAlignment = Alignment.CenterVertically) {
            Text("Version", style = Chalk.type.body, color = Chalk.colors.ink, modifier = Modifier.weight(1f))
            MonoText(remember { model.versionName() })
        }
        licences.forEach { (name, text) ->
            Hairline(color = Chalk.colors.borderMuted)
            ChoiceRowLike(name, if (open == name) "Hide" else "Licence") { open = if (open == name) null else name }
            if (open == name) {
                Text(
                    text, style = Chalk.type.monoSmall, color = Chalk.colors.mutedText,
                    modifier = Modifier.padding(horizontal = Metrics.md, vertical = Metrics.sm),
                )
            }
        }
    }
}

@Composable
private fun ChoiceRowLike(title: String, trailing: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = Metrics.touchTarget).clickable(onClick = onClick).padding(horizontal = Metrics.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = Chalk.type.body, color = Chalk.colors.ink, modifier = Modifier.weight(1f))
        Text(trailing, style = Chalk.type.small, color = Chalk.colors.primary)
    }
}

// region Sync

@Composable
private fun SyncSection(sync: SyncController) {
    val status by sync.status.collectAsStateWithLifecycle()
    val credentials by sync.credentials.collectAsStateWithLifecycle()
    val pairing by sync.isPairing.collectAsStateWithLifecycle()
    val error by sync.pairingError.collectAsStateWithLifecycle()
    if (credentials != null) PairedSync(sync, status, credentials!!.serverURL) else UnpairedSync(sync, pairing)
    error?.let {
        Text(
            it, style = Chalk.type.small, color = Chalk.colors.danger,
            modifier = Modifier
                .fillMaxWidth()
                .background(Chalk.colors.danger.copy(alpha = 0.08f), Metrics.control)
                .border(BorderStroke(Metrics.hairline, Chalk.colors.danger.copy(alpha = 0.4f)), Metrics.control)
                .padding(Metrics.md)
                .testTag("sync_error"),
        )
    }
}

@Composable
private fun PairedSync(sync: SyncController, status: SyncUiState, serverURL: String) {
    val scope = rememberCoroutineScope()
    val invite by sync.invite.collectAsStateWithLifecycle()
    var now by remember { mutableStateOf(Instant.now()) }
    var makingCode by remember { mutableStateOf(false) }
    var codeError by remember { mutableStateOf<String?>(null) }
    var confirmUnpair by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { while (true) { delay(30_000); now = Instant.now() } }
    val clipboard = LocalClipboard.current
    val context = LocalContext.current

    Section("Sync") {
        Row(Modifier.fillMaxWidth().heightIn(min = Metrics.touchTarget).padding(horizontal = Metrics.md), verticalAlignment = Alignment.CenterVertically) {
            Text("Status", style = Chalk.type.body, color = Chalk.colors.ink, modifier = Modifier.weight(1f))
            Text(
                SyncStatusText.describe(status, now),
                style = Chalk.type.small,
                color = if (status is SyncUiState.Failed) Chalk.colors.danger else Chalk.colors.mutedText,
                modifier = Modifier.weight(2f, fill = false).testTag("sync_status"),
            )
        }
        Hairline(color = Chalk.colors.borderMuted)
        Row(Modifier.fillMaxWidth().heightIn(min = Metrics.touchTarget).padding(horizontal = Metrics.md), verticalAlignment = Alignment.CenterVertically) {
            Text("Server", style = Chalk.type.body, color = Chalk.colors.ink, modifier = Modifier.weight(1f))
            MonoText(SyncController.hostOf(serverURL))
        }
        Hairline(color = Chalk.colors.borderMuted)
        Row(Modifier.padding(Metrics.md), horizontalArrangement = Arrangement.spacedBy(Metrics.sm)) {
            PButton("Sync now", icon = PIcons.Sync, enabled = status != SyncUiState.Syncing, modifier = Modifier.testTag("sync_now")) { sync.syncNow() }
            PButton("Unpair", destructive = true, modifier = Modifier.testTag("sync_unpair")) { confirmUnpair = true }
        }
    }
    val current = invite?.takeIf { it.expiresAt == null || it.expiresAt.isAfter(now) }
    Section("Add a device", footer = "A one-time code. The other device scans it, or opens the link.") {
        if (current != null) {
            val link = current.link.url
            Column(Modifier.fillMaxWidth().padding(Metrics.md), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Metrics.md)) {
                QrImage(link, Modifier.size(224.dp))
                current.expiresAt?.let {
                    Text("Scan it on the other device. Expires at ${Format.time(it)}.", style = Chalk.type.small, color = Chalk.colors.mutedText)
                }
                MonoText(link, style = Chalk.type.monoSmall, modifier = Modifier.testTag("pairing_link"))
                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.sm)) {
                    PButton("Copy link", icon = PIcons.Copy) {
                        scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Pairing link", link))) }
                    }
                    PButton("Share", icon = Icons.Filled.Share) {
                        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, link)
                        context.startActivity(Intent.createChooser(send, "Share pairing link"))
                    }
                }
            }
        } else {
            Column(Modifier.padding(Metrics.md), verticalArrangement = Arrangement.spacedBy(Metrics.sm)) {
                PButton(if (makingCode) "Making a code…" else "Add a device", icon = PIcons.QrCode, enabled = !makingCode, modifier = Modifier.testTag("sync_add_device")) {
                    scope.launch {
                        makingCode = true
                        codeError = sync.makePairingLink().exceptionOrNull()?.let { it.message ?: "Couldn't make a code." }
                        makingCode = false
                    }
                }
                codeError?.let { Text(it, style = Chalk.type.small, color = Chalk.colors.danger) }
            }
        }
    }
    if (confirmUnpair) {
        AlertDialog(
            onDismissRequest = { confirmUnpair = false },
            containerColor = Chalk.colors.raised,
            tonalElevation = 0.dp,
            shape = Metrics.card,
            title = { Text("Unpair this device?", style = Chalk.type.heading, color = Chalk.colors.ink) },
            text = { Text("Your tasks stay on this device. They stop syncing with your other devices.", style = Chalk.type.body, color = Chalk.colors.mutedText) },
            confirmButton = {
                TextButton(onClick = { confirmUnpair = false; sync.unpair() }, modifier = Modifier.testTag("sync_unpair_confirm")) {
                    Text("Unpair", color = Chalk.colors.danger)
                }
            },
            dismissButton = { TextButton(onClick = { confirmUnpair = false }) { Text("Cancel", color = Chalk.colors.ink) } },
        )
    }
}

@Composable
private fun UnpairedSync(sync: SyncController, pairing: Boolean) {
    val scope = rememberCoroutineScope()
    var scanning by remember { mutableStateOf(false) }
    var pasted by rememberSaveable { mutableStateOf("") }
    var server by rememberSaveable { mutableStateOf("") }
    var token by remember { mutableStateOf("") }
    Section("Sync", footer = "On a paired device, open Settings, then Add a device.") {
        Column(Modifier.padding(Metrics.md), verticalArrangement = Arrangement.spacedBy(Metrics.sm)) {
            Text(if (pairing) "Pairing…" else "Not set up", style = Chalk.type.small, color = Chalk.colors.mutedText, modifier = Modifier.testTag("sync_status"))
            PButton("Scan code", icon = PIcons.QrCode, primary = true, enabled = !pairing, modifier = Modifier.fillMaxWidth().testTag("sync_scan")) { scanning = true }
            Field(pasted, { pasted = it }, "Or paste a pairing link", Modifier.testTag("sync_paste_field"), KeyboardType.Uri)
            PButton("Pair", enabled = !pairing && pasted.isNotBlank(), modifier = Modifier.testTag("sync_paste_pair")) {
                val link = SyncPairingLink.parse(pasted)
                if (link == null) {
                    sync.pairFromLink(pasted)
                } else {
                    sync.clearPairingError()
                    scope.launch { if (sync.pair(link)) pasted = "" }
                }
            }
        }
    }
    Section("Advanced", footer = "For the first device on a new server: its address and the admin token it was started with.") {
        Column(Modifier.padding(Metrics.md), verticalArrangement = Arrangement.spacedBy(Metrics.sm)) {
            Field(server, { server = it }, "Server URL", Modifier.testTag("sync_server_field"), KeyboardType.Uri)
            Field(token, { token = it }, "Admin token", Modifier.testTag("sync_token_field"), KeyboardType.Password, secret = true)
            PButton("Pair with server", enabled = !pairing && server.isNotBlank() && token.isNotBlank(), modifier = Modifier.testTag("sync_server_pair")) {
                scope.launch { if (sync.pair(server, token)) token = "" }
            }
        }
    }
    if (scanning) {
        PairingScanner(
            onLink = { link ->
                scanning = false
                scope.launch { sync.pair(link) }
            },
            onDismiss = { scanning = false },
        )
    }
}

@Composable
private fun Field(
    value: String,
    onChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    keyboard: KeyboardType = KeyboardType.Text,
    secret: Boolean = false,
) {
    val colors = Chalk.colors
    BasicTextField(
        value = value,
        onValueChange = onChange,
        singleLine = true,
        textStyle = Chalk.type.body.copy(color = colors.ink, fontSize = 16.sp),
        cursorBrush = SolidColor(colors.primary),
        visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = keyboard, autoCorrectEnabled = false),
        modifier = modifier.fillMaxWidth().semantics { contentDescription = placeholder },
        decorationBox = { inner ->
            Box(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = Metrics.touchTarget)
                    .background(colors.paper, Metrics.control)
                    .border(BorderStroke(Metrics.hairline, colors.inputBorder), Metrics.control)
                    .padding(horizontal = Metrics.md),
                contentAlignment = Alignment.CenterStart,
            ) {
                if (value.isEmpty()) Text(placeholder, style = Chalk.type.body.copy(fontSize = 16.sp), color = colors.dimText)
                inner()
            }
        },
    )
}

// endregion
