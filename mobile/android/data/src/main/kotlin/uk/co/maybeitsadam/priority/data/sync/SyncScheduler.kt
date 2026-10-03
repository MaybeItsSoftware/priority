package uk.co.maybeitsadam.priority.data.sync

import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.runningFold
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * When to sync (port of `Sources/PrioritySync/SyncScheduler.swift`): on
 * demand, [debounce] after the last local write, and in a long-poll loop while
 * the app is in front, so another device's edit appears within a second or two.
 *
 * A ViewModel or Application calls [start] on foreground and [stop] on
 * background; [watchLocalWrites] turns outbox growth into [noteLocalChange].
 */
class SyncScheduler(
    private val engine: SyncEngine,
    private val scope: CoroutineScope,
    private val debounce: Duration = 2.seconds,
) {
    private var loop: Job? = null
    private var pending: Job? = null
    private var watcher: Job? = null
    private var failures = 0

    /** Set by a 401: the token is gone, so nothing here runs again until a new scheduler is made after signing in. */
    @Volatile
    var isSignedOut = false
        private set

    private val _lastOutcome = MutableStateFlow<SyncEngine.Outcome?>(null)

    /** The most recent successful cycle's outcome; the engine's [SyncEngine.status] carries the rest. */
    val lastOutcome: StateFlow<SyncEngine.Outcome?> = _lastOutcome.asStateFlow()

    /** Syncs now and keeps a long-poll open until [stop]. */
    @Synchronized
    fun start() {
        if (loop != null || isSignedOut) return
        loop = scope.launch {
            while (isActive) {
                val backoff = runOnce(wait = 25)
                if (backoff != null) delay(backoff)
            }
        }
    }

    /** Stops the long-poll. */
    @Synchronized
    fun stop() {
        loop?.cancel()
        loop = null
    }

    /** A local write happened: sync once things go quiet. */
    @Synchronized
    fun noteLocalChange() {
        if (isSignedOut) return
        pending?.cancel()
        pending = scope.launch {
            delay(debounce)
            flush()
        }
    }

    /** Calls [noteLocalChange] whenever the outbox grows, i.e. after every recorded local write. */
    @Synchronized
    fun watchLocalWrites(store: SyncStore) {
        if (watcher != null) return
        watcher = scope.launch {
            store.observeOutboxSize()
                .runningFold(0L to 0L) { (_, previous), size -> previous to size }
                .drop(2)
                .filter { (previous, size) -> size > previous }
                .collect { noteLocalChange() }
        }
    }

    /** One cycle, for background work or a "Sync now" button. True when it succeeded. */
    suspend fun syncNow(): Boolean = runOnce(wait = 0) == null

    /**
     * Pushes promptly. A cycle holding a long-poll would not push until the
     * poll returned, so the loop is restarted: the new cycle pushes first.
     */
    private suspend fun flush() {
        val restarted = synchronized(this) {
            if (loop != null) {
                stop()
                start()
                true
            } else {
                false
            }
        }
        if (!restarted) runOnce(wait = 0)
    }

    /** Runs a cycle; returns how long to back off before the next, or null to go straight on. */
    private suspend fun runOnce(wait: Int): Duration? = if (isSignedOut) SIGNED_OUT_PAUSE else try {
        _lastOutcome.value = engine.sync(wait)
        failures = 0
        null
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Exception) {
        failures += 1
        if (error is SyncException.Unauthorized) {
            isSignedOut = true
            pending?.cancel()
        }
        if (error is SyncException.Unauthorized || error is SyncException.NotPaired) stop()
        // 2, 4, 8 … seconds, capped at five minutes, so an outage costs nothing.
        minOf(300, 1 shl minOf(failures, 8)).seconds
    }

    private companion object {
        val SIGNED_OUT_PAUSE = 300.seconds
    }
}
