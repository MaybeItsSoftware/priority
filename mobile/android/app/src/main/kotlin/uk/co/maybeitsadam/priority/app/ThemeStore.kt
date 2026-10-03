package uk.co.maybeitsadam.priority.app

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import uk.co.maybeitsadam.priority.core.theme.BuiltInThemeSpecifications
import uk.co.maybeitsadam.priority.core.theme.ThemeFileLibrary
import uk.co.maybeitsadam.priority.core.theme.ThemeFileLoader
import uk.co.maybeitsadam.priority.core.theme.ThemeFileOutcome
import uk.co.maybeitsadam.priority.core.theme.ThemeFileSource
import uk.co.maybeitsadam.priority.core.theme.ThemePlatform
import uk.co.maybeitsadam.priority.core.theme.ThemeSpecification
import uk.co.maybeitsadam.priority.ui.theme.ThemeMode

/** One imported theme file, as the synced `themes` table will hold it. */
@Serializable
data class StoredThemeFile(val name: String, val json: String)

/** A theme and appearance choice: `theme.selected` and `theme.appearance`. */
data class ThemeSelection(
    val selected: String = BuiltInThemeSpecifications.CHALK_IDENTIFIER,
    val appearance: ThemeMode = ThemeMode.SYSTEM,
)

/** Everything the theme settings and the app's root need, resolved for Android. */
data class ThemeLibraryState(
    val files: List<StoredThemeFile> = emptyList(),
    val library: ThemeFileLibrary = ThemeFileLibrary.EMPTY,
    /** The choice every device shares (synced once the `preferences` table is in). */
    val shared: ThemeSelection = ThemeSelection(),
    /** This device's own choice, used when [useDeviceChoice] is on. Never synced. */
    val device: ThemeSelection = ThemeSelection(),
    val useDeviceChoice: Boolean = false,
) {
    val builtIns: List<ThemeSpecification> get() = BuiltInThemeSpecifications.all(ThemePlatform.ANDROID)

    /** Built-ins first, then every user theme that loaded. */
    val available: List<ThemeSpecification> get() = builtIns + library.themes

    val selection: ThemeSelection get() = if (useDeviceChoice) device else shared

    /** The theme in force. A choice this device does not know (yet) is Chalk until it does. */
    val specification: ThemeSpecification
        get() = available.firstOrNull { it.identifier == selection.selected }
            ?: BuiltInThemeSpecifications.chalk(ThemePlatform.ANDROID)

    val mode: ThemeMode get() = selection.appearance
}

/**
 * Themes and the choice of theme, in DataStore for now. The file list and
 * [ThemeLibraryState.shared] are what move to the synced `themes` and
 * `preferences` tables; the device opt-out stays here.
 */
class ThemeStore(private val settings: SettingsStore) {
    private val json = Json { ignoreUnknownKeys = true }
    private val listSerializer = ListSerializer(StoredThemeFile.serializer())

    val state: Flow<ThemeLibraryState> = settings.data
        .onStart { migrateLegacy() }
        .map { prefs ->
            val files = prefs[FILES]?.let { runCatching { json.decodeFromString(listSerializer, it) }.getOrNull() }.orEmpty()
            ThemeLibraryState(
                files = files,
                library = ThemeFileLoader.load(files.map { ThemeFileSource(it.name, it.json) }, ThemePlatform.ANDROID),
                shared = ThemeSelection(
                    prefs[SELECTED] ?: BuiltInThemeSpecifications.CHALK_IDENTIFIER, ThemeMode.of(prefs[APPEARANCE]),
                ),
                device = ThemeSelection(
                    prefs[DEVICE_SELECTED] ?: BuiltInThemeSpecifications.CHALK_IDENTIFIER, ThemeMode.of(prefs[DEVICE_APPEARANCE]),
                ),
                useDeviceChoice = prefs[USE_DEVICE] == "true",
            )
        }
        .distinctUntilChanged()
        .flowOn(Dispatchers.Default)

