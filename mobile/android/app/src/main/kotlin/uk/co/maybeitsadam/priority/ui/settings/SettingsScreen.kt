package uk.co.maybeitsadam.priority.ui.settings

import android.content.ClipData
import android.content.Intent
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
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
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
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import java.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.priority.app.CelebrationStyle
import uk.co.maybeitsadam.priority.core.SyncCredentials
import uk.co.maybeitsadam.priority.core.SyncDeviceInfo
import uk.co.maybeitsadam.priority.settings.SignedOutHint
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
import uk.co.maybeitsadam.priority.ui.theme.Metrics
import uk.co.maybeitsadam.priority.ui.theme.PIcons
import uk.co.maybeitsadam.priority.ui.theme.PriorityTheme

/** Theme, celebrations, sync and about. */
@Composable
fun SettingsScreen() {
    val shell = LocalShell.current
    val model = viewModel { SettingsViewModel(shell.container) }
    Column(Modifier.fillMaxSize().background(PriorityTheme.colors.paper)) {
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
internal fun Section(title: String, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.sm)) {
        Text(title, style = PriorityTheme.type.label, color = PriorityTheme.colors.mutedText)
        Card(Modifier.fillMaxWidth()) { Column(content = content) }
        if (footer != null) Text(footer, style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText)
    }
}

/** A radio row: a ring that fills azure when chosen. */
@Composable
internal fun ChoiceRow(title: String, selected: Boolean, detail: String? = null, tag: String = "", onClick: () -> Unit) {
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
            Text(title, style = PriorityTheme.type.body, color = PriorityTheme.colors.ink)
            if (detail != null) Text(detail, style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText)
        }
        RadioRing(selected)
    }
}

