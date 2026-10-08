package uk.co.maybeitsadam.takt.data.workspace

import java.time.Instant
import kotlinx.coroutines.flow.Flow
import uk.co.maybeitsadam.takt.data.db.Db

// The `themes` and `preferences` tables (`v18_themes_and_preferences`), as
// Sources/TaktWorkspace/WorkspaceStore+Themes.swift writes them.
//
// Both sync and neither is journalled for undo. Every write is skipped when
// it would change nothing, so a row only syncs when it really changes and two
// devices cannot send the same text round and round.

/**
 * A user theme as the workspace holds it: the identifier the file resolves
 * to, and the file's text verbatim. The text is not parsed here, so a theme
 * one device cannot load still reaches the others intact.
 */
data class StoredTheme(val id: String, val json: String, val updatedAt: Instant)

/** The synced preference keys the apps share. */
object WorkspacePreferenceKey {
    /** The identifier of the chosen theme. */
    const val THEME_SELECTED = "theme.selected"

    /** `system`, `light` or `dark`. */
    const val THEME_APPEARANCE = "theme.appearance"
}

/** Every stored theme, by identifier. */
suspend fun WorkspaceRepository.themes(): List<StoredTheme> = database.read { readThemes(it) }

fun WorkspaceRepository.observeThemes(): Flow<List<StoredTheme>> = database.observe(setOf("themes")) { readThemes(it) }

/** Stores [json] as the theme [id]. False, with nothing written, when the row already holds exactly that text. */
suspend fun WorkspaceRepository.upsertTheme(id: String, json: String, now: Instant = now()): Boolean =
    coreWrite { it.upsertTheme(id, json, now.toEpochMilli()) }

/** Removes the theme [id]. False when there was none. */
suspend fun WorkspaceRepository.deleteTheme(id: String): Boolean = coreWrite { it.deleteTheme(id) }

/** The value under [key]; null when it is unset or stored as null. */
suspend fun WorkspaceRepository.preference(key: String): String? =
    database.read { it.string("SELECT value FROM preferences WHERE key = ?", key) }

/** Every stored preference. A key stored as null maps to null. */
suspend fun WorkspaceRepository.preferences(): Map<String, String?> = database.read { readPreferences(it) }

fun WorkspaceRepository.observePreferences(): Flow<Map<String, String?>> =
    database.observe(setOf("preferences")) { readPreferences(it) }

/**
 * Stores [value] under [key]. A null value is kept as a row holding null
 * rather than deleted, so clearing a choice syncs as an edit. False, with
 * nothing written, when the row already holds that value.
 */
suspend fun WorkspaceRepository.setPreference(key: String, value: String?, now: Instant = now()): Boolean =
    coreWrite { it.setPreference(key, value, now.toEpochMilli()) }

private fun readThemes(db: Db): List<StoredTheme> =
    db.core.themes().map { StoredTheme(it.id, it.json, Instant.ofEpochMilli(it.updatedAtMs)) }

private fun readPreferences(db: Db): Map<String, String?> = db.core.preferences().associate { it.key to it.value }
