package uk.co.maybeitsadam.priority.ui.settings

import android.net.Uri
import android.provider.OpenableColumns
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uk.co.maybeitsadam.priority.app.AppContainer
import uk.co.maybeitsadam.priority.app.CelebrationStyle
import uk.co.maybeitsadam.priority.settings.SyncUiState
import uk.co.maybeitsadam.priority.app.ThemeLibraryState
import uk.co.maybeitsadam.priority.ui.theme.ThemeMode

/** `Synced just now`, `Synced at 14:05`, `Couldn't sync: …`. */
object SyncStatusText {
    private val clock = DateTimeFormatter.ofPattern("HH:mm", Locale.UK)
    private val dayClock = DateTimeFormatter.ofPattern("d MMM HH:mm", Locale.UK)

    fun describe(state: SyncUiState, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): String = when (state) {
        SyncUiState.Unpaired -> "Not set up"
        SyncUiState.Syncing -> "Syncing…"
        is SyncUiState.Failed -> "Couldn't sync: ${state.message}"
        is SyncUiState.Idle -> {
            val last = state.lastSyncedAt
            when {
                last == null -> "Paired"
                now.epochSecond - last.epochSecond < 60 -> "Synced just now"
                last.atZone(zone).toLocalDate() == now.atZone(zone).toLocalDate() -> "Synced at ${clock.format(last.atZone(zone))}"
                else -> "Synced ${dayClock.format(last.atZone(zone))}"
            }
        }
    }
}

class SettingsViewModel(private val container: AppContainer) : ViewModel() {
    private val settings = container.settings

    /** Every theme, what loading each file reported, and the choice in force. */
    val themes: StateFlow<ThemeLibraryState> =
        container.themes.state.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ThemeLibraryState())

    val celebration: StateFlow<CelebrationStyle> =
        settings.celebrationStyle.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), CelebrationStyle.STRIKE)

    private val _themeError = MutableStateFlow<String?>(null)
    val themeError: StateFlow<String?> = _themeError

    fun setMode(mode: ThemeMode) = viewModelScope.launch { container.themes.setAppearance(mode) }

    fun selectTheme(identifier: String) = viewModelScope.launch { container.themes.select(identifier) }

    fun setUseDeviceTheme(enabled: Boolean) = viewModelScope.launch { container.themes.setUseDeviceChoice(enabled) }

    fun setCelebration(style: CelebrationStyle) = viewModelScope.launch { settings.setCelebrationStyle(style) }

    /**
     * Imports a theme file. It is kept whatever loading it reports, so the
     * issues show under it and a fix is one re-import; it is switched to only
     * when it loaded.
     */
    fun import(uri: Uri) = viewModelScope.launch {
        _themeError.value = null
        val resolver = container.context.contentResolver
        val read = withContext(Dispatchers.IO) {
            runCatching {
                val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                }
                val text = resolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
                text?.let { (name ?: uri.lastPathSegment ?: "theme.json") to it }
            }.getOrNull()
        }
        if (read == null) {
            _themeError.value = "That file could not be read."
            return@launch
        }
        val outcome = container.themes.import(read.first, read.second)
        val loaded = outcome?.specification
        if (loaded != null) {
            container.themes.select(loaded.identifier)
            container.undo.say("Using ${loaded.name}")
        } else {
            _themeError.value = "${read.first} was not loaded: ${outcome?.skippedReason ?: "it could not be read"}."
        }
    }

    fun removeTheme(id: String) = viewModelScope.launch {
        _themeError.value = null
        container.themes.remove(id)
    }

    fun versionName(): String = runCatching {
        container.context.packageManager.getPackageInfo(container.context.packageName, 0).versionName
    }.getOrNull() ?: "?"

    /** The bundled licence files, by name. */
    suspend fun licences(): List<Pair<String, String>> = withContext(Dispatchers.IO) {
        val assets = container.context.assets
        (assets.list("licenses") ?: emptyArray()).sorted().map { file ->
            file.removeSuffix(".txt") to assets.open("licenses/$file").use { it.readBytes().toString(Charsets.UTF_8) }
        }
    }
}
