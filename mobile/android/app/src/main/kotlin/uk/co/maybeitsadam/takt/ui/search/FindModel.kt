package uk.co.maybeitsadam.takt.ui.search

import androidx.compose.runtime.Immutable
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import uniffi.takt_core.CommandEntry
import uniffi.takt_core.CommandSurface
import uniffi.takt_core.PaletteCandidate
import uniffi.takt_core.paletteRank
import uniffi.takt_core.paletteRankCommands
import uniffi.takt_core.paletteRecording
import uniffi.takt_core.phonePaletteCommands
import uk.co.maybeitsadam.takt.data.workspace.SidebarData

/** A place Find can open: a list, a filter list, or Everything. */
@Immutable
data class FindPlace(val id: String?, val name: String, val detail: String, val kind: FindPlaceKind, val colorHex: String? = null)

enum class FindPlaceKind { EVERYTHING, LIST, FILTER }

/** What Find offers besides tasks: the commands and places that match, best first. */
@Immutable
data class FindPalette(
    val commands: ImmutableList<CommandEntry> = persistentListOf(),
    val places: ImmutableList<FindPlace> = persistentListOf(),
)

/**
 * Find's matching, all of it the core's (`core/src/palette.rs`), so a query
 * lands on the same row on the iPhone and here, and on the Mac's palette's
 * scoring. Nothing typed: recent commands first, then every place.
 */
object FindModel {
    /** How many command rows a query shows; the rest are a scroll away in tasks. */
    const val COMMAND_LIMIT = 5
    const val PLACE_LIMIT = 6

    /** Android's one command beyond the core's list: only Android has the habit form so far. */
    const val HABIT_NEW = "androidHabitNew"

    /** The commands the phones offer, read once from the core, and [HABIT_NEW]. */
    val commands: List<CommandEntry> by lazy {
        phonePaletteCommands() + CommandEntry(
            HABIT_NEW, "New habit", "Task", emptyList(), emptyList(), CommandSurface.ANYWHERE, false, null,
        )
    }

    fun palette(query: String, recents: List<String>, places: List<FindPlace>): FindPalette {
        val trimmed = query.trim()
        val byId = commands.associateBy { it.id }
        val ranked = paletteRankCommands(trimmed, commands, recents).mapNotNull(byId::get)
        val rankedPlaces = if (trimmed.isEmpty()) {
            places
        } else {
            val order = paletteRank(trimmed, places.map { PaletteCandidate(it.name, it.detail, emptyList(), 0) })
            order.map { places[it.toInt()] }
        }
        return FindPalette(
            commands = (if (trimmed.isEmpty()) ranked else ranked.take(COMMAND_LIMIT)).toImmutableList(),
            places = (if (trimmed.isEmpty()) rankedPlaces else rankedPlaces.take(PLACE_LIMIT)).toImmutableList(),
        )
    }

    /** Everything, then the filter lists, then every live list with its folder as detail. */
    fun places(data: SidebarData): List<FindPlace> {
        val folders = data.folders.associateBy { it.id }
        return buildList {
            add(FindPlace(null, "Everything", "All active lists", FindPlaceKind.EVERYTHING))
            data.filterLists.forEach { add(FindPlace(it.id, it.name, it.summary, FindPlaceKind.FILTER, it.colorHex)) }
            data.lists.filter { !it.isArchived && it.completedAt == null }.forEach { list ->
                add(FindPlace(list.id, list.name, list.folderId?.let { folders[it]?.name }.orEmpty(), FindPlaceKind.LIST, list.colorHex))
            }
        }
    }

    /** The stored recents, newest first, with [id] moved to the front. */
    fun recording(id: String, recents: List<String>): List<String> = paletteRecording(id, recents)

    fun decodeRecents(raw: String?): List<String> = raw?.split('\n')?.filter { it.isNotBlank() }.orEmpty()

    fun encodeRecents(recents: List<String>): String = recents.joinToString("\n")
}
