package uk.co.maybeitsadam.takt.watch.data

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Node
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import uk.co.maybeitsadam.takt.wear.contract.WearActionKind
import uk.co.maybeitsadam.takt.wear.contract.WearCodec
import uk.co.maybeitsadam.takt.wear.contract.WearPaths

/**
 * The watch's end of the Data Layer: sends queued actions to the phone that
 * declares [WearPaths.PHONE_CAPABILITY], asks it for a fresh day, and reads
 * the day it last published.
 */
class PhoneLink(
    context: Context,
    private val store: WatchStore,
    private val scope: CoroutineScope,
) {
    private val capabilities = Wearable.getCapabilityClient(context)
    private val messages = Wearable.getMessageClient(context)
    private val data = Wearable.getDataClient(context)
    private val sending = Mutex()

    private val _reachable = MutableStateFlow(true)

    /** Whether the phone answered last time we tried. Starts hopeful so the first draw does not cry wolf. */
    val reachable: StateFlow<Boolean> = _reachable.asStateFlow()

    init {
        capabilities.addListener({ info ->
            _reachable.value = info.nodes.isNotEmpty()
            if (info.nodes.isNotEmpty()) scope.launch { flush() }
        }, WearPaths.PHONE_CAPABILITY)
    }

    /** Does [kind] now, as far as the watch can: drawn at once, sent when the phone is in reach. */
    fun act(kind: WearActionKind, taskId: String?) {
        store.enqueue(kind, taskId)
        scope.launch { flush() }
    }

    /** Sends whatever is queued, oldest first, stopping at the first failure. */
    suspend fun flush() {
        sending.withLock {
            if (store.queued.value.isEmpty()) return
            val node = phone() ?: return
            for (action in store.queued.value) {
                try {
                    messages.sendMessage(node.id, WearPaths.ACTION, WearCodec.encode(action)).await()
                    store.delivered(action)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    Log.w(TAG, "Couldn't send an action to the phone; it stays queued", error)
                    _reachable.value = false
                    return
                }
            }
        }
    }

    /** Asks the phone to publish its day again, and takes whatever it last published meanwhile. */
    suspend fun refresh() {
        readPublished()
        val node = phone() ?: return
        try {
            messages.sendMessage(node.id, WearPaths.REFRESH, ByteArray(0)).await()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            Log.w(TAG, "Couldn't reach the phone", error)
            _reachable.value = false
        }
        flush()
    }

    /** The Data Layer keeps the phone's last item locally, so it can be read without the phone. */
    private suspend fun readPublished() {
        try {
            val items = data.dataItems.await()
            try {
                items.firstOrNull { it.uri.path == WearPaths.TODAY }?.let { item ->
                    val bytes = DataMapItem.fromDataItem(item).dataMap.getByteArray(WearPaths.SNAPSHOT_KEY) ?: return@let
                    WearCodec.decodeSnapshot(bytes)?.let { store.receive(it) }
                }
            } finally {
                items.release()
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            Log.w(TAG, "Couldn't read the last day the phone published", error)
        }
    }

    private suspend fun phone(): Node? {
        val nodes = try {
            capabilities.getCapability(WearPaths.PHONE_CAPABILITY, CapabilityClient.FILTER_REACHABLE).await().nodes
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            Log.w(TAG, "Couldn't look for the phone", error)
            emptySet()
        }
        _reachable.value = nodes.isNotEmpty()
        return nodes.firstOrNull { it.isNearby } ?: nodes.firstOrNull()
    }

    private companion object {
        const val TAG = "PhoneLink"
    }
}
