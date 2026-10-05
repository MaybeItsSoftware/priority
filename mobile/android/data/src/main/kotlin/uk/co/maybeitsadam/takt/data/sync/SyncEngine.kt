package uk.co.maybeitsadam.takt.data.sync

import java.time.Clock
import java.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import uk.co.maybeitsadam.takt.core.HybridLogicalClock
import uk.co.maybeitsadam.takt.core.SyncIncomingRow
import uk.co.maybeitsadam.takt.core.SyncPushChange

/**
 * The client half of docs/sync.md (port of `Sources/TaktSync/SyncEngine.swift`).
 *
 * One cycle at a time: a second [sync] call waits for the first to finish
 * rather than racing it. The scheduling (foreground, 2 s after a write, a
 * long-poll loop while in front, background refresh) belongs to the caller.
 */
class SyncEngine(
    private val store: SyncStore,
    private val transport: SyncTransport,
    private val deviceId: String,
    private val wallClock: Clock = Clock.systemUTC(),
) {
    data class Outcome(val pushed: Int, val pulled: Int, val changedWorkspace: Boolean)

    sealed interface Status {
        data object Idle : Status
        data object Syncing : Status
        data class Synced(val at: Instant) : Status
        data class Failed(val message: String) : Status

        /** The server no longer knows this device's token. Retrying cannot help; the user has to sign in again. */
        data object SignedOut : Status
    }

    private val cycle = Mutex()
    private val _status = MutableStateFlow<Status>(Status.Idle)
    val status: StateFlow<Status> = _status.asStateFlow()

    /**
     * One push-then-pull cycle. The first cycle after pairing snapshots the
     * workspace and pulls first, so a device joining an account adopts it.
     * [wait] long-polls the first pull page for up to that many seconds.
     */
    suspend fun sync(wait: Int = 0): Outcome = cycle.withLock {
        val state = store.syncState() ?: throw SyncException.NotPaired()
        _status.value = Status.Syncing
        try {
            var clock = state.hlc?.let(HybridLogicalClock::parse) ?: HybridLogicalClock(0, 0, deviceId)
            var outcome = Outcome(0, 0, false)
            if (state.needsSnapshot) {
                store.enqueueSnapshot(wallClock.instant())
                pull(state.cursor, clock, 0).let { (c, o) -> clock = c; outcome = outcome.plus(o) }
                push(clock).let { (c, o) -> clock = c; outcome = outcome.plus(o) }
            } else {
                push(clock).let { (c, o) -> clock = c; outcome = outcome.plus(o) }
                val cursor = store.syncState()?.cursor ?: state.cursor
                pull(cursor, clock, wait).let { (_, o) -> outcome = outcome.plus(o) }
            }
            _status.value = Status.Synced(wallClock.instant())
            outcome
        } catch (error: SyncException.Unauthorized) {
            _status.value = Status.SignedOut
            throw error
        } catch (error: Throwable) {
            _status.value = Status.Failed(error.message ?: error.toString())
            throw error
        }
    }

    private fun Outcome.plus(other: Outcome) =
        Outcome(pushed + other.pushed, pulled + other.pulled, changedWorkspace || other.changedWorkspace)

    private suspend fun push(start: HybridLogicalClock): Pair<HybridLogicalClock, Outcome> {
        var clock = start
        var pushed = 0
        while (true) {
            val (changes, throughSeq) = store.pendingChanges(PUSH_BATCH)
            if (throughSeq == null || changes.isEmpty()) break
            // Stamped in the order the edits were made, so a later edit to a
            // column always carries the later clock.
            val wire = changes.sortedBy { it.changedAtMs }.map { change ->
                clock = clock.tick(maxOf(change.changedAtMs, wallClock.millis()))
                SyncPushChange(
                    table = change.table,
                    id = change.rowId,
                    op = change.operation.wire,
                    hlc = clock.toString(),
                    values = if (change.operation == SyncOutgoingChange.Operation.DELETE) null else change.values,
                )
            }
            transport.push(wire)
            store.acknowledge(throughSeq)
            store.recordProgress(hlc = clock.toString(), now = wallClock.instant())
            pushed += wire.size
        }
        return clock to Outcome(pushed, 0, false)
    }

    private suspend fun pull(cursor: Long, start: HybridLogicalClock, wait: Int): Pair<HybridLogicalClock, Outcome> {
        var clock = start
        val rows = mutableListOf<SyncIncomingRow>()
        var next = cursor
        var firstPage = true
        while (true) {
            val page = transport.changes(next, PULL_PAGE, if (firstPage) wait else 0)
            firstPage = false
            rows += page.rows
            next = page.cursor
            if (!page.hasMore) break
        }
        for (row in rows) {
            val stamp = row.hlc?.let(HybridLogicalClock::parse) ?: continue
            clock = clock.receiving(stamp, wallClock.millis())
        }
        // Every page lands in one transaction: a task can arrive a page before
        // its list, and only the end of the whole pull is a consistent state.
        val changed = store.applyRemoteRows(rows, next, clock.toString(), wallClock.instant())
        return clock to Outcome(0, rows.size, changed)
    }

    companion object {
        const val PUSH_BATCH = 500
        const val PULL_PAGE = 1000
    }
}
