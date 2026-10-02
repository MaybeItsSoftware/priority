package uk.co.maybeitsadam.priority.app

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import uk.co.maybeitsadam.priority.ui.theme.ThemeJson
import uk.co.maybeitsadam.priority.ui.theme.ThemeMode
import uk.co.maybeitsadam.priority.ui.theme.ThemeSpec

private val Context.settingsDataStore: DataStore<Preferences> by preferencesDataStore(name = "settings")

/** How finishing something is marked; the Mac's celebration plugins by the same names. */
enum class CelebrationStyle(val raw: String, val title: String, val detail: String) {
    STRIKE("strike", "Strike", "A rule drawn through the finished row."),
    SPARK("spark", "Spark", "A brief spark where the row was."),
    FOLD("fold", "Fold", "The row folds away."),
    NONE("none", "None", "Nothing but the tick.");

    companion object {
        fun of(raw: String?): CelebrationStyle = entries.firstOrNull { it.raw == raw } ?: STRIKE
    }
}

/**
 * App preferences, in a DataStore. Typed flows for what the shell reads, and a
 * small string/string-set API so features can keep their own keys here without
 * editing this file.
 */
class SettingsStore(context: Context) {
    private val store = context.applicationContext.settingsDataStore

    val themeMode: Flow<ThemeMode> = string(THEME_MODE).map { ThemeMode.of(it) }.distinctUntilChanged()

    /** The imported theme's JSON, if one is in use. */
    val importedThemeJson: Flow<String?> = string(THEME_JSON)

    /** The theme in force: the imported one when it still parses, otherwise Chalk. */
    val themeSpec: Flow<ThemeSpec> = string(THEME_JSON).map { json ->
        json?.let { runCatching { ThemeJson.parse(it) }.getOrNull() } ?: ThemeSpec.Chalk
    }.distinctUntilChanged()

    val celebrationStyle: Flow<CelebrationStyle> = string(CELEBRATION).map { CelebrationStyle.of(it) }

    suspend fun setThemeMode(mode: ThemeMode) = putString(THEME_MODE, mode.raw)

    suspend fun setImportedThemeJson(json: String?) = putString(THEME_JSON, json)

    suspend fun setCelebrationStyle(style: CelebrationStyle) = putString(CELEBRATION, style.raw)

    fun string(key: String): Flow<String?> = store.data.map { it[stringPreferencesKey(key)] }.distinctUntilChanged()

    suspend fun putString(key: String, value: String?) {
        store.edit { prefs ->
            if (value == null) prefs.remove(stringPreferencesKey(key)) else prefs[stringPreferencesKey(key)] = value
        }
    }

    fun stringSet(key: String): Flow<Set<String>> =
        store.data.map { it[stringSetPreferencesKey(key)] ?: emptySet() }.distinctUntilChanged()

    suspend fun putStringSet(key: String, value: Set<String>) {
        store.edit { it[stringSetPreferencesKey(key)] = value }
    }

    companion object {
        const val THEME_MODE = "themeMode"
        const val THEME_JSON = "themeJSON"
        const val CELEBRATION = "celebrationStyle"
    }
}
