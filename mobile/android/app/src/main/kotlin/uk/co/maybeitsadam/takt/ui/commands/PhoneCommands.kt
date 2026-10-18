package uk.co.maybeitsadam.takt.ui.commands

import uk.co.maybeitsadam.takt.app.ListsPrompt
import uk.co.maybeitsadam.takt.app.QuickAddRequest
import uk.co.maybeitsadam.takt.ui.navigation.Shell
import uk.co.maybeitsadam.takt.ui.navigation.Tab

/**
 * What each of Find's commands does here. The list of commands is the core's
 * (`phone_palette_commands`), shared with the iPhone; this is only the
 * dispatch, and [HANDLED] is held to that list by a test so a command the
 * core adds cannot go quietly missing.
 */
object PhoneCommands {
    val HANDLED: Set<String> = setOf(
        "taskNew", "goToday", "goInbox", "goEverything", "goFocus", "goTimeline",
        "listNew", "folderNew", "windowUndo", "windowRedo",
        "androidHabitNew", "phoneGoLists", "phoneHistory", "phoneSettings",
    )

    /** Runs [id]; false for an id this build does not know. */
    fun run(id: String, shell: Shell, inboxId: String?): Boolean {
        val container = shell.container
        val navigator = shell.navigator
        when (id) {
            "taskNew" -> container.quickAdd.open(QuickAddRequest(listId = container.quickAdd.contextListId.value))
            "goToday" -> navigator.openTab(Tab.TODAY)
            "goInbox" -> navigator.openList(inboxId)
            "goEverything" -> navigator.openList(null)
            "goFocus" -> navigator.openTab(Tab.FOCUS)
            "goTimeline" -> navigator.openTab(Tab.REVIEW)
            "listNew", "folderNew", "phoneGoLists" -> {
                navigator.openTab(Tab.LISTS)
                if (id != "phoneGoLists") container.listsPrompt.request(if (id == "listNew") ListsPrompt.NEW_LIST else ListsPrompt.NEW_FOLDER)
            }
            "windowUndo" -> container.undo.undo()
            "windowRedo" -> container.undo.redo()
            "androidHabitNew" ->container.habits.open(null)
            "phoneHistory" -> shell.showHistory()
            "phoneSettings" -> navigator.openSettings()
            else -> return false
        }
        return true
    }
}