    /**
     * Adds a theme file, replacing one of the same name, and returns what
     * loading it gave so the importer can say so.
     */
    suspend fun import(fileName: String, text: String): ThemeFileOutcome? {
        val name = fileName.trim().ifEmpty { "theme" }.let {
            if (it.endsWith(".${ThemeFileLoader.FILE_EXTENSION}")) it else "$it.${ThemeFileLoader.FILE_EXTENSION}"
        }
        var outcome: ThemeFileOutcome? = null
        settings.edit { prefs ->
            val files = decode(prefs[FILES]).filterNot { it.name == name } + StoredThemeFile(name, text)
            prefs[FILES] = json.encodeToString(listSerializer, files)
            outcome = ThemeFileLoader.load(files.map { ThemeFileSource(it.name, it.json) }, ThemePlatform.ANDROID)
                .outcomes.firstOrNull { it.source == name }
        }
        return outcome
    }

    suspend fun remove(fileName: String) = settings.edit { prefs ->
        prefs[FILES] = json.encodeToString(listSerializer, decode(prefs[FILES]).filterNot { it.name == fileName })
    }

    /** Chooses a theme, on this device alone when it has opted out of the shared choice. */
    suspend fun select(identifier: String) = settings.edit { prefs ->
        prefs[if (prefs[USE_DEVICE] == "true") DEVICE_SELECTED else SELECTED] = identifier
    }

    suspend fun setAppearance(mode: ThemeMode) = settings.edit { prefs ->
        prefs[if (prefs[USE_DEVICE] == "true") DEVICE_APPEARANCE else APPEARANCE] = mode.raw
    }

    /** Opting in starts the device's choice from the shared one, so nothing changes until it is changed. */
    suspend fun setUseDeviceChoice(enabled: Boolean) = settings.edit { prefs ->
        if (enabled && prefs[USE_DEVICE] != "true") {
            prefs[DEVICE_SELECTED] = prefs[SELECTED] ?: BuiltInThemeSpecifications.CHALK_IDENTIFIER
            prefs[DEVICE_APPEARANCE] = prefs[APPEARANCE] ?: ThemeMode.SYSTEM.raw
        }
        prefs[USE_DEVICE] = enabled.toString()
    }

    private fun decode(text: String?): List<StoredThemeFile> =
        text?.let { runCatching { json.decodeFromString(listSerializer, it) }.getOrNull() }.orEmpty()

    /**
     * The first theme settings kept one imported file and the active JSON
     * under two keys. They become a file in the list and a selection.
     */
    private suspend fun migrateLegacy() = settings.edit { prefs ->
        val legacyMode = prefs[LEGACY_MODE]
        val legacyActive = prefs[LEGACY_ACTIVE]
        val legacyLibrary = prefs[LEGACY_LIBRARY]
        if (legacyMode == null && legacyActive == null && legacyLibrary == null) return@edit
        if (legacyMode != null && prefs[APPEARANCE] == null) prefs[APPEARANCE] = legacyMode
        val imported = legacyLibrary ?: legacyActive?.takeIf { !it.contains(BuiltInThemeSpecifications.CHALK_DARK_IDENTIFIER) }
        if (imported != null) {
            val name = "imported.${ThemeFileLoader.FILE_EXTENSION}"
            prefs[FILES] = json.encodeToString(listSerializer, decode(prefs[FILES]) + StoredThemeFile(name, imported))
        }
        if (prefs[SELECTED] == null && legacyActive != null) {
            prefs[SELECTED] = if (legacyActive.contains(BuiltInThemeSpecifications.CHALK_DARK_IDENTIFIER)) {
                BuiltInThemeSpecifications.CHALK_DARK_IDENTIFIER
            } else {
                ThemeFileLoader.decode(legacyActive, "imported.json").first
                    ?.let { ThemeFileLoader.identifier(it, "imported.json") }
                    ?: BuiltInThemeSpecifications.CHALK_IDENTIFIER
            }
        }
        prefs.remove(LEGACY_MODE)
        prefs.remove(LEGACY_ACTIVE)
        prefs.remove(LEGACY_LIBRARY)
    }

    companion object {
        val FILES = SettingsStore.key("theme.files")
        val SELECTED = SettingsStore.key("theme.selected")
        val APPEARANCE = SettingsStore.key("theme.appearance")
        val USE_DEVICE = SettingsStore.key("theme.device.enabled")
        val DEVICE_SELECTED = SettingsStore.key("theme.device.selected")
        val DEVICE_APPEARANCE = SettingsStore.key("theme.device.appearance")

        private val LEGACY_MODE = SettingsStore.key("themeMode")
        private val LEGACY_ACTIVE = SettingsStore.key("themeJSON")
        private val LEGACY_LIBRARY = SettingsStore.key("importedThemeLibrary")
    }
}
