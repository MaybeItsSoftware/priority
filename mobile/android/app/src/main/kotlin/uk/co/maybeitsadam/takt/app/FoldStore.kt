package uk.co.maybeitsadam.takt.app

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

private val Context.foldDataStore: DataStore<Preferences> by preferencesDataStore(name = "folds")

/**
 * Which tasks are folded, per list, the way Checkvist keeps it: the outline
 * and the board's card subtasks read the same set, so folding in one folds in
 * the other. The Everything scope uses the key [EVERYTHING].
 */
class FoldStore(context: Context) {
    private val store = context.applicationContext.foldDataStore

    fun folded(listKey: String): Flow<Set<String>> =
        store.data.map { it[key(listKey)] ?: emptySet() }.distinctUntilChanged()

    suspend fun toggle(listKey: String, taskId: String) {
        store.edit { prefs ->
            val current = prefs[key(listKey)] ?: emptySet()
            prefs[key(listKey)] = if (taskId in current) current - taskId else current + taskId
        }
    }

    suspend fun set(listKey: String, folded: Set<String>) {
        store.edit { it[key(listKey)] = folded }
    }

    private fun key(listKey: String) = stringSetPreferencesKey("fold.$listKey")

    companion object {
        const val EVERYTHING = "everything"
    }
}
