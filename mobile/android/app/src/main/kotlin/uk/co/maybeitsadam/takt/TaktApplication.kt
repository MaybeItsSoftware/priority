package uk.co.maybeitsadam.takt

import android.app.Application
import android.content.Context
import uk.co.maybeitsadam.takt.app.AppContainer
import uk.co.maybeitsadam.takt.wear.WearBridge

/** Owns the [AppContainer]; the workspace opens off the main thread as the process starts. */
class TaktApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        WearBridge.attach(container)
    }
}

/** The process's container, from any context. */
val Context.appContainer: AppContainer get() = (applicationContext as TaktApplication).container
