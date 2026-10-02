package uk.co.maybeitsadam.priority.focus

import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.updateAll
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.priority.app.AppContainer
import uk.co.maybeitsadam.priority.core.FocusContext
import uk.co.maybeitsadam.priority.widget.NextUpSummary
import uk.co.maybeitsadam.priority.widget.NextUpWidget

/**
 * Called once from [AppContainer]'s init. Watches the active focus session and
 * starts or stops [FocusService] with it, and keeps the Next up widget fresh
 * from the same snapshot the day is drawn from.
 */
object FocusServiceLauncher {
    @OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
    fun attach(container: AppContainer) {
        val context = container.context.applicationContext
        container.scope.launch {
            container.withSession { it.repository.observeActiveFocusSession() }
                .map { it.needsForegroundService() }
                .distinctUntilChanged()
                .collect { needed ->
                    val intent = Intent(context, FocusService::class.java)
                    // Starting a foreground service from the background is refused on
                    // API 31+; the next time the app is in front the session starts it.
                    runCatching {
                        if (needed) ContextCompat.startForegroundService(context, intent) else context.stopService(intent)
                    }.onFailure { Log.w("FocusServiceLauncher", "Could not change the focus service", it) }
                }
        }
        container.scope.launch {
            container.withSession { session ->
                session.repository.observeActiveFocusSession()
                    .map { it?.activeTaskId }
                    .distinctUntilChanged()
                    .flatMapLatest { runningId ->
                        session.repository.observeNextUpSnapshot(session.workspace.id, FocusContext(), runningId)
                            .map { NextUpSummary.of(it, runningId) }
                    }
            }
                .distinctUntilChanged()
                .debounce(1_000)
                .collect {
                    runCatching {
                        if (GlanceAppWidgetManager(context).getGlanceIds(NextUpWidget::class.java).isNotEmpty()) {
                            NextUpWidget().updateAll(context)
                        }
                    }
                }
        }
    }
}
