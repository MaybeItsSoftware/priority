package uk.co.maybeitsadam.takt.watch

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.material3.TimeText
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import uk.co.maybeitsadam.takt.watch.ui.FocusScreen
import uk.co.maybeitsadam.takt.watch.ui.TodayScreen
import uk.co.maybeitsadam.takt.watch.ui.WatchTheme
import uk.co.maybeitsadam.takt.wear.contract.WearActionKind
import uk.co.maybeitsadam.takt.wear.contract.WearSnapshot

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = watch
        // While on screen: a fresh day from the phone at once, then anything
        // queued retried every so often in case the phone came back quietly.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                app.link.refresh()
                while (isActive) {
                    delay(RETRY_MILLIS)
                    app.link.flush()
                }
            }
        }
        // Read once here, so the first frame draws the last day rather than nothing.
        val stored = app.store.snapshot.value
        setContent { WatchTheme { WatchApp(app, stored) } }
    }

    private companion object {
        const val RETRY_MILLIS = 15_000L
        /** How long a ticked row stays crossed out on Today before the tick is sent. */
        const val CROSS_OUT_MILLIS = 700L
    }

    @Composable
    private fun WatchApp(app: WatchApplication, stored: WearSnapshot?) {
        val snapshot by app.store.displayed.collectAsStateWithLifecycle(initialValue = stored)
        val reachable by app.link.reachable.collectAsStateWithLifecycle()
        val queued by app.store.queued.collectAsStateWithLifecycle()
        val nav = rememberSwipeDismissableNavController()
        AppScaffold(timeText = { TimeText() }) {
            SwipeDismissableNavHost(navController = nav, startDestination = TODAY) {
                composable(TODAY) {
                    TodayScreen(
                        snapshot = snapshot,
                        reachable = reachable,
                        queuedCount = queued.size,
                        onComplete = { task ->
                            app.scope.launch {
                                delay(CROSS_OUT_MILLIS)
                                app.link.act(if (task.isDaily) WearActionKind.LOG_DAILY else WearActionKind.COMPLETE, task.id)
                            }
                        },
                        onStart = { task ->
                            app.link.act(WearActionKind.START, task.id)
                            nav.navigate(FOCUS)
                        },
                        onOpenFocus = { nav.navigate(FOCUS) },
                    )
                }
                composable(FOCUS) {
                    val session = snapshot?.session
                    // The block ended (here or on the phone): back to the day.
                    LaunchedEffect(session?.taskId == null) {
                        if (session?.taskId == null && nav.currentDestination?.route == FOCUS) {
                            delay(400)
                            nav.popBackStack(TODAY, inclusive = false)
                        }
                    }
                    FocusScreen(
                        session = session,
                        title = snapshot?.runningTask?.title,
                        onPause = { app.link.act(WearActionKind.PAUSE, session?.taskId) },
                        onResume = { app.link.act(WearActionKind.RESUME, session?.taskId) },
                        onDone = { app.link.act(WearActionKind.DONE, session?.taskId) },
                        onStop = { app.link.act(WearActionKind.STOP, session?.taskId) },
                    )
                }
            }
        }
    }
}

private const val TODAY = "today"
private const val FOCUS = "focus"
