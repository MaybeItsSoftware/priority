package uk.co.maybeitsadam.takt.watch.data

import com.google.android.gms.wearable.CapabilityInfo
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.WearableListenerService
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.takt.watch.watch
import uk.co.maybeitsadam.takt.wear.contract.WearCodec
import uk.co.maybeitsadam.takt.wear.contract.WearPaths

/**
 * Started by Play Services when the phone publishes a new day or comes back
 * in reach, whether or not the app is open: the snapshot is stored and
 * anything queued is sent.
 */
class PhoneListenerService : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) {
        val app = watch
        for (event in events) {
            if (event.type != DataEvent.TYPE_CHANGED || event.dataItem.uri.path != WearPaths.TODAY) continue
            val bytes = DataMapItem.fromDataItem(event.dataItem).dataMap.getByteArray(WearPaths.SNAPSHOT_KEY) ?: continue
            WearCodec.decodeSnapshot(bytes)?.let { app.store.receive(it) }
        }
        // The phone just spoke, so it is in reach.
        app.scope.launch { app.link.flush() }
    }

    override fun onCapabilityChanged(info: CapabilityInfo) {
        if (info.name != WearPaths.PHONE_CAPABILITY || info.nodes.isEmpty()) return
        val app = watch
        app.scope.launch { app.link.flush() }
    }
}