@Composable
private fun CelebrationSection(model: SettingsViewModel) {
    val style by model.celebration.collectAsStateWithLifecycle()
    Section("Completing a task") {
        CelebrationStyle.entries.forEachIndexed { index, option ->
            if (index > 0) Hairline(color = PriorityTheme.colors.borderMuted)
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
            Text("Version", style = PriorityTheme.type.body, color = PriorityTheme.colors.ink, modifier = Modifier.weight(1f))
            MonoText(remember { model.versionName() })
        }
        licences.forEach { (name, text) ->
            Hairline(color = PriorityTheme.colors.borderMuted)
            ChoiceRowLike(name, if (open == name) "Hide" else "Licence") { open = if (open == name) null else name }
            if (open == name) {
                Text(
                    text, style = PriorityTheme.type.monoSmall, color = PriorityTheme.colors.mutedText,
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
        Text(title, style = PriorityTheme.type.body, color = PriorityTheme.colors.ink, modifier = Modifier.weight(1f))
        Text(trailing, style = PriorityTheme.type.small, color = PriorityTheme.colors.primary)
    }
}

// region Sync

@Composable
private fun SyncSection(sync: SyncController) {
    val status by sync.status.collectAsStateWithLifecycle()
    val credentials by sync.credentials.collectAsStateWithLifecycle()
    val signingIn by sync.isSigningIn.collectAsStateWithLifecycle()
    val error by sync.signInError.collectAsStateWithLifecycle()
    val hint by sync.signedOut.collectAsStateWithLifecycle()
    val signedIn = credentials
    if (signedIn != null) SignedInSync(sync, status, signedIn) else SignedOutSync(sync, signingIn, hint)
    error?.let { ErrorNote(it, Modifier.testTag("sync_error")) }
}

@Composable
private fun ErrorNote(message: String, modifier: Modifier = Modifier) {
    Text(
        message, style = PriorityTheme.type.small, color = PriorityTheme.colors.danger,
        modifier = modifier
            .fillMaxWidth()
            .background(PriorityTheme.colors.danger.copy(alpha = 0.08f), Metrics.control)
            .border(BorderStroke(Metrics.hairline, PriorityTheme.colors.danger.copy(alpha = 0.4f)), Metrics.control)
            .padding(Metrics.md),
    )
}

@Composable
private fun InfoRow(title: String, modifier: Modifier = Modifier, value: @Composable () -> Unit) {
    Row(
        modifier.fillMaxWidth().heightIn(min = Metrics.touchTarget).padding(horizontal = Metrics.md, vertical = Metrics.sm),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.md),
    ) {
        Text(title, style = PriorityTheme.type.body, color = PriorityTheme.colors.ink, modifier = Modifier.weight(1f))
        value()
    }
}

@Composable
private fun SignedInSync(sync: SyncController, status: SyncUiState, credentials: SyncCredentials) {
    val scope = rememberCoroutineScope()
    val account by sync.account.collectAsStateWithLifecycle()
    var now by remember { mutableStateOf(Instant.now()) }
    var confirmSignOut by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var accountError by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { while (true) { delay(30_000); now = Instant.now() } }
    LaunchedEffect(credentials.deviceId) { accountError = sync.refreshAccount() }
    val email = account?.email ?: credentials.email

    Section("Sync") {
        InfoRow("Signed in as") {
            Text(
                email ?: "this device's account", style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText,
                modifier = Modifier.weight(2f, fill = false).testTag("sync_email"),
            )
        }
        Hairline(color = PriorityTheme.colors.borderMuted)
        InfoRow("Status") {
            Text(
                SyncStatusText.describe(status, now),
                style = PriorityTheme.type.small,
                color = if (status is SyncUiState.Failed || status is SyncUiState.SessionExpired) PriorityTheme.colors.danger else PriorityTheme.colors.mutedText,
                modifier = Modifier.weight(2f, fill = false).testTag("sync_status"),
            )
        }
        if (credentials.serverURL.trimEnd('/') != SyncController.defaultServer.trimEnd('/')) {
            Hairline(color = PriorityTheme.colors.borderMuted)
            InfoRow("Server") { MonoText(SyncController.hostOf(credentials.serverURL)) }
        }
        Hairline(color = PriorityTheme.colors.borderMuted)
        Row(Modifier.padding(Metrics.md), horizontalArrangement = Arrangement.spacedBy(Metrics.sm)) {
            PButton("Sync now", icon = PIcons.Sync, enabled = status != SyncUiState.Syncing, modifier = Modifier.testTag("sync_now")) { sync.syncNow() }
            PButton("Sign out", modifier = Modifier.testTag("sync_sign_out")) { confirmSignOut = true }
        }
    }

    Section("Devices", footer = "Every device signed in to this account.") {
        val devices = account?.devices.orEmpty()
        when {
            devices.isNotEmpty() -> devices.forEachIndexed { index, device ->
                if (index > 0) Hairline(color = PriorityTheme.colors.borderMuted)
                DeviceRow(device, now)
            }
            accountError != null -> Column(Modifier.padding(Metrics.md), verticalArrangement = Arrangement.spacedBy(Metrics.sm)) {
                Text(accountError!!, style = PriorityTheme.type.small, color = PriorityTheme.colors.danger)
                PButton("Try again") { scope.launch { accountError = sync.refreshAccount() } }
            }
            else -> Text("Loading…", style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText, modifier = Modifier.padding(Metrics.md))
        }
    }

    AddDeviceSection(sync, now)

    Section("Account", footer = "Deleting the account removes it and everything it synced from the server. Each device keeps its own copy of your tasks.") {
        Row(Modifier.padding(Metrics.md)) {
            PButton("Delete account", destructive = true, modifier = Modifier.testTag("sync_delete_account")) { deleting = true }
        }
    }

    if (confirmSignOut) {
        AlertDialog(
            onDismissRequest = { confirmSignOut = false },
            containerColor = PriorityTheme.colors.raised,
            tonalElevation = 0.dp,
            shape = Metrics.card,
            title = { Text("Sign out of sync?", style = PriorityTheme.type.heading, color = PriorityTheme.colors.ink) },
            text = { Text("Your tasks stay on this device. They stop syncing until you sign in again.", style = PriorityTheme.type.body, color = PriorityTheme.colors.mutedText) },
            confirmButton = {
                TextButton(onClick = { confirmSignOut = false; sync.signOut() }, modifier = Modifier.testTag("sync_sign_out_confirm")) {
                    Text("Sign out", color = PriorityTheme.colors.danger)
                }
            },
            dismissButton = { TextButton(onClick = { confirmSignOut = false }) { Text("Cancel", color = PriorityTheme.colors.ink) } },
        )
    }
    if (deleting) DeleteAccountDialog(sync, email) { deleting = false }
}

@Composable
private fun DeviceRow(device: SyncDeviceInfo, now: Instant) {
    val seen = device.lastSeenAt?.let(SyncController::parseExpiry)
    val detail = buildList {
        device.platform?.takeIf { it.isNotBlank() }?.let { add(platformName(it)) }
        when {
            device.current -> add("this device")
            seen != null && now.epochSecond - seen.epochSecond < 120 -> add("seen just now")
            seen != null -> add("last seen ${Format.day(seen)}, ${Format.time(seen)}")
        }
    }.joinToString(" · ")
    Column(
        Modifier.fillMaxWidth().heightIn(min = Metrics.touchTarget).padding(horizontal = Metrics.md, vertical = Metrics.sm).testTag("sync_device"),
        verticalArrangement = Arrangement.Center,
    ) {
        Text(device.name?.takeIf { it.isNotBlank() } ?: "Unnamed device", style = PriorityTheme.type.body, color = PriorityTheme.colors.ink)
        if (detail.isNotEmpty()) Text(detail, style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText)
    }
}

private fun platformName(platform: String): String = when (platform.lowercase()) {
    "ios" -> "iPhone"
    "android" -> "Android"
    "macos", "mac" -> "Mac"
    else -> platform
}

@Composable
private fun DeleteAccountDialog(sync: SyncController, email: String?, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var password by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = { if (!working) onDismiss() },
        containerColor = PriorityTheme.colors.raised,
        tonalElevation = 0.dp,
        shape = Metrics.card,
        title = { Text("Delete your account?", style = PriorityTheme.type.heading, color = PriorityTheme.colors.ink) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.sm)) {
                Text(
                    "This removes ${email ?: "the account"} and everything it synced from the server, and signs out every device. " +
                        "Each device keeps its own copy of your tasks. Enter your password to confirm.",
                    style = PriorityTheme.type.body, color = PriorityTheme.colors.mutedText,
                )
                Field(
                    password, { password = it; error = null }, "Password", Modifier.testTag("sync_delete_password"),
                    KeyboardType.Password, secret = true, autofill = ContentType.Password,
                )
                error?.let { Text(it, style = PriorityTheme.type.small, color = PriorityTheme.colors.danger) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !working && password.isNotEmpty(),
                onClick = {
                    scope.launch {
                        working = true
                        error = sync.deleteAccount(password)
                        working = false
                        if (error == null) onDismiss()
                    }
                },
                modifier = Modifier.testTag("sync_delete_confirm"),
            ) { Text(if (working) "Deleting…" else "Delete account", color = PriorityTheme.colors.danger) }
        },
        dismissButton = { TextButton(enabled = !working, onClick = onDismiss) { Text("Cancel", color = PriorityTheme.colors.ink) } },
    )
}

