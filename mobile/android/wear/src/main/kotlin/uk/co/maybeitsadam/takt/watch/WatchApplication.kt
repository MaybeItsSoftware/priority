package uk.co.maybeitsadam.takt.watch

import android.app.Application
import android.content.ComponentName
import android.content.Context
import androidx.wear.tiles.TileService
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.takt.watch.complication.TodayComplicationService
import uk.co.maybeitsadam.takt.watch.data.PhoneLink
import uk.co.maybeitsadam.takt.watch.data.WatchStore
import uk.co.maybeitsadam.takt.watch.tile.TodayTileService

/** Owns the watch's store and its link to the phone for the life of the process. */
class WatchApplication : Application() {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    lateinit var store: WatchStore
        private set
    lateinit var link: PhoneLink
        private set

    override fun onCreate() {
        super.onCreate()
        store = WatchStore(this)
        link = PhoneLink(this, store, scope)
        // The tile and the complication show what the app shows, optimistic
        // actions included, so both redraw whenever that changes.
        scope.launch {
            store.displayed.map { it?.copy(generatedAt = 0) }.distinctUntilChanged().drop(1).collect { refreshGlanceables(this@WatchApplication) }
        }
    }

    companion object {
        fun refreshGlanceables(context: Context) {
            runCatching { TileService.getUpdater(context).requestUpdate(TodayTileService::class.java) }
            runCatching {
                ComplicationDataSourceUpdateRequester.create(context, ComponentName(context, TodayComplicationService::class.java)).requestUpdateAll()
            }
        }
    }
}

val Context.watch: WatchApplication get() = applicationContext as WatchApplication
