package uk.co.maybeitsadam.takt.watch

import android.app.Application
import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import uk.co.maybeitsadam.takt.watch.data.PhoneLink
import uk.co.maybeitsadam.takt.watch.data.WatchStore

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
    }
}

val Context.watch: WatchApplication get() = applicationContext as WatchApplication