@Composable
private fun AddDeviceSection(sync: SyncController, now: Instant) {
    val scope = rememberCoroutineScope()
    val invite by sync.invite.collectAsStateWithLifecycle()
    var makingCode by remember { mutableStateOf(false) }
    var codeError by remember { mutableStateOf<String?>(null) }
    val clipboard = LocalClipboard.current
    val context = LocalContext.current
    val current = invite?.takeIf { it.expiresAt == null || it.expiresAt.isAfter(now) }
    Section("Add a device", footer = "A one-time code, so the other device can skip the password. It scans the code, or opens the link.") {
        if (current != null) {
            val link = current.link.url
            Column(Modifier.fillMaxWidth().padding(Metrics.md), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Metrics.md)) {
                QrImage(link, Modifier.size(224.dp))
                current.expiresAt?.let {
                    Text("Scan it on the other device. Expires at ${Format.time(it)}.", style = PriorityTheme.type.small, color = PriorityTheme.colors.mutedText)
                }
                MonoText(link, style = PriorityTheme.type.monoSmall, modifier = Modifier.testTag("pairing_link"))
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
                        codeError = sync.makePairingLink().exceptionOrNull()?.let { SyncController.message(it, "Couldn't make a code.") }
                        makingCode = false
                    }
                }
                codeError?.let { Text(it, style = PriorityTheme.type.small, color = PriorityTheme.colors.danger) }
            }
        }
    }
}

