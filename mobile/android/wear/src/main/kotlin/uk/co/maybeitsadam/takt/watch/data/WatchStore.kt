package uk.co.maybeitsadam.takt.watch.data

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import uk.co.maybeitsadam.takt.wear.contract.WearAction
import uk.co.maybeitsadam.takt.wear.contract.WearActionKind
import uk.co.maybeitsadam.takt.wear.contract.WearCodec
import uk.co.maybeitsadam.takt.wear.contract.WearSnapshot
import uk.co.maybeitsadam.takt.wear.contract.withPending

/**
 * The watch's only state: the phone's last snapshot, and the actions made
 * here that the phone has not yet reported doing. Both survive the process,
 * so the watch opens on the last day it saw and a queue made offline is still
 * there when the phone comes back.
 */
class WatchStore(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("takt_watch", Context.MODE_PRIVATE)

    private val _snapshot = MutableStateFlow(prefs.getString(KEY_SNAPSHOT, null)?.let { WearCodec.decodeSnapshot(it.encodeToByteArray()) })

    /** The phone's last snapshot, as it sent it. */
    val snapshot: StateFlow<WearSnapshot?> = _snapshot.asStateFlow()

    private val _queued = MutableStateFlow(WearCodec.decodeActions(prefs.getString(KEY_QUEUED, null) ?: "[]"))

    /** Made here, not yet delivered to the phone. */
    val queued: StateFlow<List<WearAction>> = _queued.asStateFlow()

    private val _awaiting = MutableStateFlow(WearCodec.decodeActions(prefs.getString(KEY_AWAITING, null) ?: "[]"))

    /** Delivered, but not yet in a snapshot's `handled`. */
    val awaiting: StateFlow<List<WearAction>> = _awaiting.asStateFlow()

    /** What to draw: the phone's day with everything still on its way laid over it. */
    val displayed: Flow<WearSnapshot?> = combine(_snapshot, _queued, _awaiting) { snapshot, queued, awaiting ->
        snapshot?.withPending(awaiting + queued)
    }

    /** Takes a snapshot from the phone, unless one already here is newer. True when it was taken. */
    @Synchronized
    fun receive(snapshot: WearSnapshot, now: Long = System.currentTimeMillis()): Boolean {
        val current = _snapshot.value
        if (current != null && current.generatedAt > snapshot.generatedAt) return false
        _snapshot.value = snapshot
        prefs.edit { putString(KEY_SNAPSHOT, WearCodec.encode(snapshot).decodeToString()) }
        val handled = snapshot.handled.toSet()
        // The phone forgets what it handled when its process ends, so a
        // delivered action stops being drawn after a while regardless.
        setAwaiting(_awaiting.value.filter { it.id !in handled && now - it.issuedAt < AWAITING_MILLIS })
        return true
    }

    /** Records an action made here and returns it, queued for [PhoneLink.flush]. */
    @Synchronized
    fun enqueue(kind: WearActionKind, taskId: String?, now: Long = System.currentTimeMillis()): WearAction {
        val action = WearAction(id = UUID.randomUUID().toString(), action = kind, taskId = taskId, issuedAt = now)
        setQueued(_queued.value + action)
        return action
    }

    /** [action] reached the phone: draw it until the phone says it is done. */
    @Synchronized
    fun delivered(action: WearAction) {
        setQueued(_queued.value.filterNot { it.id == action.id })
        setAwaiting(_awaiting.value + action)
    }

    private fun setQueued(actions: List<WearAction>) {
        _queued.value = actions
        prefs.edit { putString(KEY_QUEUED, WearCodec.encodeActions(actions)) }
    }

    private fun setAwaiting(actions: List<WearAction>) {
        _awaiting.value = actions
        prefs.edit { putString(KEY_AWAITING, WearCodec.encodeActions(actions)) }
    }

    private companion object {
        const val KEY_SNAPSHOT = "snapshot"
        const val KEY_QUEUED = "queued"
        const val KEY_AWAITING = "awaiting"
        const val AWAITING_MILLIS = 60_000L
    }
}
