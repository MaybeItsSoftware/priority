package uk.co.maybeitsadam.priority

import android.app.Application
import android.content.Context
import uk.co.maybeitsadam.priority.app.AppContainer

/** Owns the [AppContainer]; the workspace opens off the main thread as the process starts. */
class PriorityApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
    }
}

/** The process's container, from any context. */
val Context.appContainer: AppContainer get() = (applicationContext as PriorityApplication).container
