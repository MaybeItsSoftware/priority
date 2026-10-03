package uk.co.maybeitsadam.priority.ui.settings

import android.net.Uri
import androidx.compose.runtime.Immutable
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
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uk.co.maybeitsadam.priority.app.AppContainer
import uk.co.maybeitsadam.priority.app.CelebrationStyle
import uk.co.maybeitsadam.priority.settings.SyncUiState
import uk.co.maybeitsadam.priority.ui.theme.ThemeImportException
import uk.co.maybeitsadam.priority.ui.theme.ThemeJson
import uk.co.maybeitsadam.priority.ui.theme.ThemeMode
import uk.co.maybeitsadam.priority.ui.theme.ThemeSpec

/** Which theme is in force. */
sealed interface ThemeChoice {
    data object Chalk : ThemeChoice
    data object ChalkDark : ThemeChoice
    data class Imported(val name: String) : ThemeChoice
}

@Immutable
data class ThemeState(
    val mode: ThemeMode = ThemeMode.SYSTEM,
    val choice: ThemeChoice = ThemeChoice.Chalk,
    /** The imported theme's name, when one has been imported. */
    val importedName: String? = null,
)

/**
 * Theme choice on top of the foundation's single "theme JSON" key: Chalk is
 * no JSON, Chalk Dark is a one-line JSON extending the dark built-in, and the
 * imported file is kept under its own key so switching away and back keeps it.
 */
object ThemeChoices {
    const val LIBRARY_KEY = "importedThemeLibrary"
    val chalkDarkJson = """{"name":"Chalk Dark","identifier":"${ThemeSpec.ChalkDark.identifier}","extends":"${ThemeSpec.ChalkDark.identifier}"}"""

    fun choice(activeJson: String?): ThemeChoice {
        if (activeJson == null) return ThemeChoice.Chalk
        val spec = runCatching { ThemeJson.parse(activeJson) }.getOrNull() ?: return ThemeChoice.Chalk
        return if (spec.identifier == ThemeSpec.ChalkDark.identifier) ThemeChoice.ChalkDark else ThemeChoice.Imported(spec.name)
    }

    /** The imported theme: the library copy, or an active JSON that is not Chalk Dark. */
    fun importedJson(activeJson: String?, library: String?): String? =
        library ?: activeJson?.takeIf { choice(it) is ThemeChoice.Imported }

    fun name(json: String?): String? = json?.let { runCatching { ThemeJson.parse(it).name }.getOrNull() }
}

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

    val theme: StateFlow<ThemeState> = combine(
        settings.themeMode, settings.importedThemeJson, settings.string(ThemeChoices.LIBRARY_KEY),
    ) { mode, active, library ->
        ThemeState(mode, ThemeChoices.choice(active), ThemeChoices.name(ThemeChoices.importedJson(active, library)))
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ThemeState())

    val celebration: StateFlow<CelebrationStyle> =
        settings.celebrationStyle.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), CelebrationStyle.STRIKE)

    private val _themeError = MutableStateFlow<String?>(null)
    val themeError: StateFlow<String?> = _themeError

    fun setMode(mode: ThemeMode) = viewModelScope.launch { settings.setThemeMode(mode) }

    fun setCelebration(style: CelebrationStyle) = viewModelScope.launch { settings.setCelebrationStyle(style) }

    fun choose(choice: ThemeChoice) = viewModelScope.launch {
        when (choice) {
            ThemeChoice.Chalk -> settings.setImportedThemeJson(null)
            ThemeChoice.ChalkDark -> settings.setImportedThemeJson(ThemeChoices.chalkDarkJson)
            is ThemeChoice.Imported -> {
                settings.string(ThemeChoices.LIBRARY_KEY).first()?.let { settings.setImportedThemeJson(it) }
            }
        }
    }

    fun import(uri: Uri) = viewModelScope.launch {
        _themeError.value = null
        try {
            val text = withContext(Dispatchers.IO) {
                container.context.contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
            } ?: throw ThemeImportException("That file could not be read.")
            val spec = withContext(Dispatchers.Default) { ThemeJson.parse(text) }
            settings.putString(ThemeChoices.LIBRARY_KEY, text)
            settings.setImportedThemeJson(text)
            container.undo.say("Using ${spec.name}")
        } catch (error: ThemeImportException) {
            _themeError.value = error.message
        } catch (error: java.io.IOException) {
            _themeError.value = error.message ?: "That file could not be read."
        } catch (error: SecurityException) {
            _themeError.value = error.message ?: "That file could not be read."
        }
    }

    fun removeImported() = viewModelScope.launch {
        if (theme.value.choice is ThemeChoice.Imported) settings.setImportedThemeJson(null)
        settings.putString(ThemeChoices.LIBRARY_KEY, null)
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