@Composable
private fun SignedOutSync(sync: SyncController, signingIn: Boolean, hint: SignedOutHint?) {
    val scope = rememberCoroutineScope()
    var email by rememberSaveable(hint?.email) { mutableStateOf(hint?.email.orEmpty()) }
    var password by rememberSaveable { mutableStateOf("") }
    var server by rememberSaveable(hint?.serverURL) { mutableStateOf(hint?.serverURL ?: SyncController.defaultServer) }
    var otherServer by rememberSaveable(hint?.serverURL) {
        mutableStateOf(hint?.serverURL != null && hint.serverURL.trimEnd('/') != SyncController.defaultServer.trimEnd('/'))
    }
    var scanning by remember { mutableStateOf(false) }
    var pasted by rememberSaveable { mutableStateOf("") }
    val requestingReset by sync.isRequestingReset.collectAsStateWithLifecycle()
    val resetNotice by sync.passwordResetNotice.collectAsStateWithLifecycle()
    val ready =!signingIn && email.isNotBlank() && password.isNotEmpty()
    val target = if (otherServer) server else SyncController.defaultServer

    Section("Sync", footer = "One account keeps your tasks the same on every device. The password needs at least 8 characters.") {
        if (hint?.expired == true) {
            Text(
                "Signed out — sign in again to keep syncing.", style = PriorityTheme.type.small, color = PriorityTheme.colors.danger,
                modifier = Modifier.padding(start = Metrics.md, end = Metrics.md, top = Metrics.md).testTag("sync_status"),
            )
        }
        Column(Modifier.padding(Metrics.md), verticalArrangement = Arrangement.spacedBy(Metrics.sm)) {
            Field(
                email, { email = it; sync.clearSignInError() }, "Email", Modifier.testTag("sync_email_field"),
                KeyboardType.Email, autofill = ContentType.EmailAddress + ContentType.Username, imeAction = ImeAction.Next,
            )
            Field(
                password, { password = it; sync.clearSignInError() }, "Password", Modifier.testTag("sync_password_field"),
                KeyboardType.Password, secret = true, autofill = ContentType.Password + ContentType.NewPassword, imeAction = ImeAction.Done,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.sm)) {
                PButton(if (signingIn) "Signing in…" else "Sign in", primary = true, enabled = ready, modifier = Modifier.testTag("sync_sign_in")) {
                    scope.launch { if (sync.signIn(target, email, password)) password = "" }
                }
                PButton("Create account", enabled = ready, modifier = Modifier.testTag("sync_sign_up")) {
                    scope.launch { if (sync.signUp(target, email, password)) password = "" }
                }
            }
            Text(
                if (requestingReset) "Sending link…" else "Forgot password?",
                style = PriorityTheme.type.small,
                color = if (signingIn || requestingReset) PriorityTheme.colors.dimText else PriorityTheme.colors.mutedText,
                modifier = Modifier
                    .heightIn(min = Metrics.touchTarget)
                    .clickable(enabled = !signingIn && !requestingReset, role = Role.Button) {
                        scope.launch { sync.requestPasswordReset(target, email) }
                    }
                    .wrapContentHeight(Alignment.CenterVertically)
                    .testTag("sync_forgot_password"),
            )
            resetNotice?.let {
                Text(
                    it, style = PriorityTheme.type.small, color = PriorityTheme.colors.ink,
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(PriorityTheme.colors.primary.copy(alpha = 0.08f), Metrics.control)
                        .border(BorderStroke(Metrics.hairline, PriorityTheme.colors.primary.copy(alpha = 0.4f)), Metrics.control)
                        .padding(Metrics.md)
                        .testTag("sync_reset_notice"),
                )
            }
        }
        Hairline(color = PriorityTheme.colors.borderMuted)
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = Metrics.touchTarget)
                .clickable(role = Role.Button) { otherServer = !otherServer }
                .padding(horizontal = Metrics.md)
                .testTag("sync_other_server"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Use a different server", style = PriorityTheme.type.body, color = PriorityTheme.colors.ink, modifier = Modifier.weight(1f))
            Icon(
                Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = PriorityTheme.colors.mutedText,
                modifier = Modifier.size(20.dp).rotate(if (otherServer) 180f else 0f),
            )
        }
        if (otherServer) {
            Column(Modifier.padding(start = Metrics.md, end = Metrics.md, bottom = Metrics.md)) {
                Field(server, { server = it; sync.clearSignInError() }, "Server address", Modifier.testTag("sync_server_field"), KeyboardType.Uri)
            }
        }
    }

    Section("Pair with a code", footer = "On a device that's signed in, open Settings, then Add a device.") {
        Column(Modifier.padding(Metrics.md), verticalArrangement = Arrangement.spacedBy(Metrics.sm)) {
            PButton("Scan code", icon = PIcons.QrCode, enabled = !signingIn, modifier = Modifier.fillMaxWidth().testTag("sync_scan")) { scanning = true }
            Field(pasted, { pasted = it }, "Or paste a pairing link", Modifier.testTag("sync_paste_field"), KeyboardType.Uri)
            PButton("Pair", enabled = !signingIn && pasted.isNotBlank(), modifier = Modifier.testTag("sync_paste_pair")) {
                val link = SyncPairingLink.parse(pasted)
                if (link == null) {
                    sync.pairFromLink(pasted)
                } else {
                    sync.clearSignInError()
                    scope.launch { if (sync.pair(link)) pasted = "" }
                }
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
    autofill: ContentType? = null,
    imeAction: ImeAction = ImeAction.Default,
) {
    val colors = PriorityTheme.colors
    BasicTextField(
        value = value,
        onValueChange = onChange,
        singleLine = true,
        textStyle = PriorityTheme.type.field.copy(color = colors.ink),
        cursorBrush = SolidColor(colors.primary),
        visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(
            keyboardType = keyboard,
            autoCorrectEnabled = false,
            capitalization = KeyboardCapitalization.None,
            imeAction = imeAction,
        ),
        modifier = modifier.fillMaxWidth().semantics {
            contentDescription = placeholder
            if (autofill != null) contentType = autofill
        },
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
                if (value.isEmpty()) Text(placeholder, style = PriorityTheme.type.field, color = colors.dimText)
                inner()
            }
        },
    )
}

// endregion
