package uk.co.maybeitsadam.priority.settings

import uk.co.maybeitsadam.priority.app.AppContainer

/**
 * Stub: the settings slice fills this in. Pairing, credentials (Keystore),
 * the scheduler's lifecycle (ProcessLifecycleOwner) and WorkManager.
 */
class SyncController(private val container: AppContainer) {
    /** Called once from the container's init, on the main thread. */
    fun attach() {
    }

    /** Pairs with a `priority-sync://pair?server=…&code=…` link (deep link, scan or paste). */
    fun pairFromLink(link: String) {
    }
}
