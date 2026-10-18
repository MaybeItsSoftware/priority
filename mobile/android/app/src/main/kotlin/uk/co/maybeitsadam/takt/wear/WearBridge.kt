package uk.co.maybeitsadam.takt.wear

import android.util.Log
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.CapabilityInfo
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import uk.co.maybeitsadam.takt.app.AppContainer
import uk.co.maybeitsadam.takt.core.FocusContext
import uk.co.maybeitsadam.takt.core.WorkspaceNextUpSnapshot
import uk.co.maybeitsadam.takt.data.workspace.observeBlockedTaskIds
import uk.co.maybeitsadam.takt.ui.today.DayShaping
import uk.co.maybeitsadam.takt.ui.today.DayState
import uk.co.maybeitsadam.takt.ui.today.dayTicks
import uk.co.maybeitsadam.takt.ui.today.minuteTicks
import uk.co.maybeitsadam.takt.wear.contract.WearCodec
import uk.co.maybeitsadam.takt.wear.contract.WearPaths
import uk.co.maybeitsadam.takt.wear.contract.WearSnapshot

/**
 * The phone's half of the watch companion (docs/wear-os.md). While a watch
 * with Takt on it is paired, the day as Today reads it is published as the
 * `DataItem` at [WearPaths.TODAY] whenever it changes. Actions come back
 * through [WearActionService].
 *
 * Attached once from [uk.co.maybeitsadam.takt.TaktApplication]. On a phone
 * without the Wear OS app the Data Layer is unavailable and this stays idle.
 */
object WearBridge {
    private const val TAG = "WearBridge"
    private const val HANDLED_KEPT = 20

    private val watchPresent = MutableStateFlow(false)
    private val handled = MutableStateFlow<List<String>>(emptyList())
    private val publishing = Mutex()
    private var lastPublished: WearSnapshot? = null
    private var attached: AppContainer? = null

    fun attach(container: AppContainer) {
        if (attached != null) return
        attached = container
        val capabilities = Wearable.getCapabilityClient(container.context)
        container.scope.launch {
            try {
                val info = capabilities.getCapability(WearPaths.WATCH_CAPABILITY, CapabilityClient.FILTER_ALL).await()
                watchPresent.value = info.nodes.isNotEmpty()
                capabilities.addListener({ changed: CapabilityInfo -> watchPresent.value = changed.nodes.isNotEmpty() }, WearPaths.WATCH_CAPABILITY)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (unavailable: ApiException) {
                Log.i(TAG, "No Wearable Data Layer on this phone; the watch companion is idle")
                return@launch
            } catch (error: Exception) {
                Log.w(TAG, "Couldn't look for a watch", error)
            }
            watchPresent
                .flatMapLatest { present -> if (present) snapshots(container) else emptyFlow() }
                .debounce(300)
                .collect { publish(container, it, force = false) }
        }
    }

    /** A watch spoke to the phone, so one is paired whatever the capability lookup said. */
    fun watchSeen() {
        watchPresent.value = true
    }

    fun isHandled(actionId: String): Boolean = actionId in handled.value

    /** Records that [actionId] has been applied; the next snapshot tells the watch. */
    fun markHandled(actionId: String) {
        handled.value = (handled.value + actionId).takeLast(HANDLED_KEPT)
    }

    /** Publishes the latest snapshot again with a fresh time, so the watch knows it is current. */
    fun refresh(container: AppContainer) {
        watchSeen()
        container.scope.launch {
            val latest = publishing.withLock { lastPublished } ?: return@launch
            publish(container, latest.copy(generatedAt = System.currentTimeMillis()), force = true)
        }
    }

    private fun snapshots(container: AppContainer): Flow<WearSnapshot> =
        combine(day(container), handled) { day, handledIds -> WearSnapshotShaping.of(day, handledIds, Instant.now()) }
            .distinctUntilChanged { old, new -> old.copy(generatedAt = 0) == new.copy(generatedAt = 0) }

    /** The same reads [uk.co.maybeitsadam.takt.ui.today.TodayViewModel] makes, so the watch's day is the phone's. */
    private fun day(container: AppContainer): Flow<DayState> = container.withSession { session ->
        val repo = session.repository
        val active = repo.observeActiveFocusSession()
        val snapshot = active.map { it?.activeTaskId }.distinctUntilChanged().flatMapLatest { runningId ->
            minuteTicks().flatMapLatest {
                repo.observeNextUpSnapshot(
                    session.workspace.id, FocusContext(), runningId, ladderLimit = WorkspaceNextUpSnapshot.fallbackDayLength,
                )
            }
        }
        val dailies = dayTicks().flatMapLatest { repo.observeDailies(Instant.now()) }
        combine(
            snapshot, active, dailies, repo.observeLists(session.workspace.id), repo.observeBlockedTaskIds(),
        ) { next, focusSession, daily, lists, blocked ->
            DayShaping.build(next, focusSession, daily, lists, blocked)
        }
    }.flowOn(Dispatchers.Default)

    private suspend fun publish(container: AppContainer, snapshot: WearSnapshot, force: Boolean) {
        publishing.withLock {
            val previous = lastPublished
            if (!force && previous != null && previous.copy(generatedAt = 0) == snapshot.copy(generatedAt = 0)) return
            try {
                val request = PutDataMapRequest.create(WearPaths.TODAY).apply {
                    dataMap.putByteArray(WearPaths.SNAPSHOT_KEY, WearCodec.encode(snapshot))
                }.asPutDataRequest().setUrgent()
                Wearable.getDataClient(container.context).putDataItem(request).await()
                lastPublished = snapshot
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                Log.w(TAG, "Couldn't publish the day to the watch", error)
            }
        }
    }
}
