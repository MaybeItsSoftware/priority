package uk.co.maybeitsadam.priority.ui.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.ui.graphics.vector.ImageVector
import uk.co.maybeitsadam.priority.ui.theme.PIcons
import kotlinx.serialization.Serializable

/** Type-safe destinations. The five tabs, the list screen, and settings. */
@Serializable data object TodayRoute

@Serializable data object ListsRoute

/**
 * One list, or the Everything scope when [listId] is null. [revealTaskId]
 * scrolls to and selects a task (from search, undo, or the done rail).
 */
@Serializable data class ListRoute(val listId: String? = null, val revealTaskId: String? = null)

@Serializable data object FocusRoute

@Serializable data object ReviewRoute

@Serializable data object SearchRoute

@Serializable data object SettingsRoute

/** The bottom bar (phones) and rail (tablets), in order. */
enum class Tab(val title: String, private val iconProvider: () -> ImageVector, val route: Any) {
    TODAY("Today", { PIcons.Today }, TodayRoute),
    LISTS("Lists", { PIcons.ListIcon }, ListsRoute),
    FOCUS("Focus", { PIcons.Focus }, FocusRoute),
    REVIEW("Review", { PIcons.Review }, ReviewRoute),
    SEARCH("Search", { Icons.Filled.Search }, SearchRoute),
    ;

    val icon: ImageVector get() = iconProvider()
}

/** What screens may ask of the shell's navigation, without seeing the NavController. */
interface AppNavigator {
    fun openTab(tab: Tab)
    fun openList(listId: String?, revealTaskId: String? = null)
    fun openSettings()
    fun back()
}
